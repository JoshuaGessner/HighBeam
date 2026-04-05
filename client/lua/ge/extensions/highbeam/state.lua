local M = {}
local logTag = "HighBeam.State"

M.localVehicles = {}  -- [gameVehicleId] = serverVehicleId
M.playerId = nil
M.sessionToken = nil
M._pendingSpawns = {}  -- [requestId] = { gameVid = number, sentAt = number }
M._nextSpawnRequestId = 1

local sendTimer = 0
local connection = nil
local config = nil
local _damageTimers = {}  -- [gameVehicleId] = cooldown timer
local _damageTimer = 0  -- global polling timer for damage
local _lastDamageHashes = {}  -- [gameVehicleId] = hash string of last sent damage
local _configPollTimer = 0  -- timer for mid-session config change detection
local _lastConfigs = {}  -- [gameVehicleId] = last known partConfig string
local _electricsTimer = 0  -- timer for electrics polling
local _inputsTimer = 0     -- timer for input polling (decoupled from electrics)
local _lastElectrics = {}  -- [gameVehicleId] = last sent electrics state string
M._cachedInputs = {}  -- [gameVehicleId] = {steer, throttle, brake} from vlua callback
M._cachedVluaRot = {} -- [gameVehicleId] = {x, y, z, w} rotation from vlua physics
M._damageDirty = {}   -- P3.2: [gameVehicleId] = true when damage event fires
local _lastUdpErrorLogAt = -math.huge
local _udpErrorLogCooldown = 2.0
local _pendingSpawnTimeoutSec = 8.0
local _diagLogIntervalSec = 5.0
local _diagLogTimer = 0
local _udpSentCount = 0
local _udpEncodeErrorCount = 0
local _udpSendErrorCount = 0

local function _countPendingSpawns()
  local count = 0
  for _, _ in pairs(M._pendingSpawns) do
    count = count + 1
  end
  return count
end

local function _countLocalVehicles()
  local count = 0
  for _, _ in pairs(M.localVehicles) do
    count = count + 1
  end
  return count
end

local function _logUdpErrorRateLimited(message)
  local now = os.clock()
  if (now - _lastUdpErrorLogAt) >= _udpErrorLogCooldown then
    _lastUdpErrorLogAt = now
    log('E', logTag, message)
  end
end

M.setSubsystems = function(conn, cfg)
  connection = conn
  config = cfg
  local marker = (rawget(_G, "HIGHBEAM_CLIENT_MARKER") or "unknown")
  log('I', logTag, 'State subsystem active marker=' .. tostring(marker))
end

