local M = {}
local logTag = "HighBeam.Connection"

local socket = nil  -- Loaded lazily via require("socket")
local tcp = nil
local udp = nil
local recvBuffer = ""
local HEADER_SIZE = 4  -- 4-byte LE uint32 length prefix
local CONNECT_TIMEOUT = 5  -- 5-second connect timeout (Phase 2.1)
local PONG_TIMEOUT = 30  -- 30-second pong timeout (Phase 2.2)

-- Reconnection settings
local RECONNECT_BASE_DELAY = 2    -- Initial delay in seconds
local RECONNECT_MAX_DELAY = 30    -- Maximum delay cap in seconds
local RECONNECT_MAX_ATTEMPTS = 5  -- Give up after this many attempts

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
M._statusCallback = nil  -- Optional callback for connection status changes

-- Reconnection state
M._reconnectAttempt = 0
M._reconnectDelay = 0
M._reconnectTimer = 0
M._reconnectCredentials = nil  -- Stored {host, port, username, password} for reconnect
M._autoReconnect = false  -- Whether we should attempt reconnection

-- Player tracking
M._players = {}  -- player_id -> { name = "..." }
M._serverEventHandlers = {}  -- event_name -> callback(payload)
M._serverMap = nil  -- map path from ServerHello

-- Error tracking for diagnostics (Phase 2.4)
M._errorCount = 0
M._lastErrorTime = nil
M._droppedMalformedPackets = 0
M._lastServerPacketTime = nil
M._pendingWorldVehicles = nil
M._pendingWorldStateDeadline = nil
M._pendingWorldStateLevel = nil
M._udpFirstSeenVehicles = {}
M._udpRxCount = 0
M._udpPositionRxCount = 0
M._udpDecodeErrorCount = 0
M._udpUnexpectedCount = 0
M._tcpRxTypeCounts = {}
M._tcpTxTypeCounts = {}
M._diagTimer = 0
M._diagIntervalSec = 5.0

local function _bumpCounter(map, key)
  if not map then return end
  local k = tostring(key or "unknown")
  map[k] = (map[k] or 0) + 1
end

local function _formatCounterMap(map)
  local keys = {}
  for k, v in pairs(map or {}) do
    if v and v > 0 then
      table.insert(keys, k)
    end
  end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do
    table.insert(out, k .. '=' .. tostring(map[k]))
  end
  if #out == 0 then
    return "none"
  end
  return table.concat(out, ',')
end

M.getErrorStats = function()
  return {
    count = M._errorCount,
    lastError = M._lastErrorTime,
    droppedMalformedPackets = M._droppedMalformedPackets,
  }
end

M.getConnectionQuality = function()
  local now = os.clock()
  local sincePacket = nil
  if M._lastServerPacketTime then
    sincePacket = now - M._lastServerPacketTime
  end

  local quality = "good"
  if M.state ~= M.STATE_CONNECTED then
    quality = "disconnected"
  elseif sincePacket and sincePacket > 10 then
    quality = "poor"
  elseif sincePacket and sincePacket > 4 then
    quality = "fair"
  end

  return {
    quality = quality,
    sinceLastServerPacketSec = sincePacket,
    reconnectAttempt = M._reconnectAttempt,
    droppedMalformedPackets = M._droppedMalformedPackets,
  }
end

M.setErrorCallback = function(callback)
  M._errorCallback = callback
end

M.setStatusCallback = function(callback)
  M._statusCallback = callback
end

M._notifyStatus = function(status, detail)
  if M._statusCallback then
    pcall(M._statusCallback, status, detail)
  end
end

local function _isLoopbackHost(host)
  if not host then return false end
  local h = tostring(host):lower()
  return h == '127.0.0.1' or h == 'localhost' or h == '::1'
end

local function _normalizeLevelId(levelId)
  if not levelId or levelId == '' then return nil end
  return levelId:gsub('^/levels/', ''):gsub('/info%.json$', '')
end

local function _currentLevelNormalized()
  if not getCurrentLevelIdentifier then return nil end
  return _normalizeLevelId(getCurrentLevelIdentifier())
