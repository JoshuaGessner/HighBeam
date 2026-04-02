-- HighBeam Browser — in-game server browser, favorites, recents, and direct connect
-- Renders an IMGUI window via the BeamNG GE extension onPreRender hook.

local M = {}
local logTag = "HighBeam.Browser"

local MAX_RECENTS   = 10
local MAX_FAVORITES = 50

-- ──────────────────────────────────────────────────────────────────────────────
-- JSON helpers (Engine.JSONEncode/Decode -> require("json") fallback)
-- Defined early because bridge functions below use them.
-- ──────────────────────────────────────────────────────────────────────────────

local function _jsonEncode(t)
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

-- Strip % (ImGui format specifiers) and ASCII control chars from relay-provided strings.
local function _sanitize(s)
  return (tostring(s):gsub("[%%%c]", ""))
end

-- Returns true when a host string is a loopback or private-range address.
-- Rejects relay-injected entries that would redirect connections to localhost or LAN.
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

-- Visibility and state
M._visible      = false
M._connectError = ""

-- Data stores
M._favorites    = {}   -- [{host, port, name, description, addedAt}]
M._recents      = {}   -- [{host, port, name, connectedAt}]
M._relayServers = {}   -- [{host, port, name, map, players, maxPlayers, pingMs, isFav}]

-- Relay fetch state: "", "fetching", "done", "error"
M._fetchStatus  = ""
M._fetchError   = ""

-- Async HTTP fetch state machine (polled every frame by _relayPoll)
M._relayFetch   = { state = "idle", sock = nil, buf = "", bytes = 0 }
-- Async ping queue: list of {sock, sentAt, index} for in-flight UDP pings
M._pingQueue    = {}

-- Pending recent entry: set on connect(), cleared after onConnected()
local _pendingRecent = nil

-- ──────────────────────────────────────────────────────────────────────────────
-- File I/O helpers (FS: API → io.open fallback)
-- ──────────────────────────────────────────────────────────────────────────────

local SAVE_DIR = "userdata/highbeam"
local FAV_FILE = SAVE_DIR .. "/favorites.json"
local REC_FILE = SAVE_DIR .. "/recents.json"

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
    os.execute('mkdir "' .. SAVE_DIR:gsub('/', '\\') .. '" 2>nul')
  else
    os.execute('mkdir -p "' .. SAVE_DIR .. '" 2>/dev/null')
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

-- Proceed with a direct connection (no IPC required or IPC unavailable)
local function _bridgeDirectConnect()
  local p = M._bridge.pending
  if not p then return end
  M._bridge.pending = nil
  M._visible = false
  _connection.connect(p.host, p.port, p.username,
    (p.password and p.password ~= "" and p.password or nil))
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
  local content = _readFile(IPC_STATE_FILE)
  if content then
    local state = _jsonDecode(content)
    if state and tonumber(state.port) then
      M._bridge.port = tonumber(state.port)
      _bridgeConnect(targetHost, targetPort)
      return
    end
  end
  -- Launcher not detected; connect directly (mods already staged or server needs no mods)
  M._bridge.state = "unavailable"
  log('I', logTag, 'Launcher IPC not detected; connecting directly')
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
-- Persistence — Favorites
-- ──────────────────────────────────────────────────────────────────────────────

