local M = {}
local logTag = "HighBeam.Connection"

local socket = nil  -- Loaded lazily via require("socket")
local tcp = nil
local recvBuffer = ""
local HEADER_SIZE = 4  -- 4-byte LE uint32 length prefix

-- Connection states
M.STATE_DISCONNECTED    = 0
M.STATE_CONNECTING      = 1
M.STATE_AUTHENTICATING  = 2
M.STATE_CONNECTED       = 3
M.STATE_DISCONNECTING   = 4

M.state = 0  -- STATE_DISCONNECTED

M.connect = function(host, port, username, password)
  log('I', logTag, 'Connect requested: ' .. host .. ':' .. tostring(port))

  -- Load LuaSocket
  local ok, sock = pcall(require, "socket")
  if not ok then
    log('E', logTag, 'LuaSocket not available: ' .. tostring(sock))
    return
  end
  socket = sock

  M.state = M.STATE_CONNECTING
  tcp = socket.tcp()
  tcp:settimeout(0)  -- NON-BLOCKING: critical for not freezing the game

  local result, err = tcp:connect(host, port)
  -- Non-blocking connect returns nil, "timeout" immediately
  -- Must check with socket.select() on subsequent ticks
  if result or err == "timeout" then
    -- Connection in progress
    M._pendingAuth = { username = username, password = password }
  else
    log('E', logTag, 'Connect failed: ' .. tostring(err))
    M.state = M.STATE_DISCONNECTED
    tcp = nil
  end
end

M.disconnect = function()
  log('I', logTag, 'Disconnect requested')
  if tcp then
    pcall(function() tcp:close() end)
    tcp = nil
  end
  recvBuffer = ""
  M.state = M.STATE_DISCONNECTED
end

M.tick = function(dt)
  if not tcp or not socket then return end

  if M.state == M.STATE_CONNECTING then
    -- Check if TCP connect completed
    local _, writable = socket.select(nil, {tcp}, 0)
    if writable and #writable > 0 then
      -- Connected! Wait for ServerHello
      M.state = M.STATE_AUTHENTICATING
      log('I', logTag, 'TCP connected, waiting for ServerHello')
    end
  end

  if M.state == M.STATE_AUTHENTICATING or M.state == M.STATE_CONNECTED then
    -- Read available data (non-blocking)
    local data, err, partial = tcp:receive(8192)
    local chunk = data or partial
    if chunk and #chunk > 0 then
      recvBuffer = recvBuffer .. chunk
      M._processBuffer()
    end
    if err == "closed" then
      M._onDisconnect("Connection closed by server")
    end
  end
end

M._processBuffer = function()
  while #recvBuffer >= HEADER_SIZE do
    -- Read 4-byte LE length
    local b1, b2, b3, b4 = recvBuffer:byte(1, 4)
    local payloadLen = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    if payloadLen > 1048576 then
      M._onDisconnect("Packet too large")
      return
    end
    if #recvBuffer < HEADER_SIZE + payloadLen then
      break  -- Wait for more data
    end
    local json = recvBuffer:sub(HEADER_SIZE + 1, HEADER_SIZE + payloadLen)
    recvBuffer = recvBuffer:sub(HEADER_SIZE + payloadLen + 1)
    M._handlePacket(json)
  end
end

M._sendPacket = function(packetTable)
  if not tcp then return end
  local json = require("highbeam/lib/json").encode(packetTable)
  local len = #json
  local header = string.char(
    len % 256,
    math.floor(len / 256) % 256,
    math.floor(len / 65536) % 256,
    math.floor(len / 16777216) % 256
  )
  tcp:send(header .. json)
end

M._handlePacket = function(jsonStr)
  local ok, packet = pcall(function()
    return require("highbeam/lib/json").decode(jsonStr)
  end)
  if not ok or not packet then
    log('W', logTag, 'Failed to decode packet: ' .. tostring(packet))
    return
  end

  local ptype = packet.type
  if ptype == "server_hello" then
    log('I', logTag, 'Received ServerHello: ' .. tostring(packet.name))
    -- Validate protocol version
    if packet.version ~= 1 then
      log('E', logTag, 'Protocol version mismatch: ' .. tostring(packet.version))
      M.disconnect()
      return
    end
    -- Send auth request
    if M._pendingAuth then
      M._sendPacket({
        type = "auth_request",
        username = M._pendingAuth.username,
        password = M._pendingAuth.password,
      })
    end
  elseif ptype == "auth_response" then
    if packet.success then
      log('I', logTag, 'Authenticated as player ' .. tostring(packet.player_id))
      M._playerId = packet.player_id
      M._sessionToken = packet.session_token
      -- Send ready
      M._sendPacket({ type = "ready" })
      M.state = M.STATE_CONNECTED
    else
      log('E', logTag, 'Auth failed: ' .. tostring(packet.error))
      M.disconnect()
    end
  elseif ptype == "player_join" then
    log('I', logTag, 'Player joined: ' .. tostring(packet.name) .. ' (id=' .. tostring(packet.player_id) .. ')')
  elseif ptype == "player_leave" then
    log('I', logTag, 'Player left: id=' .. tostring(packet.player_id))
  elseif ptype == "kick" then
    log('W', logTag, 'Kicked: ' .. tostring(packet.reason))
    M.disconnect()
  else
    log('D', logTag, 'Unhandled packet type: ' .. tostring(ptype))
  end
end

M._onDisconnect = function(reason)
  log('I', logTag, 'Disconnected: ' .. tostring(reason))
  if tcp then
    pcall(function() tcp:close() end)
    tcp = nil
  end
  recvBuffer = ""
  M.state = M.STATE_DISCONNECTED
end

M.getState = function()
  return M.state
end

return M
