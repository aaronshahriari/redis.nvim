local M = {}

local function path()
  return require("redis-nvim.config").options.connections_path
end

function M.load()
  local p = path()
  local f = io.open(p, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.fn.json_decode, content)
  return (ok and type(data) == "table") and data or {}
end

function M.save(conns)
  local p = path()
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  local f = io.open(p, "w")
  if not f then
    vim.notify("[redis-nvim] cannot write " .. p, vim.log.levels.ERROR)
    return
  end
  f:write(vim.fn.json_encode(conns))
  f:close()
end

function M.add(fields)
  -- fields: { name, host, port, db, user, password }
  local conns = M.load()
  local conn = {
    id       = tostring(os.time()) .. math.random(1000, 9999),
    name     = fields.name     or "local",
    host     = fields.host     or "localhost",
    port     = tostring(fields.port     or "6379"),
    db       = tostring(fields.db       or "0"),
    user     = (fields.user     ~= "" and fields.user)     or nil,
    password = (fields.password ~= "" and fields.password) or nil,
  }
  table.insert(conns, conn)
  M.save(conns)
  return conn
end

function M.delete(id)
  local conns = M.load()
  for i, c in ipairs(conns) do
    if c.id == id then
      table.remove(conns, i)
      break
    end
  end
  M.save(conns)
end

return M
