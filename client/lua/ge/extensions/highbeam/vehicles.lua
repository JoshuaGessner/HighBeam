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
local VE_PROBE_RETRY_DELAY = 0.5      -- seconds between VE probe retries
local VE_PROBE_MAX_RETRIES = 6        -- max re-probes before giving up

-- Thresholds for skipping setPositionRotation when delta is negligible
local POS_DELTA_SQ_THRESHOLD = 0.000025  -- 0.005m squared
local ROT_DELTA_SQ_THRESHOLD = 0.000001  -- ~0.001 quat component

-- P0: Correction magnitude counters for diagnostics
local _correctionPosSum = 0
local _correctionRotSum = 0
local _correctionCount = 0
local _teleportCount = 0
local _componentApplyStats = {}
local makeKey

local function _verboseSyncLoggingEnabled()
  return config and config.get and config.get("verboseSyncLogging") == true
end

local function _bumpApplyStat(name)
  local key = tostring(name)
  _componentApplyStats[key] = (_componentApplyStats[key] or 0) + 1
end

local function _withRemoteVehicle(playerId, vehicleId, stage)
  local key = makeKey(playerId, vehicleId)
  local rv = M.remoteVehicles[key]
  if not rv then
    _bumpApplyStat(stage .. "_drop_no_remote")
    if _verboseSyncLoggingEnabled() then
      log('D', logTag, stage .. ' drop no remote key=' .. key)
    end
    return nil, nil, key
  end

  local veh = rv.gameVehicle or (rv.gameVehicleId and scenetree.findObjectById(rv.gameVehicleId))
  if not veh then
    _bumpApplyStat(stage .. "_drop_no_game_vehicle")
    if _verboseSyncLoggingEnabled() then
      log('D', logTag, stage .. ' drop no game vehicle key=' .. key
        .. ' gameVehicleId=' .. tostring(rv.gameVehicleId))
    end
    return nil, rv, key
  end

  return veh, rv, key
end

local function _quatNormalize(q)
  return interpolationMath.normalizeQuat(q)
end

local function _quatFromAngularVelocity(baseRot, angVel, dt)
  if not baseRot or not angVel or dt <= 0 then return baseRot end
  local wx = angVel[1] or 0
  local wy = angVel[2] or 0
  local wz = angVel[3] or 0
  local speed = math.sqrt(wx*wx + wy*wy + wz*wz)
  if speed < 0.0001 then return baseRot end

  local half = 0.5 * speed * dt
  local s = math.sin(half)
  local c = math.cos(half)
  local ax = wx / speed
  local ay = wy / speed
  local az = wz / speed
  local dq = { ax * s, ay * s, az * s, c }

  local bx, by, bz, bw = baseRot[1], baseRot[2], baseRot[3], baseRot[4]
  local dx, dy, dz, dw = dq[1], dq[2], dq[3], dq[4]
  local out = {
    dw*bx + dx*bw + dy*bz - dz*by,
    dw*by - dx*bz + dy*bw + dz*bx,
    dw*bz + dx*by - dy*bx + dz*bw,
    dw*bw - dx*bx - dy*by - dz*bz,
  }
  return _quatNormalize(out)
end

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

local function _applyPosRot(rv, pos, rot, vel)
  -- When VE is active, updateRemote() already sends raw setTarget directly.
  -- Only update tracking state here; skip the redundant queueLuaCommand to
  -- avoid double-smoothing (GE interpolation + VE PD correction).
  if rv._hasVE and rv.gameVehicle then
    rv._lastAppliedPos = { pos[1], pos[2], pos[3] }
    rv._lastAppliedRot = { rot[1], rot[2], rot[3], rot[4] }
    return
  end

  -- Fallback for pre-VE bootstrap: use setPositionRotation (resets velocity)
  rv.gameVehicle:setPositionRotation(pos[1], pos[2], pos[3], rot[1], rot[2], rot[3], rot[4])
  rv._lastAppliedPos = { pos[1], pos[2], pos[3] }
  rv._lastAppliedRot = { rot[1], rot[2], rot[3], rot[4] }
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

