-- HighBeam Browser — in-game server browser, favorites, recents, and direct connect
-- v0.8.0: community node discovery mesh replaces relay URL; server IDs used for
-- favorites/recents so servers remain accessible across IP changes.
-- Renders an IMGUI window via the BeamNG GE extension onPreRender hook.

local M = {}
local logTag = "HighBeam.Browser"

local MAX_RECENTS       = 10
local MAX_FAVORITES     = 50
local MAX_NODES_STORED  = 20   -- community nodes we remember

-- ──────────────────────────────────────────────────────────────────────────────
-- JSON helpers (Engine.JSONEncode/Decode -> require("json") fallback)
-- Defined early because bridge functions below use them.
-- ──────────────────────────────────────────────────────────────────────────────

local function _jsonEncode(t)
  if jsonEncode then
    local ok, s = pcall(jsonEncode, t)
    if ok then return s end
  end
  if Engine and Engine.JSONEncode then
    local ok, s = pcall(Engine.JSONEncode, t)
    if ok then return s end
  end
  local ok, json = pcall(require, "json")
  if ok and json then return json.encode(t) end
  return "{}"
end

local function _jsonDecode(s)
  if not s or s == "" then return nil end
  if jsonDecode then
    local ok, t = pcall(jsonDecode, s)
    if ok then return t end
  end
  if Engine and Engine.JSONDecode then
    local ok, t = pcall(Engine.JSONDecode, s)
    if ok then return t end
  end
  local ok, json = pcall(require, "json")
  if ok and json then
    local ok2, t = pcall(json.decode, s)
    if ok2 then return t end
  end
  return nil
end

-- Strip % (ImGui format specifiers) and ASCII control characters from
-- community-provided strings to prevent injection.
local function _sanitize(s)
  return (tostring(s):gsub("[%%%c]", ""))
end

-- Returns true when a host string is a loopback or private-range address.
local function _isPrivateAddr(h)
  h = tostring(h):lower()
  if h == "localhost" then return true end
  if h:match("^127%.") then return true end
  if h:match("^0%.0%.0%.0") then return true end
  if h == "::1" then return true end
  if h:match("^10%.") then return true end
  if h:match("^192%.168%.") then return true end
  local b = tonumber(h:match("^172%.(%d+)%."))
  if b and b >= 16 and b <= 31 then return true end
  return false
end

-- Validate community node address format (host:port).
local function _isValidNodeAddr(addr)
  if not addr or addr == "" then return false end
  local h, p = addr:match("^([^:]+):(%d+)$")
  if not h or not p then return false end
  p = tonumber(p)
  if not p or p < 1 or p > 65535 then return false end
  if #h > 253 then return false end
  if _isPrivateAddr(h) then return false end
  return true
end

-- ──────────────────────────────────────────────────────────────────────────────
-- State
-- ──────────────────────────────────────────────────────────────────────────────

M._visible      = false
M._connectError = ""

-- Data stores
M._favorites       = {}   -- [{serverId?, host?, port?, name, description?, addedAt}]
M._recents         = {}   -- [{serverId?, host?, port?, name, connectedAt}]
M._communityNodes  = {}   -- [{addr, addedAt}] — the nodes we gossip with
M._communityServers= {}   -- [{id, name, description, map, players, maxPlayers, authMode,
                          --   modCount, mods, pingMs, isFav, nodeAddr}]

-- Fetch state
M._fetchStatus  = ""   -- "" | "fetching" | "done" | "error"
M._fetchError   = ""

-- Current node being polled during sequential fetch
local _nodeQueue    = {}  -- list of node addrs to try
local _currentFetch = { state = "idle", sock = nil, buf = "", bytes = 0, nodeAddr = "", startT = 0 }

-- Resolve state machine: "idle" | "resolving" | "done" | "error"
local _resolve = { state = "idle", serverId = nil, sock = nil, buf = "", nodeAddr = "" }

-- Apply-after-resolve pending connect details
local _pendingConnect = nil  -- {serverId, name, username, password, nodeAddr}

-- Pending recent entry set on connect(), cleared after onConnected()
local _pendingRecent = nil

-- HTTP body size limit (512 KB) — guards against malformed/large responses
local HTTP_BODY_LIMIT = 512 * 1024

-- ──────────────────────────────────────────────────────────────────────────────
-- File I/O helpers (FS: API → io.open fallback)
-- ──────────────────────────────────────────────────────────────────────────────

local SAVE_DIR    = "userdata/highbeam"
local FAV_FILE    = SAVE_DIR .. "/favorites.json"
local REC_FILE    = SAVE_DIR .. "/recents.json"
local NODES_FILE  = SAVE_DIR .. "/community_nodes.json"

local function _ensureDir()
  if FS and FS.directoryCreate then
    pcall(function() FS:directoryCreate(SAVE_DIR) end)
    return
  end
  -- Cross-platform fallback: try lfs, then os-specific mkdir
  local ok, lfs = pcall(require, 'lfs')
  if ok and lfs then pcall(lfs.mkdir, SAVE_DIR); return end
  local sep = package.config:sub(1, 1)
  if sep == '\\' then
    pcall(function()
      os.execute('mkdir "' .. SAVE_DIR:gsub('/', '\\') .. '" 2>nul')
    end)
  else
    pcall(function()
      os.execute('mkdir -p "' .. SAVE_DIR .. '" 2>/dev/null')
    end)
  end
end

local function _readFile(path)
  if FS and FS.readFileToString then
    local ok, c = pcall(function() return FS:readFileToString(path) end)
    if ok and type(c) == "string" and c ~= "" then return c end
  end
  if readFile then
    local ok, c = pcall(readFile, path)
    if ok and type(c) == "string" and c ~= "" then return c end
  end
  local f = io.open(path, "r")
  if f then
    local c = f:read("*all")
    f:close()
    return c
  end
  return nil
end

local function _writeFile(path, content)
  _ensureDir()
  if FS and FS.writeFile then
    local ok = pcall(function() FS:writeFile(path, content) end)
    if ok then return true end
  end
  if writeFile then
    local ok = pcall(writeFile, path, content)
    if ok then return true end
  end
  local f = io.open(path, "w")
  if f then
    f:write(content)
    f:close()
    return true
  end
  return false
