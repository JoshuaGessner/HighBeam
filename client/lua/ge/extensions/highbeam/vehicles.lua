local M = {}
local logTag = "HighBeam.Vehicles"

M.remoteVehicles = {} -- [playerId_vehicleId] = vehicleData
M._remoteGameIds = {} -- [gameVehicleId] = true  (quick lookup for isRemote)
M._spawningRemote = false -- Guard flag: true while core_vehicles.spawnNewVehicle is in-flight
M._debugStats = {}  -- P0: Exposed debug stats for overlay

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

local function _isMalformedVeLuaChunk(chunk)
  if type(chunk) ~= "string" or chunk == "" then
    return true, "empty_chunk"
  end
  if string.find(chunk, "thenif", 1, true) then
    return true, "token_thenif"
  end
  local badToken = string.match(chunk, "highbeam[%w_]+end")
  if badToken then
    return true, badToken
  end
  return false, nil
end

local function _queueVeLuaCommand(veh, chunk, stage)
  local malformed, reason = _isMalformedVeLuaChunk(chunk)
  if malformed then
    _bumpApplyStat((stage or "ve_cmd") .. "_drop_malformed")
    log('E', logTag, 'Dropped malformed VE command stage=' .. tostring(stage)
      .. ' reason=' .. tostring(reason)
      .. ' chunk=' .. tostring(chunk))
    return false
  end
  local ok = pcall(function()
    veh:queueLuaCommand(chunk)
  end)
  if not ok then
    _bumpApplyStat((stage or "ve_cmd") .. "_error_apply")
    return false
  end
  return true
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

local function _getMaxSnapshots()
  return 2  -- Only need latest + previous for spawn retry and nametag lookups
end

makeKey = function(playerId, vehicleId)
  return tostring(playerId) .. "_" .. tostring(vehicleId)
end

