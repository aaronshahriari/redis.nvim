local url_mod = require("oil-redis.url")
local redis = require("oil-redis.redis")

-- oil.constants uses numeric indices as field keys.
-- Require lazily so this module can be loaded before oil is fully set up.
local function get_constants()
  local ok, c = pcall(require, "oil.constants")
  if ok then return c end
  -- Fallback matching oil.nvim's actual constant values
  return { FIELD_NAME = 1, FIELD_TYPE = 2, FIELD_META = 3 }
end

local M = {}
M.name = "redis"

local function conn_from(parsed)
  return { host = parsed.host, port = parsed.port, db = parsed.db, user = parsed.user, password = parsed.password }
end

M.parse_url = function(url)
  return url_mod.parse(url)
end

M.normalize_url = function(url, cb)
  local parsed = url_mod.parse(url)
  cb(parsed and url_mod.build(parsed) or url)
end

M.get_parent = function(url)
  local parsed = url_mod.parse(url)
  if not parsed then return url end
  local parent = url_mod.parent_prefix(parsed.prefix)
  if parent == nil then return url end
  parsed.prefix = parent
  return url_mod.build(parsed)
end

M.is_modifiable = function(_bufnr)
  return true
end

M.get_column = function(_name)
  return nil
end

-- List a Redis namespace. Directories are first-level prefix segments (ending
-- in ":"); files are leaf keys with no further ":" after the current prefix.
M.list = function(url, _column_defs, cb)
  local parsed = url_mod.parse(url)
  if not parsed then
    return cb("oil-redis: invalid URL: " .. url)
  end

  local c = get_constants()
  local FIELD_NAME = c.FIELD_NAME
  local FIELD_TYPE = c.FIELD_TYPE

  local conn = conn_from(parsed)
  local pattern = parsed.prefix == "" and "*" or (parsed.prefix .. "*")

  redis.scan_all(conn, pattern, function(err, keys)
    if err then return cb(err) end

    local dirs = {}   -- name (including trailing ":") -> true
    local files = {}  -- name -> true

    for _, key in ipairs(keys) do
      local rest = key:sub(#parsed.prefix + 1)
      if rest == "" then goto continue end

      local colon = rest:find(":")
      if colon then
        dirs[rest:sub(1, colon)] = true  -- e.g. "user:" or "123:"
      else
        files[rest] = true
      end

      ::continue::
    end

    local entries = {}

    for name in pairs(dirs) do
      table.insert(entries, { [FIELD_NAME] = name, [FIELD_TYPE] = "directory" })
    end

    for name in pairs(files) do
      -- If there is also a directory with this name as a sub-prefix, the
      -- directory takes precedence and the leaf key is only accessible inside.
      if not dirs[name .. ":"] then
        table.insert(entries, { [FIELD_NAME] = name, [FIELD_TYPE] = "file" })
      end
    end

    table.sort(entries, function(a, b)
      if a[FIELD_TYPE] ~= b[FIELD_TYPE] then
        return a[FIELD_TYPE] == "directory"
      end
      return a[FIELD_NAME] < b[FIELD_NAME]
    end)

    cb(nil, entries)
  end)
end

-- Called by oil when opening a file buffer whose name is an oil-redis:// URL.
M.read_file = function(bufnr)
  local url = vim.api.nvim_buf_get_name(bufnr)
  local parsed = url_mod.parse(url)
  if not parsed or parsed.prefix == "" then return end

  local conn = conn_from(parsed)
  local key = parsed.prefix

  redis.get_type(conn, key, function(err, key_type)
    if err then
      vim.schedule(function()
        vim.notify("oil-redis: " .. err, vim.log.levels.ERROR)
      end)
      return
    end

    redis.get_value(conn, key, key_type, function(err2, lines)
      if err2 then
        vim.schedule(function()
          vim.notify("oil-redis: " .. err2, vim.log.levels.ERROR)
        end)
        return
      end

      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
        vim.b[bufnr].oil_redis_type = key_type
        vim.bo[bufnr].modified = false
      end)
    end)
  end)
end

-- Called by oil when the user saves a file buffer.
M.write_file = function(bufnr)
  local url = vim.api.nvim_buf_get_name(bufnr)
  local parsed = url_mod.parse(url)
  if not parsed or parsed.prefix == "" then return end

  local conn = conn_from(parsed)
  local key = parsed.prefix
  local key_type = vim.b[bufnr].oil_redis_type or "string"
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  redis.set_value(conn, key, lines, key_type, function(err)
    vim.schedule(function()
      if err then
        vim.notify("oil-redis: " .. err, vim.log.levels.ERROR)
        return
      end
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.bo[bufnr].modified = false
      end
    end)
  end)
end

M.perform_action = function(action, cb)
  local function parse_key(u)
    local p = url_mod.parse(u)
    if not p then return nil end
    return { conn = conn_from(p), key = p.prefix }
  end

  if action.type == "create" then
    local info = parse_key(action.url)
    if not info then return cb("oil-redis: invalid URL") end
    if action.entry_type == "directory" then
      -- Redis has no empty namespaces; creating one is a no-op until a key
      -- is placed inside it. Signal success without writing anything.
      cb(nil)
    else
      redis.run(info.conn, { "SET", info.key, "" }, function(err, _) cb(err) end)
    end

  elseif action.type == "delete" then
    local info = parse_key(action.url)
    if not info then return cb("oil-redis: invalid URL") end
    if action.entry_type == "directory" then
      redis.scan_all(info.conn, info.key .. "*", function(err, keys)
        if err then return cb(err) end
        if #keys == 0 then return cb(nil) end
        local args = { "DEL" }
        vim.list_extend(args, keys)
        redis.run(info.conn, args, function(err2, _) cb(err2) end)
      end)
    else
      redis.run(info.conn, { "DEL", info.key }, function(err, _) cb(err) end)
    end

  elseif action.type == "move" then
    local src = parse_key(action.src_url)
    local dst = parse_key(action.dest_url)
    if not src or not dst then return cb("oil-redis: invalid URL") end
    redis.run(src.conn, { "RENAME", src.key, dst.key }, function(err, _) cb(err) end)

  elseif action.type == "copy" then
    local src = parse_key(action.src_url)
    local dst = parse_key(action.dest_url)
    if not src or not dst then return cb("oil-redis: invalid URL") end
    -- COPY requires Redis >= 6.2; fall back to DUMP+RESTORE for older servers
    redis.run(src.conn, { "COPY", src.key, dst.key }, function(err, _)
      if not err then return cb(nil) end
      -- Fallback
      redis.run(src.conn, { "DUMP", src.key }, function(err2, lines)
        if err2 then return cb(err2) end
        local dump = lines[1] or ""
        redis.run(dst.conn, { "RESTORE", dst.key, "0", dump }, function(err3, _) cb(err3) end)
      end)
    end)

  else
    cb("oil-redis: unsupported action: " .. tostring(action.type))
  end
end

M.render_action = function(action)
  local function key(u)
    local p = url_mod.parse(u)
    return p and p.prefix or u
  end
  if action.type == "create" then
    return string.format("SET %s ''", key(action.url))
  elseif action.type == "delete" then
    return string.format("DEL %s", key(action.url))
  elseif action.type == "move" then
    return string.format("RENAME %s %s", key(action.src_url), key(action.dest_url))
  elseif action.type == "copy" then
    return string.format("COPY %s %s", key(action.src_url), key(action.dest_url))
  end
  return action.type
end

return M
