local M = {}
local logTag = "HighBeam.Overlay"

local _im = nil
local _ffi = nil

local _connection = nil
local _vehicles = nil
local _state = nil
local _chat = nil
local _config = nil

local _visible = false
local _rows = {}
local _refreshTimer = 0
local _refreshInterval = 0.125
local _chatInput = nil

local function _localPos()
  if core_camera and core_camera.getPosition then
    local p = core_camera.getPosition()
    if p then return { p.x, p.y, p.z } end
  end
  return nil
end

local function _distanceMeters(a, b)
  if not a or not b then return nil end
  local dx = a[1] - b[1]
  local dy = a[2] - b[2]
  local dz = a[3] - b[3]
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function _fmtPing(pingMs)
  if type(pingMs) ~= "number" then return "--" end
  return tostring(math.floor(pingMs + 0.5)) .. " ms"
end

local function _fmtDistance(distM)
  if type(distM) ~= "number" then return "--" end
  return tostring(math.floor(distM + 0.5)) .. " m"
end

local function _collectRows()
  local players = _connection and _connection.getPlayers and _connection.getPlayers() or {}
  local localPos = _localPos()
  local rows = {}

  for pid, info in pairs(players or {}) do
    local summary = _vehicles and _vehicles.getPlayerActiveVehicle and _vehicles.getPlayerActiveVehicle(pid) or nil
    local dist = _distanceMeters(localPos, summary and summary.position or nil)

    table.insert(rows, {
      playerId = pid,
      name = (info and info.name) or ("Player " .. tostring(pid)),
      ping_ms = info and info.ping_ms or nil,
      distance_m = dist,
      car = (summary and summary.model) or "--",
    })
  end

  table.sort(rows, function(a, b)
    if a.distance_m and b.distance_m then
      if a.distance_m ~= b.distance_m then
        return a.distance_m < b.distance_m
      end
    elseif a.distance_m and not b.distance_m then
      return true
    elseif not a.distance_m and b.distance_m then
      return false
    end
    return tostring(a.name) < tostring(b.name)
  end)

  _rows = rows
end

local function _sendChatFromInput()
  if not _chatInput or not _ffi then return end
  local txt = _ffi.string(_chatInput or "")
  txt = tostring(txt or ""):match("^%s*(.-)%s*$")
  if txt == "" then return end

  local sent = _chat and _chat.send and _chat.send(txt)
  if sent then
    _chatInput = _im.ArrayChar(256, "")
  else
    if _chat and _chat.systemMessage then
      _chat.systemMessage("Failed to send message")
    end
  end
end

M.load = function(connectionRef, vehiclesRef, stateRef, chatRef, configRef)
  _connection = connectionRef
  _vehicles = vehiclesRef
  _state = stateRef
  _chat = chatRef
  _config = configRef

  local refreshHz = _config and _config.get and _config.get("overlayRefreshHz") or nil
  if type(refreshHz) == "number" and refreshHz > 0 then
    _refreshInterval = 1.0 / math.max(1.0, refreshHz)
  end

  _visible = not (_config and _config.get and _config.get("overlayVisible") == false)
  _collectRows()
  log('I', logTag, 'Overlay loaded visible=' .. tostring(_visible))
end

M.onConnectionStatus = function(status, _detail)
  if status == "connected" then
    _collectRows()
    if _config and _config.get and _config.get("overlayVisible") ~= false then
      _visible = true
    end
  elseif status == "disconnected" or status == "reconnect_failed" then
    _collectRows()
  end
end

M.open = function()
  _visible = true
  if _config and _config.set then
    _config.set("overlayVisible", true)
    _config.save()
  end
end

M.close = function()
  _visible = false
  if _config and _config.set then
    _config.set("overlayVisible", false)
    _config.save()
  end
end

M.toggle = function()
  if _visible then M.close() else M.open() end
end

M.isVisible = function()
  return _visible
end

M.tick = function(dt)
  _refreshTimer = _refreshTimer + (dt or 0)
  if _refreshTimer >= _refreshInterval then
    _refreshTimer = 0
    _collectRows()
  end
end

