-- HighBeam - Decentralized multiplayer for BeamNG.drive
-- Main extension entry point (GELUA)

local M = {}
local logTag = "HighBeam"
local CLIENT_BUILD_MARKER = "hb-client-2026-04-04-proto-safe-v1"

-- Expose marker globally so subsystem modules can include it in diagnostics.
rawset(_G, "HIGHBEAM_CLIENT_MARKER", CLIENT_BUILD_MARKER)

-- Subsystem references (loaded in onExtensionLoaded)
local connection   -- highbeam/connection.lua
local protocol     -- highbeam/protocol.lua
local vehicles     -- highbeam/vehicles.lua
local state        -- highbeam/state.lua
local chat         -- highbeam/chat.lua
local config       -- highbeam/config.lua
local browser      -- highbeam/browser.lua
local nametags     -- highbeam/nametags.lua
local overlay      -- highbeam/overlay.lua

local MENU_ENTRY_ID = "highbeam.multiplayer"
local OVERLAY_MENU_ENTRY_ID = "highbeam.overlay"
local _menuRegistered = false

local function _safeRequire(moduleName)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    log('E', logTag, 'Failed to load module ' .. moduleName .. ': ' .. tostring(mod))
    return nil
  end
  return mod
end

local function _openBrowserFromMenu()
  if browser then
    browser.open()
  end
end

local function _toggleOverlayFromMenu()
  if overlay and overlay.toggle then
    overlay.toggle()
  end
end

local function _menuController()
  return (extensions and extensions.core_quickAccess) or core_quickAccess
end

local function _registerMenuEntry()
  local qa = _menuController()
  if not qa then
    log('D', logTag, 'core_quickAccess not available yet — will retry later')
    return false
  end

  local browserEntry = {
    id = MENU_ENTRY_ID,
    title = "HighBeam Multiplayer",
    desc = "Open server browser",
    icon = "multiplayer_gamemode",
    onSelect = _openBrowserFromMenu,
  }

  local overlayEntry = {
    id = OVERLAY_MENU_ENTRY_ID,
    title = "HighBeam Overlay",
    desc = "Toggle live chat and player stats",
    icon = "group",
    onSelect = _toggleOverlayFromMenu,
  }

  -- BeamNG builds differ in addEntry/removeEntry signatures; try method-call
  -- (qa:addEntry) and plain-function variants.
  local function _registerOne(id, entry)
    local ok = false
    if qa.addEntry then
      ok = pcall(qa.addEntry, qa, id, entry)
      if not ok then
        ok = pcall(qa.addEntry, qa, entry)
      end
      if not ok then
        ok = pcall(qa.addEntry, entry)
      end
      if not ok then
        ok = pcall(qa.addEntry, id, entry)
      end
    end
    return ok
  end

  local okBrowser = _registerOne(MENU_ENTRY_ID, browserEntry)
  local okOverlay = _registerOne(OVERLAY_MENU_ENTRY_ID, overlayEntry)

  if okBrowser or okOverlay then
    _menuRegistered = true
    log('I', logTag, 'Registered More menu entries for browser/overlay')
  else
    log('W', logTag, 'Could not register More menu entries (addEntry failed)')
  end

  return okBrowser or okOverlay
end

local function _unregisterMenuEntry()
  if not _menuRegistered then
    return
  end

  local qa = _menuController()
  if qa and qa.removeEntry then
    local ok = pcall(qa.removeEntry, MENU_ENTRY_ID)
    if not ok then
      pcall(qa.removeEntry, "HighBeam Multiplayer")
    end
    pcall(qa.removeEntry, OVERLAY_MENU_ENTRY_ID)
    pcall(qa.removeEntry, "HighBeam Overlay")
  end

  _menuRegistered = false
end