end

-- Subsystem refs (injected by load())
local _connection = nil
local _config     = nil

-- ImGui / FFI handles (loaded lazily on first render)
local _im  = nil
local _ffi = nil

-- UI input buffers (allocated once, persist between renders)
local _bufs = nil

-- ──────────────────────────────────────────────────────────────────────────────
-- Launcher IPC bridge (Phase C) — triggers per-server mod sync before connect
-- State machine: idle | syncing | unavailable | failed
-- ──────────────────────────────────────────────────────────────────────────────

local IPC_STATE_FILE = "userdata/highbeam-launcher.json"

M._bridge = {
  state   = "idle",   -- idle | syncing | unavailable | failed
  port    = nil,      -- TCP port of the launcher IPC server
  sock    = nil,      -- open socket while syncing
  recvBuf = "",       -- receive buffer for newline-delimited messages
  error   = nil,      -- error string when state == "failed"
  pending = nil,      -- {host, port, username, password, name} waiting for sync
}

-- Last resolved real server target used behind launcher proxy. This lets us
-- recover when a stale localhost proxy port times out during reconnect.
M._lastBridgeTarget = nil -- {host, port, username, password, name}
local function _bridgeDirectConnect()
  local p = M._bridge.pending
  if not p then return end
  if not _connection or type(_connection.connect) ~= "function" then
    M._bridge.state = "failed"
    M._bridge.error = "Connection subsystem unavailable"
    M._connectError = M._bridge.error
    return
  end
  M._bridge.pending = nil
  M._lastBridgeTarget = {
    host = p.host,
    port = p.port,
    username = p.username,
    password = p.password,
    name = p.name,
  }

  -- If the launcher provided proxy ports, route through localhost proxy
  -- instead of connecting directly to the (sandbox-blocked) remote address.
  local connectHost = p.host
  local connectPort = p.port
  local connectUdpPort = nil
  if p.proxy_tcp_port then
    connectHost = "127.0.0.1"
    connectPort = p.proxy_tcp_port
    connectUdpPort = p.proxy_udp_port
    log('I', logTag, 'Using launcher proxy: tcp=' .. tostring(connectPort)
      .. ' udp=' .. tostring(connectUdpPort)
      .. ' -> ' .. p.host .. ':' .. tostring(p.port))
  end

  local ok, started, err = pcall(_connection.connect, connectHost, connectPort, p.username,
    (p.password and p.password ~= "" and p.password or nil),
    connectUdpPort)
  if not ok then
    M._bridge.state = "failed"
    M._bridge.error = "Connect failed: " .. tostring(err)
    M._connectError = M._bridge.error
    return
  end

  if started == false then
    M._bridge.state = "failed"
    M._bridge.error = tostring(err or "Connection failed")
    M._connectError = M._bridge.error
    return
  end

  -- We already fell back to direct connect, so keep launcher availability as
  -- informational only and avoid presenting it as the active failure state.
  if M._bridge.state == "unavailable" then
    M._bridge.state = "idle"
  end
end

local function _bridgeRefreshForReconnect(reason)
  local p = M._lastBridgeTarget
  if not p then
    M._connectError = reason or "Proxy reconnect required but no previous target is known"
    return
  end
  if M._bridge.state == "syncing" then
    return
  end

  log('I', logTag, 'Refreshing launcher proxy endpoints after reconnect failure: ' .. tostring(reason))
  M._connectError = "Refreshing launcher proxy..."
  M._bridge.error = nil
  M._bridge.pending = {
    host = p.host,
    port = p.port,
    username = p.username,
    password = p.password,
    name = p.name,
  }
  _bridgeInitiate(p.host, p.port)
end

-- Open the IPC socket and send a join_request
local function _bridgeConnect(targetHost, targetPort)
  local sok, socket = pcall(require, "socket")
  if not sok then
    M._bridge.state = "unavailable"
    _bridgeDirectConnect()
    return
  end
  local tcp = socket.tcp()
  tcp:settimeout(0.5)  -- short timeout; localhost connects near-instantly
  local ok, err = tcp:connect("127.0.0.1", M._bridge.port)
  if not ok then
    tcp:close()
    log('W', logTag, 'Launcher IPC connect failed: ' .. tostring(err))
    M._bridge.state = "unavailable"
    _bridgeDirectConnect()
    return
  end
  local req = _jsonEncode({
    type   = "join_request",
    server = targetHost .. ":" .. tostring(targetPort),
  })
  local sent, sendErr = tcp:send(req .. "\n")
  if not sent then
    tcp:close()
    M._bridge.state = "failed"
    M._bridge.error = "IPC send failed: " .. tostring(sendErr)
    return
  end
  tcp:settimeout(0)  -- switch to non-blocking for polling
  M._bridge.sock    = tcp
  M._bridge.state   = "syncing"
  M._bridge.recvBuf = ""
  log('I', logTag, 'Launcher IPC: join request sent for ' ..
    targetHost .. ':' .. tostring(targetPort))
end

