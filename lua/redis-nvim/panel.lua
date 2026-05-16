local M = {}

local state = {
  buf      = -1,
  win      = -1,
  prev_win = -1,
  line_map = {},   -- line number (1-based) -> connection table
}

local NS = vim.api.nvim_create_namespace("redis-nvim-panel")

local function buf_valid() return state.buf ~= -1 and vim.api.nvim_buf_is_valid(state.buf) end
local function win_valid() return state.win ~= -1 and vim.api.nvim_win_is_valid(state.win) end

local function setup_hl()
  vim.api.nvim_set_hl(0, "RedisNvimPanelTitle",  { default = true, bold = true, link = "Title" })
  vim.api.nvim_set_hl(0, "RedisNvimPanelSep",    { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "RedisNvimPanelActive", { default = true, link = "DiagnosticOk" })
end

-- Render panel contents. active_conn may be nil.
function M.render(active_conn)
  if not buf_valid() then return end

  local width  = require("redis-nvim.config").options.panel.width
  local conns  = require("redis-nvim.connections").load()
  local lines  = { " Connections", " " .. string.rep("─", width - 2) }
  local lmap   = {}

  if #conns == 0 then
    table.insert(lines, "  (none — press 'a' to add)")
  else
    for _, c in ipairs(conns) do
      local active = active_conn and c.id == active_conn.id
      table.insert(lines, (active and " ✓  " or "    ") .. c.name)
      lmap[#lines] = c
    end
  end

  table.insert(lines, "")
  table.insert(lines, "  <CR> connect   a add")
  table.insert(lines, "  D    delete   cw edit")

  state.line_map = lmap

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
  vim.api.nvim_buf_add_highlight(state.buf, NS, "RedisNvimPanelTitle", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(state.buf, NS, "RedisNvimPanelSep",   1, 0, -1)

  for line, c in pairs(lmap) do
    if active_conn and c.id == active_conn.id then
      vim.api.nvim_buf_add_highlight(state.buf, NS, "RedisNvimPanelActive", line - 1, 0, -1)
    end
  end
end

local function conn_at_cursor()
  if not win_valid() then return nil end
  local line = vim.api.nvim_win_get_cursor(state.win)[1]
  return state.line_map[line]
end

local function setup_buf(on_select, on_add, on_delete, on_edit)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].swapfile   = false
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_set_name(buf, "redis-nvim://panel")

  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, noremap = true, silent = true })
  end

  map("<CR>", function()
    local c = conn_at_cursor()
    if c then on_select(c) end
  end)

  map("a", on_add)

  map("D", function()
    local c = conn_at_cursor()
    if not c then return end
    vim.ui.input({ prompt = 'Delete "' .. c.name .. '"? (y/N): ' }, function(ans)
      if ans == "y" or ans == "Y" then on_delete(c) end
    end)
  end)

  map("cw", function()
    local c = conn_at_cursor()
    if c then on_edit(c) end
  end)

  map("q", M.close)

  return buf
end

function M.open(active_conn, on_select, on_add, on_delete, on_edit)
  if win_valid() then return end

  setup_hl()
  state.prev_win = vim.api.nvim_get_current_win()

  if not buf_valid() then
    state.buf = setup_buf(on_select, on_add, on_delete, on_edit)
  end

  local width = require("redis-nvim.config").options.panel.width
  vim.cmd("topleft " .. width .. "vsplit")
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, state.buf)

  vim.wo[state.win].number         = false
  vim.wo[state.win].relativenumber = false
  vim.wo[state.win].signcolumn     = "no"
  vim.wo[state.win].wrap           = false
  vim.wo[state.win].winfixwidth    = true
  vim.wo[state.win].cursorline     = true

  M.render(active_conn)

  -- Start cursor on first real connection (line 3)
  local first = math.min(3, vim.api.nvim_buf_line_count(state.buf))
  vim.api.nvim_win_set_cursor(state.win, { first, 0 })

  -- Return focus to where the user was
  if vim.api.nvim_win_is_valid(state.prev_win) then
    vim.api.nvim_set_current_win(state.prev_win)
  end
end

function M.close()
  if win_valid() then
    vim.api.nvim_win_close(state.win, true)
    state.win = -1
  end
  if vim.api.nvim_win_is_valid(state.prev_win) then
    vim.api.nvim_set_current_win(state.prev_win)
  end
end

function M.is_open() return win_valid() end

function M.toggle(active_conn, on_select, on_add, on_delete, on_edit)
  if M.is_open() then
    M.close()
  else
    M.open(active_conn, on_select, on_add, on_delete, on_edit)
  end
end

return M
