local M = {}

local function build_cmd(conn, args)
  local cmd = {
    "redis-cli", "--no-auth-warning", "--raw",
    "-h", conn.host,
    "-p", tostring(conn.port),
    "-n", tostring(conn.db),
  }
  if conn.password and conn.password ~= "" then
    vim.list_extend(cmd, { "-a", conn.password })
  end
  if conn.user and conn.user ~= "" then
    vim.list_extend(cmd, { "--user", conn.user })
  end
  vim.list_extend(cmd, args)
  return cmd
end

-- Run a redis-cli command async. cb(err, lines)
function M.run(conn, args, cb)
  local output = {}
  vim.fn.jobstart(build_cmd(conn, args), {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data) vim.list_extend(output, data) end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then vim.notify("[redis-nvim] " .. line, vim.log.levels.WARN) end
      end
    end,
    on_exit = function(_, code)
      if output[#output] == "" then table.remove(output) end
      cb(code ~= 0 and ("redis-cli exit " .. code) or nil, output)
    end,
  })
end

-- Single SCAN iteration. cb(err, next_cursor, keys)
function M.scan(conn, cursor, pattern, count, cb)
  M.run(conn, { "SCAN", tostring(cursor), "MATCH", pattern, "COUNT", tostring(count) }, function(err, lines)
    if err then return cb(err, nil, nil) end
    local next_cursor = lines[1] or "0"
    local keys = {}
    for i = 2, #lines do
      if lines[i] ~= "" then table.insert(keys, lines[i]) end
    end
    cb(nil, next_cursor, keys)
  end)
end

function M.type(conn, key, cb)
  M.run(conn, { "TYPE", key }, function(err, lines)
    cb(err, lines and lines[1] or "none")
  end)
end

function M.ttl(conn, key, cb)
  M.run(conn, { "TTL", key }, function(err, lines)
    cb(err, lines and lines[1] or "-1")
  end)
end

function M.get_value(conn, key, key_type, cb)
  if key_type == "string" then
    M.run(conn, { "GET", key }, function(err, lines) cb(err, lines or {}) end)

  elseif key_type == "hash" then
    M.run(conn, { "HGETALL", key }, function(err, lines)
      if err then return cb(err) end
      local out = {}
      for i = 1, #lines, 2 do
        table.insert(out, (lines[i] or "") .. ": " .. (lines[i + 1] or ""))
      end
      cb(nil, out)
    end)

  elseif key_type == "list" then
    M.run(conn, { "LRANGE", key, "0", "-1" }, function(err, lines) cb(err, lines or {}) end)

  elseif key_type == "set" then
    M.run(conn, { "SMEMBERS", key }, function(err, lines) cb(err, lines or {}) end)

  elseif key_type == "zset" then
    M.run(conn, { "ZRANGE", key, "0", "-1", "WITHSCORES" }, function(err, lines)
      if err then return cb(err) end
      local out = {}
      for i = 1, #lines, 2 do
        table.insert(out, (lines[i] or "") .. " " .. (lines[i + 1] or "0"))
      end
      cb(nil, out)
    end)

  elseif key_type == "ReJSON-RL" then
    M.run(conn, { "JSON.GET", key }, function(err, lines) cb(err, lines or {}) end)

  else
    cb(nil, { "(unsupported type: " .. tostring(key_type) .. ")" })
  end
end

function M.set_value(conn, key, lines, key_type, cb)
  if key_type == "string" then
    M.run(conn, { "SET", key, table.concat(lines, "\n") }, function(err) cb(err) end)

  elseif key_type == "hash" then
    local args = { "HSET", key }
    for _, line in ipairs(lines) do
      local field, val = line:match("^([^:]+):%s*(.*)$")
      if field then
        table.insert(args, vim.trim(field))
        table.insert(args, val or "")
      end
    end
    M.run(conn, { "DEL", key }, function(err)
      if err or #args == 2 then return cb(err) end
      M.run(conn, args, function(e) cb(e) end)
    end)

  elseif key_type == "list" then
    local args = { "RPUSH", key }
    for _, line in ipairs(lines) do
      if line ~= "" then table.insert(args, line) end
    end
    M.run(conn, { "DEL", key }, function(err)
      if err or #args == 2 then return cb(err) end
      M.run(conn, args, function(e) cb(e) end)
    end)

  elseif key_type == "set" then
    local args = { "SADD", key }
    for _, line in ipairs(lines) do
      if line ~= "" then table.insert(args, line) end
    end
    M.run(conn, { "DEL", key }, function(err)
      if err or #args == 2 then return cb(err) end
      M.run(conn, args, function(e) cb(e) end)
    end)

  elseif key_type == "zset" then
    local args = { "ZADD", key }
    for _, line in ipairs(lines) do
      local member, score = line:match("^(.+)%s+([%d%.%-%+eE]+)$")
      if member then
        table.insert(args, score)
        table.insert(args, member)
      end
    end
    M.run(conn, { "DEL", key }, function(err)
      if err or #args == 2 then return cb(err) end
      M.run(conn, args, function(e) cb(e) end)
    end)

  elseif key_type == "ReJSON-RL" then
    M.run(conn, { "JSON.SET", key, "$", table.concat(lines, "\n") }, function(err) cb(err) end)

  else
    cb("cannot write type: " .. tostring(key_type))
  end
end

function M.keys(conn, pattern, cb)
  M.run(conn, { "KEYS", pattern }, function(err, lines) cb(err, lines or {}) end)
end

function M.del(conn, key, cb)
  M.run(conn, { "DEL", key }, function(err) cb(err) end)
end

function M.ping(conn, cb)
  M.run(conn, { "PING" }, function(err, lines)
    cb(err, lines and lines[1])
  end)
end

return M