local function _queueRemoteVeBootstrap(rv, key)
  if not rv or not rv.gameVehicle then return end
  local vehObj = rv.gameVehicle
  pcall(function()
    vehObj:queueLuaCommand([[
      extensions.loadModulesInDirectory("lua/vehicle/extensions/highbeam")
      local _missing = {}
      local _ready = false
      if highbeamVE and highbeamVE.setActive then
        highbeamVE.setActive(true, true)
        _ready = true
      else
        table.insert(_missing, "highbeamVE")
      end
      if not highbeamPositionVE then table.insert(_missing, "highbeamPositionVE") end
      if not highbeamVelocityVE then table.insert(_missing, "highbeamVelocityVE") end
      if not highbeamInputsVE then table.insert(_missing, "highbeamInputsVE") end
      if not highbeamElectricsVE then table.insert(_missing, "highbeamElectricsVE") end
      if not highbeamPowertrainVE then table.insert(_missing, "highbeamPowertrainVE") end
      if not highbeamDamageVE then table.insert(_missing, "highbeamDamageVE") end
      if #_missing > 0 then _ready = false end
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
    log('D', logTag, 'Queued remote VE bootstrap key=' .. tostring(key)
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
      rv._veLastHeartbeat = os.clock()
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

-- Receive heartbeat from remote vehicle's positionVE (sent every ~1s while vlua alive).
-- Updates _veLastHeartbeat timestamp used by death detection in onUpdate.
local VE_DEATH_TIMEOUT_SEC = 5.0
M.onVEHeartbeat = function(gameVehicleId)
  if not gameVehicleId then return end
  for _, rv in pairs(M.remoteVehicles) do
    if rv and rv.gameVehicleId == gameVehicleId and rv._hasVE then
      rv._veLastHeartbeat = os.clock()
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
    local cmd = string.format(
      "if highbeamPositionVE and highbeamPositionVE.setTarget then highbeamPositionVE.setTarget(%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.6f,%.6f,%.6f,%.6f,%.4f,%.4f,%.4f,%.0f) end",
      decoded.pos[1], decoded.pos[2], decoded.pos[3],
      decoded.vel[1], decoded.vel[2], decoded.vel[3],
      decoded.rot[1], decoded.rot[2], decoded.rot[3], decoded.rot[4],
      ax, ay, az,
      decoded.time or 0
    )
    _queueVeLuaCommand(rv.gameVehicle, cmd, "position")
  end

  -- Keep latest snapshot for spawn retry position and nametag lookups
  table.insert(rv.snapshots, {
    pos = decoded.pos,
    rot = decoded.rot,
    vel = decoded.vel,
    time = decoded.time,
    received = recvTime,
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
      local cmd = string.format(
        "if highbeamPositionVE and highbeamPositionVE.setTarget then highbeamPositionVE.setTarget(%.4f,%.4f,%.4f,0,0,0,%.6f,%.6f,%.6f,%.6f,0,0,0,%.0f) end",
        cfg.pos[1], cfg.pos[2], cfg.pos[3],
        cfg.rot[1], cfg.rot[2], cfg.rot[3], cfg.rot[4],
        os.clock()
      )
      _queueVeLuaCommand(rv.gameVehicle, cmd, "reset")
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
    local cmd = "if highbeamElectricsVE and highbeamElectricsVE.applyElectrics then local _hbj=" .. jsonPayload .. "; local _hbt=(jsonDecode and jsonDecode(_hbj)) or {}; highbeamElectricsVE.applyElectrics(_hbt) end"
    local okForward = _queueVeLuaCommand(veh, cmd, "electrics")
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
    -- ignitionLevel is handled exclusively by powertrainVE.
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

  local cmd = "if highbeamInputsVE and highbeamInputsVE.applyInputs then local d={} for part in string.gmatch(" .. escapeLuaString(deltaStr) .. ",'[^,]+') do local k,v=string.match(part,'^([%a]+)=([^,]+)$'); if k then d[k]=tonumber(v) or 0 end end highbeamInputsVE.applyInputs(d) end"
  local ok = _queueVeLuaCommand(veh, cmd, "inputs")
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
  local cmd = "if highbeamPowertrainVE and highbeamPowertrainVE.applyPowertrain then local _hbj=" .. jsonPayload .. "; local _hbt=(jsonDecode and jsonDecode(_hbj)) or {}; highbeamPowertrainVE.applyPowertrain(_hbt) end"
  local ok = _queueVeLuaCommand(veh, cmd, "powertrain")
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
M.tick = function(dt)
  local now = os.clock()

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

    -- VE death detection: if heartbeat stops arriving for VE_DEATH_TIMEOUT_SEC,
    -- the remote vlua has crashed. Re-bootstrap to recover.
    if rv._hasVE and rv._veLastHeartbeat then
      local hbAge = now - rv._veLastHeartbeat
      if hbAge > VE_DEATH_TIMEOUT_SEC then
        local key = tostring(rv.playerId) .. '_' .. tostring(rv.vehicleId)
        log('W', logTag, 'VE death detected: heartbeat timeout key=' .. key
          .. ' gameVid=' .. tostring(rv.gameVehicleId)
          .. ' lastHB=' .. string.format('%.2f', rv._veLastHeartbeat)
          .. ' age=' .. string.format('%.2f', hbAge) .. 's'
          .. ' readyAt=' .. string.format('%.2f', rv._veReadyAt or 0))
        rv._hasVE = false
        rv._veDeathAt = now
        rv._veDeathCount = (rv._veDeathCount or 0) + 1
        -- Re-queue VE bootstrap to attempt recovery
        rv._veProbeRetries = 0
        rv._veProbeQueuedAt = nil
        _queueRemoteVeBootstrap(rv, key)
        log('I', logTag, 'VE recovery queued key=' .. key
          .. ' deathCount=' .. tostring(rv._veDeathCount))
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

    -- P0: Update debug stats for overlay
    M._debugStats = {
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

    -- VE health dump: log per-vehicle VE state for diagnostics
    for key, rv in pairs(M.remoteVehicles) do
      if rv.gameVehicleId then
        local veInfo = 'hasVE=' .. tostring(rv._hasVE)
        if rv._veReadyAt then
          veInfo = veInfo .. ' readyAge=' .. string.format('%.1f', now - rv._veReadyAt) .. 's'
        end
        if rv._veLastHeartbeat then
          veInfo = veInfo .. ' hbAge=' .. string.format('%.1f', now - rv._veLastHeartbeat) .. 's'
        else
          veInfo = veInfo .. ' hbAge=never'
        end
        if rv._veDeathCount and rv._veDeathCount > 0 then
          veInfo = veInfo .. ' deaths=' .. tostring(rv._veDeathCount)
        end
        if rv._veDeathAt then
          veInfo = veInfo .. ' lastDeath=' .. string.format('%.1f', now - rv._veDeathAt) .. 's_ago'
        end
        log('I', logTag, 'VE diag key=' .. tostring(key)
          .. ' gvid=' .. tostring(rv.gameVehicleId)
          .. ' ' .. veInfo)
      end
    end
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
