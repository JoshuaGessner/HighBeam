local M = {}
local logTag = "HighBeam.Vehicles"

M.remoteVehicles = {} -- [playerId_vehicleId] = vehicleData

local interpolationMath = require("highbeam/math")
local INTERPOLATION_DELAY = 0.05 -- 50ms render delay
local MAX_SNAPSHOTS = 5

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

  while #rv.snapshots > MAX_SNAPSHOTS do
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
  local renderTime = os.clock() - INTERPOLATION_DELAY

  for _, rv in pairs(M.remoteVehicles) do
    if not rv.gameVehicle and rv.gameVehicleId then
      rv.gameVehicle = scenetree.findObjectById(rv.gameVehicleId)
    end

    if rv.gameVehicle and #rv.snapshots >= 2 then
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

      local pos = interpolationMath.lerpVec3(s1.pos, s2.pos, t)
      local rot = interpolationMath.slerpQuat(s1.rot, s2.rot, t)
      rv.gameVehicle:setPositionRotation(pos[1], pos[2], pos[3], rot[1], rot[2], rot[3], rot[4])
    end
  end
end

return M