M.render = function()
  if not _visible then return end
  if not ui_imgui then return end

  if not _im then
    _im = ui_imgui
    _ffi = require("ffi")
  end
  if not _chatInput then
    _chatInput = _im.ArrayChar(256, "")
  end

  local state = _connection and _connection.getState and _connection.getState() or -1
  local connected = _connection and _connection.STATE_CONNECTED and state == _connection.STATE_CONNECTED

  _im.SetNextWindowSize(_im.ImVec2(600, 420), 4)
  _im.SetNextWindowPos(_im.ImVec2(40, 180), 4)

  if _im.Begin("HighBeam Live Overlay##hb_overlay") then
    _im.Text("Players: " .. tostring(#_rows))
    _im.SameLine()
    if connected then
      _im.TextColored(_im.ImVec4(0.5, 1.0, 0.5, 1.0), "Connected")
    else
      _im.TextColored(_im.ImVec4(1.0, 0.5, 0.5, 1.0), "Disconnected")
    end
    _im.SameLine()
    if _im.SmallButton("Hide##hb_overlay_hide") then
      M.close()
    end

    _im.Separator()

    -- P0.1: Sync debug panel (toggled via debugOverlay config)
    local debugOverlay = _config and _config.get and _config.get("debugOverlay")
    if debugOverlay then
      local stats = _vehicles and _vehicles._debugStats or {}
      local conn = _connection or {}
      local stateStats = _state and _state._debugStats or {}
      local interpDelay = _config and _config.get and _config.get("interpolationDelayMs") or 100
      _im.TextColored(_im.ImVec4(0.8, 0.8, 0.3, 1.0), "Sync Debug")
      _im.Text("  InterpDelay: " .. tostring(interpDelay) .. " ms")
      _im.Text("  AvgCorrPos: " .. string.format("%.4f", stats.avgCorrectionPos or 0) .. " m")
      _im.Text("  AvgCorrRot: " .. string.format("%.5f", stats.avgCorrectionRot or 0))
      _im.Text("  Corrections: " .. tostring(stats.correctionCount or 0)
        .. "  Teleports: " .. tostring(stats.teleportCount or 0))
      _im.Text("  SendRate: " .. tostring(stateStats.sendRateHz or 0) .. " Hz"
        .. "  Sent: " .. tostring(stateStats.sentPackets or 0)
        .. "  Skipped: " .. tostring(stateStats.skippedUnchanged or 0))
      _im.Text("  AvgSendSpeed: " .. string.format("%.2f", stateStats.avgSendSpeed or 0) .. " m/s")
      _im.Text("  UDP RxRate: " .. tostring(conn._udpRxRateHz or 0) .. " pkt/s"
        .. "  TotalRx: " .. tostring(conn._udpRxCount or 0))
      _im.Separator()
    end

    if _im.BeginTable("##hb_overlay_table", 4, 64 + 1920 + 8) then
      _im.TableSetupColumn("Player")
      _im.TableSetupColumn("Ping")
      _im.TableSetupColumn("Distance")
      _im.TableSetupColumn("Current Car")
      _im.TableHeadersRow()

      for _, row in ipairs(_rows) do
        _im.TableNextRow()
        _im.TableSetColumnIndex(0); _im.Text(tostring(row.name))
        _im.TableSetColumnIndex(1); _im.Text(_fmtPing(row.ping_ms))
        _im.TableSetColumnIndex(2); _im.Text(_fmtDistance(row.distance_m))
        _im.TableSetColumnIndex(3); _im.Text(tostring(row.car))
      end
      _im.EndTable()
    end

    _im.Separator()
    _im.Text("Chat")

    local messages = (_chat and _chat.messages) or {}
    local total = #messages
    local first = math.max(1, total - 11)
    for i = first, total do
      local msg = messages[i]
      if msg then
        local who = msg.system and "[System]" or (msg.name or "Player")
        local text = msg.message or ""
        _im.TextWrapped(who .. ": " .. tostring(text))
      end
    end

    _im.Separator()
    _im.PushItemWidth(470)
    _im.InputText("##hb_overlay_chat_input", _chatInput, 256)
    _im.PopItemWidth()
    _im.SameLine()
    if _im.Button("Send##hb_overlay_chat_send") then
      _sendChatFromInput()
    end
  end
  _im.End()
end

return M
