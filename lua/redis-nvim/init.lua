local M = {}

function M.setup(opts)
  local cfg = require("redis-nvim.config")
  cfg.setup(opts)

  -- Global panel toggle keymap
  local toggle_key = cfg.options.keymaps.panel_toggle
  if toggle_key and toggle_key ~= "" then
    vim.keymap.set("n", toggle_key, function()
      require("redis-nvim.ui").toggle_panel()
    end, { noremap = true, silent = true, desc = "redis-nvim: toggle connection panel" })
  end
end

-- :Redis [name]  — open the browser, optionally switching to a named connection
vim.api.nvim_create_user_command("Redis", function(args)
  local ui   = require("redis-nvim.ui")
  local conns = require("redis-nvim.connections")

  local conn
  if args.args ~= "" then
    for _, c in ipairs(conns.load()) do
      if c.name == args.args then
        conn = c
        break
      end
    end
    if not conn then
      vim.notify("[redis-nvim] no connection named '" .. args.args .. "'", vim.log.levels.ERROR)
      return
    end
  end

  ui.open(conn)
end, {
  nargs = "?",
  complete = function()
    local names = {}
    for _, c in ipairs(require("redis-nvim.connections").load()) do
      table.insert(names, c.name)
    end
    return names
  end,
  desc = "Open redis-nvim browser",
})

return M