end

local function _spawnWorldVehicles(vehiclesList)
  if not vehicles or not vehiclesList then return end
  for _, v in ipairs(vehiclesList) do
    if vehicles.spawnRemoteFromSnapshot then
      vehicles.spawnRemoteFromSnapshot(v)
    else
      vehicles.spawnRemote(v.player_id, v.vehicle_id, v.data)
    end
  end
end

M._flushPendingWorldVehicles = function(reason)
  if not M._pendingWorldVehicles then return end
  local pending = M._pendingWorldVehicles
  M._pendingWorldVehicles = nil
  M._pendingWorldStateDeadline = nil
  M._pendingWorldStateLevel = nil
  log('I', logTag, 'Spawning deferred world vehicles count=' .. tostring(#pending)
    .. ' reason=' .. tostring(reason))
  _spawnWorldVehicles(pending)
end

M.getPlayers = function()
  return M._players
end

M.onServerEvent = function(eventName, callback)
  if not eventName or type(callback) ~= "function" then
    return false
  end
  M._serverEventHandlers[eventName] = callback
  return true
end

M.triggerServerEvent = function(eventName, payload)
  if M.state ~= M.STATE_CONNECTED then
    return false
  end
  return M._sendPacket({
    type = "trigger_server_event",
    name = eventName,
    payload = payload or ""
  })
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

-- State diagram:
-- DISCONNECTED -> CONNECTING -> AUTHENTICATING -> CONNECTED -> DISCONNECTING -> DISCONNECTED
-- CONNECTING/AUTHENTICATING can also transition directly to DISCONNECTED on failure.
local VALID_TRANSITIONS = {
  [M.STATE_DISCONNECTED] = {
    [M.STATE_CONNECTING] = true,
  },
  [M.STATE_CONNECTING] = {
    [M.STATE_AUTHENTICATING] = true,
    [M.STATE_DISCONNECTED] = true,
  },
  [M.STATE_AUTHENTICATING] = {
    [M.STATE_CONNECTED] = true,
    [M.STATE_DISCONNECTED] = true,
  },
  [M.STATE_CONNECTED] = {
    [M.STATE_DISCONNECTING] = true,
    [M.STATE_DISCONNECTED] = true,
  },
  [M.STATE_DISCONNECTING] = {
    [M.STATE_DISCONNECTED] = true,
  },
}

local STATE_NAMES = {
  [M.STATE_DISCONNECTED] = "DISCONNECTED",
  [M.STATE_CONNECTING] = "CONNECTING",
  [M.STATE_AUTHENTICATING] = "AUTHENTICATING",
  [M.STATE_CONNECTED] = "CONNECTED",
  [M.STATE_DISCONNECTING] = "DISCONNECTING",
}

M._setState = function(newState, context)
  local oldState = M.state
  if oldState == newState then
    return true
  end

  local allowed = VALID_TRANSITIONS[oldState] and VALID_TRANSITIONS[oldState][newState]
  if not allowed then
    M._reportError(
      'W',
      'state_transition',
      'Illegal transition ' .. tostring(STATE_NAMES[oldState]) .. ' -> ' .. tostring(STATE_NAMES[newState]) .. ' (' .. tostring(context) .. ') stack=' .. tostring(debug.traceback())
    )
    return false
  end

  M.state = newState
  return true
end

M.connect = function(host, port, username, password, udpPort)
  log('I', logTag, 'Connect requested: ' .. host .. ':' .. tostring(port)
    .. (udpPort and (' udpPort=' .. tostring(udpPort)) or ''))

  -- Store credentials for reconnection
  M._reconnectCredentials = { host = host, port = port, username = username, password = password, udpPort = udpPort }
  M._reconnectAttempt = 0
  M._autoReconnect = true

  -- Load LuaSocket
  local ok, sock = pcall(require, "socket")
  if not ok then
    local reason = 'LuaSocket not available: ' .. tostring(sock)
    log('E', logTag, reason)
    M._notifyStatus("connect_failed", reason)
    return false, reason
  end
  socket = sock

  if not M._setState(M.STATE_CONNECTING, "connect") then
    local reason = "Connect rejected: invalid connection state"
    log('W', logTag, reason)
    M._notifyStatus("connect_failed", reason)
    return false, reason
  end
  M._notifyStatus("connecting", host .. ":" .. tostring(port))
  tcp = socket.tcp()
  tcp:settimeout(0)  -- NON-BLOCKING: critical for not freezing the game

  -- Resolve hostname to IP (LuaSocket tcp:connect does not do DNS)
  local resolved = host
  local ip = socket.dns.toip(host)
  if ip then
    resolved = ip
    if resolved ~= host then
      log('I', logTag, 'Resolved host ' .. tostring(host) .. ' -> ' .. tostring(resolved))
    end
  end

  local result, err = tcp:connect(resolved, port)
  -- Non-blocking connect returns nil, "timeout" immediately
  -- Must check with socket.select() on subsequent ticks
  if result or err == "timeout" then
    -- Connection in progress
    M._pendingAuth = { username = username, password = password, host = host, port = port, udpPort = udpPort }
    M._connectStartTime = os.clock()  -- Track start time for timeout (Phase 2.1)
    return true
  else
    local reason = 'TCP connect failed: ' .. tostring(err)
    log('E', logTag, reason)
    M._setState(M.STATE_DISCONNECTED, "connect_failed")
    tcp = nil
    M._notifyStatus("connect_failed", reason)
    return false, reason
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
  M._autoReconnect = false  -- Manual disconnect disables reconnection
  M._reconnectAttempt = 0
  if M.state == M.STATE_DISCONNECTED then
    return
  end

  M._setState(M.STATE_DISCONNECTING, "disconnect")
  M._notifyStatus("disconnecting")

  -- Clean up all remote vehicles before closing sockets
  if vehicles then
    for pid, _ in pairs(M._players) do
      pcall(vehicles.removeAllForPlayer, pid)
    end
  end
  -- Clear local vehicle mappings
  if state and state.onDisconnect then
    pcall(state.onDisconnect)
  end

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
  M._lastPingTime = nil
  M._connectStartTime = nil
  M._serverMap = nil
  M._players = {}
  M._pendingWorldVehicles = nil
  M._pendingWorldStateDeadline = nil
  M._pendingWorldStateLevel = nil
  M._udpFirstSeenVehicles = {}
  M._udpRxCount = 0
  M._udpPositionRxCount = 0
  M._udpDecodeErrorCount = 0
  M._udpUnexpectedCount = 0
  M._tcpRxTypeCounts = {}
  M._tcpTxTypeCounts = {}
  M._diagTimer = 0
  M._setState(M.STATE_DISCONNECTED, "disconnect_complete")
  M._notifyStatus("disconnected")
end

M.tick = function(dt)
  -- Handle reconnection timer when disconnected
  if M.state == M.STATE_DISCONNECTED and M._autoReconnect and M._reconnectCredentials then
    if M._reconnectAttempt >= RECONNECT_MAX_ATTEMPTS then
      log('W', logTag, 'Reconnection failed after ' .. RECONNECT_MAX_ATTEMPTS .. ' attempts')
      M._autoReconnect = false
      M._notifyStatus("reconnect_failed")
      return
    end
    M._reconnectTimer = M._reconnectTimer - dt
    if M._reconnectTimer <= 0 then
      M._reconnectAttempt = M._reconnectAttempt + 1
      M._reconnectDelay = math.min(RECONNECT_BASE_DELAY * (2 ^ (M._reconnectAttempt - 1)), RECONNECT_MAX_DELAY)
      M._reconnectTimer = M._reconnectDelay
      log('I', logTag, 'Reconnection attempt ' .. M._reconnectAttempt .. '/' .. RECONNECT_MAX_ATTEMPTS)
      M._notifyStatus("reconnecting", "attempt " .. M._reconnectAttempt .. "/" .. RECONNECT_MAX_ATTEMPTS)
      local creds = M._reconnectCredentials
      -- Save state that connect() would reset, then restore after
      local savedAutoReconnect = M._autoReconnect
      local savedAttempt = M._reconnectAttempt
      M._autoReconnect = false
      M.connect(creds.host, creds.port, creds.username, creds.password, creds.udpPort)
      M._autoReconnect = savedAutoReconnect
      M._reconnectAttempt = savedAttempt
    end
    return
  end

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
      if M._setState(M.STATE_AUTHENTICATING, "tcp_connected") then
        log('I', logTag, 'TCP connected, waiting for ServerHello')
      else
        M._onDisconnect("Invalid state transition during connect")
        return
      end
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
    if M._pendingWorldVehicles then
      local currentLevel = _currentLevelNormalized()
      local expected = M._pendingWorldStateLevel
      local deadline = M._pendingWorldStateDeadline or 0
      if (currentLevel and expected and currentLevel == expected) or os.clock() >= deadline then
        M._flushPendingWorldVehicles((currentLevel == expected) and "map_ready" or "timeout")
      end
    end

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

    M._diagTimer = M._diagTimer + dt
    if M._diagTimer >= M._diagIntervalSec then
      M._diagTimer = 0
      local deferredCount = M._pendingWorldVehicles and #M._pendingWorldVehicles or 0
      local tcpSince = M._lastServerPacketTime and (os.clock() - M._lastServerPacketTime) or -1
      local reconnectHost = M._reconnectCredentials and M._reconnectCredentials.host or 'none'
      log('I', logTag, 'Sync diag state=' .. tostring(STATE_NAMES[M.state])
        .. ' tcpIdle=' .. string.format('%.2f', tcpSince)
        .. ' udpRx=' .. tostring(M._udpRxCount)
        .. ' udpPos=' .. tostring(M._udpPositionRxCount)
        .. ' udpDecodeErr=' .. tostring(M._udpDecodeErrorCount)
        .. ' udpUnexpected=' .. tostring(M._udpUnexpectedCount)
        .. ' deferredWorldVehicles=' .. tostring(deferredCount))
      log('I', logTag, 'Sync diag tcpRxTypes=' .. _formatCounterMap(M._tcpRxTypeCounts)
        .. ' tcpTxTypes=' .. _formatCounterMap(M._tcpTxTypeCounts)
        .. ' reconnectAttempt=' .. tostring(M._reconnectAttempt)
        .. ' reconnectHost=' .. tostring(reconnectHost))
      M._udpRxCount = 0
      M._udpPositionRxCount = 0
      M._udpDecodeErrorCount = 0
      M._udpUnexpectedCount = 0
      M._tcpRxTypeCounts = {}
      M._tcpTxTypeCounts = {}
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
  if not tcp then return false end
  if M.state ~= M.STATE_AUTHENTICATING and M.state ~= M.STATE_CONNECTED then
    M._reportError('W', 'send_packet', 'Attempted send while not authenticated/connected')
    return false
  end

  -- Encode: try BeamNG global jsonEncode first, then Engine.JSONEncode, then require("json")
  local jsonStr
  if jsonEncode then
    local ok, s = pcall(jsonEncode, packetTable)
    if ok and s then jsonStr = s end
  end
  if not jsonStr and Engine and Engine.JSONEncode then
    local ok, s = pcall(Engine.JSONEncode, packetTable)
    if ok and s then jsonStr = s end
  end
  if not jsonStr then
    local ok, jsonLib = pcall(require, "json")
    if ok and jsonLib then
      local ok2, s = pcall(jsonLib.encode, packetTable)
      if ok2 and s then jsonStr = s end
    end
  end
  if not jsonStr then
    M._reportError('E', 'send_packet', 'JSON encode failed — no encoder available')
    return false
  end

  local len = #jsonStr
  local header = string.char(
    len % 256,
    math.floor(len / 256) % 256,
    math.floor(len / 65536) % 256,
    math.floor(len / 16777216) % 256
  )
  local sent, sendErr = tcp:send(header .. jsonStr)
  if not sent then
    M._reportError('W', 'send_packet', 'TCP send failed: ' .. tostring(sendErr))
    return false
  end
  _bumpCounter(M._tcpTxTypeCounts, packetTable and packetTable.type)
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
  M._lastServerPacketTime = os.clock()
  -- Decode: try BeamNG global jsonDecode first, then Engine.JSONDecode, then require("json")
  local packet
  if jsonDecode then
    local ok, t = pcall(jsonDecode, jsonStr)
    if ok then packet = t end
  end
  if not packet and Engine and Engine.JSONDecode then
    local ok, t = pcall(Engine.JSONDecode, jsonStr)
    if ok then packet = t end
  end
  if not packet then
    local ok, jsonLib = pcall(require, "json")
    if ok and jsonLib then
      local ok2, t = pcall(jsonLib.decode, jsonStr)
      if ok2 then packet = t end
    end
  end
  if not packet then
    -- Log parse error with hex dump for debugging (Phase 2.3)
    M._reportError('W', 'packet_decode', 'Failed to decode packet: JSON decode returned nil')
    M._droppedMalformedPackets = M._droppedMalformedPackets + 1
    local hexDump = _hexDump(jsonStr)
    log('D', logTag, 'Hex dump of malformed packet: ' .. hexDump)
    -- Drop malformed payload and continue running; this is recoverable.
    M._reportError('I', 'packet_recovery', 'Dropped malformed JSON packet and continued')
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
  _bumpCounter(M._tcpRxTypeCounts, ptype)
  if ptype == "server_hello" then
    log('I', logTag, 'Received ServerHello: ' .. tostring(packet.name) .. ' map=' .. tostring(packet.map))
    M._serverMap = packet.map
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
      if not M._setState(M.STATE_CONNECTED, "auth_success") then
        M._onDisconnect("Invalid state transition after auth")
        return
      end
      M._notifyStatus("connected")
      -- Reset reconnection state on successful connect
      M._reconnectAttempt = 0
      M._reconnectTimer = 0
      M._lastPingTime = os.clock()  -- Initialize ping tracking (Phase 2.2)
      -- Bind UDP after successful auth
      if M._pendingAuth then
        -- Use proxy UDP port if provided, otherwise same as TCP port
        local udpHost = M._pendingAuth.host
        local udpPort = M._pendingAuth.udpPort or M._pendingAuth.port
        -- Wrap UDP binding in pcall - UDP is optional (Phase 2.4)
        local ok, err = pcall(function()
          M._bindUdp(udpHost, udpPort, M._sessionToken)
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
    -- Load the server's map if it differs from the current level
    local needsLoad = false
    local serverLevel = nil
    if M._serverMap then
      local currentNorm = _currentLevelNormalized()
      serverLevel = _normalizeLevelId(M._serverMap)
      needsLoad = currentNorm ~= nil and serverLevel ~= nil and currentNorm ~= serverLevel
      if currentNorm == nil and serverLevel and serverLevel ~= '' then
        needsLoad = true
      end
      if needsLoad and serverLevel ~= '' then
        log('I', logTag, 'Loading server map: ' .. serverLevel)
        if freeroam_freeroam and freeroam_freeroam.startFreeroam then
          pcall(freeroam_freeroam.startFreeroam, '/levels/' .. serverLevel .. '/info.json')
        elseif core_levels and core_levels.loadLevel then
          pcall(core_levels.loadLevel, '/levels/' .. serverLevel .. '/info.json')
        else
          log('W', logTag, 'No map loader available — player may be on wrong map')
        end
      end
    end
    -- Populate player tracking from world state
    M._players = {}
    if packet.players then
      for _, p in ipairs(packet.players) do
        if p.player_id and p.name then
          M._players[p.player_id] = { name = p.name }
        end
      end
    end
    -- Refresh mod database so newly synced mods are available for vehicle spawning
    local modMgr = (extensions and extensions.core_modmanager) or core_modmanager
    if modMgr and modMgr.initDB then
      log('I', logTag, 'Refreshing mod database before spawning vehicles')
      pcall(modMgr.initDB)
    end
    if packet.vehicles then
      if needsLoad then
        M._pendingWorldVehicles = packet.vehicles
        M._pendingWorldStateDeadline = os.clock() + 8.0
        M._pendingWorldStateLevel = serverLevel
        log('I', logTag, 'Deferring world vehicle spawn until map is ready count=' .. tostring(#packet.vehicles))
      else
        _spawnWorldVehicles(packet.vehicles)
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
        state.onLocalVehicleSpawned(packet.vehicle_id, packet.data, packet.spawn_request_id)
      end
    else
      if vehicles then
        vehicles.spawnRemote(packet.player_id, packet.vehicle_id, packet.data)
      end
    end
  elseif ptype == "vehicle_spawn_rejected" then
    if state and state.onLocalVehicleSpawnRejected then
      state.onLocalVehicleSpawnRejected(packet.spawn_request_id, packet.reason)
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
  elseif ptype == "vehicle_damage" then
    if vehicles and packet.player_id ~= M._playerId then
      vehicles.applyDamage(packet.player_id, packet.vehicle_id, packet.data)
    end
  elseif ptype == "vehicle_electrics" then
    if vehicles and packet.player_id ~= M._playerId then
      vehicles.applyElectrics(packet.player_id, packet.vehicle_id, packet.data)
    end
  elseif ptype == "vehicle_coupling" then
    if vehicles and packet.player_id ~= M._playerId then
      vehicles.applyCoupling(packet.player_id, packet.vehicle_id, packet.target_vehicle_id, packet.coupled, packet.node_id, packet.target_node_id)
    end
  elseif ptype == "server_message" then
    log('I', logTag, 'Server message: ' .. tostring(packet.text))
    local okChat, chat = pcall(require, "highbeam/chat")
    if okChat and chat and chat.systemMessage then
      pcall(chat.systemMessage, packet.text)
    end
  elseif ptype == "trigger_client_event" then
    local name = packet.name
    local payload = packet.payload
    local handler = name and M._serverEventHandlers[name]
    if handler then
      local okEvent, err = pcall(handler, payload)
      if not okEvent then
        M._reportError('W', 'client_event', 'Server event handler failed: ' .. tostring(err))
      end
    else
      log('D', logTag, 'No handler for server event: ' .. tostring(name))
    end
  elseif ptype == "player_join" then
    log('I', logTag, 'Player joined: ' .. tostring(packet.name) .. ' (id=' .. tostring(packet.player_id) .. ')')
    if packet.player_id and packet.name then
      M._players[packet.player_id] = { name = packet.name }
    end
  elseif ptype == "player_leave" then
    log('I', logTag, 'Player left: id=' .. tostring(packet.player_id))
    if packet.player_id then
      M._players[packet.player_id] = nil
    end
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
    M._notifyStatus("kicked", packet.reason or "No reason given")
    M._autoReconnect = false  -- Don't auto-reconnect after kick
    M.disconnect()
  else
    log('D', logTag, 'Unhandled packet type: ' .. tostring(ptype))
  end
end

-- Explicit test scenario helper for v0.3 hardening verification.
M.runBadJsonRecoveryScenario = function()
  if M.state == M.STATE_DISCONNECTED then
    return false, "Not connected"
  end

  local beforeState = M.state
  M._handlePacket("{bad-json-payload")

  if M.state == beforeState then
    return true, "Recovered: malformed JSON was dropped without disconnect"
  end

  return false, "State changed unexpectedly during malformed JSON recovery"
end

-- ── UDP ──────────────────────────────────────────────────────────────

M._bindUdp = function(host, port, sessionToken)
  if not socket then return end

  -- Compute session hash (SHA-256 truncated to 16 bytes)
  M._sessionHash = M._computeSessionHash(sessionToken)
  if not M._sessionHash then
    log('E', logTag, 'Cannot bind UDP: session hash computation failed (SHA-256 unavailable)')
    return
  end

  udp = socket.udp()
  udp:settimeout(0)  -- Non-blocking
  udp:setpeername(host, port)  -- Connected mode

  -- Send UdpBind packet: hash + type 0x01
  udp:send(M._sessionHash .. string.char(0x01))
  log('I', logTag, 'UDP bound to ' .. host .. ':' .. tostring(port))
end

M.sendUdp = function(data)
  if M.state ~= M.STATE_CONNECTED then
    return false
  end
  if udp then
    return udp:send(data)
  end
  return false
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
    M._udpRxCount = M._udpRxCount + 1
    if #data >= 65 and (data:byte(17) == 0x10 or data:byte(17) == 0x11) then
      -- Binary position update (0x10 legacy / 0x11 extended) — decode and dispatch
      local decoded = protocol.decodePositionUpdate(data)
      if decoded and vehicles then
        M._udpPositionRxCount = M._udpPositionRxCount + 1
        local firstKey = tostring(decoded.playerId) .. '_' .. tostring(decoded.vehicleId)
        if not M._udpFirstSeenVehicles[firstKey] then
          M._udpFirstSeenVehicles[firstKey] = true
          log('I', logTag, 'First UDP snapshot for remote vehicle ' .. firstKey)
        end
        vehicles.updateRemote(decoded)
      elseif not decoded then
        M._udpDecodeErrorCount = M._udpDecodeErrorCount + 1
      else
        -- decoded is valid but vehicles subsystem not loaded
        M._udpDecodeErrorCount = M._udpDecodeErrorCount + 1
      end
    else
      M._udpUnexpectedCount = M._udpUnexpectedCount + 1
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
  local okHash, hashHex = pcall(hashStringSHA256, token)
  if okHash and hashHex and #hashHex >= 32 then
    -- Convert first 32 hex chars (16 bytes) to binary
    local result = ""
    for i = 1, 32, 2 do
      result = result .. string.char(tonumber(hashHex:sub(i, i + 1), 16))
    end
    return result
  end
  -- hashStringSHA256 unavailable — cannot compute a valid session hash.
  -- Returning nil will prevent UDP binding; TCP still works.
  log('E', logTag, 'hashStringSHA256 unavailable — UDP will be disabled for this session')
  return nil
end

M.getSessionHash = function()
  return M._sessionHash
end

M.getPlayerId = function()
  return M._playerId
end

M._onDisconnect = function(reason)
  log('I', logTag, 'Disconnected: ' .. tostring(reason))

  -- Clean up all remote vehicles before closing sockets
  if vehicles then
    for pid, _ in pairs(M._players) do
      pcall(vehicles.removeAllForPlayer, pid)
    end
  end
  -- Clear local vehicle mappings
  if state and state.onDisconnect then
    pcall(state.onDisconnect)
  end

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
  M._serverMap = nil
  M._players = {}
  M._pendingWorldVehicles = nil
  M._pendingWorldStateDeadline = nil
  M._pendingWorldStateLevel = nil
  M._setState(M.STATE_DISCONNECTED, "remote_disconnect")
  -- Trigger auto-reconnection if enabled
  if M._autoReconnect and M._reconnectCredentials then
    M._reconnectTimer = RECONNECT_BASE_DELAY
    M._notifyStatus("reconnecting", "connection lost: " .. tostring(reason))
  else
    M._notifyStatus("disconnected", reason)
  end
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
  local reason = "Connection timeout to " .. tostring(host)
  local timedOutProxy = M._reconnectCredentials
    and _isLoopbackHost(M._reconnectCredentials.host)

  if M._onConnectFailedCallback then
    pcall(M._onConnectFailedCallback, "timeout", host)
  end

  -- Reconnecting to stale launcher proxy ports can dead-loop if we keep retrying
  -- raw localhost sockets; ask browser/launcher bridge to refresh proxy endpoints.
  if timedOutProxy then
    M._autoReconnect = false
  end

  M._notifyStatus("connect_failed", reason)
  M._onDisconnect(reason)

  if timedOutProxy then
    M._notifyStatus("proxy_reconnect_required", reason)
  end
end

return M
