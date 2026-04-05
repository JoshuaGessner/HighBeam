local M = {}
local logTag = "HighBeam.Vehicles"

M.remoteVehicles = {} -- [playerId_vehicleId] = vehicleData
M._remoteGameIds = {} -- [gameVehicleId] = true  (quick lookup for isRemote)
M._spawningRemote = false -- Guard flag: true while core_vehicles.spawnNewVehicle is in-flight
M._debugStats = {}  -- P0: Exposed debug stats for overlay

local interpolationMath = require("highbeam/math")
local config = require("highbeam/config")
local _diagTimer = 0
local _diagIntervalSec = 5.0
local _staleDropCount = 0
local _spawnRetryDropCount = 0
local _spawnRetryAttemptCount = 0
local _spawnRetrySuccessCount = 0
local SPAWN_RETRY_MAX_ATTEMPTS = 15
local SPAWN_RETRY_BASE_DELAY = 0.75

-- Thresholds for skipping setPositionRotation when delta is negligible
local POS_DELTA_SQ_THRESHOLD = 0.000025  -- 0.005m squared
local ROT_DELTA_SQ_THRESHOLD = 0.000001  -- ~0.001 quat component

-- P0: Correction magnitude counters for diagnostics
local _correctionPosSum = 0
local _correctionRotSum = 0
local _correctionCount = 0
local _teleportCount = 0

local function _shouldApplyPosRot(rv, pos, rot)
  if not rv._lastAppliedPos then return true end
  local lp = rv._lastAppliedPos
  local lr = rv._lastAppliedRot
  local dx = pos[1] - lp[1]
  local dy = pos[2] - lp[2]
  local dz = pos[3] - lp[3]
  if (dx*dx + dy*dy + dz*dz) > POS_DELTA_SQ_THRESHOLD then return true end
  local drx = rot[1] - lr[1]
  local dry = rot[2] - lr[2]
  local drz = rot[3] - lr[3]
  local drw = rot[4] - lr[4]
  if (drx*drx + dry*dry + drz*drz + drw*drw) > ROT_DELTA_SQ_THRESHOLD then return true end
  return false
end

local function _applyPosRot(rv, pos, rot)
  rv.gameVehicle:setPositionRotation(pos[1], pos[2], pos[3], rot[1], rot[2], rot[3], rot[4])
  rv._lastAppliedPos = pos
  rv._lastAppliedRot = rot
  -- NOTE: obj:setVelocity() and obj:setAngularVelocity() do not exist in
  -- BeamNG's vlua context.  BeamMP works around this with per-node
  -- obj:applyForceVector() in a dedicated velocityVE extension.  For now
  -- setPositionRotation() from the GE context is sufficient; a force-based
  -- velocity system can be added later for smoother motion.
end

local function _countPendingSpawnRetries()
  local count = 0
  for _, rv in pairs(M.remoteVehicles) do
    if rv.spawnRetry then
      count = count + 1
    end
  end
  return count
end

local function _getConfigNumber(key, fallback)
  local value = config and config.get and config.get(key) or nil
  if type(value) == "number" then
    return value
  end
  return fallback
end

local function _getInterpolationDelay()
  return _getConfigNumber("interpolationDelayMs", 50) / 1000.0
end

local function _getExtrapolationWindow()
  return _getConfigNumber("extrapolationMs", 120) / 1000.0
end

local function _getMaxSnapshots()
  local raw = _getConfigNumber("jitterBufferSnapshots", 8)
  return math.max(2, math.floor(raw))
end

local function _getCorrectionBlendFactor()
  return _getConfigNumber("correctionBlendFactor", 0.15)
end

local function _getCorrectionTeleportDist()
  return _getConfigNumber("correctionTeleportDist", 10.0)
end

local function _getLodDistanceNear()
  return _getConfigNumber("lodDistanceNear", 200)
end

local function _getLodDistanceFar()
  return _getConfigNumber("lodDistanceFar", 500)
end

local function _isDirectSteering()
  local value = config and config.get and config.get("directSteering")
  return value ~= false  -- default true
end

local function makeKey(playerId, vehicleId)
  return tostring(playerId) .. "_" .. tostring(vehicleId)
end

-- Decode JSON config using available decoders
local function _decodeJson(str)
  if not str or str == '' then return nil end
  local decoded
  if jsonDecode then
    local ok, t = pcall(jsonDecode, str)
    if ok then return t end
  end
  if Engine and Engine.JSONDecode then
    local ok, t = pcall(Engine.JSONDecode, str)
    if ok then return t end
  end
  local ok, jsonLib = pcall(require, "json")
  if ok and jsonLib then
    local ok2, t = pcall(jsonLib.decode, str)
    if ok2 then return t end
  end
  return nil
end