makeKey = function(playerId, vehicleId)
  return tostring(playerId) .. "_" .. tostring(vehicleId)
end

local function _queueRemoteVeBootstrap(rv, key)
  if not rv or not rv.gameVehicle then return end
  local vehObj = rv.gameVehicle
  pcall(function()
    vehObj:queueLuaCommand([[
      local _missing = {}

      -- Register VE modules as controllers so physics callbacks (onPhysicsStep)
      -- are guaranteed to execute for remote simulation.
      local _veModules = {
        {"highbeam/highbeamVE", "highbeam_highbeamVE"},
        {"highbeam/highbeamPositionVE", "highbeam_highbeamPositionVE"},
        {"highbeam/highbeamVelocityVE", "highbeam_highbeamVelocityVE"},
        {"highbeam/highbeamInputsVE", "highbeam_highbeamInputsVE"},
        {"highbeam/highbeamElectricsVE", "highbeam_highbeamElectricsVE"},
        {"highbeam/highbeamPowertrainVE", "highbeam_highbeamPowertrainVE"},
        {"highbeam/highbeamDamageVE", "highbeam_highbeamDamageVE"},
      }
      local _controllerLoader = controller and controller.loadControllerExternal
      if _controllerLoader then
        for _, entry in ipairs(_veModules) do
          pcall(_controllerLoader, entry[1], entry[2])
        end
      else
        table.insert(_missing, "controller.loadControllerExternal")
      end

      local _hasVE = highbeam_highbeamVE and highbeam_highbeamVE.setActive
      local _hasPos = highbeam_highbeamPositionVE and highbeam_highbeamPositionVE.setRemote and highbeam_highbeamPositionVE.setTarget
      local _hasVel = highbeam_highbeamVelocityVE and highbeam_highbeamVelocityVE.addVelocity
      local _hasInputs = highbeam_highbeamInputsVE and highbeam_highbeamInputsVE.setActive
      local _hasElectrics = highbeam_highbeamElectricsVE and highbeam_highbeamElectricsVE.setActive
      local _hasPowertrain = highbeam_highbeamPowertrainVE and highbeam_highbeamPowertrainVE.setActive
      local _hasDamage = highbeam_highbeamDamageVE and highbeam_highbeamDamageVE.setActive

      if not _hasVE then table.insert(_missing, "highbeam_highbeamVE") end
      if not _hasPos then table.insert(_missing, "highbeam_highbeamPositionVE") end
      if not _hasVel then table.insert(_missing, "highbeam_highbeamVelocityVE") end
      if not _hasInputs then table.insert(_missing, "highbeam_highbeamInputsVE") end
      if not _hasElectrics then table.insert(_missing, "highbeam_highbeamElectricsVE") end
      if not _hasPowertrain then table.insert(_missing, "highbeam_highbeamPowertrainVE") end
      if not _hasDamage then table.insert(_missing, "highbeam_highbeamDamageVE") end

      local _ready = (_controllerLoader and _hasVE and _hasPos and _hasVel and _hasInputs and _hasElectrics and _hasPowertrain and _hasDamage) and true or false

      if _ready then
        -- Defensive: call init() explicitly in case controller system defers dispatch.
        for _, entry in ipairs(_veModules) do
          local _mod = rawget(_G, entry[2])
          if _mod and _mod.init then pcall(_mod.init) end
        end
        highbeam_highbeamVE.setActive(true, true)
        highbeam_highbeamPositionVE.setRemote(true)
        highbeam_highbeamInputsVE.setActive(true, true)
        highbeam_highbeamElectricsVE.setActive(true, true)
        highbeam_highbeamPowertrainVE.setActive(true, true)
        highbeam_highbeamDamageVE.setActive(true, true)
      end

      local _missingCsv = table.concat(_missing, ",")
      obj:queueGameEngineLua(
        "if extensions and extensions.highbeam and extensions.highbeam.onRemoteVEReady then extensions.highbeam.onRemoteVEReady(" .. tostring(obj:getID()) .. "," .. tostring(_ready) .. "," .. string.format("%q", _missingCsv) .. ") end"
      )
    ]])
  end)
  rv._veProbeQueuedAt = os.clock()
  rv._veProbeMissing = nil
  rv._hasVE = false
  if _verboseSyncLoggingEnabled() then
    log('D', logTag, 'Queued remote VE capability probe key=' .. tostring(key)
      .. ' gameVid=' .. tostring(rv.gameVehicleId))
  end
