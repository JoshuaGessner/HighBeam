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
local _lastLocalResetSentAt = {} -- [gameVehicleId] = os.clock()
local _pendingResetData = {}    -- Secondary #3: [gameVehicleId] = {data=string, queuedAt=number}

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

  if rawget(_G, 'MP_Console') or rawget(_G, 'MPVehicleGE') then
    log('W', logTag, 'BeamMP appears to be loaded in this profile; this can interfere with HighBeam sync testing')
  end

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
    overlay.load(connection, vehicles, state, chat, config)
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

  -- Secondary #3: Drain pending queued resets after debounce window expires
  if connection and connection.getState() == connection.STATE_CONNECTED then
    local now = os.clock()
    local debounceSec = 0.75
    if config and config.get then
      debounceSec = config.get("localResetDebounceSec") or debounceSec
    end
    for gameVid, pending in pairs(_pendingResetData) do
      local lastSent = _lastLocalResetSentAt[gameVid] or 0
      if (now - lastSent) >= debounceSec then
        _lastLocalResetSentAt[gameVid] = now
        _pendingResetData[gameVid] = nil
        connection._sendPacket({
          type = "vehicle_reset",
          vehicle_id = pending.serverVid,
          data = pending.data,
        })
        if state and state.clearDamageHash then
          state.clearDamageHash(gameVid)
        end
      end
    end
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
  if state.canRequestSpawn then
    local allowed, reason = state.canRequestSpawn(gameVehicleId)
    if not allowed then
      log('D', logTag, 'Skipping local spawn registration gameVid=' .. tostring(gameVehicleId)
        .. ' reason=' .. tostring(reason))
      return
    end
  end
  log('I', logTag, 'Local vehicle spawned: gameVid=' .. tostring(gameVehicleId) .. ' model=' .. tostring(veh:getField('JBeam', '0')))
  state.requestSpawn(gameVehicleId, configData)

  -- Activate per-vehicle VE sync modules for local vehicle data collection.
  pcall(function()
    veh:queueLuaCommand([[
      local function hbGetController(name)
        if not controller or not controller.getController then return nil end
        local ok, mod = pcall(controller.getController, name)
        if ok then return mod end
        return nil
      end
      local function hbLoadController(name)
        local mod = hbGetController(name)
        if mod then return mod end
        if not controller or not controller.loadControllerExternal then
          return nil, "controller.loadControllerExternal unavailable"
        end
        local ok, err = pcall(controller.loadControllerExternal, "highbeam/" .. name, name)
        if not ok then return nil, tostring(err) end
        mod = hbGetController(name)
        if not mod then return nil, "controller.getController returned nil after load" end
        return mod
      end
      local function hbRequireController(name, missing)
        local mod, err = hbLoadController(name)
        if not mod then table.insert(missing, name .. ":" .. tostring(err or "missing")) end
        return mod
      end
      local missing = {}
      hbRequireController("highbeamVelocityVE", missing)
      hbRequireController("highbeamPositionVE", missing)
      hbRequireController("highbeamInputsVE", missing)
      hbRequireController("highbeamElectricsVE", missing)
      hbRequireController("highbeamPowertrainVE", missing)
      hbRequireController("highbeamDamageVE", missing)
      local mainVE = hbRequireController("highbeamVE", missing)
      if mainVE and mainVE.setActive then
        local ok, err = pcall(mainVE.setActive, true, false)
        if not ok then table.insert(missing, "highbeamVE.setActive:" .. tostring(err)) end
      elseif mainVE then
        table.insert(missing, "highbeamVE.setActive:missing")
      end
      if #missing > 0 then
        obj:queueGameEngineLua(
          "if extensions and extensions.highbeam and extensions.highbeam.onLocalVEReady then extensions.highbeam.onLocalVEReady(" .. tostring(obj:getID()) .. ",false," .. string.format("%q", table.concat(missing, ",")) .. ") end"
        )
      else
        obj:queueGameEngineLua(
          "if extensions and extensions.highbeam and extensions.highbeam.onLocalVEReady then extensions.highbeam.onLocalVEReady(" .. tostring(obj:getID()) .. ",true,\"\") end"
        )
      end
    ]])
  end)
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

  local now = os.clock()
  local debounceSec = 0.75
  if config and config.get then
    debounceSec = config.get("localResetDebounceSec") or debounceSec
  end

  local serverVid = state.localVehicles[gameVehicleId]
  if not serverVid then return end

  local veh = be:getObjectByID(gameVehicleId)
  if not veh then return end

  local pos = veh:getPosition()
  -- SceneObject:getRotation() can lag the actual soft-body orientation. Use
  -- the same physics-facing direction-vector quaternion as the pose stream so
  -- a repair/reset cannot inject a stale or 180-degree-mismatched heading.
  local rot = quatFromDir(-veh:getDirectionVector(), veh:getDirectionVectorUp())
  local resetTime = 0
  if state and state.getLocalMotionTime then
    resetTime = state.getLocalMotionTime(gameVehicleId) or 0
  end
  local resetData = '{"pos":[' .. pos.x .. ',' .. pos.y .. ',' .. pos.z .. '],"rot":[' .. rot.x .. ',' .. rot.y .. ',' .. rot.z .. ',' .. rot.w .. '],"time":' .. tostring(resetTime) .. '}'

  local lastSent = _lastLocalResetSentAt[gameVehicleId]
  if lastSent and (now - lastSent) < debounceSec then
    -- Secondary #3: Queue the reset instead of dropping it
    _pendingResetData[gameVehicleId] = { data = resetData, queuedAt = now, serverVid = serverVid }
    if config and config.get and config.get("verboseSyncLogging") == true then
      log('D', logTag, 'Queued local reset packet gameVid=' .. tostring(gameVehicleId)
        .. ' dt=' .. string.format('%.3f', now - lastSent)
        .. 's')
    end
    return
  end
  _lastLocalResetSentAt[gameVehicleId] = now
  _pendingResetData[gameVehicleId] = nil

  connection._sendPacket({
    type = "vehicle_reset",
    vehicle_id = serverVid,
    data = resetData,
  })

  -- Bug #3a: Clear damage hash after sending reset so fresh damage is detected
  if state and state.clearDamageHash then
    state.clearDamageHash(gameVehicleId)
  end
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
M.onInputsReport = function(gameVid, steer, throttle, brake, gear, handbrake)
  if state and state.onInputsReport then
    state.onInputsReport(gameVid, steer, throttle, brake, gear, handbrake)
  end