local function _buildSpawnSpec(configData, snapshot)
  local cfg = _decodeJson(configData) or {}
  return {
    model = cfg.model or "pickup",
    partCfg = cfg.partConfig or "",
    pos = (snapshot and snapshot.position) or cfg.pos or { 0, 0, 0 },
    rot = (snapshot and snapshot.rotation) or cfg.rot or { 0, 0, 0, 1 },
    vel = (snapshot and snapshot.velocity) or { 0, 0, 0 },
    snapshotTimeMs = snapshot and snapshot.snapshotTimeMs,
  }
end

local function _spawnGameVehicle(spec)
  local vehObj = nil
  M._spawningRemote = true
  log('I', logTag, '_spawnGameVehicle: model=' .. tostring(spec.model)
    .. ' partCfg=' .. tostring(spec.partCfg and string.sub(spec.partCfg, 1, 60) or 'nil')
    .. ' pos=' .. tostring(spec.pos and spec.pos[1])
    .. ' core_vehicles=' .. tostring(core_vehicles ~= nil)
    .. ' spawnNewVehicle=' .. tostring(core_vehicles and core_vehicles.spawnNewVehicle ~= nil))

  -- Save the player's current vehicle so we can restore focus after spawn
  local savedPlayerVeh = be and be:getPlayerVehicle(0) or nil

  local ok, err = pcall(function()
    vehObj = core_vehicles.spawnNewVehicle(spec.model, {
      config = spec.partCfg,
      pos = vec3(spec.pos[1], spec.pos[2], spec.pos[3]),
      rot = quat(spec.rot[1], spec.rot[2], spec.rot[3], spec.rot[4]),
      autoEnterVehicle = false,
      cling = true,
    })
  end)

  log('I', logTag, '_spawnGameVehicle: primary pcall ok=' .. tostring(ok)
    .. ' vehObj=' .. tostring(vehObj) .. ' type=' .. type(vehObj)
    .. ' err=' .. tostring(err))

  if not ok or not vehObj then
    local firstErr = err
    local ok2
    log('I', logTag, '_spawnGameVehicle: primary failed, trying fallback pickup')
    ok2, err = pcall(function()
      vehObj = core_vehicles.spawnNewVehicle("pickup", {
        pos = vec3(spec.pos[1], spec.pos[2], spec.pos[3]),
        rot = quat(spec.rot[1], spec.rot[2], spec.rot[3], spec.rot[4]),
        autoEnterVehicle = false,
        cling = true,
      })
    end)
    log('I', logTag, '_spawnGameVehicle: fallback pcall ok2=' .. tostring(ok2)
      .. ' vehObj=' .. tostring(vehObj) .. ' type=' .. type(vehObj)
      .. ' err=' .. tostring(err))
    if not ok2 or not vehObj then
      M._spawningRemote = false
      return nil, nil, tostring(firstErr or err)
    end
  end
  M._spawningRemote = false

  -- Restore camera focus to the player's vehicle (spawn may steal it)
  if savedPlayerVeh and be then
    pcall(function() be:enterVehicle(0, savedPlayerVeh) end)
  end

  -- core_vehicles.spawnNewVehicle returns a vehicle object (userdata), not an ID
  local vid = nil
  if type(vehObj) == "userdata" and vehObj.getID then
    vid = vehObj:getID()
  elseif type(vehObj) == "number" then
    vid = vehObj
    vehObj = scenetree.findObjectById(vid)
  end

  log('I', logTag, '_spawnGameVehicle: extracted vid=' .. tostring(vid)
    .. ' vehObjType=' .. type(vehObj))

  if not vid then
    return nil, nil, "spawnNewVehicle returned unexpected type: " .. type(vehObj)
  end

  return vid, vehObj
end

-- Check if a game vehicle ID belongs to a remote player
M.isRemote = function(gameVehicleId)
  return M._remoteGameIds[gameVehicleId] == true
end

