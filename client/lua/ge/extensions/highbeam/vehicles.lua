local M = {}
local logTag = "HighBeam.Vehicles"

M.remoteVehicles = {}  -- [playerId_vehicleId] = vehicleData

M.spawnRemote = function(playerId, vehicleId, configData)
end

M.updateRemote = function(playerId, vehicleId, pos, rot, vel)
end

M.removeRemote = function(playerId, vehicleId)
end

M.removeAllForPlayer = function(playerId)
end

M.tick = function(dt)
  -- Apply interpolation to remote vehicles
end

return M