-- Capture the vehicle config JSON from a BeamNG vehicle object
M.captureVehicleConfig = function(veh)
  local model = veh:getField('JBeam', '0') or 'pickup'
  local partConfig = ''
  local ok, pc = pcall(function() return veh:getField('partConfig', '0') end)
  if ok and pc and pc ~= '' then partConfig = pc end

  local pos = veh:getPosition()
  local rot = veh:getRotation()

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

  local now = os.clock()

  -- Clean up stale spawn requests so mapping cannot drift forever after dropped/rejected responses.
  for requestId, pending in pairs(M._pendingSpawns) do
    local sentAt = (type(pending) == "table" and pending.sentAt) or 0
    if (now - sentAt) >= _pendingSpawnTimeoutSec then
      local gameVid = (type(pending) == "table" and pending.gameVid) or pending
      log('W', logTag, 'Spawn request timed out reqId=' .. tostring(requestId)
        .. ' gameVid=' .. tostring(gameVid))
      M._pendingSpawns[requestId] = nil
      -- Tell the server to clean up the vehicle it may have spawned for us.
      -- Without this, a late server confirmation creates a phantom vehicle
      -- that receives no position updates from us.
      if connection and connection.getState() == connection.STATE_CONNECTED then
        -- We don't know the server-assigned vehicle_id, but request id 0
        -- signals a cleanup-by-game-vid which the server won't process.
        -- Instead, just log prominently so operators can investigate.
        log('E', logTag, 'PHANTOM RISK: spawn timeout for gameVid=' .. tostring(gameVid)
          .. ' — server may hold an orphaned vehicle')
      end
    end
  end

  local updateRate = (config and config.get("updateRate")) or 20

  -- P3.1: Adaptive send rate — increase update rate when vehicle is moving fast.
  -- At rest or slow speeds: use configured updateRate.
  -- At high speed (>20 m/s ≈ 72 km/h): double the rate.
  local adaptiveSendRate = config and config.get("adaptiveSendRate")
  if adaptiveSendRate ~= false then
    local maxSpeedSq = 0
    for gameVid, _ in pairs(M.localVehicles) do
      local veh = scenetree.findObjectById(gameVid)
      if veh then
        local vel = veh:getVelocity()
        if vel then
          local speedSq = vel.x*vel.x + vel.y*vel.y + vel.z*vel.z
          if speedSq > maxSpeedSq then maxSpeedSq = speedSq end
        end
      end
    end
    -- 20 m/s = 400 speedSq
    if maxSpeedSq > 400 then
      updateRate = math.min(60, updateRate * 2)
    elseif maxSpeedSq > 100 then  -- 10 m/s
      updateRate = math.min(60, math.floor(updateRate * 1.5))
    end
  end

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
      local vel = veh:getVelocity()

      -- Use vlua-sourced rotation (physics-accurate) with GE fallback.
      -- veh:getRotation() returns the SceneObject transform rotation which is
      -- stale for soft-body vehicles.  The vlua cache is populated each frame
      -- via _pollVluaRotation → queueGameEngineLua callback.
      local cachedRot = M._cachedVluaRot[gameVid]
      local rot
      if cachedRot then
        rot = cachedRot
      else
        local geRot = veh:getRotation()
        rot = { x = geRot.x, y = geRot.y, z = geRot.z, w = geRot.w }
      end

      -- Capture input state for input-augmented extrapolation
      -- NOTE: electrics are in vlua context, so we read from cached data
      -- populated by _pollInputs via queueLuaCommand callback
      local inputs = M._cachedInputs and M._cachedInputs[gameVid] or nil

      local okEncode, dataOrErr = pcall(
        protocol.encodePositionUpdate,
        sessionHash,
        serverVid,
        { pos.x, pos.y, pos.z },
        { rot.x, rot.y, rot.z, rot.w },
        { vel.x, vel.y, vel.z },
        now,
        inputs
      )

      if not okEncode then
        _udpEncodeErrorCount = _udpEncodeErrorCount + 1
        _logUdpErrorRateLimited('UDP encode threw for vehicle ' .. tostring(serverVid) .. ': ' .. tostring(dataOrErr))
      elseif not dataOrErr or dataOrErr == '' then
        _udpEncodeErrorCount = _udpEncodeErrorCount + 1
        _logUdpErrorRateLimited('UDP encode returned empty packet for vehicle ' .. tostring(serverVid))
      else
        local okSend, sendErr = pcall(connection.sendUdp, dataOrErr)
        if not okSend then
          _udpSendErrorCount = _udpSendErrorCount + 1
          _logUdpErrorRateLimited('UDP send threw for vehicle ' .. tostring(serverVid) .. ': ' .. tostring(sendErr))
        else
          _udpSentCount = _udpSentCount + 1
        end
      end
    end
  end

  _diagLogTimer = _diagLogTimer + dt
  if _diagLogTimer >= _diagLogIntervalSec then
    _diagLogTimer = 0
    log('I', logTag,
      'Sync stats locals=' .. tostring(_countLocalVehicles())
      .. ' pendingSpawns=' .. tostring(_countPendingSpawns())
      .. ' udpSent=' .. tostring(_udpSentCount)
      .. ' udpEncodeErr=' .. tostring(_udpEncodeErrorCount)
      .. ' udpSendErr=' .. tostring(_udpSendErrorCount)
    )
    _udpSentCount = 0
    _udpEncodeErrorCount = 0
    _udpSendErrorCount = 0
  end

  -- ── Damage polling (every 1000ms) ─────────────────────────────────
  -- P3.2: Only poll damage for vehicles that have recently had a collision.
  -- We track a per-vehicle "dirty" flag that is set by onBeamBroke / manual triggers.
  -- Fallback: poll at a reduced rate (every 3s) to catch missed events.
  _damageTimer = _damageTimer + dt
  if _damageTimer >= 1.0 then
    _damageTimer = 0
    for gameVid, serverVid in pairs(M.localVehicles) do
      local dirty = M._damageDirty and M._damageDirty[gameVid]
      if dirty then
        M._pollDamage(gameVid)
        if M._damageDirty then M._damageDirty[gameVid] = nil end
      end
    end
  end

  -- P3.2: Fallback full damage poll every 3s for vehicles with no dirty flag
  if not M._damageFullTimer then M._damageFullTimer = 0 end
  M._damageFullTimer = M._damageFullTimer + dt
  if M._damageFullTimer >= 3.0 then
    M._damageFullTimer = 0
    for gameVid, serverVid in pairs(M.localVehicles) do
      M._pollDamage(gameVid)
    end
  end

  -- ── Config change detection (every 2s) ────────────────────────────
  _configPollTimer = _configPollTimer + dt
  if _configPollTimer >= 2.0 then
    _configPollTimer = 0
    for gameVid, serverVid in pairs(M.localVehicles) do
      M._pollConfigChange(gameVid, serverVid)
    end
  end

  -- ── Electrics polling (every 500ms) ───────────────────────────────
  _electricsTimer = _electricsTimer + dt
  if _electricsTimer >= 0.5 then
    _electricsTimer = 0
    for gameVid, serverVid in pairs(M.localVehicles) do
      M._pollElectrics(gameVid, serverVid)
    end
  end

  -- ── Input polling (every 100ms) ───────────────────────────────────
  _inputsTimer = _inputsTimer + dt
  if _inputsTimer >= 0.1 then
    _inputsTimer = 0
    for gameVid, _ in pairs(M.localVehicles) do
      M._pollInputs(gameVid)
      M._pollVluaRotation(gameVid)
    end
  end