M.spawnRemote = function(playerId, vehicleId, configData, snapshot)
  local key = makeKey(playerId, vehicleId)
  log('I', logTag, 'spawnRemote: key=' .. key
    .. ' playerId=' .. tostring(playerId)
    .. ' vehicleId=' .. tostring(vehicleId)
    .. ' hasConfig=' .. tostring(configData ~= nil)
    .. ' hasSnapshot=' .. tostring(snapshot ~= nil))
  if M.remoteVehicles[key] then
    log('W', logTag, 'Remote vehicle already exists: ' .. key)
    return
  end

  local spec = _buildSpawnSpec(configData, snapshot)
  local vid, vehObj, spawnErr = _spawnGameVehicle(spec)

  if vid then
    M._remoteGameIds[vid] = true
  end

  M.remoteVehicles[key] = {
    playerId = playerId,
    vehicleId = vehicleId,
    gameVehicleId = vid,
    gameVehicle = vehObj,
    snapshots = {},
    lastSeqTime = -1,  -- For out-of-order rejection
    spawnSpec = spec,
    spawnRetry = nil,
  }

  if snapshot or spec.snapshotTimeMs then
    table.insert(M.remoteVehicles[key].snapshots, {
      pos = spec.pos,
      rot = spec.rot,
      vel = spec.vel,
      time = (spec.snapshotTimeMs or 0) / 1000.0,
      received = os.clock(),
      inputs = nil,
    })
  end

  if vid then
    log('I', logTag, 'Spawned remote vehicle: ' .. key .. ' gameVid=' .. tostring(vid))
  else
    M.remoteVehicles[key].spawnRetry = {
      attempts = 1,
      nextAt = os.clock() + SPAWN_RETRY_BASE_DELAY,
      lastError = spawnErr,
    }
    log('W', logTag, 'Remote spawn failed: ' .. key .. ' gameVid=nil; queued retry attempts=' .. tostring(SPAWN_RETRY_MAX_ATTEMPTS))
  end
end

M.spawnRemoteFromSnapshot = function(vehicle)
  log('I', logTag, 'spawnRemoteFromSnapshot called: vehicle=' .. tostring(vehicle ~= nil)
    .. ' type=' .. type(vehicle))
  if not vehicle then
    log('E', logTag, 'spawnRemoteFromSnapshot: vehicle is nil/false!')
    return
  end
  log('I', logTag, 'spawnRemoteFromSnapshot: player_id=' .. tostring(vehicle.player_id)
    .. ' vehicle_id=' .. tostring(vehicle.vehicle_id)
    .. ' data=' .. tostring(vehicle.data and string.sub(vehicle.data, 1, 80) or 'nil'))
  M.spawnRemote(vehicle.player_id, vehicle.vehicle_id, vehicle.data, {
    position = vehicle.position,
    rotation = vehicle.rotation,
    velocity = vehicle.velocity,
    snapshotTimeMs = vehicle.snapshot_time_ms,
  })
end

local _updateRemoteDropLog = 0
-- P2.3: Improved time offset convergence with min-filter + EMA
M.updateRemote = function(decoded)
  local key = makeKey(decoded.playerId, decoded.vehicleId)
  local rv = M.remoteVehicles[key]
  if not rv then
    _updateRemoteDropLog = _updateRemoteDropLog + 1
    if _updateRemoteDropLog <= 5 or _updateRemoteDropLog % 50 == 0 then
      log('W', logTag, 'updateRemote: no remote vehicle for key=' .. key
        .. ' (drops=' .. tostring(_updateRemoteDropLog) .. ')')
    end
    return
  end

  -- Out-of-order protection: reject packets older than newest received
  if decoded.time and rv.lastSeqTime and decoded.time < rv.lastSeqTime then
    _staleDropCount = _staleDropCount + 1
    return  -- Stale packet, discard
  end
  if decoded.time then
    rv.lastSeqTime = decoded.time
  end

  -- Compute smoothed time offset between local clock and sender's simTime.
  -- P2.3: Use minimum-filter over recent window, then EMA-smooth the minimum.
  -- This converges faster and avoids overestimating due to jitter spikes.
  local recvTime = os.clock()
  if decoded.time then
    local instantOffset = recvTime - decoded.time

    -- Maintain a small circular buffer of recent offsets for min-filter
    if not rv._offsetSamples then
      rv._offsetSamples = {}
      rv._offsetSampleIdx = 0
    end
    local maxSamples = 8
    rv._offsetSampleIdx = (rv._offsetSampleIdx % maxSamples) + 1
    rv._offsetSamples[rv._offsetSampleIdx] = instantOffset

    -- Find minimum offset in the window (closest to true one-way delay)
    local minOffset = instantOffset
    for _, v in ipairs(rv._offsetSamples) do
      if v < minOffset then minOffset = v end
    end

    if not rv.timeOffset then
      rv.timeOffset = minOffset
    else
      -- EMA with higher alpha for faster convergence
      local alpha = 0.15
      rv.timeOffset = rv.timeOffset + alpha * (minOffset - rv.timeOffset)
    end
  end

  table.insert(rv.snapshots, {
    pos = decoded.pos,
    rot = decoded.rot,
    vel = decoded.vel,
    time = decoded.time,
    received = recvTime,
    inputs = decoded.inputs,  -- nil for legacy 0x10 packets
  })

  local maxSnapshots = _getMaxSnapshots()
  while #rv.snapshots > maxSnapshots do
    table.remove(rv.snapshots, 1)
  end
end