end

M.onRemoteVEReady = function(gameVehicleId, ready, missingCsv)
  if not gameVehicleId then return end
  local readyBool = (ready == true) or (ready == 1) or (tostring(ready) == "true")
  for key, rv in pairs(M.remoteVehicles) do
    if rv and rv.gameVehicleId == gameVehicleId then
      rv._hasVE = readyBool
      rv._veReadyAt = os.clock()
      rv._veProbeMissing = missingCsv
      if readyBool then
        rv._veProbeRetries = VE_PROBE_MAX_RETRIES  -- stop retrying
        log('I', logTag, 'Remote VE confirmed key=' .. tostring(key)
          .. ' gameVid=' .. tostring(gameVehicleId)
          .. ' retries=' .. tostring(rv._veProbeRetries or 0))
      else
        local missing = tostring(missingCsv or '')
        local retries = rv._veProbeRetries or 0
        if retries < VE_PROBE_MAX_RETRIES then
          log('D', logTag, 'VE probe pending retry key=' .. tostring(key)
            .. ' gameVid=' .. tostring(gameVehicleId)
            .. ' attempt=' .. tostring(retries)
            .. ' missing=' .. (missing ~= '' and missing or 'unknown'))
        else
          log('W', logTag, 'Remote VE failed after retries key=' .. tostring(key)
            .. ' gameVid=' .. tostring(gameVehicleId)
            .. ' missing=' .. (missing ~= '' and missing or 'unknown'))
        end
      end
      return
    end
  end
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
      rot = quat(0, 0, 0, 1),
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
        rot = quat(0, 0, 0, 1),
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

  -- Apply authoritative transform after spawn to avoid constructor ordering ambiguity.
  pcall(function()
    if vehObj and spec and spec.pos and spec.rot then
      vehObj:setPositionRotation(
        spec.pos[1], spec.pos[2], spec.pos[3],
        spec.rot[1], spec.rot[2], spec.rot[3], spec.rot[4]
      )
    end
  end)

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
    _hasVE = false,
  }

  if snapshot or spec.snapshotTimeMs then
    table.insert(M.remoteVehicles[key].snapshots, {
      pos = spec.pos,
      rot = spec.rot,
      vel = spec.vel,
      time = (spec.snapshotTimeMs or 0) / 1000.0,
      received = os.clock(),
      inputs = nil,
      angVel = nil,
    })
  end

  if vid then
    _queueRemoteVeBootstrap(M.remoteVehicles[key], key)
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

  if rv._hasVE and rv.gameVehicle then
    local ax = decoded.angVel and decoded.angVel[1] or 0
    local ay = decoded.angVel and decoded.angVel[2] or 0
    local az = decoded.angVel and decoded.angVel[3] or 0
    pcall(function()
      rv.gameVehicle:queueLuaCommand(string.format(
        "if highbeam_highbeamPositionVE and highbeam_highbeamPositionVE.setTarget then highbeam_highbeamPositionVE.setTarget(%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.6f,%.6f,%.6f,%.6f,%.4f,%.4f,%.4f,%.4f) end",
        decoded.pos[1], decoded.pos[2], decoded.pos[3],
        decoded.vel[1], decoded.vel[2], decoded.vel[3],
        decoded.rot[1], decoded.rot[2], decoded.rot[3], decoded.rot[4],
        ax, ay, az,
        decoded.time or 0
      ))
    end)
  end

  -- Store for GE interpolation fallback path
  rv._lastAngVel = decoded.angVel
  rv._lastTargetTime = decoded.time

  table.insert(rv.snapshots, {
    pos = decoded.pos,
    rot = decoded.rot,
    vel = decoded.vel,
    time = decoded.time,
    received = recvTime,
    inputs = decoded.inputs,  -- nil for legacy 0x10 packets
    angVel = decoded.angVel,
  })

  local maxSnapshots = _getMaxSnapshots()
  while #rv.snapshots > maxSnapshots do
    table.remove(rv.snapshots, 1)
  end