end

-- ── Damage polling ───────────────────────────────────────────────────
-- Queries the vehicle-side Lua for beam break/deform state and sends deltas.
-- BeamNG vehicles expose beam state via queueLuaCommand + obj callback pattern,
-- but for GE extension polling we use the object's getBeamCount / getDeformGroupDamage
-- approach and track a simple hash to detect changes.
M._pollDamage = function(gameVid)
  local veh = scenetree.findObjectById(gameVid)
  if not veh then return end

  -- Request the vehicle Lua to report damage state back to GE.
  -- The vehicle-side callback will fire our GE extension event.
  pcall(function()
    veh:queueLuaCommand(
      'local d = {} '
      .. 'd.broken = {} '
      .. 'for i = 0, obj:getBeamCount() - 1 do '
      .. '  if obj:beamIsBroken(i) then table.insert(d.broken, i) end '
      .. 'end '
      .. 'd.deform = {} '
      .. 'for i = 0, obj:getBeamCount() - 1 do '
      .. '  if not obj:beamIsBroken(i) then '
      .. '    local def = obj:getBeamDeformation(i) '
      .. '    if def > 0.001 then '
      .. '      local rl = obj:getBeamRestLength(i) '
      .. '      d.deform[tostring(i)] = {math.floor(def * 1000) / 1000, math.floor(rl * 1000) / 1000} '
      .. '    end '
      .. '  end '
      .. 'end '
      .. 'obj:queueGameEngineLua("extensions.highbeam.onVehicleDamageReport(' .. gameVid .. ', \'" .. (jsonEncode and jsonEncode(d) or "{}") .. "\')")'
    )
  end)
end

-- Called back from vehicle-side Lua with damage state JSON
M.onDamageReport = function(gameVid, damageJson)
  if not M.localVehicles[gameVid] then return end

  -- Simple change detection: compare JSON string hash
  local hash = damageJson  -- use the full string as a change key
  if _lastDamageHashes[gameVid] == hash then return end
  _lastDamageHashes[gameVid] = hash

  -- Only send if there's actual damage content
  if damageJson == '{}' or damageJson == '' or damageJson == '{"broken":[],"deform":{}}' then return end

  M.sendDamage(gameVid, damageJson)
end