M.onExtensionLoaded = function()
  log('I', logTag, 'HighBeam extension loaded marker=' .. CLIENT_BUILD_MARKER)

  connection = _safeRequire("highbeam/connection")
  protocol   = _safeRequire("highbeam/protocol")
  vehicles   = _safeRequire("highbeam/vehicles")
  state      = _safeRequire("highbeam/state")
  chat       = _safeRequire("highbeam/chat")
  config     = _safeRequire("highbeam/config")
  browser    = _safeRequire("highbeam/browser")
  nametags   = _safeRequire("highbeam/nametags")
  overlay    = _safeRequire("highbeam/overlay")

  if not connection or not protocol or not vehicles or not state or not chat or not config or not overlay then
    log('E', logTag, 'HighBeam startup aborted due to module load failure')
    return
  end

  log('I', logTag, 'Protocol module version=' .. tostring(protocol.VERSION))

  connection.setErrorCallback(function(context, message, level)
    log(level or 'E', logTag, '[ConnectionError][' .. tostring(context) .. '] ' .. tostring(message))
  end)

  -- Notify browser when connection succeeds so it can record the recent entry
  connection.setStatusCallback(function(status, detail)
    if browser and browser.onConnectionStatus then
      browser.onConnectionStatus(status, detail)
    end
    if overlay and overlay.onConnectionStatus then
      overlay.onConnectionStatus(status, detail)
    end
    if status == "connected" and browser then
      browser.onConnected()
    end
  end)

  -- Wire subsystem cross-references
  connection.setSubsystems(vehicles, state)
  state.setSubsystems(connection, config)

  config.load()

  if browser then
    browser.load(connection, config)
  end

  if nametags then
    nametags.init(vehicles, connection, config)
  end

  if overlay then
    overlay.load(connection, vehicles, chat, config)
  end

  _registerMenuEntry()
end

M.onExtensionUnloaded = function()
  log('I', logTag, 'HighBeam extension unloaded')

  _unregisterMenuEntry()

  if connection then
    connection.disconnect()
  end
end

-- Retry menu registration after the UI is fully initialised
M.onClientPostStartMission = function()
  if not _menuRegistered then
    _registerMenuEntry()
  end
end

M.onUpdate = function(dtReal, dtSim, dtRaw)
  -- Network tick: process incoming, send outgoing
  if connection then
    connection.tick(dtReal)
  end
  -- Position sending
  if state then
    state.tick(dtReal)
  end
  -- Remote vehicle interpolation
  if vehicles then
    vehicles.tick(dtReal)
  end
  if overlay then
    overlay.tick(dtReal)
  end
end

M.onPreRender = function(dtReal, dtSim, dtRaw)
  -- Render the server browser IMGUI window every frame when it is open
  if browser then
    browser.renderUI()
  end
  -- Render player name tags above remote vehicles
  if nametags then
    nametags.render()
  end
  if overlay then
    overlay.render()
  end
end

-- ──────────────────── BeamNG vehicle lifecycle hooks ─────────────────────────

M.onVehicleSpawned = function(gameVehicleId)
  if not state or not connection then return end
  if connection.getState() ~= connection.STATE_CONNECTED then return end
  -- Ignore remote vehicles we spawned ourselves
  if vehicles and vehicles.isRemote(gameVehicleId) then return end
  -- Ignore vehicles being spawned by the remote spawn pipeline (callback fires synchronously)
  if vehicles and vehicles._spawningRemote then return end

  local veh = be:getObjectByID(gameVehicleId)
  if not veh then return end

  -- Build config JSON from the vehicle object
  local configData = state.captureVehicleConfig(veh)
  log('I', logTag, 'Local vehicle spawned: gameVid=' .. tostring(gameVehicleId) .. ' model=' .. tostring(veh:getField('JBeam', '0')))
  state.requestSpawn(gameVehicleId, configData)
end

M.onVehicleDestroyed = function(gameVehicleId)
  if not state or not connection then return end
  if connection.getState() ~= connection.STATE_CONNECTED then return end
  -- Ignore remote vehicles
  if vehicles and vehicles.isRemote(gameVehicleId) then return end

  state.requestDelete(gameVehicleId)
end

M.onVehicleResetted = function(gameVehicleId)
  if not state or not connection then return end
  if connection.getState() ~= connection.STATE_CONNECTED then return end
  if vehicles and vehicles.isRemote(gameVehicleId) then return end

  local serverVid = state.localVehicles[gameVehicleId]
  if not serverVid then return end

  local veh = be:getObjectByID(gameVehicleId)
  if not veh then return end

  local pos = veh:getPosition()
  local rot = veh:getRotation()
  local resetData = '{"pos":[' .. pos.x .. ',' .. pos.y .. ',' .. pos.z .. '],"rot":[' .. rot.x .. ',' .. rot.y .. ',' .. rot.z .. ',' .. rot.w .. ']}'
  connection._sendPacket({
    type = "vehicle_reset",
    vehicle_id = serverVid,
    data = resetData,
  })
