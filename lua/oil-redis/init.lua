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
-- Uses oil's fetch_more pagination so the first SCAN batch appears immediately.
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
  local prefix_len = #parsed.prefix

  -- Track across all batches so we never emit the same entry twice and so
  -- directories always win over files with the same base name.
  local seen = {}  -- entry name -> "directory" | "file"

  local function process_batch(cursor, batch_cb)
    redis.run(conn, { "SCAN", cursor, "MATCH", pattern, "COUNT", "200" }, function(err, lines)
      if err then return batch_cb(err) end

      local next_cursor = lines[1] or "0"
      local entries = {}

      for i = 2, #lines do
        local key = lines[i]
        if key == "" then goto continue end

        local rest = key:sub(prefix_len + 1)
        if rest == "" then goto continue end

        local colon = rest:find(":")
        if colon then
          local name = rest:sub(1, colon)   -- e.g. "rjbank_kb_v1:"
          if not seen[name] then
            seen[name] = "directory"
            -- Prevent the bare name from being emitted as a file later
            seen[name:sub(1, -2)] = "skip"
            table.insert(entries, { [FIELD_NAME] = name, [FIELD_TYPE] = "directory" })
          end
        else
          if not seen[rest] then
            seen[rest] = "file"
            table.insert(entries, { [FIELD_NAME] = rest, [FIELD_TYPE] = "file" })
          end
        end

        ::continue::
      end

      table.sort(entries, function(a, b)
        if a[FIELD_TYPE] ~= b[FIELD_TYPE] then return a[FIELD_TYPE] == "directory" end
        return a[FIELD_NAME] < b[FIELD_NAME]
      end)

      local fetch_more
      if next_cursor ~= "0" then
        fetch_more = function(more_cb) process_batch(next_cursor, more_cb) end
      end

      batch_cb(nil, entries, fetch_more)
    end)
  end

  process_batch("0", cb)
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