M.loadFavorites = function()
  local c = _readFile(FAV_FILE)
  if not c then M._favorites = {}; return end
  local d = _jsonDecode(c)
  M._favorites = (type(d) == "table" and type(d.favorites) == "table") and d.favorites or {}
  log('I', logTag, 'Loaded ' .. #M._favorites .. ' favorites')
end

M.saveFavorites = function()
  _writeFile(FAV_FILE, _jsonEncode({ favorites = M._favorites }))
end

M.isFavorite = function(host, port)
  for _, f in ipairs(M._favorites) do
    if f.host == host and f.port == port then return true end
  end
  return false
end

M.addFavorite = function(host, port, name, description)
  M.removeFavorite(host, port)
  if #M._favorites >= MAX_FAVORITES then table.remove(M._favorites, 1) end
  table.insert(M._favorites, {
    host        = host,
    port        = port,
    name        = name or (host .. ":" .. tostring(port)),
    description = description or "",
    addedAt     = os.time(),
  })
  M.saveFavorites()
  -- Refresh isFav flag in relay list
  for _, s in ipairs(M._relayServers) do
    if s.host == host and s.port == port then s.isFav = true end
  end
end

M.removeFavorite = function(host, port)
  for i = #M._favorites, 1, -1 do
    if M._favorites[i].host == host and M._favorites[i].port == port then
      table.remove(M._favorites, i)
    end
  end
  M.saveFavorites()
  for _, s in ipairs(M._relayServers) do
    if s.host == host and s.port == port then s.isFav = false end
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
  log('I', logTag, 'Loaded ' .. #M._recents .. ' recents')
end

M.saveRecents = function()
  _writeFile(REC_FILE, _jsonEncode({ recents = M._recents }))
end

M.addRecent = function(host, port, serverName)
  for i = #M._recents, 1, -1 do
    if M._recents[i].host == host and M._recents[i].port == port then
      table.remove(M._recents, i)
    end
  end
  table.insert(M._recents, 1, {
    host        = host,
    port        = port,
    name        = serverName or (host .. ":" .. tostring(port)),
    connectedAt = os.time(),
  })
  while #M._recents > MAX_RECENTS do table.remove(M._recents) end
  M.saveRecents()
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Network — relay HTTP fetch (async) and UDP ping (async)
-- ──────────────────────────────────────────────────────────────────────────────

local HTTP_BODY_LIMIT = 512 * 1024  -- bytes; relay lists beyond this are malformed/malicious

-- Send UDP discovery pings to listed servers (non-blocking) and queue sockets for
-- response collection by _pingPoll each frame.  Defined first; called by _parseRelayBody.
local function _launchPings()
  M._pingQueue = {}
  local sok, socket = pcall(require, "socket")
  if not sok then return end
  local limit = math.min(#M._relayServers, 8)
  for i = 1, limit do
    local s = M._relayServers[i]
    local udp = socket.udp()
    if udp then
      udp:settimeout(0)
      local ok = pcall(function()
        udp:setpeername(s.host, s.port)
        udp:send(string.char(0x7A))  -- HighBeam discovery query byte
      end)
      if ok then
        table.insert(M._pingQueue, { sock = udp, sentAt = os.clock(), index = i })
      else
        udp:close()
      end
    end
  end
end

-- Collect any arrived ping responses without blocking; called every frame from renderUI.
local function _pingPoll()
  if #M._pingQueue == 0 then return end
  local remaining = {}
  for _, p in ipairs(M._pingQueue) do
    local resp, _ = p.sock:receive()
    if resp then
      local ms = math.floor((os.clock() - p.sentAt) * 1000)
      if M._relayServers[p.index] then
        M._relayServers[p.index].pingMs = ms
      end
      p.sock:close()
    elseif (os.clock() - p.sentAt) > 1.0 then
      p.sock:close()  -- 1 s hard timeout; no response
    else
      table.insert(remaining, p)
    end
  end
  M._pingQueue = remaining
end

-- Parse a complete HTTP response buffer, validate + sanitize entries, and populate
-- M._relayServers.  Supports both {host, port} and {addr = "host:port"} relay formats.
local function _parseRelayBody(raw)
  local status = raw:match("HTTP/%S+ (%d+)") or "?"
  local body   = raw:match("\r\n\r\n(.*)$") or ""
  if status ~= "200" then
    M._fetchStatus = "error"
    M._fetchError  = "HTTP " .. status
    log('W', logTag, 'Relay HTTP error: ' .. status)
    return
  end
  local data = _jsonDecode(body)
  local list = (type(data) == "table" and type(data.servers) == "table" and data.servers)
            or (type(data) == "table" and #data > 0 and data)
            or {}
  local result = {}
  for _, s in ipairs(list) do
    if type(s) == "table" then
      -- Support both {host, port} (common) and {addr = "host:port"} (Rust relay struct) formats
      local h, p = s.host or s.address, tonumber(s.port)
      if not h and type(s.addr) == "string" and s.addr ~= "" then
        local ah, ap = s.addr:match("^(.+):(%d+)$")
        h = ah; p = p or tonumber(ap)
      end
      h = h and tostring(h) or ""
      p = p or 18860
      -- Validate: reject empty, private/loopback, oversized, or invalid hostnames
      if h ~= "" and not _isPrivateAddr(h) and #h <= 253
         and h:match("^[%w%.%-]+$") then
        table.insert(result, {
          host       = h,
          port       = math.max(1, math.min(65535, p)),
          name       = _sanitize(s.name  or (h .. ":" .. p)):sub(1, 64),
          map        = _sanitize(s.map   or "?"):sub(1, 64),
          players    = tonumber(s.players)                       or 0,
          maxPlayers = tonumber(s.max_players or s.maxPlayers)   or 0,
          pingMs     = nil,
          isFav      = M.isFavorite(h, p),
        })
      end
    end
  end
  M._relayServers = result
  M._fetchStatus  = "done"
  log('I', logTag, 'Relay returned ' .. #result .. ' server(s)')
  _launchPings()
end

-- Drive the async HTTP receive state machine; called every frame from renderUI.
local function _relayPoll()
  local f = M._relayFetch
  if f.state ~= "receiving" then return end
  while true do
    local chunk, err, partial = f.sock:receive(4096)
    local data = chunk or partial
    if data and data ~= "" then
      f.bytes = f.bytes + #data
      if f.bytes > HTTP_BODY_LIMIT then
        f.sock:close(); f.sock = nil; f.state = "error"
        M._fetchStatus = "error"
        M._fetchError  = "Relay response exceeds 512 KB limit"
        log('W', logTag, M._fetchError)
        return
      end
      f.buf = f.buf .. data
    end
    if err == "closed" then
      f.sock:close(); f.sock = nil; f.state = "done"
      _parseRelayBody(f.buf)
      return
    elseif err == "timeout" then
      return  -- no data this frame; come back next frame
    elseif err then
      f.sock:close(); f.sock = nil; f.state = "error"
      M._fetchStatus = "error"
      M._fetchError  = tostring(err)
      log('W', logTag, 'Relay receive error: ' .. M._fetchError)
      return
    end
    if not chunk then break end
  end
end

M.fetchRelayServers = function(relayUrl)
  if M._fetchStatus == "fetching" then return end
  if not relayUrl or relayUrl:match("^%s*$") then return end

  -- Reject https:// — LuaSocket cannot perform TLS; the scheme would be silently ignored,
  -- leaving the user falsely believing the connection is encrypted.
  if relayUrl:match("^https://") then
    M._fetchStatus = "error"
    M._fetchError  = "HTTPS relay URLs are not supported — use http://"
    log('W', logTag, M._fetchError)
    return
  end

  -- Parse URL
  local host, portStr, path = relayUrl:match("^http://([^/:]+):?(%d*)(/?[^%s]*)$")
  if not host then
    M._fetchStatus = "error"
    M._fetchError  = "Invalid relay URL: " .. tostring(relayUrl)
    return
  end
  local port = tonumber(portStr) or 80
  path = (path == "" and "/" or path)
  -- Normalise path: append /servers when no explicit sub-path is present
  local trimmed = relayUrl:gsub("/$", "")
  if not trimmed:match("^http://[^/]+/") then
    path = "/servers"
  end

  M._fetchStatus  = "fetching"
  M._relayServers = {}
  M._fetchError   = ""
  M._relayFetch   = { state = "idle", sock = nil, buf = "", bytes = 0 }

  log('I', logTag, 'Fetching relay: http://' .. host .. ':' .. port .. path)

  local sok, socket = pcall(require, "socket")
  if not sok then
    M._fetchStatus = "error"; M._fetchError = "LuaSocket not available"; return
  end
  local tcp = socket.tcp()
  tcp:settimeout(2)  -- 2 s blocking connect; relay is on public internet
  local ok, err = tcp:connect(host, port)
  if not ok then
    tcp:close()
    M._fetchStatus = "error"
    M._fetchError  = "Connection failed: " .. tostring(err)
    log('W', logTag, 'Relay connect failed: ' .. M._fetchError)
    return
  end
  tcp:send("GET " .. path .. " HTTP/1.0\r\nHost: " .. host .. "\r\nConnection: close\r\n\r\n")
  tcp:settimeout(0)  -- switch to non-blocking; receive is driven by _relayPoll each frame
  M._relayFetch = { state = "receiving", sock = tcp, buf = "", bytes = 0 }
end

M.pingServer = function(host, port, callback)
  local sok, socket = pcall(require, "socket")
  if not sok then if callback then callback(nil) end; return end
  local udp = socket.udp()
  if not udp then if callback then callback(nil) end; return end
  udp:settimeout(0.5)
  local ok = pcall(function()
    udp:setpeername(host, port)
    udp:send(string.char(0x7A))  -- HighBeam discovery query byte
  end)
  if not ok then udp:close(); if callback then callback(nil) end; return end
  local t0   = os.clock()
  local resp = udp:receive()
  local ms   = resp and math.floor((os.clock() - t0) * 1000) or nil
  udp:close()
  if callback then callback(ms) end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Connect
-- ──────────────────────────────────────────────────────────────────────────────

M.connect = function(host, port, username, password, serverName)
  host     = (host     or ""):match("^%s*(.-)%s*$")
  username = (username or ""):match("^%s*(.-)%s*$")
  if host     == "" then return false, "Host is required"      end
  if username == "" then return false, "Username is required"  end
  port = tonumber(port) or 18860
  if not _connection then return false, "Browser not initialised" end
  -- Guard: refuse to stomp an active session
  if _connection.state == _connection.STATE_CONNECTED or
     _connection.state == _connection.STATE_CONNECTING or
     _connection.state == _connection.STATE_AUTHENTICATING then
    return false, "Already connected — disconnect first"
  end

  -- Persist last-used values so they survive a session restart
  if _config then
    _config.set("username",          username)
    _config.set("directConnectHost", host)
    _config.set("directConnectPort", port)
    if _bufs then
      local relayStr = _ffi.string(_bufs.relay):match("^%s*(.-)%s*$")
      if relayStr ~= "" then _config.set("relayUrl", relayStr) end
    end
    _config.save()
  end

  _pendingRecent  = { host = host, port = port, name = serverName }
  M._connectError = ""

  -- Store pending connect details for the bridge state machine
  M._bridge.pending = {
    host = host, port = port, username = username,
    password = password, name = serverName,
  }
  M._bridge.error = nil

  -- Ask the launcher to sync mods first; falls back to direct connect if unavailable
  _bridgeInitiate(host, port)
  return true
end

-- Called by the main extension when the connection transitions to CONNECTED
M.onConnected = function()
  if _pendingRecent then
    local label = _pendingRecent.name
              or (_pendingRecent.host .. ":" .. tostring(_pendingRecent.port))
    M.addRecent(_pendingRecent.host, _pendingRecent.port, label)
    _pendingRecent = nil
  end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Visibility
-- ──────────────────────────────────────────────────────────────────────────────

M.open  = function() M._visible = true  end
M.close = function() M._visible = false end
M.isOpen = function() return M._visible  end

-- ──────────────────────────────────────────────────────────────────────────────
-- IMGUI rendering helpers
-- ──────────────────────────────────────────────────────────────────────────────

-- ImGui table flags: RowBg(64) + Borders(1920) + ScrollY(16384)
local TBL_FLAGS = bit.bor(64, 1920, 16384)

-- ImGuiInputTextFlags_Password = 1 << 15 = 32768
local PW_FLAG   = 32768

local function _initBufs()
  if _bufs then return end
  _im  = ui_imgui
  _ffi = require("ffi")
  if not _im or not _ffi then return end

  local savedHost  = (_config and _config.get("directConnectHost")) or ""
  local savedPort  = tostring((_config and _config.get("directConnectPort")) or 18860)
  local savedUser  = (_config and _config.get("username"))          or ""
  local savedRelay = (_config and _config.get("relayUrl"))          or ""

  _bufs = {
    host     = _im.ArrayChar(256, savedHost),
    port     = _im.ArrayChar(16,  savedPort),
    username = _im.ArrayChar(64,  savedUser),
    password = _im.ArrayChar(128, ""),
    relay    = _im.ArrayChar(256, savedRelay),
  }
end

local function _pingColor(ms)
  if ms == nil then return nil end
  if ms <= 80  then return _im.ImVec4(0.40, 0.95, 0.40, 1.0) end
  if ms <= 150 then return _im.ImVec4(1.00, 0.90, 0.25, 1.0) end
  return _im.ImVec4(1.0, 0.30, 0.30, 1.0)
end

local function _connectBtn(host, port, id, serverName)
  if _im.SmallButton("Connect##c" .. id) then
    local username = _ffi.string(_bufs.username):match("^%s*(.-)%s*$")
    if username == "" then
      M._connectError = "Enter a username on the Direct Connect tab first."
    else
      local ok, err = M.connect(host, port, username, nil, serverName)
      if not ok then M._connectError = err or "" end
    end
  end
end

local function _favBtn(host, port, id, serverName)
  if M.isFavorite(host, port) then
    if _im.SmallButton("- Fav##f" .. id) then M.removeFavorite(host, port) end
    if _im.IsItemHovered() then _im.SetTooltip("Remove from favorites") end
  else
    if _im.SmallButton("+ Fav##f" .. id) then M.addFavorite(host, port, serverName) end
    if _im.IsItemHovered() then _im.SetTooltip("Add to favorites") end
  end
end

local function _serverRow(s, showRemove, rowIdx)
  _im.TableNextRow()
  _im.TableSetColumnIndex(0); _im.Text(s.name or (s.host .. ":" .. tostring(s.port)))
  _im.TableSetColumnIndex(1); _im.Text(s.map or "?")
  _im.TableSetColumnIndex(2); _im.Text(tostring(s.players or 0) .. "/" .. tostring(s.maxPlayers or 0))
  _im.TableSetColumnIndex(3)
  local c = _pingColor(s.pingMs)
  if c   then _im.TextColored(c, tostring(s.pingMs) .. "ms")
  else        _im.TextDisabled("-") end
  _im.TableSetColumnIndex(4)
  -- Include row index in ID to prevent collisions when two entries share host:port
  local rid = tostring(rowIdx) .. "_" .. s.host .. "_" .. tostring(s.port)
  _connectBtn(s.host, s.port, rid)
  _im.SameLine()
  if showRemove then
    if _im.SmallButton("Remove##r" .. rid) then M.removeFavorite(s.host, s.port) end
  else
    _favBtn(s.host, s.port, rid, s.name)
  end
end

local function _serverTable(list, id, showRemove)
  if #list == 0 then return false end
  if _im.BeginTable(id, 5, TBL_FLAGS, _im.ImVec2(0, 280)) then
    _im.TableSetupScrollFreeze(0, 1)
    _im.TableSetupColumn("Name");    _im.TableSetupColumn("Map")
    _im.TableSetupColumn("Players"); _im.TableSetupColumn("Ping")
    _im.TableSetupColumn("Actions")
    _im.TableHeadersRow()
    for i, s in ipairs(list) do _serverRow(s, showRemove, i) end
    _im.EndTable()
  end
  return true
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Tab: Direct Connect
-- ──────────────────────────────────────────────────────────────────────────────

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

  -- Launcher bridge status (Phase C)
  local bridgeSyncing = M._bridge.state == "syncing"
  if bridgeSyncing then
    _im.TextColored(_im.ImVec4(0.3, 0.7, 1.0, 1.0), "Syncing mods with launcher…")
    _im.TextDisabled("Please wait — downloading required server mods.")
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

-- ──────────────────────────────────────────────────────────────────────────────
-- Tab: Browse Servers
-- ──────────────────────────────────────────────────────────────────────────────

local function _tabBrowse()
  _im.Spacing()
  _im.Text("Relay URL")
  _im.SameLine()
  _im.SetNextItemWidth(340)
  _im.InputText("##hb_relay", _bufs.relay, 256)
  _im.SameLine()

  if M._fetchStatus == "fetching" then
    _im.TextDisabled("Fetching...")
  else
    if _im.Button("Refresh##hb_ref") then
      local url = _ffi.string(_bufs.relay):match("^%s*(.-)%s*$")
      if url ~= "" then
        if _config then _config.set("relayUrl", url); _config.save() end
        M.fetchRelayServers(url)
      else
        M._fetchStatus = "error"
        M._fetchError  = "Enter a relay URL first"
      end
    end
  end

  if M._fetchStatus == "error" then
    _im.TextColored(_im.ImVec4(1, 0.35, 0.35, 1), "Error: " .. M._fetchError)
  elseif M._fetchStatus == "done" then
    _im.TextDisabled(tostring(#M._relayServers) .. " server(s) found — green ≤80ms / yellow ≤150ms / red >150ms")
  else
    _im.TextDisabled("Enter a relay URL and click Refresh to list public servers.")
  end

  _im.Spacing()
  if not _serverTable(M._relayServers, "##srv_browse", false) then
    _im.TextDisabled("No servers loaded.")
  end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Tab: Favorites
-- ──────────────────────────────────────────────────────────────────────────────

local function _tabFavorites()
  _im.Spacing()
  if not _serverTable(M._favorites, "##srv_fav", true) then
    _im.TextDisabled("No favorites saved.")
    _im.TextDisabled("Browse servers and click  + Fav  to save one.")
  end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Tab: Recent
-- ──────────────────────────────────────────────────────────────────────────────

local function _tabRecent()
  _im.Spacing()
  if #M._recents == 0 then
    _im.TextDisabled("No recent servers yet.")
    return
  end

  if _im.BeginTable("##srv_rec", 4, TBL_FLAGS, _im.ImVec2(0, 280)) then
    _im.TableSetupScrollFreeze(0, 1)
    _im.TableSetupColumn("Server")
    _im.TableSetupColumn("Last Connected")
    _im.TableSetupColumn("Actions")
    _im.TableSetupColumn("Favorite")
    _im.TableHeadersRow()
    for i, s in ipairs(M._recents) do
      _im.TableNextRow()
      _im.TableSetColumnIndex(0)
      _im.Text(s.name or (s.host .. ":" .. tostring(s.port)))
      _im.TableSetColumnIndex(1)
      _im.TextDisabled(os.date("%Y-%m-%d %H:%M", s.connectedAt or 0))
      _im.TableSetColumnIndex(2)
      local rid = "re_" .. tostring(i) .. "_" .. s.host .. "_" .. tostring(s.port)
      _connectBtn(s.host, s.port, rid, s.name)
      _im.TableSetColumnIndex(3)
      _favBtn(s.host, s.port, rid, s.name)
    end
    _im.EndTable()
  end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Main render — called every frame by highbeam.lua onPreRender
-- ──────────────────────────────────────────────────────────────────────────────

M.renderUI = function()
  -- Poll launcher bridge every frame (no-op when not syncing)
  _bridgePoll()
  -- Poll async relay HTTP receive and ping collection every frame
  _relayPoll()
  _pingPoll()

  if not M._visible     then return end
  if not ui_imgui       then return end
  if not _im            then _im = ui_imgui; _ffi = require("ffi") end
  _initBufs()
  if not _bufs then return end

  -- ImGuiCond_FirstUseEver = 4 (position/size only set the very first time)
  _im.SetNextWindowSize(_im.ImVec2(700, 500), 4)
  _im.SetNextWindowPos( _im.ImVec2(160, 160), 4)

  if _im.Begin("HighBeam Multiplayer##hb_main") then
    if _im.BeginTabBar("##hb_tabs") then
      if _im.BeginTabItem("Direct Connect##hb_t0") then _tabDirectConnect(); _im.EndTabItem() end
      if _im.BeginTabItem("Browse Servers##hb_t1") then _tabBrowse();        _im.EndTabItem() end
      if _im.BeginTabItem("Favorites##hb_t2")      then _tabFavorites();     _im.EndTabItem() end
      if _im.BeginTabItem("Recent##hb_t3")         then _tabRecent();        _im.EndTabItem() end
      _im.EndTabBar()
    end

    _im.Separator()
    _im.Spacing()
    _im.TextDisabled("HighBeam Multiplayer Mod  |  close: extensions.highbeam.closeBrowser()")
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
  -- Auto-open so the user sees the browser immediately on load
  M._visible = true
  log('I', logTag, 'Browser module loaded (window visible)')
end

return M
