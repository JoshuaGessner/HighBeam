local M = {}
local logTag = "HighBeam.Vehicles"

M.remoteVehicles = {}  -- [playerId_vehicleId] = vehicleData

local function makeKey(playerId, vehicleId)
  return tostring(playerId) .. "_" .. tostring(vehicleId)
end

local function lerpVal(a, b, t)
  return a + (b - a) * t
end

local function lerpVec3(a, b, t)
  return {
    lerpVal(a[1], b[1], t),
    lerpVal(a[2], b[2], t),
    lerpVal(a[3], b[3], t),
  }
end

local function slerpQuat(a, b, t)
  -- Simple normalized lerp (nlerp) — good enough for small time steps
  local r = {
    lerpVal(a[1], b[1], t),
    lerpVal(a[2], b[2], t),
    lerpVal(a[3], b[3], t),
    lerpVal(a[4], b[4], t),
  }
  local len = math.sqrt(r[1]*r[1] + r[2]*r[2] + r[3]*r[3] + r[4]*r[4])
  if len > 0.0001 then
    r[1] = r[1] / len
    r[2] = r[2] / len
    r[3] = r[3] / len
    r[4] = r[4] / len
  end
  return r
end

M.spawnRemote = function(playerId, vehicleId, configData)
  local key = makeKey(playerId, vehicleId)
  if M.remoteVehicles[key] then
    log('W', logTag, 'Remote vehicle already exists: ' .. key)
    return
  end

  local config = {}
  local ok, decoded = pcall(function()
    return require("highbeam/lib/json").decode(configData)
  end)
  if ok and decoded then config = decoded end

  local spawnData = {
    model = config.model or "pickup",
    config = config.partConfig or "",
    pos = config.pos or {0, 0, 0},
    rot = config.rot or {0, 0, 0, 1},
  }

  -- Spawn via BeamNG API
  local vid = be:spawnVehicle(spawnData.model, spawnData.config,
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
  if not rv then return end

  -- Push new snapshot into interpolation buffer
  table.insert(rv.snapshots, {
    pos = decoded.pos,
    rot = decoded.rot,
    vel = decoded.vel,
    time = decoded.time,
    received = os.clock(),
  })
  -- Keep only last 3 snapshots
  while #rv.snapshots > 3 do
    table.remove(rv.snapshots, 1)
  end
end

M.updateRemoteConfig = function(playerId, vehicleId, configData)
  local key = makeKey(playerId, vehicleId)
  local rv = M.remoteVehicles[key]
  if not rv then return end
  -- Apply config changes (part swaps, paint, etc.)
  log('D', logTag, 'Config update for remote vehicle: ' .. key)
end

M.resetRemote = function(playerId, vehicleId, data)
  local key = makeKey(playerId, vehicleId)
  local rv = M.remoteVehicles[key]
  if not rv or not rv.gameVehicle then return end
  -- Reset the vehicle (respawn at position from data)
  log('D', logTag, 'Reset remote vehicle: ' .. key)
end

M.removeRemote = function(playerId, vehicleId)
  local key = makeKey(playerId, vehicleId)
  local rv = M.remoteVehicles[key]
  if not rv then return end

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
  for key, rv in pairs(M.remoteVehicles) do
    -- Resolve game vehicle reference if needed
    if not rv.gameVehicle and rv.gameVehicleId then
      rv.gameVehicle = scenetree.findObjectById(rv.gameVehicleId)
    end

    if rv.gameVehicle and #rv.snapshots >= 2 then
      -- Interpolate between two most recent snapshots
      local s1 = rv.snapshots[#rv.snapshots - 1]
      local s2 = rv.snapshots[#rv.snapshots]
      local elapsed = s2.received - s1.received
      if elapsed > 0 then
        local t = (os.clock() - s2.received) / elapsed
        t = math.max(0, math.min(1, t))

        local pos = lerpVec3(s1.pos, s2.pos, t)
        local rot = slerpQuat(s1.rot, s2.rot, t)
        rv.gameVehicle:setPositionRotation(pos[1], pos[2], pos[3], rot[1], rot[2], rot[3], rot[4])
      end
    end
  end
end

return M