end

-- Called from vehicle-side queueGameEngineLua with input values and physics rotation
M.onInputsAndRotationReport = function(gameVid, steer, throttle, brake, gear, handbrake, rx, ry, rz, rw)
  if state and state.onInputsAndRotationReport then
    state.onInputsAndRotationReport(gameVid, steer, throttle, brake, gear, handbrake, rx, ry, rz, rw)
  end
end

-- Called from vehicle-side queueGameEngineLua with physics rotation quaternion
M.onVluaRotationReport = function(gameVid, rx, ry, rz, rw)
  if state and state.onVluaRotationReport then
    state.onVluaRotationReport(gameVid, rx, ry, rz, rw)
  end
end

-- Called from vehicle-side highbeamVE.lua with per-frame data.
M.onVEData = function(gameVid, px, py, pz, rx, ry, rz, rw, vx, vy, vz, avx, avy, avz,
    steer, throttle, brake, gear, handbrake, sampleTime, sampleDelta)
  if state and state.onVEData then
    state.onVEData(gameVid, px, py, pz, rx, ry, rz, rw, vx, vy, vz, avx, avy, avz,
      steer, throttle, brake, gear, handbrake, sampleTime, sampleDelta)
  end
end

M.onLocalVEReady = function(gameVid, ready, missingCsv)
  if ready == true or tostring(ready) == "true" then
    log('I', logTag, 'Local VE confirmed gameVid=' .. tostring(gameVid))
    return
  end
  log('E', logTag, 'Local VE missing gameVid=' .. tostring(gameVid)
    .. ' missing=' .. tostring(missingCsv or ''))
end

-- Temporary sync diagnostics: confirms controller lifecycle hooks are firing
-- after controller.loadControllerExternal registration.
M.onVEControllerInit = function(gameVid, controllerName, physicsHookAvailable)
  log('I', logTag, 'VE controller init name=' .. tostring(controllerName)
    .. ' gameVid=' .. tostring(gameVid)
    .. ' physicsHookAvailable=' .. tostring(physicsHookAvailable))