end

M.updateRemoteConfig = function(playerId, vehicleId, configData)
  local veh, rv, key = _withRemoteVehicle(playerId, vehicleId, "config")
  if not veh then return end

  local cfg = _decodeJson(configData)
  if not cfg then
    _bumpApplyStat("config_drop_decode")
    if _verboseSyncLoggingEnabled() then
      log('D', logTag, 'config drop decode key=' .. key)
    end
    return
  end

  local commandsApplied = 0

  -- Apply part config change to existing vehicle
  if rv.gameVehicleId and cfg.partConfig and cfg.partConfig ~= '' then
    local ok = pcall(function()
      veh:setField('partConfig', '0', cfg.partConfig)
    end)
    if ok then
      commandsApplied = commandsApplied + 1
    else
      _bumpApplyStat("config_error_part")
    end
  end

  -- Apply color change
  if rv.gameVehicleId and cfg.color then
    local ok = pcall(function()
      veh:setField('color', '0', cfg.color)
    end)
    if ok then
      commandsApplied = commandsApplied + 1
    else
      _bumpApplyStat("config_error_color")
    end
  end

  if commandsApplied == 0 then
    _bumpApplyStat("config_noop")
  else
    _bumpApplyStat("config_applied")
    if _verboseSyncLoggingEnabled() then
      log('D', logTag, 'config applied key=' .. key .. ' commands=' .. tostring(commandsApplied))
    end
  end
end

M.resetRemote = function(playerId, vehicleId, data)
  local veh, rv, key = _withRemoteVehicle(playerId, vehicleId, "reset")
  if not veh then return end

  local now = os.clock()
  local resetMinInterval = math.max(0.0, math.min(3.0, _getConfigNumber("remoteResetMinIntervalSec", 0.5)))
  local resetUnchanged = (rv._lastResetPayload ~= nil and rv._lastResetPayload == data)
  if rv._lastResetAt and (now - rv._lastResetAt) < resetMinInterval and resetUnchanged then
    _bumpApplyStat("reset_suppressed")
    if _verboseSyncLoggingEnabled() then
      log('D', logTag, 'Reset suppressed key=' .. key
        .. ' dt=' .. string.format('%.3f', now - rv._lastResetAt)
        .. 's')
    end
    return
  end
  rv._lastResetAt = now
  rv._lastResetPayload = data

  local resetBurstWindowSec = math.max(0.2, math.min(10.0, _getConfigNumber("resetBurstWindowSec", 2.0)))
  local resetBurstThreshold = math.max(2, math.floor(_getConfigNumber("resetBurstThreshold", 3)))
  local resetStabilizeSec = math.max(0.2, math.min(10.0, _getConfigNumber("resetStabilizeSec", 2.0)))

  local lastBurstAt = rv._resetBurstLastAt or 0
  if (now - lastBurstAt) <= resetBurstWindowSec then
    rv._resetBurstCount = (rv._resetBurstCount or 0) + 1
  else
    rv._resetBurstCount = 1
  end
  rv._resetBurstLastAt = now
  if rv._resetBurstCount >= resetBurstThreshold then
    rv._resetStabilizeUntil = now + resetStabilizeSec
    _bumpApplyStat("reset_stabilize_enter")
  end

  local cfg = _decodeJson(data)
  if not cfg then
    _bumpApplyStat("reset_drop_decode")
    return
  end

  if cfg.pos and cfg.rot then
    local okPos = pcall(function()
      veh:setPositionRotation(
        cfg.pos[1], cfg.pos[2], cfg.pos[3],
        cfg.rot[1], cfg.rot[2], cfg.rot[3], cfg.rot[4]
      )
    end)
    if not okPos then
      _bumpApplyStat("reset_error_pose")
    end
    -- Notify VE positionVE so it targets the reset pose instead of snapping back.
    if rv._hasVE and rv.gameVehicle then
      pcall(function()
        rv.gameVehicle:queueLuaCommand(string.format(
          "if highbeam_highbeamPositionVE and highbeam_highbeamPositionVE.setTarget then highbeam_highbeamPositionVE.setTarget(%.4f,%.4f,%.4f,0,0,0,%.6f,%.6f,%.6f,%.6f,0,0,0,%.4f) end",
          cfg.pos[1], cfg.pos[2], cfg.pos[3],
          cfg.rot[1], cfg.rot[2], cfg.rot[3], cfg.rot[4],
          os.clock()
        ))
      end)
    end
  else
    _bumpApplyStat("reset_no_pose")
  end

  -- Clear snapshots so interpolation restarts from the new position
  rv.snapshots = {}
  rv.lastSeqTime = -1

  -- Keep damage persistent across resets by re-applying last known damage payload.
  local persistDamage = config and config.get and config.get("persistRemoteDamageOnReset")
  if persistDamage ~= false and rv._lastDamageData and rv._lastDamageData ~= '' then
    M.applyDamage(playerId, vehicleId, rv._lastDamageData)
    _bumpApplyStat("damage_reapplied_after_reset")
  end

  _bumpApplyStat("reset_applied")
  log('D', logTag, 'Reset remote vehicle: ' .. key)
