local M = {}
local logTag = "HighBeam.Vehicles"

M.remoteVehicles = {} -- [playerId_vehicleId] = vehicleData

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

M.spawnRemote = function(playerId, vehicleId, configData)
  local key = makeKey(playerId, vehicleId)
  if M.remoteVehicles[key] then
    log('W', logTag, 'Remote vehicle already exists: ' .. key)
    return
  end

  local config = {}
  local okDecode, decoded = pcall(function()
    local okJson, jsonLib = pcall(require, "highbeam/lib/json")
    if not okJson or not jsonLib then
      return nil
    end
    return jsonLib.decode(configData)
  end)
  if okDecode and decoded then
    config = decoded
  end

  local spawnData = {
    model = config.model or "pickup",
    config = config.partConfig or "",
    pos = config.pos or { 0, 0, 0 },
    rot = config.rot or { 0, 0, 0, 1 },
  }

  local vid = be:spawnVehicle(
    spawnData.model,
    spawnData.config,
    vec3(spawnData.pos[1], spawnData.pos[2], spawnData.pos[3]),
    quat(spawnData.rot[1], spawnData.rot[2], spawnData.rot[3], spawnData.rot[4])
  )

  M.remoteVehicles[key] = {
    playerId = playerId,
    vehicleId = vehicleId,
    gameVehicleId = vid,
    gameVehicle = vid and scenetree.findObjectById(vid) or nil,
    snapshots = {},
  }

  log('I', logTag, 'Spawned remote vehicle: ' .. key .. ' gameVid=' .. tostring(vid))
end

M.updateRemote = function(decoded)
  local key = makeKey(decoded.playerId, decoded.vehicleId)
  local rv = M.remoteVehicles[key]
  if not rv then
    return
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
  if not rv then
    return
  end

  log('D', logTag, 'Config update for remote vehicle: ' .. key)
end

M.resetRemote = function(playerId, vehicleId, data)
  local key = makeKey(playerId, vehicleId)
  local rv = M.remoteVehicles[key]
  if not rv or not rv.gameVehicle then
    return
  end

  log('D', logTag, 'Reset remote vehicle: ' .. key)
end

M.removeRemote = function(playerId, vehicleId)
  local key = makeKey(playerId, vehicleId)
  local rv = M.remoteVehicles[key]
  if not rv then
    return
  end

  if rv.gameVehicleId then
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
        pos = interpolationMath.lerpVec3(s1.pos, s2.pos, t)
        rot = interpolationMath.slerpQuat(s1.rot, s2.rot, t)
      else
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
      -- Interpolation disabled: snap to latest known authoritative state.
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