-- ── Config change detection ─────────────────────────────────────────
M._pollConfigChange = function(gameVid, serverVid)
  local veh = scenetree.findObjectById(gameVid)
  if not veh then return end

  local currentConfig = ''
  pcall(function() currentConfig = veh:getField('partConfig', '0') or '' end)

  local currentColor = ''
  pcall(function() currentColor = veh:getField('color', '0') or '' end)

  local combined = currentConfig .. '|' .. currentColor

  if _lastConfigs[gameVid] == nil then
    -- First poll: store baseline, don't send
    _lastConfigs[gameVid] = { combined = combined, partConfig = currentConfig, color = currentColor }
    return
  end

  if _lastConfigs[gameVid].combined ~= combined then
    -- Build delta: only include fields that actually changed
    local editParts = {}
    if _lastConfigs[gameVid].partConfig ~= currentConfig then
      table.insert(editParts, '"partConfig":' .. M._jsonStr(currentConfig))
    end
    if _lastConfigs[gameVid].color ~= currentColor then
      table.insert(editParts, '"color":' .. M._jsonStr(currentColor))
    end

    _lastConfigs[gameVid] = { combined = combined, partConfig = currentConfig, color = currentColor }

    if #editParts > 0 then
      local editData = '{' .. table.concat(editParts, ',') .. '}'
      connection._sendPacket({
        type = "vehicle_edit",
        vehicle_id = serverVid,
        data = editData,
      })
      log('I', logTag, 'Config change detected, sent VehicleEdit delta for gameVid=' .. tostring(gameVid))
    end
  end
end

-- ── Electrics polling ───────────────────────────────────────────────
-- Polls key electrics values and sends state changes via TCP.
M._pollElectrics = function(gameVid, serverVid)
  local veh = scenetree.findObjectById(gameVid)
  if not veh then return end

  -- Query electrics via vehicle-side Lua and report back to GE
  -- P4.3: Added gear and parking brake for full drivetrain sync
  pcall(function()
    veh:queueLuaCommand(
      'local e = electrics.values '
      .. 'local s = {} '
      .. 's.lights = e.lights_state or 0 '
      .. 's.signal_L = (e.signal_L and e.signal_L > 0.5) and 1 or 0 '
      .. 's.signal_R = (e.signal_R and e.signal_R > 0.5) and 1 or 0 '
      .. 's.hazard = (e.hazard_enabled and e.hazard_enabled > 0.5) and 1 or 0 '
      .. 's.horn = (e.horn and e.horn > 0.5) and 1 or 0 '
      .. 's.headlights = e.lowbeam or 0 '
      .. 's.highbeams = e.highbeam or 0 '
      .. 's.gear = e.gear_A or 0 '
      .. 's.parkingbrake = (e.parkingbrake and e.parkingbrake > 0.5) and 1 or 0 '
      .. 'obj:queueGameEngineLua("extensions.highbeam.onElectricsReport(' .. gameVid .. ', \'" .. (jsonEncode and jsonEncode(s) or "{}") .. "\')")'
    )
  end)
end

-- Called back from vehicle-side Lua with electrics state
M.onElectricsReport = function(gameVid, electricsJson)
  local serverVid = M.localVehicles[gameVid]
  if not serverVid then return end

  -- Delta detection: only send if state changed
  if _lastElectrics[gameVid] == electricsJson then return end
  _lastElectrics[gameVid] = electricsJson

  connection._sendPacket({
    type = "vehicle_electrics",
    vehicle_id = serverVid,
    data = electricsJson,
  })
end

-- ── Input polling (for input-augmented extrapolation) ───────────────
-- Fetches steering/throttle/brake from vlua electrics and caches in GE.
M._pollInputs = function(gameVid)
  local veh = scenetree.findObjectById(gameVid)
  if not veh then return end

  pcall(function()
    veh:queueLuaCommand(
      'local e = electrics.values '
      .. 'local st = e.steering_input or e.steering or 0 '
      .. 'local th = e.throttle_input or e.throttle or 0 '
      .. 'local br = e.brake_input or e.brake or 0 '
      .. 'obj:queueGameEngineLua("extensions.highbeam.onInputsReport(' .. gameVid .. '," .. st .. "," .. th .. "," .. br .. ")")'
    )
  end)
end

-- Called back from vehicle-side Lua with input values
M.onInputsReport = function(gameVid, steer, throttle, brake)
  M._cachedInputs[gameVid] = {
    steer = steer or 0,
    throttle = throttle or 0,
    brake = brake or 0,
  }
end

-- ── Vlua rotation polling ───────────────────────────────────────────
-- veh:getRotation() returns the SceneObject transform rotation which does NOT
-- track physics orientation on soft-body vehicles.  This polls the actual
-- physics rotation from vlua using direction vectors (same as BeamMP).
M._pollVluaRotation = function(gameVid)
  local veh = scenetree.findObjectById(gameVid)
  if not veh then return end

  pcall(function()
    veh:queueLuaCommand(
      'local r = quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp())) '
      .. 'obj:queueGameEngineLua("extensions.highbeam.onVluaRotationReport(' .. gameVid .. '," .. r.x .. "," .. r.y .. "," .. r.z .. "," .. r.w .. ")")'
    )
  end)
