local M = {}
local logTag = "HighBeam.State"

M.localVehicles = {}  -- [gameVehicleId] = serverVehicleId
M.playerId = nil
M.sessionToken = nil
M._pendingSpawns = {}  -- [requestId] = gameVehicleId  (request-ID keyed map)
M._nextSpawnRequestId = 1

local sendTimer = 0
local connection = nil
local config = nil
local _damageTimers = {}  -- [gameVehicleId] = cooldown timer

M.setSubsystems = function(conn, cfg)
  connection = conn
  config = cfg
end

-- Capture the vehicle config JSON from a BeamNG vehicle object
M.captureVehicleConfig = function(veh)
  local model = veh:getField('JBeam', '0') or 'pickup'
  local partConfig = ''
  local ok, pc = pcall(function() return veh:getField('partConfig', '0') end)
  if ok and pc and pc ~= '' then partConfig = pc end

  local pos = veh:getPosition()
  local rot = quatFromDir(veh:getDirectionVector(), veh:getDirectionVectorUp())

  -- Build JSON manually to avoid dependency on a JSON encoder
  local json = '{"model":' .. M._jsonStr(model)
    .. ',"partConfig":' .. M._jsonStr(partConfig)
    .. ',"pos":[' .. pos.x .. ',' .. pos.y .. ',' .. pos.z .. ']'
    .. ',"rot":[' .. rot.x .. ',' .. rot.y .. ',' .. rot.z .. ',' .. rot.w .. ']'

  -- Try to capture color data
  local okColor, color = pcall(function() return veh:getField('color', '0') end)
  if okColor and color and color ~= '' then
    json = json .. ',"color":' .. M._jsonStr(color)
  end

  json = json .. '}'
  return json
end

M._jsonStr = function(s)
  if not s then return '""' end
  return '"' .. tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
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
  log('I', logTag, 'Received world state with ' .. tostring(#players) .. ' players')
end

M.onLocalVehicleSpawned = function(serverVehicleId, configData, spawnRequestId)
  -- Use request ID to map if available (robust), fall back to first pending (legacy)
  local gameVid = nil
  if spawnRequestId and M._pendingSpawns[spawnRequestId] then
    gameVid = M._pendingSpawns[spawnRequestId]
    M._pendingSpawns[spawnRequestId] = nil
  else
    -- Legacy fallback: find any pending spawn
    for rid, gvid in pairs(M._pendingSpawns) do
      gameVid = gvid
      M._pendingSpawns[rid] = nil
      break
    end
  end

  if gameVid then
    M.localVehicles[gameVid] = serverVehicleId
    log('I', logTag, 'Local vehicle mapped: game=' .. tostring(gameVid) .. ' server=' .. tostring(serverVehicleId) .. ' reqId=' .. tostring(spawnRequestId))
  else
    log('W', logTag, 'Spawn confirmation but no pending spawn (server vid=' .. tostring(serverVehicleId) .. ')')
  end
end

M.requestSpawn = function(gameVehicleId, configData)
  if not connection or connection.getState() ~= connection.STATE_CONNECTED then return end
  local requestId = M._nextSpawnRequestId
  M._nextSpawnRequestId = M._nextSpawnRequestId + 1
  M._pendingSpawns[requestId] = gameVehicleId
  connection._sendPacket({
    type = "vehicle_spawn",
    vehicle_id = 0,  -- Server will assign
    data = configData,
    spawn_request_id = requestId,
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

-- Send damage state for a local vehicle (called on collision events)
M.sendDamage = function(gameVehicleId, damageData)
  if not connection or connection.getState() ~= connection.STATE_CONNECTED then return end
  local serverVid = M.localVehicles[gameVehicleId]
  if not serverVid then return end

  -- Throttle damage sends: at most once per 200ms per vehicle
  local now = os.clock()
  if _damageTimers[gameVehicleId] and (now - _damageTimers[gameVehicleId]) < 0.2 then return end
  _damageTimers[gameVehicleId] = now

  connection._sendPacket({
    type = "vehicle_damage",
    vehicle_id = serverVid,
    data = damageData,
  })
end

M.onDisconnect = function()
  log('I', logTag, 'Clearing local vehicle state on disconnect')
  M.localVehicles = {}
  M._pendingSpawns = {}
  M._nextSpawnRequestId = 1
  M.playerId = nil
  M.sessionToken = nil
  sendTimer = 0
  _damageTimers = {}
end

return M
