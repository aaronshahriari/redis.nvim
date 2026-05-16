local M = {}

-- Run a redis-cli command async.
-- conn = { host, port, db }
-- args = list of Redis command args
-- cb(err, lines) where lines is a list of strings
local function run(conn, args, cb)
  local cmd = { "redis-cli", "--no-auth-warning", "--raw", "-h", conn.host, "-p", tostring(conn.port), "-n", tostring(conn.db) }
  if conn.password then vim.list_extend(cmd, { "-a", conn.password }) end
  if conn.user     then vim.list_extend(cmd, { "--user", conn.user }) end
  vim.list_extend(cmd, args)

  local output = {}
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      vim.list_extend(output, data)
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          vim.notify("oil-redis: " .. line, vim.log.levels.WARN)
        end
      end
    end,
    on_exit = function(_, code)
      -- jobstart appends a trailing "" to buffered output
      if output[#output] == "" then table.remove(output) end
      if code ~= 0 then
        cb(string.format("redis-cli exited %d", code), nil)
      else
        cb(nil, output)
      end
    end,
  })
end

M.run = run

-- Iteratively SCAN until cursor returns to "0", collecting all matching keys.
function M.scan_all(conn, pattern, cb)
  local keys = {}
  local function step(cursor)
    run(conn, { "SCAN", cursor, "MATCH", pattern, "COUNT", "1000" }, function(err, lines)
      if err then return cb(err, nil) end
      local next_cursor = lines[1] or "0"
      for i = 2, #lines do
        if lines[i] ~= "" then
          table.insert(keys, lines[i])
        end
      end
      if next_cursor == "0" then
        cb(nil, keys)
      else
        step(next_cursor)
      end
    end)
  end
  step("0")
end

-- TYPE key
function M.get_type(conn, key, cb)
  run(conn, { "TYPE", key }, function(err, lines)
    if err then return cb(err, nil) end
    cb(nil, lines[1] or "none")
  end)
end

-- Fetch a key's value and return it as a list of display lines.
-- Supports: string, hash, list, set, zset
function M.get_value(conn, key, key_type, cb)
  if key_type == "string" then
    run(conn, { "GET", key }, function(err, lines)
      cb(err, lines or { "" })
    end)

  elseif key_type == "hash" then
    run(conn, { "HGETALL", key }, function(err, lines)
      if err then return cb(err, nil) end
      local out = {}
      for i = 1, #lines, 2 do
        local field = lines[i] or ""
        local val = lines[i + 1] or ""
        table.insert(out, field .. ": " .. val)
      end
      cb(nil, #out > 0 and out or { "" })
    end)

  elseif key_type == "list" then
    run(conn, { "LRANGE", key, "0", "-1" }, function(err, lines)
      cb(err, (lines and #lines > 0) and lines or { "" })
    end)

  elseif key_type == "set" then
    run(conn, { "SMEMBERS", key }, function(err, lines)
      cb(err, (lines and #lines > 0) and lines or { "" })
    end)

  elseif key_type == "zset" then
    run(conn, { "ZRANGE", key, "0", "-1", "WITHSCORES" }, function(err, lines)
      if err then return cb(err, nil) end
      local out = {}
      for i = 1, #lines, 2 do
        local member = lines[i] or ""
        local score = lines[i + 1] or "0"
        table.insert(out, member .. " " .. score)
      end
      cb(nil, #out > 0 and out or { "" })
    end)

  else
    cb(nil, { "(unsupported type: " .. tostring(key_type) .. ")" })
  end
end

-- Write buffer lines back to Redis, respecting the original type.
-- Returns err via cb(err).
function M.set_value(conn, key, lines, key_type, cb)
  if key_type == "string" then
    local value = table.concat(lines, "\n")
    run(conn, { "SET", key, value }, function(err, _) cb(err) end)

  elseif key_type == "hash" then
    -- Parse "field: value" lines
    local args = { "HSET", key }
    for _, line in ipairs(lines) do
      local field, val = line:match("^([^:]+):%s*(.*)$")
      if field then
        table.insert(args, vim.trim(field))
        table.insert(args, val or "")
      end
    end
    if #args == 2 then return cb(nil) end  -- nothing to set
    -- Clear existing fields first, then set new ones
    run(conn, { "DEL", key }, function(err)
      if err then return cb(err) end
      run(conn, args, function(err2, _) cb(err2) end)
    end)

  elseif key_type == "list" then
    local args = { "RPUSH", key }
    for _, line in ipairs(lines) do
      if line ~= "" then table.insert(args, line) end
    end
    run(conn, { "DEL", key }, function(err)
      if err then return cb(err) end
      if #args == 2 then return cb(nil) end
      run(conn, args, function(err2, _) cb(err2) end)
    end)

  elseif key_type == "set" then
    local args = { "SADD", key }
    for _, line in ipairs(lines) do
      if line ~= "" then table.insert(args, line) end
    end
    run(conn, { "DEL", key }, function(err)
      if err then return cb(err) end
      if #args == 2 then return cb(nil) end
      run(conn, args, function(err2, _) cb(err2) end)
    end)

  elseif key_type == "zset" then
    -- Parse "member score" lines
    local args = { "ZADD", key }
    for _, line in ipairs(lines) do
      local member, score = line:match("^(.+)%s+([%d%.%-]+)$")
      if member and score then
        table.insert(args, score)
        table.insert(args, member)
      end
    end
    run(conn, { "DEL", key }, function(err)
      if err then return cb(err) end
      if #args == 2 then return cb(nil) end
      run(conn, args, function(err2, _) cb(err2) end)
    end)

  else
    cb("Cannot write unsupported type: " .. tostring(key_type))
  end
end

return M
