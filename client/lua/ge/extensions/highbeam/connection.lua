local M = {}
local logTag = "HighBeam.Connection"

local socket = nil  -- Loaded lazily via require("socket")
local tcp = nil
local udp = nil
local recvBuffer = ""
local HEADER_SIZE = 4  -- 4-byte LE uint32 length prefix
local CONNECT_TIMEOUT = 5  -- 5-second connect timeout (Phase 2.1)
local PONG_TIMEOUT = 30  -- 30-second pong timeout (Phase 2.2)

-- Connection states
M.STATE_DISCONNECTED    = 0
M.STATE_CONNECTING      = 1
M.STATE_AUTHENTICATING  = 2
M.STATE_CONNECTED       = 3
M.STATE_DISCONNECTING   = 4

M.state = 0  -- STATE_DISCONNECTED
M._playerId = nil
M._sessionToken = nil
M._sessionHash = nil
M._lastPingTime = nil  -- Track last ping time for heartbeat (Phase 2.2)
M._connectStartTime = nil  -- Track connection start time for timeout (Phase 2.1)
M._onConnectFailedCallback = nil  -- Optional callback for connect failures
M._errorCallback = nil  -- Optional callback for runtime errors (Phase 2.4)

-- Error tracking for diagnostics (Phase 2.4)
M._errorCount = 0
M._lastErrorTime = nil

M.getErrorStats = function()
  return {
    count = M._errorCount,
    lastError = M._lastErrorTime
  }
end

M.setErrorCallback = function(callback)
  M._errorCallback = callback
end

M._reportError = function(level, context, message)
  M._errorCount = M._errorCount + 1
  M._lastErrorTime = os.clock()
  log(level or 'E', logTag, '[' .. tostring(context) .. '] ' .. tostring(message))
  if M._errorCallback then
    pcall(M._errorCallback, context, message, level)
  end
end


-- Subsystem references (set by highbeam.lua after loading)
local vehicles = nil
local state = nil

M.setSubsystems = function(v, s)
  vehicles = v
  state = s
end

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
    M._pendingAuth = { username = username, password = password, host = host, port = port }
    M._connectStartTime = os.clock()  -- Track start time for timeout (Phase 2.1)
  else
    log('E', logTag, 'Connect failed: ' .. tostring(err))
    M.state = M.STATE_DISCONNECTED
    tcp = nil
  end
end