M.updateRemoteConfig = function(playerId, vehicleId, configData)
  local key = makeKey(playerId, vehicleId)
  local rv = M.remoteVehicles[key]
  if not rv then return end

  local cfg = _decodeJson(configData)
  if not cfg then return end

  -- Apply part config change to existing vehicle
  if rv.gameVehicleId and cfg.partConfig and cfg.partConfig ~= '' then
    local veh = rv.gameVehicle or scenetree.findObjectById(rv.gameVehicleId)
    if veh then
      pcall(function()
        veh:setField('partConfig', '0', cfg.partConfig)
      end)
    end
  end

  -- Apply color change
  if rv.gameVehicleId and cfg.color then
    local veh = rv.gameVehicle or scenetree.findObjectById(rv.gameVehicleId)
    if veh then
      pcall(function()
        veh:setField('color', '0', cfg.color)
      end)
    end
  end

  log('D', logTag, 'Config update applied for remote vehicle: ' .. key)
end

M.resetRemote = function(playerId, vehicleId, data)
  local key = makeKey(playerId, vehicleId)
  local rv = M.remoteVehicles[key]
  if not rv then return end

  local cfg = _decodeJson(data)
  if not cfg then return end

  local veh = rv.gameVehicle or (rv.gameVehicleId and scenetree.findObjectById(rv.gameVehicleId))
  if not veh then return end

  -- Reset physics state (clears deformation/damage) then teleport to position
  pcall(function()
    veh:queueLuaCommand('obj:requestReset(RESET_PHYSICS)')
  end)

  if cfg.pos and cfg.rot then
    pcall(function()
      veh:setPositionRotation(
        cfg.pos[1], cfg.pos[2], cfg.pos[3],
        cfg.rot[1], cfg.rot[2], cfg.rot[3], cfg.rot[4]
      )
    end)
  end

  -- Clear snapshots so interpolation restarts from the new position
  rv.snapshots = {}
  rv.lastSeqTime = -1

  log('D', logTag, 'Reset remote vehicle: ' .. key)
end

-- Apply damage data to a remote vehicle
M.applyDamage = function(playerId, vehicleId, damageData)
  local key = makeKey(playerId, vehicleId)
  local rv = M.remoteVehicles[key]
  if not rv then return end

  local veh = rv.gameVehicle or (rv.gameVehicleId and scenetree.findObjectById(rv.gameVehicleId))
  if not veh then return end

  local dmg = _decodeJson(damageData)
  if not dmg then return end

  -- Apply beam deformation data via queueLuaCommand
  if dmg.deformGroup then
    pcall(function()
      veh:queueLuaCommand('obj:applyClusterVelocityScaleAdd(' .. tostring(dmg.deformGroup) .. ', 0, 0, 0, ' .. tostring(dmg.deformScale or 1) .. ')')
    end)
  end

  -- Apply beam breaks (sender field name is 'broken')
  if dmg.broken then
    pcall(function()
      for _, beamId in ipairs(dmg.broken) do
        veh:queueLuaCommand('obj:breakBeam(' .. tostring(beamId) .. ')')
      end
    end)
  end

  -- Apply beam deformation (sender field name is 'deform')
  -- Each entry is {deformVal, restLength} or a plain number (legacy).
  -- We use obj:setBeamLength to set the physical length directly.
  -- NOTE: beamstate.beamDeformed() does not exist in BeamNG's vlua —
  -- obj:setBeamLength() alone handles the visual + physical deformation.
  if dmg.deform then
    pcall(function()
      for beamIdStr, val in pairs(dmg.deform) do
        local cid = tostring(beamIdStr)
        if type(val) == 'table' and val[2] then
          -- New format: {deformation, restLength}
          veh:queueLuaCommand('obj:setBeamLength(' .. cid .. ', ' .. tostring(val[2]) .. ')')
        end
        -- Legacy format (plain number) had no restLength, so we cannot call
        -- setBeamLength.  The deformation is purely cosmetic tracking and was
        -- using the non-existent beamstate.beamDeformed() — skip silently.
      end
    end)
  end
end