end

-- Called back from vehicle-side Lua with physics rotation quaternion
M.onVluaRotationReport = function(gameVid, rx, ry, rz, rw)
  M._cachedVluaRot[gameVid] = { x = rx or 0, y = ry or 0, z = rz or 0, w = rw or 1 }
end

-- P3.2: Mark a vehicle as needing a damage poll on the next cycle.
-- Called from the main extension's onBeamBroke / collision hooks.
M.markDamageDirty = function(gameVid)
  if M.localVehicles[gameVid] then
    M._damageDirty[gameVid] = true
  end
end

M.onWorldState = function(players)
  log('I', logTag, 'Received world state with ' .. tostring(#players) .. ' players')
end

M.onLocalVehicleSpawned = function(serverVehicleId, configData, spawnRequestId)
  local gameVid = nil
  if spawnRequestId and M._pendingSpawns[spawnRequestId] then
    local pending = M._pendingSpawns[spawnRequestId]
    gameVid = type(pending) == "table" and pending.gameVid or pending
    M._pendingSpawns[spawnRequestId] = nil
  end

  if gameVid then
    M.localVehicles[gameVid] = serverVehicleId
    log('I', logTag, 'Local vehicle mapped: game=' .. tostring(gameVid) .. ' server=' .. tostring(serverVehicleId) .. ' reqId=' .. tostring(spawnRequestId))
  else
    -- Confirmation arrived after our pending request timed out (phantom).
    -- Tell the server to delete this orphaned vehicle immediately.
    log('W', logTag, 'Spawn confirmation without matching pending request reqId=' .. tostring(spawnRequestId)
      .. ' serverVid=' .. tostring(serverVehicleId) .. ' — sending VehicleDelete to clean up phantom')
    if connection and connection.getState() == connection.STATE_CONNECTED then
      connection._sendPacket({
        type = "vehicle_delete",
        vehicle_id = serverVehicleId,
      })
    end
  end
end

M.onLocalVehicleSpawnRejected = function(spawnRequestId, reason)
  if not spawnRequestId then
    log('W', logTag, 'Spawn rejected without request id reason=' .. tostring(reason))
    return
  end

  local pending = M._pendingSpawns[spawnRequestId]
  if pending then
    local gameVid = type(pending) == "table" and pending.gameVid or pending
    M._pendingSpawns[spawnRequestId] = nil
    log('W', logTag, 'Spawn rejected reqId=' .. tostring(spawnRequestId)
      .. ' gameVid=' .. tostring(gameVid) .. ' reason=' .. tostring(reason))
  else
    log('W', logTag, 'Spawn rejected for unknown reqId=' .. tostring(spawnRequestId)
      .. ' reason=' .. tostring(reason))
  end
end

M.requestSpawn = function(gameVehicleId, configData)
  if not connection or connection.getState() ~= connection.STATE_CONNECTED then return end
  local requestId = M._nextSpawnRequestId
  M._nextSpawnRequestId = M._nextSpawnRequestId + 1
  M._pendingSpawns[requestId] = {
    gameVid = gameVehicleId,
    sentAt = os.clock(),
  }
  local sent = connection._sendPacket({
    type = "vehicle_spawn",
    vehicle_id = 0,  -- Server will assign
    data = configData,
    spawn_request_id = requestId,
  })
  if not sent then
    M._pendingSpawns[requestId] = nil
    log('W', logTag, 'Failed to send spawn request reqId=' .. tostring(requestId)
      .. ' gameVid=' .. tostring(gameVehicleId))
  end
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
  _damageTimer = 0
  _lastDamageHashes = {}
  _configPollTimer = 0
  _lastConfigs = {}
  _electricsTimer = 0
  _lastElectrics = {}
  M._cachedInputs = {}
  M._damageDirty = {}
  M._damageFullTimer = 0
  _lastUdpErrorLogAt = -math.huge
  _diagLogTimer = 0
  _udpSentCount = 0
  _udpEncodeErrorCount = 0
  _udpSendErrorCount = 0
end

return M
