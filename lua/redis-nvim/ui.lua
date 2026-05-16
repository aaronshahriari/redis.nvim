local M = {}

local config = require("redis-nvim.config")
local redis  = require("redis-nvim.redis")
local conns  = require("redis-nvim.connections")

-- ── state ────────────────────────────────────────────────────────────────────

local state = {
  conn      = nil,   -- active connection table
  pattern   = "*",
  cursor    = "0",   -- SCAN cursor for next page
  keys      = {},    -- list of key strings loaded so far
  has_more  = false,

  keys_buf  = -1,
  keys_win  = -1,
  viewer_buf = -1,
  viewer_win = -1,

  viewer_key  = nil,
  viewer_type = nil,
}

-- ── helpers ───────────────────────────────────────────────────────────────────

local LOAD_MORE_LINE = "  ── load more ──"
local EMPTY_LINE     = "  (no keys)"

local function buf_valid(b) return b ~= -1 and vim.api.nvim_buf_is_valid(b) end
local function win_valid(w) return w ~= -1 and vim.api.nvim_win_is_valid(w) end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function winbar(win, text)
  if win_valid(win) then
    vim.wo[win].winbar = text
  end
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
  if state.has_more then
    table.insert(lines, LOAD_MORE_LINE)
  end
  set_lines(state.keys_buf, lines)

  local conn = state.conn
  local conn_label = conn
    and string.format("%s  %s:%s/db%s", conn.name, conn.host, conn.port, conn.db)
    or  "(no connection)"
  winbar(state.keys_win, string.format(
    " redis-nvim  │  %s  │  %s  │  %d keys  │  [f]filter  [R]reload  [c]conn  [a]add",
    conn_label, state.pattern, #state.keys
  ))
end

local function render_viewer(key, key_type, ttl, lines)
  if not buf_valid(state.viewer_buf) then return end

  local display = lines

  -- Auto pretty-print JSON for string values
  if key_type == "string" and #lines > 0 then
    local raw = table.concat(lines, "\n")
    local first = vim.trim(raw):sub(1, 1)
    if first == "{" or first == "[" then
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
  end

  local ttl_str = (ttl == "-1" or ttl == nil) and "no expiry" or (ttl .. "s")
  set_lines(state.viewer_buf, display)
  vim.bo[state.viewer_buf].modified = false

  winbar(state.viewer_win, string.format(
    " %s  │  %s  │  ttl: %s  │  [e]edit  [q]close",
    key, key_type, ttl_str
  ))
end

-- ── data loading ──────────────────────────────────────────────────────────────

local function load_keys()
  if not state.conn then
    vim.notify("[redis-nvim] no connection — press 'a' to add or 'c' to connect", vim.log.levels.WARN)
    return
  end
  local opts = config.options
  redis.scan(state.conn, state.cursor, state.pattern, opts.page_size, function(err, next_cursor, keys)
    vim.schedule(function()
      if err then
        vim.notify("[redis-nvim] " .. err, vim.log.levels.ERROR)
        return
      end
      vim.list_extend(state.keys, keys)
      state.cursor   = next_cursor
      state.has_more = next_cursor ~= "0"
      render_keys()
    end)
  end)
end

local function reload()
  state.cursor   = "0"
  state.keys     = {}
  state.has_more = false
  load_keys()
end

local function show_value(key)
  if not state.conn then return end
  state.viewer_key  = key
  state.viewer_type = nil

  -- Fetch type and TTL concurrently, then fetch value once both arrive
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

  redis.type(state.conn, key, function(err, t)
    key_type = err and "string" or t
    on_meta()
  end)
  redis.ttl(state.conn, key, function(err, t)
    ttl_val = err and "-1" or t
    on_meta()
  end)
end

-- ── key at cursor ─────────────────────────────────────────────────────────────

local function key_at_cursor()
  if not win_valid(state.keys_win) then return nil, false end
  local line = vim.api.nvim_win_get_cursor(state.keys_win)[1]
  if line <= #state.keys then
    return state.keys[line], false
  end
  if state.has_more and line == #state.keys + 1 then
    return nil, true  -- load-more line
  end
  return nil, false