end

-- Apply damage data to a remote vehicle
M.applyDamage = function(playerId, vehicleId, damageData)
  local veh, rv, key = _withRemoteVehicle(playerId, vehicleId, "damage")
  if not veh then return end

  rv._lastDamageData = damageData
  rv._lastDamageAt = os.clock()

  local dmg = _decodeJson(damageData)
  if not dmg then
    _bumpApplyStat("damage_drop_decode")
    return
  end

  local commandsQueued = 0

  -- Apply beam deformation data via queueLuaCommand
  if dmg.deformGroup then
    local ok = pcall(function()
      veh:queueLuaCommand('obj:applyClusterVelocityScaleAdd(' .. tostring(dmg.deformGroup) .. ', 0, 0, 0, ' .. tostring(dmg.deformScale or 1) .. ')')
    end)
    if ok then
      commandsQueued = commandsQueued + 1
    else
      _bumpApplyStat("damage_error_deform_group")
    end
  end

  -- Apply beam breaks (sender field name is 'broken')
  if dmg.broken then
    local ok = pcall(function()
      for _, beamId in ipairs(dmg.broken) do
        veh:queueLuaCommand('obj:breakBeam(' .. tostring(beamId) .. ')')
        commandsQueued = commandsQueued + 1
      end
    end)
    if not ok then
      _bumpApplyStat("damage_error_break")
    end
  end

  -- Break group optimization: break all beams that belong to each group.
  if dmg.breakGroups then
    local ok = pcall(function()
      for _, groupName in ipairs(dmg.breakGroups) do
        local g = string.format("%q", tostring(groupName))
        veh:queueLuaCommand(
          'local _g=' .. g .. ' '
          .. 'for _i=0,obj:getBeamCount()-1 do '
          .. '  local _bg=obj:getBreakGroup(_i) '
          .. '  if _bg==_g then obj:breakBeam(_i) end '
          .. 'end'
        )
        commandsQueued = commandsQueued + 1
      end
    end)
    if not ok then
      _bumpApplyStat("damage_error_break_group")
    end
  end

  -- Apply beam deformation (sender field name is 'deform')
  -- Each entry is {deformVal, restLength} or a plain number (legacy).
  -- We use obj:setBeamLength to set the physical length directly.
  if dmg.deform then
    local ok = pcall(function()
      for beamIdStr, val in pairs(dmg.deform) do
        local cid = tostring(beamIdStr)
        if type(val) == 'table' and val[2] then
          -- New format: {deformation, restLength}
          veh:queueLuaCommand('obj:setBeamLength(' .. cid .. ', ' .. tostring(val[2]) .. ')')
          commandsQueued = commandsQueued + 1
        end
      end
    end)
    if not ok then
      _bumpApplyStat("damage_error_deform")
    end
  end

  -- Bug #3b: Apply node positions from damage data to reproduce deformed shape
  if dmg.nodes then
    local ok = pcall(function()
      for nodeIdStr, pos in pairs(dmg.nodes) do
        if type(pos) == 'table' and #pos >= 3 then
          local nid = tostring(nodeIdStr)
          veh:queueLuaCommand('obj:setNodePosition(' .. nid
            .. ', float3(' .. tostring(pos[1]) .. ',' .. tostring(pos[2]) .. ',' .. tostring(pos[3]) .. '))')
          commandsQueued = commandsQueued + 1
        end
      end
    end)
    if not ok then
      _bumpApplyStat("damage_error_nodes")
    end
  end

  if commandsQueued == 0 then
    _bumpApplyStat("damage_noop")
  else
    _bumpApplyStat("damage_applied")
    if _verboseSyncLoggingEnabled() then
      log('D', logTag, 'damage applied key=' .. key
        .. ' queued=' .. tostring(commandsQueued)
        .. ' broken=' .. tostring(dmg.broken and #dmg.broken or 0)
        .. ' deform=' .. tostring(dmg.deform and 1 or 0))
    end
  end
end

-- Apply electrics state update to a remote vehicle
M.applyElectrics = function(playerId, vehicleId, electricsData)
  local veh, _, key = _withRemoteVehicle(playerId, vehicleId, "electrics")
  if not veh then return end

  if M.remoteVehicles[key] and M.remoteVehicles[key]._hasVE then
    local jsonPayload = string.format("%q", tostring(electricsData or "{}"))
    local okForward = pcall(function()
      veh:queueLuaCommand("if highbeam_highbeamElectricsVE and highbeam_highbeamElectricsVE.applyElectrics then local _hbj=" .. jsonPayload .. "; local _hbt=(jsonDecode and jsonDecode(_hbj)) or {}; highbeam_highbeamElectricsVE.applyElectrics(_hbt) end")
    end)
    if okForward then
      _bumpApplyStat("electrics_applied")
      return
    end
  end

  local elec = _decodeJson(electricsData)
  if not elec then
    _bumpApplyStat("electrics_drop_decode")
    return
  end

  -- Apply electrics via vehicle-side Lua
  -- P4.3: Added gear and parking brake
  local commandCount = 0
  local ok = pcall(function()
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
    if elec.steering ~= nil then
      table.insert(cmds, 'electrics.values.steering_input = ' .. tostring(elec.steering))
      table.insert(cmds, 'electrics.values.steering = ' .. tostring(elec.steering))
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
      commandCount = #cmds
      veh:queueLuaCommand(table.concat(cmds, ' '))
    end
  end)
  if not ok then
    _bumpApplyStat("electrics_error_apply")
    return
  end

  if commandCount == 0 then
    _bumpApplyStat("electrics_noop")
  else
    _bumpApplyStat("electrics_applied")
    if _verboseSyncLoggingEnabled() then
      log('D', logTag, 'electrics applied key=' .. key .. ' cmds=' .. tostring(commandCount))
    end
  end
end

M.applyInputs = function(playerId, vehicleId, deltaStr)
  local veh, rv, key = _withRemoteVehicle(playerId, vehicleId, "inputs")
  if not veh then return end
  if not rv._hasVE then
    _bumpApplyStat("inputs_drop_no_ve")
    return
  end

  local function escapeLuaString(s)
    return string.format("%q", s or "")
  end

  local ok = pcall(function()
    veh:queueLuaCommand("if highbeam_highbeamInputsVE and highbeam_highbeamInputsVE.applyInputs then local d={} for part in string.gmatch(" .. escapeLuaString(deltaStr) .. ",'[^,]+') do local k,v=string.match(part,'^([%a]+)=([^,]+)$'); if k then d[k]=tonumber(v) or 0 end end highbeam_highbeamInputsVE.applyInputs(d) end")
  end)
  if ok then
    _bumpApplyStat("inputs_applied")
  else
    _bumpApplyStat("inputs_error_apply")
  end
end

M.applyPowertrain = function(playerId, vehicleId, powertrainData)
  local veh, rv, key = _withRemoteVehicle(playerId, vehicleId, "powertrain")
  if not veh then return end
  if not rv._hasVE then
    _bumpApplyStat("powertrain_drop_no_ve")
    return
  end

  local jsonPayload = string.format("%q", tostring(powertrainData or "{}"))
  local ok = pcall(function()
    veh:queueLuaCommand("if highbeam_highbeamPowertrainVE and highbeam_highbeamPowertrainVE.applyPowertrain then local _hbj=" .. jsonPayload .. "; local _hbt=(jsonDecode and jsonDecode(_hbj)) or {}; highbeam_highbeamPowertrainVE.applyPowertrain(_hbt) end")
  end)
  if ok then
    _bumpApplyStat("powertrain_applied")
  else
    _bumpApplyStat("powertrain_error_apply")
  end
end

-- Apply low-rate TCP pose fallback update while UDP is not yet active.
M.applyPose = function(playerId, vehicleId, poseData)
  local pose = _decodeJson(poseData)
  if not pose then
    _bumpApplyStat("pose_drop_decode")
    return
  end

  local decoded = {
    playerId = playerId,
    vehicleId = vehicleId,
    pos = pose.pos,
    rot = pose.rot,
    vel = pose.vel,
    time = tonumber(pose.time) or os.clock(),
    inputs = pose.inputs,
    angVel = pose.angVel,
  }

  if type(decoded.pos) ~= "table" or #decoded.pos < 3
    or type(decoded.rot) ~= "table" or #decoded.rot < 4
    or type(decoded.vel) ~= "table" or #decoded.vel < 3 then
    _bumpApplyStat("pose_drop_invalid")
    return
  end

  M.updateRemote(decoded)
  _bumpApplyStat("pose_applied")
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

  if not sourceRv or not targetRv then
    _bumpApplyStat("coupling_drop_missing_remote")
    return
  end
  local sourceVeh = sourceRv.gameVehicle or (sourceRv.gameVehicleId and scenetree.findObjectById(sourceRv.gameVehicleId))
  local targetVeh = targetRv.gameVehicle or (targetRv.gameVehicleId and scenetree.findObjectById(targetRv.gameVehicleId))
  if not sourceVeh or not targetVeh then
    _bumpApplyStat("coupling_drop_missing_game_vehicle")
    return
  end

  if coupled then
    local ok = pcall(function()
      sourceVeh:queueLuaCommand(
        'beamstate.attachCouplerByNodeId(' .. tostring(nodeId or 0) .. ', '
        .. tostring(targetRv.gameVehicleId) .. ', '
        .. tostring(targetNodeId or 0) .. ')'
      )
    end)
    if ok then
      _bumpApplyStat("coupling_applied")
    else
      _bumpApplyStat("coupling_error_apply")
    end
    log('D', logTag, 'Applied coupling: ' .. tostring(sourceRv.gameVehicleId) .. ' -> ' .. tostring(targetRv.gameVehicleId))
  else
    local ok = pcall(function()
      sourceVeh:queueLuaCommand('beamstate.detachCoupler(' .. tostring(nodeId or 0) .. ')')
    end)
    if ok then
      _bumpApplyStat("coupling_applied")
    else
      _bumpApplyStat("coupling_error_apply")
    end
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
          rv._hasVE = false
          _queueRemoteVeBootstrap(rv, tostring(rv.playerId) .. '_' .. tostring(rv.vehicleId))
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

    -- VE probe retry: if previous probe failed and enough time has passed, re-probe
    if rv.gameVehicle and not rv._hasVE and rv._veProbeQueuedAt then
      local probeAge = now - rv._veProbeQueuedAt
      local retries = rv._veProbeRetries or 0
      if probeAge >= VE_PROBE_RETRY_DELAY and retries < VE_PROBE_MAX_RETRIES then
        rv._veProbeRetries = retries + 1
        local key = tostring(rv.playerId) .. '_' .. tostring(rv.vehicleId)
        if _verboseSyncLoggingEnabled() then
          log('D', logTag, 'VE probe retry #' .. tostring(rv._veProbeRetries) .. ' key=' .. key)
        end
        _queueRemoteVeBootstrap(rv, key)
      end
    end

    -- When VE is active, it handles physics-rate positioning via onPhysicsStep.
    -- GE still computes interpolation targets and forwards them via _applyPosRot
    -- (which dispatches to VE queueLuaCommand when _hasVE is true).
    -- Skip LOD throttling when VE is active since VE handles its own rate.

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
        targetRot = _quatFromAngularVelocity(s2.rot, s2.angVel, extraT)
      end

      -- P2.2: Smooth correction blending instead of instant teleport.
      -- Blend the current physics position toward the target position each frame.
      -- If the error is very large, teleport immediately.
      local finalPos = targetPos
      local finalRot = targetRot
      local correctionBlendCurrent = correctionBlend
      local teleportDistSqCurrent = teleportDistSq
      if rv._resetStabilizeUntil and now < rv._resetStabilizeUntil then
        correctionBlendCurrent = math.min(1.0, correctionBlendCurrent * 2.5)
        teleportDistSqCurrent = (teleportDist * 3.0) * (teleportDist * 3.0)
      end
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

        if errSq > teleportDistSqCurrent then
          -- Large error: teleport instantly
          _teleportCount = _teleportCount + 1
        elseif errSq > POS_DELTA_SQ_THRESHOLD then
          -- Small-to-medium error: blend toward target
          local blend = math.min(1.0, correctionBlendCurrent * dt * 60)  -- normalize to ~60fps
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

      -- Compute velocity for VE forwarding
      local interpVel = s2.vel
      if _shouldApplyPosRot(rv, finalPos, finalRot) then
        _applyPosRot(rv, finalPos, finalRot, interpVel)
      end
    elseif rv.gameVehicle and #rv.snapshots >= 1 then
      local latest = rv.snapshots[#rv.snapshots]
      local latestPos = latest.pos
      local latestRot = latest.rot
      if _shouldApplyPosRot(rv, latestPos, latestRot) then
        _applyPosRot(rv, latestPos, latestRot, latest.vel)
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

        if inp.handbrake ~= nil then
          local lastHandbrake = rv._lastAppliedHandbrake
          local newHandbrake = inp.handbrake
          if lastHandbrake == nil or math.abs(newHandbrake - lastHandbrake) > 0.01 then
            rv._lastAppliedHandbrake = newHandbrake
            inputCmds[#inputCmds+1] = 'input.event("parkingbrake", ' .. tostring(newHandbrake) .. ', 1)'
            inputCmds[#inputCmds+1] = 'electrics.values.parkingbrake = ' .. tostring(newHandbrake)
          end
        end

        if inp.gear ~= nil then
          local lastGear = rv._lastAppliedGear
          local newGear = inp.gear
          if lastGear == nil or math.abs(newGear - lastGear) > 0.01 then
            rv._lastAppliedGear = newGear
            inputCmds[#inputCmds+1] = 'electrics.values.gear_A = ' .. tostring(newGear)
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

    if next(_componentApplyStats) then
      log('I', logTag, 'Component apply diag=' .. (function()
        local parts = {}
        for k, v in pairs(_componentApplyStats) do
          if v and v > 0 then
            table.insert(parts, k .. '=' .. tostring(v))
          end
        end
        table.sort(parts)
        return #parts > 0 and table.concat(parts, ',') or 'none'
      end)())
      _componentApplyStats = {}
    end

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
