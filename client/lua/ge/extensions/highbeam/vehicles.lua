local M = {}
local logTag = "HighBeam.Vehicles"

M.remoteVehicles = {} -- [playerId_vehicleId] = vehicleData
M._remoteGameIds = {} -- [gameVehicleId] = true  (quick lookup for isRemote)

local interpolationMath = require("highbeam/math")
local config = require("highbeam/config")
local _diagTimer = 0
local _diagIntervalSec = 5.0
local _staleDropCount = 0
local _spawnRetryDropCount = 0
local _spawnRetryAttemptCount = 0
local _spawnRetrySuccessCount = 0
local SPAWN_RETRY_MAX_ATTEMPTS = 5
local SPAWN_RETRY_BASE_DELAY = 0.75

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
  local raw = _getConfigNumber("jitterBufferSnapshots", 5)
  return math.max(2, math.floor(raw))
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
  local vid = nil
  local ok, err = pcall(function()
    vid = be:spawnVehicle(
      spec.model,
      spec.partCfg,
      vec3(spec.pos[1], spec.pos[2], spec.pos[3]),
      quat(spec.rot[1], spec.rot[2], spec.rot[3], spec.rot[4])
    )
  end)

  if not ok or not vid then
    pcall(function()
      vid = be:spawnVehicle(
        "pickup", "",
        vec3(spec.pos[1], spec.pos[2], spec.pos[3]),
        quat(spec.rot[1], spec.rot[2], spec.rot[3], spec.rot[4])
      )
    end)
    if not vid then
      return nil, tostring(err)
    end
  end

  return vid
end

-- Check if a game vehicle ID belongs to a remote player
M.isRemote = function(gameVehicleId)
  return M._remoteGameIds[gameVehicleId] == true
end