-- Apply electrics state update to a remote vehicle
M.applyElectrics = function(playerId, vehicleId, electricsData)
  local key = makeKey(playerId, vehicleId)
  local rv = M.remoteVehicles[key]
  if not rv then return end

  local veh = rv.gameVehicle or (rv.gameVehicleId and scenetree.findObjectById(rv.gameVehicleId))
  if not veh then return end

  local elec = _decodeJson(electricsData)
  if not elec then return end

  -- Apply electrics via vehicle-side Lua
  -- P4.3: Added gear and parking brake
  pcall(function()
    local cmds = {}
    if elec.lights ~= nil then
      table.insert(cmds, 'electrics.values.lights_state = ' .. tostring(elec.lights))
    end
    if elec.signal_L ~= nil then
      table.insert(cmds, 'electrics.values.signal_L = ' .. tostring(elec.signal_L))
    end
    if elec.signal_R ~= nil then
      table.insert(cmds, 'electrics.values.signal_R = ' .. tostring(elec.signal_R))
    end
    if elec.hazard ~= nil then
      table.insert(cmds, 'electrics.values.hazard_enabled = ' .. tostring(elec.hazard))
    end
    if elec.horn ~= nil then
      table.insert(cmds, 'electrics.values.horn = ' .. tostring(elec.horn))
    end
    if elec.headlights ~= nil then
      table.insert(cmds, 'electrics.values.lowbeam = ' .. tostring(elec.headlights))
    end
    if elec.highbeams ~= nil then
      table.insert(cmds, 'electrics.values.highbeam = ' .. tostring(elec.highbeams))
    end
    if elec.gear ~= nil then
      table.insert(cmds, 'electrics.values.gear_A = ' .. tostring(elec.gear))
    end
    if elec.parkingbrake ~= nil then
      table.insert(cmds, 'electrics.values.parkingbrake = ' .. tostring(elec.parkingbrake))
    end
    if elec.rpm ~= nil then
      table.insert(cmds, 'electrics.values.rpm = ' .. tostring(elec.rpm))
    end
    if elec.wheelspeed ~= nil then
      table.insert(cmds, 'electrics.values.wheelspeed = ' .. tostring(elec.wheelspeed))
    end
    if elec.clutch ~= nil then
      table.insert(cmds, 'electrics.values.clutch = ' .. tostring(elec.clutch))
    end
    if elec.ignition ~= nil then
      table.insert(cmds, 'electrics.values.ignitionLevel = ' .. tostring(elec.ignition))
    end
    if #cmds > 0 then
      veh:queueLuaCommand(table.concat(cmds, ' '))
    end
  end)
end

-- Apply coupling/trailer state
M.applyCoupling = function(playerId, vehicleId, targetVehicleId, coupled, nodeId, targetNodeId)
  -- Find both remote vehicles by server vehicle ID
  local sourceRv = nil
  local targetRv = nil
  for _, rv in pairs(M.remoteVehicles) do
    if rv.playerId == playerId and rv.vehicleId == vehicleId then
      sourceRv = rv
    end
    -- Target could belong to any player
    if rv.vehicleId == targetVehicleId then
      targetRv = rv
    end
  end

  if not sourceRv or not targetRv then return end
  local sourceVeh = sourceRv.gameVehicle or (sourceRv.gameVehicleId and scenetree.findObjectById(sourceRv.gameVehicleId))
  local targetVeh = targetRv.gameVehicle or (targetRv.gameVehicleId and scenetree.findObjectById(targetRv.gameVehicleId))
  if not sourceVeh or not targetVeh then return end

  if coupled then
    pcall(function()
      sourceVeh:queueLuaCommand(
        'beamstate.attachCouplerByNodeId(' .. tostring(nodeId or 0) .. ', '
        .. tostring(targetRv.gameVehicleId) .. ', '
        .. tostring(targetNodeId or 0) .. ')'
      )
    end)
    log('D', logTag, 'Applied coupling: ' .. tostring(sourceRv.gameVehicleId) .. ' -> ' .. tostring(targetRv.gameVehicleId))
  else
    pcall(function()
      sourceVeh:queueLuaCommand('beamstate.detachCoupler(' .. tostring(nodeId or 0) .. ')')
    end)
    log('D', logTag, 'Applied decoupling: ' .. tostring(sourceRv.gameVehicleId))
  end
end

M._escapeForLuaCmd = function(s)
  if type(s) ~= "string" then return tostring(s) end
  return string.format("%q", s)
end

M.removeRemote = function(playerId, vehicleId)
  local key = makeKey(playerId, vehicleId)
  local rv = M.remoteVehicles[key]
  if not rv then
    return
  end

  if rv.gameVehicleId then
    M._remoteGameIds[rv.gameVehicleId] = nil
    pcall(function()
      local obj = be:getObjectByID(rv.gameVehicleId)
      if obj then obj:delete() end
    end)
  end

  M.remoteVehicles[key] = nil
  log('I', logTag, 'Removed remote vehicle: ' .. key)
end