-- Utility function to create hex dump of binary data
local function _hexDump(data, maxBytes)
  maxBytes = maxBytes or 64
  local bytes = {}
  for i = 1, math.min(#data, maxBytes) do
    table.insert(bytes, string.format("%02X", data:byte(i)))
  end
  local hex = table.concat(bytes, " ")
  if #data > maxBytes then
    hex = hex .. " ... (" .. (#data - maxBytes) .. " more bytes)"
  end
  return hex
end

M.disconnect = function()
  log('I', logTag, 'Disconnect requested')
  if tcp then
    pcall(function() tcp:close() end)
    tcp = nil
  end
  if udp then
    pcall(function() udp:close() end)
    udp = nil
  end
  recvBuffer = ""
  M._sessionHash = nil
  M._lastPingTime = nil  -- Clear ping tracking on disconnect (Phase 2.2)
  M._connectStartTime = nil  -- Clear connect timeout tracking (Phase 2.1)
  M.state = M.STATE_DISCONNECTED
end

M.tick = function(dt)
  if not tcp or not socket then return end

  if M.state == M.STATE_CONNECTING then
    -- Check for connect timeout (Phase 2.1)
    if M._connectStartTime and os.clock() - M._connectStartTime > CONNECT_TIMEOUT then
      local host = M._pendingAuth and M._pendingAuth.host or "unknown"
      log('E', logTag, 'Connection timeout after ' .. CONNECT_TIMEOUT .. 's to ' .. host)
      M._onConnectFailedTimeout(host)
      return
    end
    
    -- Check if TCP connect completed
    local _, writable = socket.select(nil, {tcp}, 0)
    if writable and #writable > 0 then
      -- Connected! Wait for ServerHello
      M._connectStartTime = nil  -- Clear timeout tracking
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
      -- Wrap buffer processing in pcall to prevent crashes (Phase 2.4)
      local ok, err = pcall(M._processBuffer)
      if not ok then
        log('E', logTag, 'Error processing buffer: ' .. tostring(err))
        M._onDisconnect("Buffer processing error: " .. tostring(err))
      end
    end
    if err == "closed" then
      M._onDisconnect("Connection closed by server")
    end
  end

  -- Tick UDP if connected
  if M.state == M.STATE_CONNECTED then
    -- Check for pong timeout (Phase 2.2)
    if M._lastPingTime and os.clock() - M._lastPingTime > PONG_TIMEOUT then
      log('W', logTag, 'Pong timeout - no heartbeat for ' .. PONG_TIMEOUT .. 's')
      M._onDisconnect("Heartbeat timeout")
      return
    end
    
    -- Wrap UDP processing in pcall to prevent crashes (Phase 2.4)
    local ok, err = pcall(M._tickUdp)
    if not ok then
      log('E', logTag, 'Error in UDP processing: ' .. tostring(err))
      -- Continue running - UDP is not critical
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
    -- Wrap packet handler in pcall to prevent crashes (Phase 2.4)
    local ok, err = pcall(function() M._handlePacket(json) end)
    if not ok then
      log('E', logTag, 'Error handling packet: ' .. tostring(err))
      M._onDisconnect("Packet handler error: " .. tostring(err))
    end
  end
end

M._sendPacket = function(packetTable)
  if not tcp then return end
  local okLib, jsonLib = pcall(require, "highbeam/lib/json")
  if not okLib or not jsonLib then
    M._reportError('E', 'send_packet', 'JSON library unavailable: ' .. tostring(jsonLib))
    return false
  end

  local okEncode, json = pcall(function()
    return jsonLib.encode(packetTable)
  end)
  if not okEncode or not json then
    M._reportError('E', 'send_packet', 'JSON encode failed: ' .. tostring(json))
    return false
  end

  local len = #json
  local header = string.char(
    len % 256,
    math.floor(len / 256) % 256,
    math.floor(len / 65536) % 256,
    math.floor(len / 16777216) % 256
  )
  local sent, sendErr = tcp:send(header .. json)
  if not sent then
    M._reportError('W', 'send_packet', 'TCP send failed: ' .. tostring(sendErr))
    return false
  end
  return true
end

-- Validate that packet has required fields (Phase 2.3)
local function _validatePacket(packet)
  if type(packet) ~= "table" then
    return false, "Packet is not a table"
  end
  if type(packet.type) ~= "string" then
    return false, "Packet missing 'type' field or type is not string"
  end
  return true
end

M._handlePacket = function(jsonStr)
  local ok, packet = pcall(function()
    return require("highbeam/lib/json").decode(jsonStr)
  end)
  if not ok or not packet then
    -- Log parse error with hex dump for debugging (Phase 2.3)
    M._reportError('W', 'packet_decode', 'Failed to decode packet (Phase 2.3): ' .. tostring(packet))
    local hexDump = _hexDump(jsonStr)
    log('D', logTag, 'Hex dump of malformed packet: ' .. hexDump)
    -- Gracefully disconnect on parse error
    M._onDisconnect("Malformed packet received (JSON parse failed)")
    return
  end

  -- Validate packet structure (Phase 2.3)
  local valid, err = _validatePacket(packet)
  if not valid then
    M._reportError('W', 'packet_validate', 'Packet validation failed: ' .. tostring(err))
    local hexDump = _hexDump(jsonStr)
    log('D', logTag, 'Hex dump: ' .. hexDump)
    M._onDisconnect("Invalid packet structure: " .. tostring(err))
    return
  end

  local ptype = packet.type
  if ptype == "server_hello" then
    log('I', logTag, 'Received ServerHello: ' .. tostring(packet.name))
    -- Validate protocol version
    if packet.version ~= 1 and packet.version ~= 2 then
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
      M._lastPingTime = os.clock()  -- Initialize ping tracking (Phase 2.2)
      -- Bind UDP after successful auth
      if M._pendingAuth then
        -- Wrap UDP binding in pcall - UDP is optional (Phase 2.4)
        local ok, err = pcall(function()
          M._bindUdp(M._pendingAuth.host, M._pendingAuth.port, M._sessionToken)
        end)
        if not ok then
          log('W', logTag, 'UDP binding failed: ' .. tostring(err))
          -- Continue without UDP - TCP is functional
        end
      end
    else
      log('E', logTag, 'Auth failed: ' .. tostring(packet.error))
      M.disconnect()
    end
  elseif ptype == "world_state" then
    log('I', logTag, 'Received WorldState: ' .. tostring(#(packet.players or {})) .. ' players, ' .. tostring(#(packet.vehicles or {})) .. ' vehicles')
    if vehicles and packet.vehicles then
      for _, v in ipairs(packet.vehicles) do
        vehicles.spawnRemote(v.player_id, v.vehicle_id, v.data)
      end
    end
    if state and packet.players then
      state.onWorldState(packet.players)
    end
  elseif ptype == "vehicle_spawn" then
    log('I', logTag, 'VehicleSpawn: player=' .. tostring(packet.player_id) .. ' vid=' .. tostring(packet.vehicle_id))
    if packet.player_id == M._playerId then
      -- Server assigned ID for our vehicle
      if state then
        state.onLocalVehicleSpawned(packet.vehicle_id, packet.data)
      end
    else
      if vehicles then
        vehicles.spawnRemote(packet.player_id, packet.vehicle_id, packet.data)
      end
    end
  elseif ptype == "vehicle_edit" then
    if vehicles and packet.player_id ~= M._playerId then
      vehicles.updateRemoteConfig(packet.player_id, packet.vehicle_id, packet.data)
    end
  elseif ptype == "vehicle_delete" then
    if vehicles and packet.player_id ~= M._playerId then
      vehicles.removeRemote(packet.player_id, packet.vehicle_id)
    end
  elseif ptype == "vehicle_reset" then
    if vehicles and packet.player_id ~= M._playerId then
      vehicles.resetRemote(packet.player_id, packet.vehicle_id, packet.data)
    end
  elseif ptype == "player_join" then
    log('I', logTag, 'Player joined: ' .. tostring(packet.name) .. ' (id=' .. tostring(packet.player_id) .. ')')
  elseif ptype == "player_leave" then
    log('I', logTag, 'Player left: id=' .. tostring(packet.player_id))
    if vehicles then
      vehicles.removeAllForPlayer(packet.player_id)
    end
  elseif ptype == "chat_broadcast" then
    local okChat, chat = pcall(require, "highbeam/chat")
    if okChat and chat then
      local okReceive, receiveErr = pcall(function()
        chat.receive(packet.player_id, packet.player_name, packet.text)
      end)
      if not okReceive then
        M._reportError('W', 'chat_receive', 'Chat receive failed: ' .. tostring(receiveErr))
      else
        log('I', logTag, 'Chat [' .. packet.player_name .. ']: ' .. packet.text)
      end
    else
      M._reportError('W', 'chat_require', 'Chat module unavailable: ' .. tostring(chat))
    end
  elseif ptype == "ping_pong" then
    log('D', logTag, 'Received PingPong: seq=' .. tostring(packet.seq))
    M._lastPingTime = os.clock()  -- Update last ping time (Phase 2.2)
    -- Send pong response immediately
    M._sendPacket({
      type = "ping_pong",
      seq = packet.seq
    })
  elseif ptype == "kick" then
    log('W', logTag, 'Kicked: ' .. tostring(packet.reason))
    M.disconnect()
  else
    log('D', logTag, 'Unhandled packet type: ' .. tostring(ptype))
  end
end

-- ── UDP ──────────────────────────────────────────────────────────────

M._bindUdp = function(host, port, sessionToken)
  if not socket then return end
  udp = socket.udp()
  udp:settimeout(0)  -- Non-blocking
  udp:setpeername(host, port)  -- Connected mode

  -- Compute session hash (SHA-256 truncated to 16 bytes)
  M._sessionHash = M._computeSessionHash(sessionToken)

  -- Send UdpBind packet: hash + type 0x01
  udp:send(M._sessionHash .. string.char(0x01))
  log('I', logTag, 'UDP bound to ' .. host .. ':' .. tostring(port))
end

M.sendUdp = function(data)
  if udp then udp:send(data) end
end

-- Send a TCP packet (for chat, commands, etc.)
M.send = function(packetType, data)
  if M.state ~= M.STATE_CONNECTED then
    log('W', logTag, 'Cannot send packet: not connected')
    return false
  end
  
  local packet = data or {}
  packet.type = packetType
  return M._sendPacket(packet)
end

M._tickUdp = function()
  if not udp then return end
  local okProtocol, protocol = pcall(require, "highbeam/protocol")
  if not okProtocol or not protocol then
    M._reportError('W', 'udp_protocol', 'Protocol module unavailable: ' .. tostring(protocol))
    return
  end
  -- Read all available UDP packets (non-blocking)
  while true do
    local data = udp:receive()
    if not data then break end
    if #data >= 65 and data:byte(17) == 0x10 then
      -- Binary position update — decode and dispatch
      local decoded = protocol.decodePositionUpdate(data)
      if decoded and vehicles then
        vehicles.updateRemote(decoded)
      end
    end
  end
end

M._computeSessionHash = function(token)
  -- SHA-256 of the session token, truncated to 16 bytes
  -- Use a simple hash since we can't depend on external crypto in BeamNG Lua
  -- This matches the server's sha2::Sha256 truncated to 16 bytes
  local hash = {}
  local tokenBytes = { token:byte(1, #token) }
  -- Portable SHA-256 implementation (standard FIPS 180-4)
  -- For BeamNG, we use the built-in hashStringSHA256 if available
  local hashHex = hashStringSHA256(token)
  if hashHex then
    -- Convert first 32 hex chars (16 bytes) to binary
    local result = ""
    for i = 1, 32, 2 do
      result = result .. string.char(tonumber(hashHex:sub(i, i + 1), 16))
    end
    return result
  end
  -- Fallback: use token bytes directly (padded/truncated to 16)
  local result = token
  while #result < 16 do result = result .. "\0" end
  return result:sub(1, 16)
end

M.getSessionHash = function()
  return M._sessionHash
end

M.getPlayerId = function()
  return M._playerId
end

M._onDisconnect = function(reason)
  log('I', logTag, 'Disconnected: ' .. tostring(reason))
  if tcp then
    pcall(function() tcp:close() end)
    tcp = nil
  end
  if udp then
    pcall(function() udp:close() end)
    udp = nil
  end
  recvBuffer = ""
  M._sessionHash = nil
  M._lastPingTime = nil  -- Clear ping tracking on disconnect (Phase 2.2)
  M.state = M.STATE_DISCONNECTED
end

M.getState = function()
  return M.state
end

M.setOnConnectFailedCallback = function(callback)
  -- Allow UI or other subsystems to handle connect failures (Phase 2.1)
  M._onConnectFailedCallback = callback
end

M._onConnectFailedTimeout = function(host)
  -- Handle connection timeout (Phase 2.1)
  if M._onConnectFailedCallback then
    pcall(M._onConnectFailedCallback, "timeout", host)
  end
  M.disconnect()
end

return M
