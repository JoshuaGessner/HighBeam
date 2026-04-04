local M = {}
local logTag = "HighBeam.Vehicles"

M.remoteVehicles = {} -- [playerId_vehicleId] = vehicleData
M._remoteGameIds = {} -- [gameVehicleId] = true  (quick lookup for isRemote)

local interpolationMath = require("highbeam/math")
local config = require("highbeam/config")

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

-- Check if a game vehicle ID belongs to a remote player
M.isRemote = function(gameVehicleId)
  return M._remoteGameIds[gameVehicleId] == true
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

M.spawnRemote = function(playerId, vehicleId, configData)
  local key = makeKey(playerId, vehicleId)
  if M.remoteVehicles[key] then
    log('W', logTag, 'Remote vehicle already exists: ' .. key)
    return
  end

  local cfg = _decodeJson(configData) or {}

  local model = cfg.model or "pickup"
  local partCfg = cfg.partConfig or ""
  local pos = cfg.pos or { 0, 0, 0 }
  local rot = cfg.rot or { 0, 0, 0, 1 }

  -- Validate model availability; fall back to pickup if not found
  local modelAvailable = true
  if scenetree and scenetree.findObject then
    -- BeamNG doesn't have a direct "does model exist" API, so we just try
    -- to spawn and handle failure below
  end

  local vid = nil
  local ok, err = pcall(function()
    vid = be:spawnVehicle(
      model,
      partCfg,
      vec3(pos[1], pos[2], pos[3]),
      quat(rot[1], rot[2], rot[3], rot[4])
    )
  end)

  if not ok or not vid then
    log('W', logTag, 'Failed to spawn model "' .. tostring(model) .. '": ' .. tostring(err) .. ' — falling back to pickup')
    pcall(function()
      vid = be:spawnVehicle(
        "pickup", "",
        vec3(pos[1], pos[2], pos[3]),
        quat(rot[1], rot[2], rot[3], rot[4])
      )
    end)
  end

  M.remoteVehicles[key] = {
    playerId = playerId,
    vehicleId = vehicleId,
    gameVehicleId = vid,
    gameVehicle = vid and scenetree.findObjectById(vid) or nil,
    snapshots = {},
    lastSeqTime = -1,  -- For out-of-order rejection
  }

  if vid then
    M._remoteGameIds[vid] = true
  end

  log('I', logTag, 'Spawned remote vehicle: ' .. key .. ' gameVid=' .. tostring(vid))
end

M.updateRemote = function(decoded)
  local key = makeKey(decoded.playerId, decoded.vehicleId)
  local rv = M.remoteVehicles[key]
  if not rv then
    return
  end

  -- Out-of-order protection: reject packets older than newest received
  if decoded.time and rv.lastSeqTime and decoded.time < rv.lastSeqTime then
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

M._escapeForLuaCmd = function(s)
  if type(s) ~= "string" then return tostring(s) end
  return "'" .. s:gsub("'", "\\'") .. "'"
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
        -- Extrapolate using latest velocity
        local extraT = math.min((renderTime - s2.received), extrapolationWindow)
        pos = {
          s2.pos[1] + (s2.vel[1] or 0) * extraT,
          s2.pos[2] + (s2.vel[2] or 0) * extraT,
          s2.pos[3] + (s2.vel[3] or 0) * extraT,
        }
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
end

return M
