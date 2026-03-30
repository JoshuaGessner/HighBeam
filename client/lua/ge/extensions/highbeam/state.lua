local M = {}
local logTag = "HighBeam.State"

M.localVehicles = {}  -- [gameVehicleId] = { serverId, lastSentTime, ... }
M.playerId = nil
M.sessionToken = nil

M.tick = function(dt)
  -- Check for vehicle spawns/deletes, send position updates at configured rate
end

return M
