local M = {}

M.options = {
  page_size = 200,
  key_win_width = 55,
  connections_path = vim.fn.stdpath("data") .. "/redis-nvim/connections.json",
  panel = {
    width = 32,
  },
  keymaps = {
    select       = "<CR>",      -- open key value / trigger load-more
    filter       = "f",         -- prompt for new pattern
    reload       = "R",         -- reload from cursor 0
    delete       = "dd",        -- delete key under cursor
    conn_pick    = "c",         -- pick active connection (keys pane)
    conn_add     = "a",         -- add new connection
    conn_del     = "D",         -- delete connection
    panel_toggle = "<leader>e", -- toggle connection panel globally
    edit         = "e",         -- make viewer editable
    close        = "q",         -- close viewer
  },
}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.options, opts or {})
end

return M
