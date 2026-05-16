local M = {}

local DEFAULT_PORT = "6379"
local DEFAULT_DB = "0"

-- Parse oil-redis://[user:pass@][host][:port]/[db]/[key-or-prefix]
-- Directories end with ":" (e.g. "user:"), files do not (e.g. "user:123")
-- Root is represented by an empty prefix: oil-redis://host:port/db/
--
-- Auth examples:
--   oil-redis://:secret@localhost:6379/0/          password only
--   oil-redis://alice:secret@localhost:6379/0/     ACL user + password (Redis ≥ 6)
function M.parse(url)
  local rest = url:match("^oil%-redis://(.+)$")
  if not rest then return nil end

  -- Extract optional userinfo before the first "@"
  local user, password
  local at = rest:find("@", 1, true)
  if at then
    local userinfo = rest:sub(1, at - 1)
    rest = rest:sub(at + 1)
    local colon = userinfo:find(":", 1, true)
    if colon then
      user     = colon > 1            and userinfo:sub(1, colon - 1) or nil
      password = colon < #userinfo    and userinfo:sub(colon + 1)    or nil
    else
      user = userinfo ~= "" and userinfo or nil
    end
  end

  local host, port, after_host
  host, port, after_host = rest:match("^([^:/]+):(%d+)/(.*)$")
  if not host then
    host, after_host = rest:match("^([^/]+)/(.*)$")
    port = DEFAULT_PORT
  end
  if not host then return nil end

  local db, prefix = after_host:match("^(%d+)/(.*)$")
  if not db then
    db = DEFAULT_DB
    prefix = after_host
  end

  return { host = host, port = port, db = db, prefix = prefix, user = user, password = password }
end

function M.build(parsed)
  local auth = ""
  if parsed.user or parsed.password then
    auth = string.format("%s:%s@", parsed.user or "", parsed.password or "")
  end
  return string.format("oil-redis://%s%s:%s/%s/%s", auth, parsed.host, parsed.port, parsed.db, parsed.prefix)
end

-- "user:123:" -> "user:"
-- "user:"     -> ""  (root)
-- "user:123"  -> "user:"  (parent of a file)
function M.parent_prefix(prefix)
  if prefix == "" then return nil end
  local p = prefix:gsub(":$", "")    -- strip trailing colon
  local pos = p:match(".*:()")        -- position after last colon
  if pos then
    return p:sub(1, pos - 2) .. ":"  -- everything up to (not including) that colon, plus ":"
  end
  return ""                           -- first-level segment, parent is root
end

-- Convert a Redis key prefix (using ":" separator) to the URL prefix.
-- They are the same; this exists for clarity.
function M.prefix_to_redis(prefix)
  return prefix
end

return M