end

-- ── connection management ─────────────────────────────────────────────────────

local function pick_connection()
  local list = conns.load()
  if #list == 0 then
    vim.notify("[redis-nvim] no connections saved — press 'a' to add one", vim.log.levels.INFO)
    return
  end
  local items = {}
  for _, c in ipairs(list) do
    table.insert(items, string.format("%-20s %s:%s  db:%s", c.name, c.host, c.port, c.db))
  end
  vim.ui.select(items, { prompt = "Redis connection:" }, function(_, idx)
    if not idx then return end
    state.conn = list[idx]
    reload()
  end)
end

local function add_connection()
  vim.ui.input({ prompt = "URI (redis://[user:pass@]host[:port][/db]): " }, function(url)
    if not url or url == "" then return end
    local parsed = conns.parse_url(url)
    if not parsed then
      vim.notify("[redis-nvim] invalid URI — expected redis://[user:pass@]host[:port][/db]", vim.log.levels.ERROR)
      return
    end
    vim.ui.input({ prompt = "Name: ", default = parsed.host }, function(name)
      if not name or name == "" then return end
      parsed.name = name
      local conn = conns.add(parsed)
      vim.notify("[redis-nvim] added: " .. conn.name, vim.log.levels.INFO)
      state.conn = conn
      reload()
    end)
  end)
end

-- ── buffer / window setup ─────────────────────────────────────────────────────

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

  map(km.select, function()
    local key, is_more = key_at_cursor()
    if is_more then
      load_keys()
    elseif key then
      show_value(key)
    end
  end)

  map(km.filter, function()
    vim.ui.input({ prompt = "Pattern: ", default = state.pattern }, function(p)
      if p == nil then return end
      state.pattern = p
      reload()
    end)
  end)

  map(km.reload, reload)

  map(km.conn_pick, pick_connection)

  map(km.conn_add, add_connection)

  map(km.delete, function()
    local key = key_at_cursor()
    if not key then return end
    vim.ui.input({ prompt = 'Delete "' .. key .. '"? (y/N): ' }, function(ans)
      if ans ~= "y" and ans ~= "Y" then return end
      redis.del(state.conn, key, function(err)
        vim.schedule(function()
          if err then
            vim.notify("[redis-nvim] " .. err, vim.log.levels.ERROR)
            return
          end
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
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_set_name(buf, "redis-nvim://viewer")

  local km = config.options.keymaps

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

  -- Write-back to Redis on :w
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
            vim.bo[buf].modified    = false
            vim.bo[buf].modifiable  = false
          end
        end)
      end)
    end,
  })

  return buf
end

-- ── open / layout ─────────────────────────────────────────────────────────────

function M.open(conn)
  -- Reuse existing windows if still valid
  local keys_alive   = buf_valid(state.keys_buf) and win_valid(state.keys_win)
  local viewer_alive = buf_valid(state.viewer_buf) and win_valid(state.viewer_win)

  if not keys_alive then
    state.keys_buf = setup_keys_buf()
    -- Open in current window
    vim.api.nvim_win_set_buf(0, state.keys_buf)
    state.keys_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(state.keys_win, config.options.key_win_width)
  end

  if not viewer_alive then
    -- Viewer is a vertical split to the right of the keys window
    vim.api.nvim_set_current_win(state.keys_win)
    vim.cmd("vsplit")
    state.viewer_buf = setup_viewer_buf()
    vim.api.nvim_win_set_buf(0, state.viewer_buf)
    state.viewer_win = vim.api.nvim_get_current_win()
    -- Return focus to keys pane
    vim.api.nvim_set_current_win(state.keys_win)
  end

  -- Set / switch connection
  if conn then
    state.conn = conn
  elseif not state.conn then
    local list = conns.load()
    state.conn = list[1]  -- pick first saved connection, if any
  end

  reload()
end

return M