M.spawnRemote = function(playerId, vehicleId, configData, snapshot)
  local key = makeKey(playerId, vehicleId)
  if M.remoteVehicles[key] then
    log('W', logTag, 'Remote vehicle already exists: ' .. key)
    return
  end

  local spec = _buildSpawnSpec(configData, snapshot)
  local vid, spawnErr = _spawnGameVehicle(spec)

  M.remoteVehicles[key] = {
    playerId = playerId,
    vehicleId = vehicleId,
    gameVehicleId = vid,
    gameVehicle = vid and scenetree.findObjectById(vid) or nil,
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
    M._remoteGameIds[vid] = true
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
  if not vehicle then return end
  M.spawnRemote(vehicle.player_id, vehicle.vehicle_id, vehicle.data, {
    position = vehicle.position,
    rotation = vehicle.rotation,
    velocity = vehicle.velocity,
    snapshotTimeMs = vehicle.snapshot_time_ms,
  })
end

M.updateRemote = function(decoded)
  local key = makeKey(decoded.playerId, decoded.vehicleId)
  local rv = M.remoteVehicles[key]
  if not rv then
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

  table.insert(rv.snapshots, {
    pos = decoded.pos,
    rot = decoded.rot,
    vel = decoded.vel,
    time = decoded.time,
    received = os.clock(),
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

  -- Teleport to reset position
  if cfg.pos and cfg.rot then
    pcall(function()
      veh:setPositionRotation(
        cfg.pos[1], cfg.pos[2], cfg.pos[3],
        cfg.rot[1], cfg.rot[2], cfg.rot[3], cfg.rot[4]
      )
    end)
  end

  -- Clear damage/deformation state on the remote vehicle
  pcall(function()
    veh:queueLuaCommand('recovery.startRecovering()')
  end)

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

  -- Apply node deformation if provided as beam breaks / deform data
  if dmg.beamBreaks then
    pcall(function()
      for _, beamId in ipairs(dmg.beamBreaks) do
        veh:queueLuaCommand('obj:breakBeam(' .. tostring(beamId) .. ')')
      end
    end)
  end

  if dmg.deformData then
    pcall(function()
      veh:queueLuaCommand('obj:applyDeformGroup(' .. M._escapeForLuaCmd(dmg.deformData) .. ')')
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
      be:deleteVehicle(rv.gameVehicleId)
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
          be:deleteVehicle(rv.gameVehicleId)
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

M.tick = function(dt)
  local interpolationEnabled = (config and config.get and config.get("interpolation")) ~= false
  local interpolationDelay = _getInterpolationDelay()
  local extrapolationWindow = _getExtrapolationWindow()
  local now = os.clock()
  local renderTime = now - interpolationDelay

  for _, rv in pairs(M.remoteVehicles) do
    if (not rv.gameVehicleId) and rv.spawnRetry then
      if now >= rv.spawnRetry.nextAt then
        local latest = rv.snapshots[#rv.snapshots]
        if latest then
          rv.spawnSpec.pos = latest.pos
          rv.spawnSpec.rot = latest.rot
          rv.spawnSpec.vel = latest.vel
        end

        local vid, spawnErr = _spawnGameVehicle(rv.spawnSpec)
        _spawnRetryAttemptCount = _spawnRetryAttemptCount + 1
        if vid then
          rv.gameVehicleId = vid
          rv.gameVehicle = scenetree.findObjectById(vid)
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

    if rv.gameVehicle and #rv.snapshots >= 2 and interpolationEnabled then
      local s1 = nil
      local s2 = nil

      for i = 1, #rv.snapshots - 1 do
        local a = rv.snapshots[i]
        local b = rv.snapshots[i + 1]
        if a.received <= renderTime and b.received >= renderTime then
          s1 = a
          s2 = b
          break
        end
      end

      if not s1 or not s2 then
        s1 = rv.snapshots[#rv.snapshots - 1]
        s2 = rv.snapshots[#rv.snapshots]
      end

      local span = s2.received - s1.received
      local t = 1
      if span > 0.0001 then
        t = (renderTime - s1.received) / span
      end

      local pos = nil
      local rot = nil

      if t <= 1.0 then
        -- Cubic Hermite interpolation using velocity at both endpoints
        pos = interpolationMath.hermiteVec3(s1.pos, s1.vel, s2.pos, s2.vel, span, t)
        rot = interpolationMath.slerpQuat(s1.rot, s2.rot, t)
      else
        -- Extrapolate using latest velocity + input-augmented arc
        local extraT = math.min((renderTime - s2.received), extrapolationWindow)
        local vx = s2.vel[1] or 0
        local vy = s2.vel[2] or 0
        local vz = s2.vel[3] or 0

        -- If we have input data, use steering for curved extrapolation
        if s2.inputs and s2.inputs.steer and math.abs(s2.inputs.steer) > 0.01 then
          local speed = math.sqrt(vx * vx + vy * vy)
          if speed > 1.0 then
            -- Approximate turn rate from steering input and speed
            -- Wheelbase ~2.5m, max steering angle ~35deg
            local turnRate = s2.inputs.steer * 0.6 / (speed * 0.1 + 1)
            local angle = turnRate * extraT
            local cosA = math.cos(angle)
            local sinA = math.sin(angle)
            -- Rotate the velocity vector
            local rvx = vx * cosA - vy * sinA
            local rvy = vx * sinA + vy * cosA
            pos = {
              s2.pos[1] + rvx * extraT,
              s2.pos[2] + rvy * extraT,
              s2.pos[3] + vz * extraT,
            }
          else
            pos = {
              s2.pos[1] + vx * extraT,
              s2.pos[2] + vy * extraT,
              s2.pos[3] + vz * extraT,
            }
          end
        else
          pos = {
            s2.pos[1] + vx * extraT,
            s2.pos[2] + vy * extraT,
            s2.pos[3] + vz * extraT,
          }
        end
        rot = s2.rot
      end

      rv.gameVehicle:setPositionRotation(pos[1], pos[2], pos[3], rot[1], rot[2], rot[3], rot[4])
    elseif rv.gameVehicle and #rv.snapshots >= 1 then
      local latest = rv.snapshots[#rv.snapshots]
      rv.gameVehicle:setPositionRotation(
        latest.pos[1],
        latest.pos[2],
        latest.pos[3],
        latest.rot[1],
        latest.rot[2],
        latest.rot[3],
        latest.rot[4]
      )
    end
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
  end
end

return M