end

M.onVEControllerActive = function(gameVid, active, remote)
  log('I', logTag, 'VE controller active gameVid=' .. tostring(gameVid)
    .. ' active=' .. tostring(active)
    .. ' remote=' .. tostring(remote))
end

-- Teleport request coming from VE PD controller when error is too large.
-- Moves the cluster without a physics reset (setClusterPosRelRot takes the
-- rotation RELATIVE to the current one) and restores the target linear
-- velocity in GE, which does not damage the vehicle. Angular velocity cannot
-- be set from GE, so it is queued back into the vehicle's velocity module.
M.onVETeleportRequest = function(gameVid, px, py, pz, rx, ry, rz, rw, vx, vy, vz, avx, avy, avz, errDist)
  local veh = be:getObjectByID(gameVid)
  if not veh then return end

  local ok = pcall(function()
    local refId = veh:getRefNodeId()
    local vehRot = quatFromDir(-veh:getDirectionVector(), veh:getDirectionVectorUp())
    local relRot = vehRot:inversed() * quat(rx, ry, rz, rw)
    veh:setClusterPosRelRot(refId, px, py, pz, relRot.x, relRot.y, relRot.z, relRot.w)
    -- setClusterPosRelRot rotates existing node velocities along with the
    -- cluster; add the difference to land on the target velocity (scale=1
    -- keeps the rotated velocity, then adds).
    local localVel = vec3(veh:getVelocity()):rotated(relRot)
    veh:applyClusterVelocityScaleAdd(refId, 1,
      (tonumber(vx) or 0) - localVel.x,
      (tonumber(vy) or 0) - localVel.y,
      (tonumber(vz) or 0) - localVel.z)
  end)
  if not ok then
    -- Last-resort fallback: physics-resetting teleport.
    pcall(veh.setPositionRotation, veh, px, py, pz, rx, ry, rz, rw)
  end

  pcall(function()
    veh:queueLuaCommand(string.format(
      "local _hb = controller and controller.getController and controller.getController('highbeamVelocityVE') or nil; if _hb and _hb.setAngularVelocity then _hb.setAngularVelocity(%.4f,%.4f,%.4f) end",
      tonumber(avx) or 0, tonumber(avy) or 0, tonumber(avz) or 0
    ))
  end)

  if config and config.get and config.get("verboseSyncLogging") == true then
    log('D', logTag, 'VE coherent correction gameVid=' .. tostring(gameVid)
      .. ' cluster=' .. tostring(ok)
      .. ' err=' .. string.format('%.3f', tonumber(errDist) or 0)
      .. ' vel=' .. string.format('%.2f,%.2f,%.2f', tonumber(vx) or 0, tonumber(vy) or 0, tonumber(vz) or 0)
      .. ' angVel=' .. string.format('%.2f,%.2f,%.2f', tonumber(avx) or 0, tonumber(avy) or 0, tonumber(avz) or 0))
  end
end

M.onVEInputs = function(gameVid, deltaStr)
  if state and state.onVEInputs then
    state.onVEInputs(gameVid, deltaStr)
  end
end

M.onVEElectrics = function(gameVid, jsonStr)
  if state and state.onVEElectrics then
    state.onVEElectrics(gameVid, jsonStr)
  end
end

M.onVEPowertrain = function(gameVid, jsonStr)
  if state and state.onVEPowertrain then
    state.onVEPowertrain(gameVid, jsonStr)
  end
end

M.onVEDamage = function(gameVid, jsonStr)
  if state and state.onVEDamage then
    state.onVEDamage(gameVid, jsonStr)
  end
end

M.onVEDamageDirty = function(gameVid)
  if state and state.markDamageDirty then
    state.markDamageDirty(gameVid)
  end
end

-- Called from remote vehicle-side capability probe to confirm VE module availability.
M.onRemoteVEReady = function(gameVid, ready, missingCsv)
  if vehicles and vehicles.onRemoteVEReady then
    vehicles.onRemoteVEReady(gameVid, ready, missingCsv)
  end
end

-- Called from remote vehicle-side positionVE heartbeat (every ~1s while vlua alive).
M.onVEHeartbeat = function(gameVid)
  if vehicles and vehicles.onVEHeartbeat then
    vehicles.onVEHeartbeat(gameVid)
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