end

-- ─────────────── Vehicle-side Lua callbacks (damage/electrics) ──────────────

-- Called from vehicle-side queueGameEngineLua with damage state JSON
M.onVehicleDamageReport = function(gameVid, damageJson)
  if state and state.onDamageReport then
    state.onDamageReport(gameVid, damageJson)
  end
end

-- Called from vehicle-side queueGameEngineLua with electrics state JSON
M.onElectricsReport = function(gameVid, electricsJson)
  if state and state.onElectricsReport then
    state.onElectricsReport(gameVid, electricsJson)
  end
end

-- Called from vehicle-side queueGameEngineLua with input values
M.onInputsReport = function(gameVid, steer, throttle, brake)
  if state and state.onInputsReport then
    state.onInputsReport(gameVid, steer, throttle, brake)
  end
end

-- Called from vehicle-side queueGameEngineLua with physics rotation quaternion
M.onVluaRotationReport = function(gameVid, rx, ry, rz, rw)
  if state and state.onVluaRotationReport then
    state.onVluaRotationReport(gameVid, rx, ry, rz, rw)
  end
end

-- ─────────────── Coupling/trailer hooks ─────────────────────────────────────

M.onCouplerAttached = function(objId1, objId2, nodeId, obj2nodeId)
  if not state or not connection then return end
  if connection.getState() ~= connection.STATE_CONNECTED then return end
  if vehicles and (vehicles.isRemote(objId1) or vehicles.isRemote(objId2)) then return end

  local serverId1 = state.localVehicles[objId1]
  local serverId2 = state.localVehicles[objId2]
  if not serverId1 or not serverId2 then return end

  connection._sendPacket({
    type = "vehicle_coupling",
    vehicle_id = serverId1,
    target_vehicle_id = serverId2,
    coupled = true,
    node_id = nodeId,
    target_node_id = obj2nodeId,
  })
  log('I', logTag, 'Coupler attached: ' .. tostring(serverId1) .. ' <-> ' .. tostring(serverId2))
end

M.onCouplerDetached = function(objId1, objId2, nodeId, obj2nodeId)
  if not state or not connection then return end
  if connection.getState() ~= connection.STATE_CONNECTED then return end
  if vehicles and (vehicles.isRemote(objId1) or vehicles.isRemote(objId2)) then return end

  local serverId1 = state.localVehicles[objId1]
  local serverId2 = state.localVehicles[objId2]
  if not serverId1 or not serverId2 then return end

  connection._sendPacket({
    type = "vehicle_coupling",
    vehicle_id = serverId1,
    target_vehicle_id = serverId2,
    coupled = false,
    node_id = nodeId,
    target_node_id = obj2nodeId,
  })
  log('I', logTag, 'Coupler detached: ' .. tostring(serverId1) .. ' <-> ' .. tostring(serverId2))
end

-- P3.2: Mark damage dirty when a beam breaks so damage polling triggers promptly.
-- BeamNG calls this hook for each broken beam on any vehicle.
M.onBeamBroke = function(gameVehicleId, breakGroup)
  if state and state.markDamageDirty then
    state.markDamageDirty(gameVehicleId)
  end
end

-- ──────────────────── Public API (callable from GE Lua console) ──────────────

-- Open the server browser window
M.openBrowser = function()
  if browser then browser.open() end
end

-- Close the server browser window
M.closeBrowser = function()
  if browser then browser.close() end
end

M.toggleOverlay = function()
  if overlay then overlay.toggle() end
end

M.openOverlay = function()
  if overlay then overlay.open() end
end

M.closeOverlay = function()
  if overlay then overlay.close() end
end

-- Quick connect shortcut (for external scripts / launcher integration)
M.connect = function(host, port, username, password)
  if browser then
    return browser.connect(host, port, username, password)
  elseif connection then
    connection.connect(host, port, username, password)
    return true
  end
  return false, "not initialised"
end

return M

