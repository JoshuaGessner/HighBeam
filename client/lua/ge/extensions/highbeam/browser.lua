-- HighBeam Browser — in-game server browser, favorites, recents, and direct connect
-- Renders an IMGUI window via the BeamNG GE extension onPreRender hook.

local M = {}
local logTag = "HighBeam.Browser"

local MAX_RECENTS   = 10
local MAX_FAVORITES = 50

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

-- Pending recent entry: set on connect(), cleared after onConnected()
local _pendingRecent = nil

-- Subsystem refs (injected by load())
local _connection = nil
local _config     = nil

-- ImGui / FFI handles (loaded lazily on first render)
local _im  = nil
local _ffi = nil

-- UI input buffers (allocated once, persist between renders)
local _bufs = nil

-- ──────────────────────────────────────────────────────────────────────────────
-- JSON helpers (Engine.JSONEncode/Decode → require("json") fallback)
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

-- ──────────────────────────────────────────────────────────────────────────────
-- File I/O helpers (FS: API → io.open fallback)
-- ──────────────────────────────────────────────────────────────────────────────

local SAVE_DIR = "userdata/highbeam"
local FAV_FILE = SAVE_DIR .. "/favorites.json"
local REC_FILE = SAVE_DIR .. "/recents.json"

local function _ensureDir()
  pcall(function() FS:directoryCreate(SAVE_DIR) end)
end

local function _readFile(path)
  if FS then
    local ok, c = pcall(function() return FS:readFileToString(path) end)
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
  if FS then
    local ok = pcall(function() FS:writeFile(path, content) end)
    if ok then return end
  end
  local f = io.open(path, "w")
  if f then f:write(content); f:close() end
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
-- Network — relay HTTP fetch and UDP ping
-- ──────────────────────────────────────────────────────────────────────────────

-- Plain HTTP GET over TCP (no TLS; relay is expected to serve plain HTTP)
local function _httpGet(url, timeoutSec)
  timeoutSec = timeoutSec or 5
  local host, portStr, path = url:match("^https?://([^/:]+):?(%d*)(/?[^%s]*)$")
  if not host then return nil, "invalid URL: " .. tostring(url) end
  local port = tonumber(portStr) or 80
  path = (path == "" and "/" or path)
  local sok, sock = pcall(require, "socket")
  if not sok then return nil, "LuaSocket not available" end
  local tcp = sock.tcp()
  tcp:settimeout(timeoutSec)
  local ok, err = tcp:connect(host, port)
  if not ok then tcp:close(); return nil, "TCP connect: " .. tostring(err) end
  tcp:send("GET " .. path .. " HTTP/1.0\r\nHost: " .. host .. "\r\nConnection: close\r\n\r\n")
  local parts = {}
  while true do
    local chunk, _err, partial = tcp:receive(4096)
    if partial and partial ~= "" then table.insert(parts, partial) end
    if not chunk then break end
    table.insert(parts, chunk)
  end
  tcp:close()
  local resp   = table.concat(parts)
  local status = resp:match("HTTP/%S+ (%d+)") or "?"
  local body   = resp:match("\r\n\r\n(.*)$") or ""
  if status ~= "200" then return nil, "HTTP " .. status end
  return body
end

M.fetchRelayServers = function(relayUrl)
  if M._fetchStatus == "fetching" then return end
  if not relayUrl or relayUrl:match("^%s*$") then return end
  M._fetchStatus  = "fetching"
  M._relayServers = {}
  M._fetchError   = ""

  -- Normalise URL: append /servers when no explicit path is present
  local url = relayUrl:gsub("/$", "")
  if not url:match("^https?://[^/]+/") then
    url = url .. "/servers"
  end

  log('I', logTag, 'Fetching relay: ' .. url)
  local body, err = _httpGet(url, 5)
  if not body then
    M._fetchStatus = "error"
    M._fetchError  = tostring(err)
    log('W', logTag, 'Relay fetch failed: ' .. M._fetchError)
    return
  end

  local data = _jsonDecode(body)
  local list = (type(data) == "table" and type(data.servers) == "table" and data.servers)
            or (type(data) == "table" and #data > 0 and data)
            or {}
  local result = {}
  for _, s in ipairs(list) do
    if type(s) == "table" then
      local h = tostring(s.host or s.address or "")
      local p = tonumber(s.port) or 18860
      if h ~= "" then
        table.insert(result, {
          host       = h,
          port       = p,
          name       = tostring(s.name or (h .. ":" .. p)),
          map        = tostring(s.map or "?"),
          players    = tonumber(s.players)                          or 0,
          maxPlayers = tonumber(s.max_players or s.maxPlayers)      or 0,
          pingMs     = nil,
          isFav      = M.isFavorite(h, p),
        })
      end
    end
  end
  M._relayServers = result
  M._fetchStatus  = "done"
  log('I', logTag, 'Relay returned ' .. #result .. ' server(s)')

  -- Ping up to 8 servers for latency (blocking 0.5s each; cap prevents excessive freeze)
  local pingLimit = math.min(#M._relayServers, 8)
  for i = 1, pingLimit do
    local s = M._relayServers[i]
    M.pingServer(s.host, s.port, function(ms)
      if M._relayServers[i] then
        M._relayServers[i].pingMs = ms
      end
    end)
  end
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
  M._visible      = false
  _connection.connect(host, port, username, (password ~= "" and password or nil))
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

  if _im.Button("Connect##hb_go", _im.ImVec2(120, 28)) then
    local host     = _ffi.string(_bufs.host)
    local portVal  = tonumber(_ffi.string(_bufs.port))
    local username = _ffi.string(_bufs.username)
    local password = _ffi.string(_bufs.password)
    local ok, err  = M.connect(host, portVal, username, (password ~= "" and password or nil))
    if not ok then M._connectError = err or "Connection failed" end
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
      local rid = "re_" .. tostring(i) .. "_" .. tostring(i) .. "_" .. s.host .. "_" .. tostring(s.port)
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
