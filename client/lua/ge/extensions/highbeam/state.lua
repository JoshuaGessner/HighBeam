local M = {}
local logTag = "HighBeam.State"

M.localVehicles = {}  -- [gameVehicleId] = serverVehicleId
M.playerId = nil
M.sessionToken = nil
M._pendingSpawnQueue = {}  -- FIFO queue of game vehicle IDs awaiting server assignment

local sendTimer = 0
local connection = nil
local config = nil

M.setSubsystems = function(conn, cfg)
  connection = conn
  config = cfg
end

M.tick = function(dt)
  if not connection or connection.getState() ~= connection.STATE_CONNECTED then return end

  local updateRate = (config and config.get("updateRate")) or 20
  local updateInterval = 1.0 / updateRate
  sendTimer = sendTimer + dt
  if sendTimer < updateInterval then return end
  sendTimer = sendTimer - updateInterval

  local protocol = require("highbeam/protocol")
  local sessionHash = connection.getSessionHash()
  if not sessionHash then return end

  -- Send position updates for all local vehicles
  for gameVid, serverVid in pairs(M.localVehicles) do
    local veh = scenetree.findObjectById(gameVid)
    if veh then
      local pos = veh:getPosition()
      local rot = quatFromDir(veh:getDirectionVector(), veh:getDirectionVectorUp())
      local vel = veh:getVelocity()

      local data = protocol.encodePositionUpdate(
        sessionHash,
        serverVid,
        { pos.x, pos.y, pos.z },
        { rot.x, rot.y, rot.z, rot.w },
        { vel.x, vel.y, vel.z },
        veh:getSimTime()
      )
      connection.sendUdp(data)
    end
  end
end

M.onWorldState = function(players)
  -- Store player info from initial world state
  log('I', logTag, 'Received world state with ' .. tostring(#players) .. ' players')
end

M.onLocalVehicleSpawned = function(serverVehicleId, configData)
  -- Pop the oldest pending game vehicle ID from the FIFO queue
  if #M._pendingSpawnQueue > 0 then
    local gameVid = table.remove(M._pendingSpawnQueue, 1)
    M.localVehicles[gameVid] = serverVehicleId
    log('I', logTag, 'Local vehicle mapped: game=' .. tostring(gameVid) .. ' server=' .. tostring(serverVehicleId))
  else
    log('W', logTag, 'Received vehicle spawn confirmation but no pending spawn in queue (server vid=' .. tostring(serverVehicleId) .. ')')
  end
end

M.requestSpawn = function(gameVehicleId, configData)
  if not connection or connection.getState() ~= connection.STATE_CONNECTED then return end
  table.insert(M._pendingSpawnQueue, gameVehicleId)
  connection._sendPacket({
    type = "vehicle_spawn",
    vehicle_id = 0,  -- Server will assign
    data = configData,
  })
end

M.requestDelete = function(gameVehicleId)
  if not connection or connection.getState() ~= connection.STATE_CONNECTED then return end
  local serverVid = M.localVehicles[gameVehicleId]
  if serverVid then
    connection._sendPacket({
      type = "vehicle_delete",
      vehicle_id = serverVid,
    })
    M.localVehicles[gameVehicleId] = nil
  end
end

M.onDisconnect = function()
  log('I', logTag, 'Clearing local vehicle state on disconnect')
  M.localVehicles = {}
  M._pendingSpawnQueue = {}
  M.playerId = nil
  M.sessionToken = nil
  sendTimer = 0
end

return M