-- Read the launcher IPC state file and attempt to connect, or fall back to direct connect
local function _bridgeInitiate(targetHost, targetPort)
  log('I', logTag, 'Bridge: looking for IPC state file at: ' .. tostring(IPC_STATE_FILE))
  local content = _readFile(IPC_STATE_FILE)
  if content then
    log('I', logTag, 'Bridge: IPC state file found, content length=' .. tostring(#content))
    local state = _jsonDecode(content)
    if state and tonumber(state.port) then
      M._bridge.port = tonumber(state.port)
      log('I', logTag, 'Bridge: launcher IPC port=' .. tostring(M._bridge.port)
        .. ' pid=' .. tostring(state.pid) .. ' version=' .. tostring(state.version))

      -- If the state file already has proxy ports (--server CLI pre-start),
      -- store them on the pending info so _bridgeDirectConnect can use them.
      if M._bridge.pending and tonumber(state.proxy_tcp_port) then
        M._bridge.pending.proxy_tcp_port = tonumber(state.proxy_tcp_port)
        M._bridge.pending.proxy_udp_port = tonumber(state.proxy_udp_port)
        log('I', logTag, 'Bridge: pre-started proxy ports found: tcp='
          .. tostring(state.proxy_tcp_port) .. ' udp=' .. tostring(state.proxy_udp_port))
      end

      _bridgeConnect(targetHost, targetPort)
      return
    else
      log('W', logTag, 'Bridge: IPC state file found but could not parse port from it')
    end
  else
    log('W', logTag, 'Bridge: IPC state file NOT found at: ' .. tostring(IPC_STATE_FILE))
  end
  -- Launcher not detected; connect directly (mods already staged or server needs no mods)
  M._bridge.state = "unavailable"
  log('I', logTag, 'Launcher IPC not detected; connecting directly (no mod sync)')
  _bridgeDirectConnect()
end

-- Poll the IPC socket for a response (called every frame from renderUI)
local function _bridgePoll()
  if M._bridge.state ~= "syncing" or not M._bridge.sock then return end
  local data, err, partial = M._bridge.sock:receive(512)
  local chunk = data or partial
  if chunk and chunk ~= "" then
    M._bridge.recvBuf = M._bridge.recvBuf .. chunk
    -- Consume one complete newline-delimited message
    local line = M._bridge.recvBuf:match("^([^\n]+)\n")
    if line then
      M._bridge.recvBuf = M._bridge.recvBuf:sub(#line + 2)
      local resp = _jsonDecode(line)
      if resp then
        local rtype = resp.type
        if rtype == "sync_complete" then
          log('I', logTag, 'Launcher IPC: mod sync complete')
          -- Capture proxy ports from response if available
          if M._bridge.pending and tonumber(resp.proxy_tcp_port) then
            M._bridge.pending.proxy_tcp_port = tonumber(resp.proxy_tcp_port)
            M._bridge.pending.proxy_udp_port = tonumber(resp.proxy_udp_port)
            log('I', logTag, 'Launcher IPC: proxy ports tcp='
              .. tostring(resp.proxy_tcp_port) .. ' udp=' .. tostring(resp.proxy_udp_port))
          end
          M._bridge.sock:close()
          M._bridge.sock  = nil
          M._bridge.state = "idle"
          _bridgeDirectConnect()
        elseif rtype == "sync_failed" then
          log('W', logTag, 'Launcher IPC: sync failed: ' .. tostring(resp.error))
          M._bridge.sock:close()
          M._bridge.sock  = nil
          M._bridge.state = "failed"
          M._bridge.error = resp.error or "Unknown sync error"
        -- sync_started is purely informational; no action needed
        end
      end
    end
  end
  if err == "closed" then
    if M._bridge.sock then M._bridge.sock:close() end
    M._bridge.sock  = nil
    M._bridge.state = "failed"
    M._bridge.error = "Launcher disconnected during mod sync"
  end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Community Nodes persistence
-- ──────────────────────────────────────────────────────────────────────────────

M.loadCommunityNodes = function()
  local c = _readFile(NODES_FILE)
  if not c then M._communityNodes = {}; return end
  local d = _jsonDecode(c)
  M._communityNodes = (type(d) == "table" and type(d.nodes) == "table") and d.nodes or {}
  log("I", logTag, "Loaded " .. #M._communityNodes .. " community node(s)")
end

M.saveCommunityNodes = function()
  _writeFile(NODES_FILE, _jsonEncode({ nodes = M._communityNodes }))
end

M.addCommunityNode = function(addr)
  addr = addr and addr:match("^%s*(.-)%s*$") or ""
  if addr == "" then return false, "Address required" end
  if not _isValidNodeAddr(addr) then
    return false, "Invalid address (use host:port, no private/local addresses)"
  end
  for _, n in ipairs(M._communityNodes) do
    if n.addr == addr then return false, "Node already in list" end
  end
  if #M._communityNodes >= MAX_NODES_STORED then table.remove(M._communityNodes, 1) end
  table.insert(M._communityNodes, { addr = addr, addedAt = os.time() })
  M.saveCommunityNodes()
  return true
end

M.removeCommunityNode = function(addr)
  for i = #M._communityNodes, 1, -1 do
    if M._communityNodes[i].addr == addr then table.remove(M._communityNodes, i) end
  end
  M.saveCommunityNodes()
end

-- Merge newly discovered node addresses from a /servers response.
local function _mergeDiscoveredNodes(nodeList)
  if type(nodeList) ~= "table" then return end
  for _, addr in ipairs(nodeList) do
    if type(addr) == "string" and _isValidNodeAddr(addr) then
      local exists = false
      for _, n in ipairs(M._communityNodes) do
        if n.addr == addr then exists = true; break end
      end
      if not exists and #M._communityNodes < MAX_NODES_STORED then
        table.insert(M._communityNodes, { addr = addr, addedAt = os.time() })
      end
    end
  end
  M.saveCommunityNodes()
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Persistence — Favorites (server_id-aware, backward-compatible)
-- ──────────────────────────────────────────────────────────────────────────────

M.loadFavorites = function()
  local c = _readFile(FAV_FILE)
  if not c then M._favorites = {}; return end
  local d = _jsonDecode(c)
  M._favorites = (type(d) == "table" and type(d.favorites) == "table") and d.favorites or {}
  log("I", logTag, "Loaded " .. #M._favorites .. " favorites")
end

M.saveFavorites = function()
  _writeFile(FAV_FILE, _jsonEncode({ favorites = M._favorites }))
end

M.isFavorite = function(serverId, host, port)
  for _, f in ipairs(M._favorites) do
    if serverId and f.serverId == serverId then return true end
    if not serverId and f.host == host and f.port == port then return true end
  end
  return false
end

M.addFavorite = function(serverId, host, port, name, description)
  M.removeFavorite(serverId, host, port)
  if #M._favorites >= MAX_FAVORITES then table.remove(M._favorites, 1) end
  table.insert(M._favorites, {
    serverId    = serverId,
    host        = host,
    port        = port,
    name        = name or (serverId or (host and (host .. ":" .. tostring(port)))) or "?",
    description = description or "",
    addedAt     = os.time(),
  })
  M.saveFavorites()
  for _, s in ipairs(M._communityServers) do
    if (serverId and s.id == serverId) or (not serverId and s.host == host and s.port == port) then
      s.isFav = true
    end
  end
end

M.removeFavorite = function(serverId, host, port)
  for i = #M._favorites, 1, -1 do
    local f = M._favorites[i]
    if (serverId and f.serverId == serverId) or
       (not serverId and f.host == host and f.port == port) then
      table.remove(M._favorites, i)
    end
  end
  M.saveFavorites()
  for _, s in ipairs(M._communityServers) do
    if (serverId and s.id == serverId) or (not serverId and s.host == host and s.port == port) then
      s.isFav = false
    end
  end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Persistence — Recents
-- ──────────────────────────────────────────────────────────────────────────────

M.loadRecents = function()
  local c = _readFile(REC_FILE)
  if not c then M._recents = {}; return end
  local d = _jsonDecode(c)
  M._recents = (type(d) == "table" and type(d.recents) == "table") and d.recents or {}
  log("I", logTag, "Loaded " .. #M._recents .. " recents")
end

M.saveRecents = function()
  _writeFile(REC_FILE, _jsonEncode({ recents = M._recents }))
end

M.addRecent = function(serverId, host, port, serverName)
  for i = #M._recents, 1, -1 do
    local r = M._recents[i]
    if (serverId and r.serverId == serverId) or
       (not serverId and r.host == host and r.port == port) then
      table.remove(M._recents, i)
    end
  end
  table.insert(M._recents, 1, {
    serverId    = serverId,
    host        = host,
    port        = port,
    name        = serverName or (serverId or (host and (host .. ":" .. tostring(port)))) or "?",
    connectedAt = os.time(),
  })
  while #M._recents > MAX_RECENTS do table.remove(M._recents) end
  M.saveRecents()
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Community node HTTP fetch (async, sequential node fallback)
-- ──────────────────────────────────────────────────────────────────────────────

-- Forward declaration needed by _communityPoll
local _tryNextNode

local function _parseCommunityResponse(raw, nodeAddr, pingMs)
  local status = raw:match("HTTP/%S+ (%d+)") or "?"
  local body   = raw:match("\r\n\r\n(.*)$") or ""
  if status ~= "200" then
    log("W", logTag, "Community node HTTP error from " .. nodeAddr .. ": " .. status)
    return false
  end
  local data = _jsonDecode(body)
  if type(data) ~= "table" or type(data.servers) ~= "table" then
    log("W", logTag, "Community node response has no servers array from " .. nodeAddr)
    return false
  end
  local result = {}
  for _, s in ipairs(data.servers) do
    if type(s) == "table" then
      local id = s.id and tostring(s.id) or ""
      -- Validate server_id format: hb-xxxxxx (6 lowercase hex chars)
      if id:match("^hb%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$") then
        local modCount = 0
        local modList  = {}
        if type(s.mods) == "table" then
          modCount = #s.mods
          for _, m in ipairs(s.mods) do
            if type(m) == "table" and type(m.name) == "string" then
              table.insert(modList, _sanitize(m.name):sub(1, 64))
            end
          end
        end
        table.insert(result, {
          id         = id,
          name       = _sanitize(s.name        or id):sub(1, 64),
          description= _sanitize(s.description or ""):sub(1, 256),
          map        = _sanitize(s.map         or "?"):sub(1, 128),
          players    = tonumber(s.players)           or 0,
          maxPlayers = tonumber(s.max_players)       or 0,
          authMode   = tostring(s.auth_mode or "open"),
          modCount   = modCount,
          mods       = modList,
          pingMs     = pingMs,
          isFav      = M.isFavorite(id, nil, nil),
          nodeAddr   = nodeAddr,
        })
      end
    end
  end
  M._communityServers = result
  M._fetchStatus = "done"
  if type(data.nodes) == "table" then _mergeDiscoveredNodes(data.nodes) end
  log("I", logTag, "Community node " .. nodeAddr .. " returned " .. #result .. " server(s)")
  return true
end

local function _communityPoll()
  local f = _currentFetch
  if f.state ~= "receiving" then return end
  while true do
    local chunk, err, partial = f.sock:receive(4096)
    local data = chunk or partial
    if data and data ~= "" then
      f.bytes = f.bytes + #data
      if f.bytes > HTTP_BODY_LIMIT then
        f.sock:close(); f.sock = nil; f.state = "error"
        log("W", logTag, "Community node response exceeds 512 KB limit")
        _tryNextNode()
        return
      end
      f.buf = f.buf .. data
    end
    if err == "closed" then
      f.sock:close(); f.sock = nil; f.state = "done"
      local pingMs = math.floor((os.clock() - f.startT) * 1000)
      if not _parseCommunityResponse(f.buf, f.nodeAddr, pingMs) then
        _tryNextNode()
      end
      return
    elseif err == "timeout" then
      return
    elseif err then
      f.sock:close(); f.sock = nil; f.state = "error"
      log("W", logTag, "Receive error from " .. f.nodeAddr .. ": " .. tostring(err))
      _tryNextNode()
      return
    end
    if not chunk then break end
  end
end

_tryNextNode = function()
  if #_nodeQueue == 0 then
    if M._fetchStatus == "fetching" then
      M._fetchStatus = "error"
      M._fetchError  = "No community nodes responded"
    end
    return
  end
  local nodeAddr = table.remove(_nodeQueue, 1)
  local host, portStr = nodeAddr:match("^([^:]+):(%d+)$")
  if not host then _tryNextNode(); return end
  local port = tonumber(portStr) or 18862
  local sok, socket = pcall(require, "socket")
  if not sok then
    M._fetchStatus = "error"; M._fetchError = "LuaSocket not available"; return
  end
  local tcp = socket.tcp()
  tcp:settimeout(2)
  local ok, err = tcp:connect(host, port)
  if not ok then
    tcp:close()
    log("W", logTag, "Node connect failed: " .. nodeAddr .. " -- " .. tostring(err))
    _tryNextNode()
    return
  end
  tcp:send("GET /servers HTTP/1.0\r\nHost: " .. host .. "\r\nConnection: close\r\n\r\n")
  tcp:settimeout(0)
  _currentFetch = { state = "receiving", sock = tcp, buf = "", bytes = 0, nodeAddr = nodeAddr, startT = os.clock() }
end

M.fetchCommunityServers = function()
  if M._fetchStatus == "fetching" then return end
  if #M._communityNodes == 0 then
    M._fetchStatus = "error"
    M._fetchError  = "No community nodes configured -- add a node address below"
    return
  end
  M._fetchStatus      = "fetching"
  M._communityServers = {}
  M._fetchError       = ""
  _currentFetch       = { state = "idle", sock = nil, buf = "", bytes = 0, nodeAddr = "", startT = 0 }
  _nodeQueue = {}
  for _, n in ipairs(M._communityNodes) do table.insert(_nodeQueue, n.addr) end
  _tryNextNode()
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Resolve -> connect (server IP never exposed to user)
-- ──────────────────────────────────────────────────────────────────────────────

local function _resolvePoll()
  if _resolve.state ~= "resolving" or not _resolve.sock then return end
  while true do
    local chunk, err, partial = _resolve.sock:receive(4096)
    local data = chunk or partial
    if data and data ~= "" then
      _resolve.buf = _resolve.buf .. data
      if #_resolve.buf > 8192 then
        _resolve.sock:close(); _resolve.sock = nil
        _resolve.state = "error"
        M._connectError = "Resolve response too large"
        return
      end
    end
    if err == "closed" then
      _resolve.sock:close(); _resolve.sock = nil
      local status = _resolve.buf:match("HTTP/%S+ (%d+)") or "?"
      local body   = _resolve.buf:match("\r\n\r\n(.*)$") or ""
      if status ~= "200" then
        _resolve.state  = "error"
        M._connectError = "Server not found in mesh (HTTP " .. status .. ")"
        return
      end
      local d = _jsonDecode(body)
      local addr = d and d.addr
      if not addr or addr == "" then
        _resolve.state  = "error"
        M._connectError = "Node returned empty address for server"
        return
      end
      local h, pStr = addr:match("^(.+):(%d+)$")
      local p = tonumber(pStr)
      if not h or not p then
        _resolve.state  = "error"
        M._connectError = "Node returned malformed address"
        return
      end
      _resolve.state = "done"
      local pc = _pendingConnect
      if pc then
        _pendingConnect   = nil
        M._bridge.pending = { host = h, port = p, username = pc.username, password = pc.password, name = pc.name }
        M._bridge.error   = nil
        _bridgeInitiate(h, p)
      end
      return
    elseif err == "timeout" then
      return
    elseif err then
      _resolve.sock:close(); _resolve.sock = nil
      _resolve.state  = "error"
      M._connectError = "Resolve error: " .. tostring(err)
      return
    end
    if not chunk then break end
  end
end

local function _startResolve(serverId, nodeAddr, username, password, serverName)
  if _resolve.state == "resolving" then return end
  local host, portStr = nodeAddr:match("^([^:]+):(%d+)$")
  if not host then M._connectError = "No community node available to resolve this server"; return end
  local port = tonumber(portStr) or 18862
  local sok, socket = pcall(require, "socket")
  if not sok then M._connectError = "LuaSocket not available"; return end
  local tcp = socket.tcp()
  tcp:settimeout(2)
  local ok, err = tcp:connect(host, port)
  if not ok then
    tcp:close()
    M._connectError = "Could not reach community node: " .. tostring(err)
    return
  end
  tcp:send("GET /resolve/" .. serverId .. " HTTP/1.0\r\nHost: " .. host .. "\r\nConnection: close\r\n\r\n")
  tcp:settimeout(0)
  _resolve        = { state = "resolving", serverId = serverId, sock = tcp, buf = "", nodeAddr = nodeAddr }
  _pendingConnect = { serverId = serverId, name = serverName, username = username, password = password, nodeAddr = nodeAddr }
  M._connectError = ""
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Connect entry points
-- ──────────────────────────────────────────────────────────────────────────────

-- Connect by community server_id (Browse tab). Resolves address via node.
M.connectById = function(serverId, nodeAddr, username, password, serverName)
  username = (username or ""):match("^%s*(.-)%s*$")
  if username == "" then return false, "Enter a username on the Direct Connect tab first." end
  if not _connection then return false, "Browser not initialised" end
  if _connection.state == _connection.STATE_CONNECTED
     or _connection.state == _connection.STATE_CONNECTING
     or _connection.state == _connection.STATE_AUTHENTICATING then
    return false, "Already connected -- disconnect first"
  end
  if _config then _config.set("username", username); _config.save() end
  _pendingRecent  = { serverId = serverId, name = serverName }
  M._connectError = ""
  _startResolve(serverId, nodeAddr, username, password, serverName)
  return true
end

-- Connect by host:port (direct connect and legacy favorites).
M.connect = function(host, port, username, password, serverName)
  host     = (host     or ""):match("^%s*(.-)%s*$")
  username = (username or ""):match("^%s*(.-)%s*$")
  if host     == "" then return false, "Host is required"      end
  if username == "" then return false, "Username is required"  end
  port = tonumber(port) or 18860
  if not _connection then return false, "Browser not initialised" end
  if _connection.state == _connection.STATE_CONNECTED
     or _connection.state == _connection.STATE_CONNECTING
     or _connection.state == _connection.STATE_AUTHENTICATING then
    return false, "Already connected -- disconnect first"
  end
  if _config then
    _config.set("username",          username)
    _config.set("directConnectHost", host)
    _config.set("directConnectPort", port)
    _config.save()
  end
  _pendingRecent    = { host = host, port = port, name = serverName }
  M._connectError   = ""
  M._bridge.pending = { host = host, port = port, username = username, password = password, name = serverName }
  M._bridge.error   = nil
  _bridgeInitiate(host, port)
  return true
end

M.onConnected = function()
  M._visible      = false
  M._bridge.state = "idle"
  M._bridge.error = nil
  _resolve.state  = "idle"
  if _pendingRecent then
    local pr = _pendingRecent
    M.addRecent(pr.serverId, pr.host, pr.port, pr.name)
    _pendingRecent = nil
  end
end

M.onConnectionStatus = function(status, detail)
  if status == "kicked" then
    M._connectError = "Kicked from server: " .. (detail or "No reason given")
    M._visible = true  -- Re-open browser to show kick reason
    if M._bridge.state == "syncing" then
      M._bridge.state = "failed"
      M._bridge.error = detail or "Kicked"
    end
  elseif status == "connect_failed" then
    M._connectError = detail or "Connection failed"
    if M._bridge.state == "syncing" then
      M._bridge.state = "failed"
      M._bridge.error = M._connectError
    end
  elseif status == "proxy_reconnect_required" then
    _bridgeRefreshForReconnect(detail)
  elseif status == "disconnected" or status == "reconnect_failed" then
    if M._bridge.state == "syncing" then
      M._bridge.state = "failed"
      M._bridge.error = detail or "Connection closed during sync"
    end
    M._connectError = detail or "Disconnected"
  elseif status == "connecting" or status == "authenticating" then
    M._connectError = ""
  end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Visibility
-- ──────────────────────────────────────────────────────────────────────────────

M.open   = function() M._visible = true  end
M.close  = function() M._visible = false end
M.isOpen = function() return M._visible  end

-- ──────────────────────────────────────────────────────────────────────────────
-- IMGUI rendering helpers
-- ──────────────────────────────────────────────────────────────────────────────

-- ImGui table flags: RowBg(64) | Borders(1920) | ScrollY(16384)
local TBL_FLAGS = bit.bor(64, 1920, 16384)
-- ImGuiInputTextFlags_Password
local PW_FLAG   = 32768

local function _initBufs()
  if _bufs then return end
  _im  = ui_imgui
  _ffi = require("ffi")
  if not _im or not _ffi then return end
  local savedHost = (_config and _config.get("directConnectHost")) or ""
  local savedPort = tostring((_config and _config.get("directConnectPort")) or 18860)
  local savedUser = (_config and _config.get("username"))           or ""
  _bufs = {
    host      = _im.ArrayChar(256, savedHost),
    port      = _im.ArrayChar(16,  savedPort),
    username  = _im.ArrayChar(64,  savedUser),
    password  = _im.ArrayChar(128, ""),
    nodeInput = _im.ArrayChar(256, ""),
    pwPrompt  = _im.ArrayChar(128, ""),
  }
end

local function _pingColor(ms)
  if ms == nil then return nil end
  if ms <= 80  then return _im.ImVec4(0.40, 0.95, 0.40, 1.0) end
  if ms <= 150 then return _im.ImVec4(1.00, 0.90, 0.25, 1.0) end
  return _im.ImVec4(1.0, 0.30, 0.30, 1.0)
end

-- ── Tab: Direct Connect ────────────────────────────────────────────────────────

local function _tabDirectConnect()
  _im.Spacing()
  _im.Text("Username")
  _im.SameLine()
  _im.SetNextItemWidth(280)
  _im.InputText("##hb_user", _bufs.username, 64)
  _im.SameLine()
  _im.TextDisabled("(saved between sessions)")

  _im.Spacing()
  _im.Text("Host    ")
  _im.SameLine()
  _im.SetNextItemWidth(220)
  _im.InputText("##hb_host", _bufs.host, 256)
  _im.SameLine()
  _im.Text("Port")
  _im.SameLine()
  _im.SetNextItemWidth(70)
  _im.InputText("##hb_port", _bufs.port, 16)

  _im.Spacing()
  _im.Text("Password")
  _im.SameLine()
  _im.SetNextItemWidth(280)
  _im.InputText("##hb_pw", _bufs.password, 128, PW_FLAG)
  _im.SameLine()
  _im.TextDisabled("(optional)")

  _im.Spacing()
  if M._connectError ~= "" then
    _im.TextColored(_im.ImVec4(1, 0.3, 0.3, 1), M._connectError)
    _im.Spacing()
  end

  local bridgeSyncing = M._bridge.state == "syncing"
  if bridgeSyncing then
    _im.TextColored(_im.ImVec4(0.3, 0.7, 1.0, 1.0), "Syncing mods with launcher...")
    _im.TextDisabled("Please wait -- downloading required server mods.")
    _im.Spacing()
  elseif M._bridge.state == "failed" then
    _im.TextColored(_im.ImVec4(1.0, 0.45, 0.2, 1.0),
      "Mod sync failed: " .. (M._bridge.error or "unknown error"))
    _im.SameLine()
    if _im.SmallButton("Connect anyway##hb_nomod") then
      M._bridge.state = "idle"
      _bridgeDirectConnect()
    end
    _im.Spacing()
  elseif M._bridge.state == "unavailable" then
    _im.TextColored(_im.ImVec4(1.0, 0.85, 0.2, 1.0),
      "Launcher not running -- server mods may not be available.")
    _im.Spacing()
  end

  if not bridgeSyncing then
    if _im.Button("Connect##hb_go", _im.ImVec2(120, 28)) then
      local host     = _ffi.string(_bufs.host)
      local portVal  = tonumber(_ffi.string(_bufs.port))
      local username = _ffi.string(_bufs.username)
      local password = _ffi.string(_bufs.password)
      local ok, err  = M.connect(host, portVal, username, (password ~= "" and password or nil))
      if not ok then M._connectError = err or "Connection failed" end
    end
  end
end

-- ── Tab: Browse Servers (community node) ──────────────────────────────────────

local _pwPopup = { open = false, serverId = nil, nodeAddr = nil, name = nil }

local function _tabBrowse()
  _im.Spacing()

  -- Introduction
  _im.TextDisabled("Add at least one public community node below, then refresh to browse available servers.")
  _im.Spacing()
  
  -- Node management bar
  _im.Text("Community Nodes (" .. tostring(#M._communityNodes) .. " configured)")
  _im.Spacing()
  _im.SetNextItemWidth(300)
  _im.InputText("##hb_node", _bufs.nodeInput, 256)
  _im.SameLine()
  _im.TextDisabled("(e.g. community.example.com:18862)")
  _im.SameLine()
  if _im.Button("Add Node##hb_addnode") then
    local addr = _ffi.string(_bufs.nodeInput):match("^%s*(.-)%s*$")
    local wasEmpty = #M._communityNodes == 0
    local ok, err = M.addCommunityNode(addr)
    if ok then
      _bufs.nodeInput = _im.ArrayChar(256, "")
      -- Auto-fetch if this was the first node
      if wasEmpty then
        M.fetchCommunityServers()
      end
    else
      M._fetchError  = err or "Invalid address"
      M._fetchStatus = "error"
    end
  end

  if #M._communityNodes > 0 then
    _im.Spacing()
    for _, n in ipairs(M._communityNodes) do
      _im.Bullet(); _im.SameLine()
      _im.Text(n.addr); _im.SameLine()
      if _im.SmallButton("Remove##nr_" .. n.addr) then
        M.removeCommunityNode(n.addr)
      end
    end
    _im.Separator()
  end

  _im.Spacing()
  if M._fetchStatus == "fetching" then
    _im.TextDisabled("Fetching servers...")
  else
    if _im.Button("Refresh##hb_cnref") then M.fetchCommunityServers() end
    _im.SameLine()
    if M._fetchStatus == "error" then
      _im.TextColored(_im.ImVec4(1, 0.35, 0.35, 1), "Error: " .. M._fetchError)
    elseif M._fetchStatus == "done" then
      _im.TextDisabled(tostring(#M._communityServers) .. " server(s)  |  ping = HTTP round-trip to node  |  [P] = password required")
    else
      _im.TextDisabled("Click Refresh to browse the community mesh.")
    end
  end

  _im.Spacing()
  if #M._communityServers == 0 then _im.TextDisabled("No servers loaded."); return end

  if _im.BeginTable("##cn_browse", 6, TBL_FLAGS, _im.ImVec2(0, 280)) then
    _im.TableSetupScrollFreeze(0, 1)
    _im.TableSetupColumn("Name"); _im.TableSetupColumn("Map")
    _im.TableSetupColumn("Players"); _im.TableSetupColumn("Mods")
    _im.TableSetupColumn("Ping"); _im.TableSetupColumn("Actions")
    _im.TableHeadersRow()

    local username = _bufs and _ffi.string(_bufs.username):match("^%s*(.-)%s*$") or ""

    for i, s in ipairs(M._communityServers) do
      _im.TableNextRow()
      _im.TableSetColumnIndex(0)
      local label = (s.authMode == "password" and "[P] " or "") .. s.name
      _im.Text(label)
      if _im.IsItemHovered() and s.description ~= "" then _im.SetTooltip(s.description) end
      _im.TableSetColumnIndex(1); _im.Text(s.map or "?")
      _im.TableSetColumnIndex(2); _im.Text(tostring(s.players or 0) .. "/" .. tostring(s.maxPlayers or 0))
      _im.TableSetColumnIndex(3)
      if s.modCount and s.modCount > 0 then
        _im.Text(tostring(s.modCount) .. " mod(s)")
        if _im.IsItemHovered() and #s.mods > 0 then _im.SetTooltip(table.concat(s.mods, "\n")) end
      else _im.TextDisabled("none") end
      _im.TableSetColumnIndex(4)
      local pc = _pingColor(s.pingMs)
      if pc then _im.TextColored(pc, "~" .. tostring(s.pingMs) .. "ms")
      else        _im.TextDisabled("-") end
      _im.TableSetColumnIndex(5)
      local rid = tostring(i) .. "_" .. s.id
      if _im.SmallButton("Connect##cc" .. rid) then
        if username == "" then
          M._connectError = "Enter a username on the Direct Connect tab first."
        elseif s.authMode == "password" then
          _pwPopup = { open = true, serverId = s.id, nodeAddr = s.nodeAddr, name = s.name }
          _im.OpenPopup("EnterPassword##hb_pw_pop")
        else
          local ok, err = M.connectById(s.id, s.nodeAddr, username, nil, s.name)
          if not ok then M._connectError = err or "" end
        end
      end
      _im.SameLine()
      if M.isFavorite(s.id, nil, nil) then
        if _im.SmallButton("-Fav##cf" .. rid) then M.removeFavorite(s.id, nil, nil) end
      else
        if _im.SmallButton("+Fav##cf" .. rid) then M.addFavorite(s.id, nil, nil, s.name, s.description) end
      end
    end
    _im.EndTable()
  end

  -- Password prompt popup
  if _im.BeginPopupModal("EnterPassword##hb_pw_pop", nil, 0) then
    _im.Text("Password required for " .. (_pwPopup.name or "this server"))
    _im.Spacing()
    _im.SetNextItemWidth(280)
    _im.InputText("##hb_pp_pw", _bufs.pwPrompt, 128, PW_FLAG)
    _im.Spacing()
    local username = _ffi.string(_bufs.username):match("^%s*(.-)%s*$")
    if _im.Button("Connect##hb_pp_go") then
      local pw = _ffi.string(_bufs.pwPrompt)
      local ok, err = M.connectById(_pwPopup.serverId, _pwPopup.nodeAddr, username, pw ~= "" and pw or nil, _pwPopup.name)
      if not ok then M._connectError = err or "" end
      _bufs.pwPrompt = _im.ArrayChar(128, "")
      _im.CloseCurrentPopup()
    end
    _im.SameLine()
    if _im.Button("Cancel##hb_pp_cancel") then
      _bufs.pwPrompt = _im.ArrayChar(128, "")
      _im.CloseCurrentPopup()
    end
    _im.EndPopup()
  end
end

-- ── Tab: Favorites ─────────────────────────────────────────────────────────────

local function _tabFavorites()
  _im.Spacing()
  if #M._favorites == 0 then
    _im.TextDisabled("No favorites saved.")
    _im.TextDisabled("Browse servers and click  + Fav  to save one.")
    return
  end
  if _im.BeginTable("##srv_fav", 4, TBL_FLAGS, _im.ImVec2(0, 280)) then
    _im.TableSetupScrollFreeze(0, 1)
    _im.TableSetupColumn("Server"); _im.TableSetupColumn("Type")
    _im.TableSetupColumn("Connect"); _im.TableSetupColumn("Remove")
    _im.TableHeadersRow()
    local username = _bufs and _ffi.string(_bufs.username):match("^%s*(.-)%s*$") or ""
    for i, f in ipairs(M._favorites) do
      _im.TableNextRow()
      _im.TableSetColumnIndex(0)
      _im.Text(f.name or (f.serverId or ((f.host or "?") .. ":" .. tostring(f.port or "?"))))
      _im.TableSetColumnIndex(1)
      if f.serverId then _im.TextDisabled("community") else _im.TextDisabled("direct") end
      _im.TableSetColumnIndex(2)
      local rid = "fav_" .. tostring(i)
      if _im.SmallButton("Connect##fc" .. rid) then
        if username == "" then
          M._connectError = "Enter a username on the Direct Connect tab first."
        elseif f.serverId then
          local nodeAddr = ""
          for _, s in ipairs(M._communityServers) do
            if s.id == f.serverId then nodeAddr = s.nodeAddr; break end
          end
          if nodeAddr == "" and #M._communityNodes > 0 then nodeAddr = M._communityNodes[1].addr end
          if nodeAddr == "" then
            M._connectError = "No community node available -- refresh Browse tab first"
          else
            local ok, err = M.connectById(f.serverId, nodeAddr, username, nil, f.name)
            if not ok then M._connectError = err or "" end
          end
        else
          local ok, err = M.connect(f.host, f.port, username, nil, f.name)
          if not ok then M._connectError = err or "" end
        end
      end
      _im.TableSetColumnIndex(3)
      if _im.SmallButton("Remove##fr" .. rid) then M.removeFavorite(f.serverId, f.host, f.port) end
    end
    _im.EndTable()
  end
end

-- ── Tab: Recent ────────────────────────────────────────────────────────────────

local function _tabRecent()
  _im.Spacing()
  if #M._recents == 0 then _im.TextDisabled("No recent servers yet."); return end
  if _im.BeginTable("##srv_rec", 5, TBL_FLAGS, _im.ImVec2(0, 280)) then
    _im.TableSetupScrollFreeze(0, 1)
    _im.TableSetupColumn("Server"); _im.TableSetupColumn("Type")
    _im.TableSetupColumn("Last Connected"); _im.TableSetupColumn("Connect")
    _im.TableSetupColumn("Favorite")
    _im.TableHeadersRow()
    local username = _bufs and _ffi.string(_bufs.username):match("^%s*(.-)%s*$") or ""
    for i, r in ipairs(M._recents) do
      _im.TableNextRow()
      _im.TableSetColumnIndex(0)
      _im.Text(r.name or (r.serverId or ((r.host or "?") .. ":" .. tostring(r.port or "?"))))
      _im.TableSetColumnIndex(1)
      if r.serverId then _im.TextDisabled("community") else _im.TextDisabled("direct") end
      _im.TableSetColumnIndex(2)
      _im.TextDisabled(os.date("%Y-%m-%d %H:%M", r.connectedAt or 0))
      _im.TableSetColumnIndex(3)
      local rid = "re_" .. tostring(i)
      if _im.SmallButton("Connect##rc" .. rid) then
        if username == "" then
          M._connectError = "Enter a username on the Direct Connect tab first."
        elseif r.serverId then
          local nodeAddr = ""
          for _, s in ipairs(M._communityServers) do
            if s.id == r.serverId then nodeAddr = s.nodeAddr; break end
          end
          if nodeAddr == "" and #M._communityNodes > 0 then nodeAddr = M._communityNodes[1].addr end
          if nodeAddr == "" then
            M._connectError = "No community node available -- refresh Browse tab first"
          else
            local ok, err = M.connectById(r.serverId, nodeAddr, username, nil, r.name)
            if not ok then M._connectError = err or "" end
          end
        else
          local ok, err = M.connect(r.host, r.port, username, nil, r.name)
          if not ok then M._connectError = err or "" end
        end
      end
      _im.TableSetColumnIndex(4)
      if M.isFavorite(r.serverId, r.host, r.port) then
        if _im.SmallButton("-Fav##rf" .. rid) then M.removeFavorite(r.serverId, r.host, r.port) end
      else
        if _im.SmallButton("+Fav##rf" .. rid) then M.addFavorite(r.serverId, r.host, r.port, r.name) end
      end
    end
    _im.EndTable()
  end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Main render — called every frame by highbeam.lua onPreRender
-- ──────────────────────────────────────────────────────────────────────────────

M.renderUI = function()
  _bridgePoll()
  _communityPoll()
  _resolvePoll()

  if not M._visible     then return end
  if not ui_imgui       then return end
  if not _im            then _im = ui_imgui; _ffi = require("ffi") end
  _initBufs()
  if not _bufs then return end

  if _resolve.state == "resolving" then M._connectError = "Resolving server address..." end

  -- ImGuiCond_FirstUseEver = 4
  _im.SetNextWindowSize(_im.ImVec2(760, 540), 4)
  _im.SetNextWindowPos( _im.ImVec2(160, 160), 4)

  if _im.Begin("HighBeam Multiplayer##hb_main") then
    if M._connectError ~= "" then
      _im.TextColored(_im.ImVec4(1, 0.3, 0.3, 1), M._connectError)
      _im.Separator()
    end
    if _im.BeginTabBar("##hb_tabs") then
      if _im.BeginTabItem("Direct Connect##hb_t0") then _tabDirectConnect(); _im.EndTabItem() end
      if _im.BeginTabItem("Browse Servers##hb_t1") then _tabBrowse();        _im.EndTabItem() end
      if _im.BeginTabItem("Favorites##hb_t2")      then _tabFavorites();     _im.EndTabItem() end
      if _im.BeginTabItem("Recent##hb_t3")         then _tabRecent();        _im.EndTabItem() end
      _im.EndTabBar()
    end
    _im.Separator(); _im.Spacing()
    _im.TextDisabled("HighBeam Multiplayer Mod")
    _im.SameLine()
    if _im.SmallButton("Close##hb_close") then M._visible = false end
  end
  _im.End()
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ──────────────────────────────────────────────────────────────────────────────

M.load = function(conn, cfg)
  _connection = conn
  _config     = cfg
  M.loadFavorites()
  M.loadRecents()
  M.loadCommunityNodes()
  M._visible = true
  log("I", logTag, "Browser module loaded (window visible)")
end

return M
