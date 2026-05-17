local M = {}

local config = require("redis-nvim.config")
local redis  = require("redis-nvim.redis")
local conns  = require("redis-nvim.connections")
local panel  = require("redis-nvim.panel")

-- ── state ────────────────────────────────────────────────────────────────────

local state = {
  conn      = nil,
  pattern   = "*",
  cursor    = "0",
  keys      = {},
  seen_keys = {},      -- dedup set: key -> true
  has_more  = false,
  loading   = false,   -- guard against concurrent scans

  keys_buf   = -1,
  keys_win   = -1,
  viewer_buf = -1,
  viewer_win = -1,

  viewer_key  = nil,
  viewer_type = nil,
}

-- ── helpers ───────────────────────────────────────────────────────────────────

local LOAD_MORE_LINE = "  ── load more ──"
local EMPTY_LINE     = "  (no keys)"

local uv = vim.uv or vim.loop

-- ── helpers ───────────────────────────────────────────────────────────────────

local function buf_valid(b) return b ~= -1 and vim.api.nvim_buf_is_valid(b) end
local function win_valid(w) return w ~= -1 and vim.api.nvim_win_is_valid(w) end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function winbar(win, text)
  if not win_valid(win) then return end
  pcall(vim.api.nvim_set_option_value, "winbar", text, { win = win })
end

-- ── spinner ───────────────────────────────────────────────────────────────────

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local spinner = { timer = nil, idx = 1 }

local function conn_label()
  local c = state.conn
  return c and c.name or "(no connection)"
end

local function spinner_winbar_text(frame)
  return string.format(" %s · %s · %s", conn_label(), state.pattern, frame)
end

