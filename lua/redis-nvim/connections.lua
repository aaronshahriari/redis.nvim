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

-- Parse redis://[user:pass@]host[:port][/db]
function M.parse_url(url)
  local rest = url:match("^redis://(.+)$")
  if not rest then return nil end

  local user, password
  local at = rest:find("@", 1, true)
  if at then
    local userinfo = rest:sub(1, at - 1)
    rest = rest:sub(at + 1)
    local colon = userinfo:find(":", 1, true)
    if colon then
      user     = colon > 1         and userinfo:sub(1, colon - 1) or nil
      password = colon < #userinfo and userinfo:sub(colon + 1)    or nil
    else
      user = userinfo ~= "" and userinfo or nil
    end
  end

  local host, port, db
  host, port, db = rest:match("^([^:/]+):(%d+)/(%d+)$")
  if not host then
    host, port = rest:match("^([^:/]+):(%d+)$")
    db = "0"
  end
  if not host then
    host, db = rest:match("^([^:/]+)/(%d+)$")
    port = "6379"
  end
  if not host then
    host = rest:match("^([^:/]+)$")
    port = "6379"
    db = "0"
  end

  return {
    host     = host or "localhost",
    port     = port or "6379",
    db       = db   or "0",
    user     = user,
    password = password,
  }
end

return M