M.removeAllForPlayer = function(playerId)
  local prefix = tostring(playerId) .. "_"
  local toRemove = {}

  for key, rv in pairs(M.remoteVehicles) do
    if key:sub(1, #prefix) == prefix then
      table.insert(toRemove, key)
      if rv.gameVehicleId then
        M._remoteGameIds[rv.gameVehicleId] = nil
        pcall(function()
          local obj = be:getObjectByID(rv.gameVehicleId)
          if obj then obj:delete() end
        end)
      end
    end
  end

  for _, key in ipairs(toRemove) do
    M.remoteVehicles[key] = nil
  end

  if #toRemove > 0 then
    log('I', logTag, 'Removed ' .. tostring(#toRemove) .. ' vehicles for player ' .. tostring(playerId))
  end
end

-- P3.4: Helper to get camera position for LOD distance
local function _getCameraPos()
  if core_camera and core_camera.getPosition then
    local p = core_camera.getPosition()
    if p then return p.x, p.y, p.z end
  end
  return nil, nil, nil
end

M.tick = function(dt)
  local interpolationEnabled = (config and config.get and config.get("interpolation")) ~= false
  local interpolationDelay = _getInterpolationDelay()
  local extrapolationWindow = _getExtrapolationWindow()
  local correctionBlend = _getCorrectionBlendFactor()
  local teleportDist = _getCorrectionTeleportDist()
  local teleportDistSq = teleportDist * teleportDist
  local directSteering = _isDirectSteering()
  local lodNear = _getLodDistanceNear()
  local lodFar = _getLodDistanceFar()
  local lodFarSq = lodFar * lodFar
  local now = os.clock()
  local renderTime = now - interpolationDelay

  -- P3.4: Get camera position for LOD calculations
  local camX, camY, camZ = _getCameraPos()

  for _, rv in pairs(M.remoteVehicles) do
    if (not rv.gameVehicleId) and rv.spawnRetry then
      if now >= rv.spawnRetry.nextAt then
        local latest = rv.snapshots[#rv.snapshots]
        if latest then
          rv.spawnSpec.pos = latest.pos
          rv.spawnSpec.rot = latest.rot
          rv.spawnSpec.vel = latest.vel
        end

        local vid, vehObj, spawnErr = _spawnGameVehicle(rv.spawnSpec)
        _spawnRetryAttemptCount = _spawnRetryAttemptCount + 1
        if vid then
          rv.gameVehicleId = vid
          rv.gameVehicle = vehObj
          rv.spawnRetry = nil
          M._remoteGameIds[vid] = true
          _spawnRetrySuccessCount = _spawnRetrySuccessCount + 1
          log('I', logTag, 'Remote spawn recovered: ' .. tostring(rv.playerId) .. '_' .. tostring(rv.vehicleId) .. ' gameVid=' .. tostring(vid))
        else
          rv.spawnRetry.attempts = rv.spawnRetry.attempts + 1
          rv.spawnRetry.lastError = spawnErr
          if rv.spawnRetry.attempts > SPAWN_RETRY_MAX_ATTEMPTS then
            _spawnRetryDropCount = _spawnRetryDropCount + 1
            log('E', logTag, 'Remote spawn permanently failed: ' .. tostring(rv.playerId) .. '_' .. tostring(rv.vehicleId)
              .. ' err=' .. tostring(rv.spawnRetry.lastError))
            rv.spawnRetry = nil
          else
            local backoff = math.min(4.0, SPAWN_RETRY_BASE_DELAY * rv.spawnRetry.attempts)
            rv.spawnRetry.nextAt = now + backoff
          end
        end
      end
    end

    if not rv.gameVehicle and rv.gameVehicleId then
      rv.gameVehicle = scenetree.findObjectById(rv.gameVehicleId)
    end

    -- P3.4: LOD skip — for very distant vehicles, reduce update frequency
    if rv.gameVehicle and camX and rv._lastAppliedPos then
      local dx = rv._lastAppliedPos[1] - camX
      local dy = rv._lastAppliedPos[2] - camY
      local dz = rv._lastAppliedPos[3] - camZ
      local distSq = dx*dx + dy*dy + dz*dz
      if distSq > lodFarSq then
        -- Beyond LOD far: update only every 4th tick
        rv._lodSkipCounter = (rv._lodSkipCounter or 0) + 1
        if rv._lodSkipCounter % 4 ~= 0 then
          goto continue_vehicle
        end
      elseif distSq > (lodNear * lodNear) then
        -- Between near and far: update every 2nd tick
        rv._lodSkipCounter = (rv._lodSkipCounter or 0) + 1
        if rv._lodSkipCounter % 2 ~= 0 then
          goto continue_vehicle
        end
      else
        rv._lodSkipCounter = 0
      end
    end

    if rv.gameVehicle and #rv.snapshots >= 2 and interpolationEnabled then
      local s1 = nil
      local s2 = nil

      -- Use sender timestamps (translated to local time) for interpolation.
      local timeOffset = rv.timeOffset or 0
      local localRenderTime = renderTime

      for i = 1, #rv.snapshots - 1 do
        local a = rv.snapshots[i]
        local b = rv.snapshots[i + 1]
        local aLocal = (a.time or a.received) + timeOffset
        local bLocal = (b.time or b.received) + timeOffset
        if aLocal <= localRenderTime and bLocal >= localRenderTime then
          s1 = a
          s2 = b
          break
        end
      end

      if not s1 or not s2 then
        s1 = rv.snapshots[#rv.snapshots - 1]
        s2 = rv.snapshots[#rv.snapshots]
      end

      local s1Local = (s1.time or s1.received) + timeOffset
      local s2Local = (s2.time or s2.received) + timeOffset
      local span = s2Local - s1Local
      local t = 1
      if span > 0.0001 then
        t = (localRenderTime - s1Local) / span
      end

      local targetPos = nil
      local targetRot = nil

      if t <= 1.0 then
        -- Cubic Hermite interpolation using velocity at both endpoints
        targetPos = interpolationMath.hermiteVec3(s1.pos, s1.vel, s2.pos, s2.vel, span, t)
        targetRot = interpolationMath.slerpQuat(s1.rot, s2.rot, t)
      else
        -- Extrapolate using latest velocity
        local extraT = math.min((localRenderTime - s2Local), extrapolationWindow)
        local vx = s2.vel[1] or 0
        local vy = s2.vel[2] or 0
        local vz = s2.vel[3] or 0

        targetPos = {
          s2.pos[1] + vx * extraT,
          s2.pos[2] + vy * extraT,
          s2.pos[3] + vz * extraT,
        }
        targetRot = s2.rot
      end

      -- P2.2: Smooth correction blending instead of instant teleport.
      -- Blend the current physics position toward the target position each frame.
      -- If the error is very large, teleport immediately.
      local finalPos = targetPos
      local finalRot = targetRot
      if rv._lastAppliedPos then
        local errX = targetPos[1] - rv._lastAppliedPos[1]
        local errY = targetPos[2] - rv._lastAppliedPos[2]
        local errZ = targetPos[3] - rv._lastAppliedPos[3]
        local errSq = errX*errX + errY*errY + errZ*errZ

        -- P0.2: Track correction magnitudes for debug overlay
        _correctionCount = _correctionCount + 1
        _correctionPosSum = _correctionPosSum + math.sqrt(errSq)
        if rv._lastAppliedRot then
          local dqx = targetRot[1] - rv._lastAppliedRot[1]
          local dqy = targetRot[2] - rv._lastAppliedRot[2]
          local dqz = targetRot[3] - rv._lastAppliedRot[3]
          local dqw = targetRot[4] - rv._lastAppliedRot[4]
          _correctionRotSum = _correctionRotSum + math.sqrt(dqx*dqx + dqy*dqy + dqz*dqz + dqw*dqw)
        end

        if errSq > teleportDistSq then
          -- Large error: teleport instantly
          _teleportCount = _teleportCount + 1
        elseif errSq > POS_DELTA_SQ_THRESHOLD then
          -- Small-to-medium error: blend toward target
          local blend = math.min(1.0, correctionBlend * dt * 60)  -- normalize to ~60fps
          finalPos = {
            rv._lastAppliedPos[1] + errX * blend,
            rv._lastAppliedPos[2] + errY * blend,
            rv._lastAppliedPos[3] + errZ * blend,
          }
          -- Also blend rotation
          if rv._lastAppliedRot then
            finalRot = interpolationMath.slerpQuat(rv._lastAppliedRot, targetRot, blend)
          end
        end
      end

      if _shouldApplyPosRot(rv, finalPos, finalRot) then
        _applyPosRot(rv, finalPos, finalRot)
      end
    elseif rv.gameVehicle and #rv.snapshots >= 1 then
      local latest = rv.snapshots[#rv.snapshots]
      local latestPos = latest.pos
      local latestRot = latest.rot
      if _shouldApplyPosRot(rv, latestPos, latestRot) then
        _applyPosRot(rv, latestPos, latestRot)
      end
    end

    -- Apply steering/throttle/brake inputs to remote vehicle
    if rv.gameVehicle and rv.snapshots and #rv.snapshots >= 1 then
      local latestSnap = rv.snapshots[#rv.snapshots]
      if latestSnap.inputs then
        local inp = latestSnap.inputs
        -- P3.3: Collect all input commands into a single batch
        local inputCmds = {}

        if directSteering then
          -- P4.1: Direct steering via electrics — bypasses the input filter
          -- that adds unwanted smoothing/deadzone to remote vehicle steering.
          if inp.steer then
            local lastSteer = rv._lastAppliedSteer
            local newSteer = inp.steer
            -- P4.2: Tighter threshold for smooth remote steering
            if not lastSteer or math.abs(newSteer - lastSteer) > 0.002 then
              rv._lastAppliedSteer = newSteer
              inputCmds[#inputCmds+1] = 'electrics.values.steering_input = ' .. tostring(newSteer)
              inputCmds[#inputCmds+1] = 'electrics.values.steering = ' .. tostring(newSteer)
            end
          end
        else
          -- Legacy: use input.event (has built-in smoothing/deadzone)
          if inp.steer then
            local lastSteer = rv._lastAppliedSteer
            local newSteer = inp.steer
            if not lastSteer or math.abs(newSteer - lastSteer) > 0.002 then
              rv._lastAppliedSteer = newSteer
              inputCmds[#inputCmds+1] = 'input.event("steering", ' .. tostring(newSteer) .. ', 1)'
            end
          end
        end

        if inp.throttle then
          local lastThrottle = rv._lastAppliedThrottle
          local newThrottle = inp.throttle
          -- P4.2: Lower threshold
          if not lastThrottle or math.abs(newThrottle - lastThrottle) > 0.002 then
            rv._lastAppliedThrottle = newThrottle
            inputCmds[#inputCmds+1] = 'input.event("throttle", ' .. tostring(newThrottle) .. ', 1)'
          end
        end

        if inp.brake then
          local lastBrake = rv._lastAppliedBrake
          local newBrake = inp.brake
          -- P4.2: Lower threshold
          if not lastBrake or math.abs(newBrake - lastBrake) > 0.002 then
            rv._lastAppliedBrake = newBrake
            inputCmds[#inputCmds+1] = 'input.event("brake", ' .. tostring(newBrake) .. ', 1)'
          end
        end

        -- P3.3: Single queueLuaCommand for all inputs
        if #inputCmds > 0 then
          pcall(function()
            rv.gameVehicle:queueLuaCommand(table.concat(inputCmds, ' '))
          end)
        end
      end
    end

    ::continue_vehicle::
  end

  _diagTimer = _diagTimer + dt
  if _diagTimer >= _diagIntervalSec then
    _diagTimer = 0
    if _staleDropCount > 0 then
      log('I', logTag, 'Dropped stale remote snapshots=' .. tostring(_staleDropCount))
      _staleDropCount = 0
    end
    if _spawnRetryDropCount > 0 then
      log('W', logTag, 'Remote spawns abandoned after retries=' .. tostring(_spawnRetryDropCount))
      _spawnRetryDropCount = 0
    end
    local pendingRetries = _countPendingSpawnRetries()
    if pendingRetries > 0 or _spawnRetryAttemptCount > 0 or _spawnRetrySuccessCount > 0 then
      log('I', logTag, 'Spawn retry diag pending=' .. tostring(pendingRetries)
        .. ' attempts=' .. tostring(_spawnRetryAttemptCount)
        .. ' recovered=' .. tostring(_spawnRetrySuccessCount))
      _spawnRetryAttemptCount = 0
      _spawnRetrySuccessCount = 0
    end

    -- P0.2: Log correction magnitudes every diagnostic interval
    if _correctionCount > 0 then
      local avgPos = _correctionPosSum / _correctionCount
      local avgRot = _correctionRotSum / _correctionCount
      log('I', logTag, 'Correction diag avgPos=' .. string.format("%.4f", avgPos)
        .. 'm avgRot=' .. string.format("%.5f", avgRot)
        .. ' samples=' .. tostring(_correctionCount)
        .. ' teleports=' .. tostring(_teleportCount))
    end

    -- P0: Update debug stats for overlay
    M._debugStats = {
      avgCorrectionPos = _correctionCount > 0 and (_correctionPosSum / _correctionCount) or 0,
      avgCorrectionRot = _correctionCount > 0 and (_correctionRotSum / _correctionCount) or 0,
      correctionCount = _correctionCount,
      teleportCount = _teleportCount,
      staleDrops = _staleDropCount,
    }

    _correctionPosSum = 0
    _correctionRotSum = 0
    _correctionCount = 0
    _teleportCount = 0
  end
end

-- Returns the best current vehicle summary for a player based on newest snapshot.
M.getPlayerActiveVehicle = function(playerId)
  local selected = nil
  local newest = -math.huge

  for _, rv in pairs(M.remoteVehicles) do
    if rv.playerId == playerId then
      local s = rv.snapshots and rv.snapshots[#rv.snapshots] or nil
      local ts = (s and s.received) or 0
      if ts >= newest then
        newest = ts
        local pos = nil
        if s and s.pos then
          pos = { s.pos[1], s.pos[2], s.pos[3] }
        elseif rv.gameVehicle then
          local p = rv.gameVehicle:getPosition()
          if p then pos = { p.x, p.y, p.z } end
        elseif rv.gameVehicleId then
          local obj = scenetree.findObjectById(rv.gameVehicleId)
          if obj then
            local p = obj:getPosition()
            if p then pos = { p.x, p.y, p.z } end
          end
        end

        selected = {
          playerId = rv.playerId,
          vehicleId = rv.vehicleId,
          model = (rv.spawnSpec and rv.spawnSpec.model) or "unknown",
          position = pos,
        }
      end
    end
  end

  return selected
end

return M