local function spinner_start()
  if spinner.timer then return end
  spinner.idx = 1
  spinner.timer = uv.new_timer()
  spinner.timer:start(0, 80, vim.schedule_wrap(function()
    if not spinner.timer then return end
    spinner.idx = (spinner.idx % #SPINNER_FRAMES) + 1
    winbar(state.keys_win, spinner_winbar_text(SPINNER_FRAMES[spinner.idx]))
  end))
end

local function spinner_stop()
  if not spinner.timer then return end
  spinner.timer:stop()
  spinner.timer:close()
  spinner.timer = nil
end

-- ── connection helpers ────────────────────────────────────────────────────────

local function set_conn(conn)
  state.conn = conn
  panel.render(state.conn)
  winbar(state.keys_win, string.format(" %s · %s · %d keys", conn_label(), state.pattern, #state.keys))
end

local function reload()
  state.cursor    = "0"
  state.keys      = {}
  state.seen_keys = {}
  state.has_more  = false
  state.loading   = false
  require("redis-nvim.ui")._load_keys()
end

-- ── rendering ─────────────────────────────────────────────────────────────────

local function render_keys()
  if not buf_valid(state.keys_buf) then return end

  local lines = {}
  if #state.keys == 0 then
    table.insert(lines, EMPTY_LINE)
  else
    for _, k in ipairs(state.keys) do
      table.insert(lines, "  " .. k)
    end
  end
  if state.has_more then table.insert(lines, LOAD_MORE_LINE) end
  set_lines(state.keys_buf, lines)

  spinner_stop()
  winbar(state.keys_win, string.format(" %s · %s · %d keys", conn_label(), state.pattern, #state.keys))
end

local function render_viewer(key, key_type, ttl, lines)
  if not buf_valid(state.viewer_buf) then return end

  local display = lines

  local is_json = key_type == "ReJSON-RL"
    or (key_type == "string" and #lines > 0
        and vim.trim(table.concat(lines, "\n")):sub(1, 1):match("[%[{]"))

  if is_json and #lines > 0 then
    local raw = table.concat(lines, "\n")
    if vim.fn.executable("jq") == 1 then
      local pretty = vim.fn.system("jq .", raw)
      if vim.v.shell_error == 0 then
        display = vim.split(vim.trim(pretty), "\n")
      end
    end
    vim.schedule(function()
      if buf_valid(state.viewer_buf) then
        vim.bo[state.viewer_buf].filetype = "json"
      end
    end)
  end

  local ttl_str = (ttl == "-1" or ttl == nil) and "no expiry" or (ttl .. "s")
  set_lines(state.viewer_buf, display)
  vim.bo[state.viewer_buf].modified = false
  winbar(state.viewer_win, string.format(" %s · %s · ttl: %s", key, key_type, ttl_str))
end

-- ── data loading ──────────────────────────────────────────────────────────────

local function load_keys()
  if not state.conn then
    vim.notify("[redis-nvim] no connection — press <leader>e then 'a' to add one", vim.log.levels.WARN)
    return
  end
  if state.loading then return end
  state.loading = true

  spinner_start()

  -- SCAN with a specific pattern may return 0 results per iteration even when
  -- matches exist (Redis scans a fixed number of slots, not keys). Keep going
  -- until we collect at least one new result or the cursor wraps back to 0.
  local function do_scan(cursor)
    redis.scan(state.conn, cursor, state.pattern, config.options.page_size,
      function(err, next_cursor, keys)
        vim.schedule(function()
          if err then
            spinner_stop()
            state.loading = false
            vim.notify("[redis-nvim] " .. err, vim.log.levels.ERROR)
            return
          end
          for _, k in ipairs(keys) do
            if not state.seen_keys[k] then
              state.seen_keys[k] = true
              table.insert(state.keys, k)
            end
          end
          state.cursor   = next_cursor
          state.has_more = next_cursor ~= "0"

          if #keys == 0 and state.has_more then
            -- No matches yet but more slots to scan — continue without rendering
            do_scan(next_cursor)
          else
            state.loading = false
            render_keys()
          end
        end)
      end)
  end

  do_scan(state.cursor)
end

-- Exposed so reload() can call it via require (avoids forward-ref issue)
M._load_keys = load_keys

local function show_value(key)
  if not state.conn then return end
  state.viewer_key  = key
  state.viewer_type = nil

  local key_type, ttl_val, pending = nil, nil, 2
  local function on_meta()
    pending = pending - 1
    if pending > 0 then return end
    redis.get_value(state.conn, key, key_type, function(err, lines)
      vim.schedule(function()
        if err then
          vim.notify("[redis-nvim] " .. err, vim.log.levels.ERROR)
          return
        end
        state.viewer_type = key_type
        render_viewer(key, key_type, ttl_val, lines)
      end)
    end)
  end

  redis.type(state.conn, key, function(err, t)  key_type = err and "string" or t; on_meta() end)
  redis.ttl(state.conn,  key, function(err, t)  ttl_val  = err and "-1"     or t; on_meta() end)
end

-- ── key at cursor ─────────────────────────────────────────────────────────────

local function key_at_cursor()
  if not win_valid(state.keys_win) then return nil, false end
  local line = vim.api.nvim_win_get_cursor(state.keys_win)[1]
  if line <= #state.keys then return state.keys[line], false end
  if state.has_more and line == #state.keys + 1 then return nil, true end
  return nil, false
end

-- ── connection management ─────────────────────────────────────────────────────

local function add_connection()
  vim.ui.input({ prompt = "URI (redis://[user:pass@]host[:port][/db]): " }, function(url)
    if not url or url == "" then return end
    local parsed = conns.parse_url(url)
    if not parsed then
      vim.notify("[redis-nvim] invalid URI", vim.log.levels.ERROR)
      return
    end
    vim.ui.input({ prompt = "Name: ", default = parsed.host }, function(name)
      if not name or name == "" then return end
      parsed.name = name
      local conn = conns.add(parsed)
      vim.notify("[redis-nvim] added: " .. conn.name, vim.log.levels.INFO)
      set_conn(conn)
      reload()
    end)
  end)
end

local function edit_connection(conn)
  vim.ui.input({ prompt = "New URI (blank to keep current): " }, function(url)
    if not url or url == "" then return end
    local parsed = conns.parse_url(url)
    if not parsed then
      vim.notify("[redis-nvim] invalid URI", vim.log.levels.ERROR)
      return
    end
    vim.ui.input({ prompt = "Name: ", default = conn.name }, function(name)
      if not name or name == "" then return end
      -- Delete old, add new
      conns.delete(conn.id)
      parsed.name = name
      local new_conn = conns.add(parsed)
      vim.notify("[redis-nvim] updated: " .. new_conn.name, vim.log.levels.INFO)
      if state.conn and state.conn.id == conn.id then
        set_conn(new_conn)
        reload()
      else
        panel.render(state.conn)
      end
    end)
  end)
end

local function delete_connection(conn)
  conns.delete(conn.id)
  vim.notify("[redis-nvim] deleted connection: " .. conn.name, vim.log.levels.INFO)
  if state.conn and state.conn.id == conn.id then
    local list = conns.load()
    set_conn(list[1])  -- nil if empty
    reload()
  else
    panel.render(state.conn)
  end
end

-- ── panel toggle ──────────────────────────────────────────────────────────────

function M.toggle_panel()
  panel.toggle(state.conn,
    function(conn) set_conn(conn); reload() end,  -- on_select
    add_connection,                                 -- on_add
    delete_connection,                              -- on_delete
    edit_connection)                                -- on_edit (cw)
end

-- ── buffer setup ─────────────────────────────────────────────────────────────

local function setup_keys_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].swapfile   = false
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_set_name(buf, "redis-nvim://keys")

  local km = config.options.keymaps
  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, noremap = true, silent = true })
  end

  if km.panel_toggle and km.panel_toggle ~= "" then
    map(km.panel_toggle, function() M.toggle_panel() end)
  end

  map(km.select, function()
    local key, is_more = key_at_cursor()
    if is_more   then load_keys()
    elseif key   then show_value(key) end
  end)

  map(km.filter, function()
    vim.ui.input({ prompt = "Pattern: ", default = state.pattern }, function(p)
      if p == nil then return end
      state.pattern = p
      reload()
    end)
  end)

  map(km.reload, reload)

  map(km.conn_add, add_connection)

  -- 'c' still works as a quick pick from the keys pane
  map(km.conn_pick, function()
    local list = conns.load()
    if #list == 0 then
      vim.notify("[redis-nvim] no connections — press 'a' to add one", vim.log.levels.INFO)
      return
    end
    local items = {}
    for _, c in ipairs(list) do
      table.insert(items, string.format("%-20s %s:%s  db:%s", c.name, c.host, c.port, c.db))
    end
    vim.ui.select(items, { prompt = "Redis connection:" }, function(_, idx)
      if not idx then return end
      set_conn(list[idx])
      reload()
    end)
  end)

  map(km.delete, function()
    local key = key_at_cursor()
    if not key then return end
    vim.ui.input({ prompt = 'Delete key "' .. key .. '"? (y/N): ' }, function(ans)
      if ans ~= "y" and ans ~= "Y" then return end
      redis.del(state.conn, key, function(err)
        vim.schedule(function()
          if err then vim.notify("[redis-nvim] " .. err, vim.log.levels.ERROR); return end
          for i, k in ipairs(state.keys) do
            if k == key then table.remove(state.keys, i); break end
          end
          render_keys()
          vim.notify("[redis-nvim] deleted " .. key, vim.log.levels.INFO)
        end)
      end)
    end)
  end)

  return buf
end

local function setup_viewer_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].swapfile   = false
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_set_name(buf, "redis-nvim://viewer")

  local km = config.options.keymaps

  if km.panel_toggle and km.panel_toggle ~= "" then
    vim.keymap.set("n", km.panel_toggle, function() M.toggle_panel() end,
      { buffer = buf, noremap = true, silent = true })
  end

  vim.keymap.set("n", km.edit, function()
    vim.bo[buf].modifiable = true
    vim.notify("[redis-nvim] editing — :w to save, u to undo", vim.log.levels.INFO)
  end, { buffer = buf, noremap = true, silent = true })

  vim.keymap.set("n", km.close, function()
    if win_valid(state.viewer_win) then
      vim.api.nvim_win_close(state.viewer_win, true)
      state.viewer_win = -1
    end
  end, { buffer = buf, noremap = true, silent = true })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      if not state.viewer_key or not state.viewer_type or not state.conn then return end
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      redis.set_value(state.conn, state.viewer_key, lines, state.viewer_type, function(err)
        vim.schedule(function()
          if err then
            vim.notify("[redis-nvim] save failed: " .. err, vim.log.levels.ERROR)
          else
            vim.notify("[redis-nvim] saved " .. state.viewer_key, vim.log.levels.INFO)
            vim.bo[buf].modified   = false
            vim.bo[buf].modifiable = false
          end
        end)
      end)
    end,
  })

  return buf
end

-- ── open / layout ─────────────────────────────────────────────────────────────

function M.open(conn)
  local keys_alive   = buf_valid(state.keys_buf)   and win_valid(state.keys_win)
  local viewer_alive = buf_valid(state.viewer_buf)  and win_valid(state.viewer_win)

  if not keys_alive then
    state.keys_buf = setup_keys_buf()
    vim.api.nvim_win_set_buf(0, state.keys_buf)
    state.keys_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(state.keys_win, config.options.key_win_width)
  end

  if not viewer_alive then
    vim.api.nvim_set_current_win(state.keys_win)
    vim.cmd("vsplit")
    state.viewer_buf = setup_viewer_buf()
    vim.api.nvim_win_set_buf(0, state.viewer_buf)
    state.viewer_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(state.keys_win)
  end

  if conn then
    set_conn(conn)
  elseif not state.conn then
    set_conn(conns.load()[1])
  end

  reload()
end

return M
