local M = {}
local logTag = "HighBeam.State"
local syncMath = require("highbeam/math")

M.localVehicles = {}  -- [gameVehicleId] = serverVehicleId
M.playerId = nil
M.sessionToken = nil
M._pendingSpawns = {}  -- [requestId] = { gameVid = number, sentAt = number }
M._inflightByGameVid = {} -- [gameVehicleId] = requestId
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
local _vePos = {}          -- [gameVehicleId] = {x,y,z}
local _veRot = {}          -- [gameVehicleId] = {x,y,z,w}
local _veVel = {}          -- [gameVehicleId] = {x,y,z}
local _veDataReady = {}    -- [gameVehicleId] = true if VE callback is active
local _veLastDataAt = {}   -- [gameVehicleId] = os.clock timestamp
M._cachedInputs = {}  -- [gameVehicleId] = {steer, throttle, brake} from vlua callback
M._cachedVluaRot = {} -- [gameVehicleId] = {x, y, z, w} rotation from vlua physics
M._cachedVluaRotTime = {} -- [gameVehicleId] = os.clock timestamp for cached rotation
M._cachedAngVel = {}  -- [gameVehicleId] = {x, y, z} angular velocity (rad/s) from quat delta
M._damageDirty = {}   -- P3.2: [gameVehicleId] = true when damage event fires
M._lastSentState = {} -- [gameVehicleId] = {pos={x,y,z}, rot={x,y,z,w}, vel={x,y,z}, inputs={...}, sentAt=time}
M._debugStats = {
  sendRateHz = 20,
  skippedUnchanged = 0,
  sentPackets = 0,
  avgSendSpeed = 0,
}
local _lastUdpErrorLogAt = -math.huge
local _udpErrorLogCooldown = 2.0
local _pendingSpawnTimeoutSec = 8.0
local _diagLogIntervalSec = 5.0
local _diagLogTimer = 0
local _udpSentCount = 0
local _udpEncodeErrorCount = 0
local _udpSendErrorCount = 0
local _udpSkippedUnchangedCount = 0
local _sendSpeedAccum = 0
local _sendSpeedSamples = 0
local _componentTxStats = {
  damage_sent = 0,
  damage_throttled = 0,
  damage_no_server_vid = 0,
  damage_send_failed = 0,
  electrics_sent = 0,
  electrics_unchanged = 0,
  electrics_no_server_vid = 0,
  electrics_send_failed = 0,
  inputs_sent = 0,
  inputs_send_failed = 0,
  powertrain_sent = 0,
  powertrain_send_failed = 0,
}
local _pollLuaCommandCount = 0
local _pollLuaCommandErrorCount = 0
local _damageFallbackTimer = 0
local _damageFallbackCursor = 0
local _tcpPoseSentCount = 0
local _tcpPoseSendErrorCount = 0
local _lastTcpPoseSentAt = {}
local _forcedKeyframeCount = 0
local _forcedWatchdogCount = 0
local _skipStreakByVehicle = {}
local _playerVehicleReconcileTimer = 0
local _playerVehicleReconcileCount = 0
local _playerVehicleReconcileDeleteCount = 0

local POS_SEND_DELTA_SQ = 0.01 * 0.01
local ROT_SEND_DELTA_RAD = math.rad(0.5)
local VEL_SEND_DELTA_SQ = 0.05 * 0.05
local INPUT_SEND_DELTA = 0.005
local ABSOLUTE_SEND_RATE_CAP = 45
local DEFAULT_TCP_POSE_FALLBACK_INTERVAL_SEC = 0.2
local DEFAULT_FORCE_KEYFRAME_INTERVAL_SEC = 0.45
local DEFAULT_MOTION_WATCHDOG_SEC = 0.7
local DEFAULT_MOTION_WATCHDOG_MIN_SPEED = 0.5
local DEFAULT_LOCAL_VEHICLE_RECONCILE_SEC = 1.0

local function _rotErrorRad(a, b)
  if not a or not b then return math.huge end
  local dot = a[1]*b[1] + a[2]*b[2] + a[3]*b[3] + a[4]*b[4]
  dot = math.abs(dot)
  if dot > 1 then dot = 1 end
  return 2 * math.acos(dot)
end

local function _inputsChanged(lastInputs, inputs)
  if (not lastInputs) and inputs then return true end
  if lastInputs and (not inputs) then return true end
  if not lastInputs and not inputs then return false end

  local function changed(k)
    local a = tonumber(lastInputs[k] or 0) or 0
    local b = tonumber(inputs[k] or 0) or 0
    return math.abs(a - b) > INPUT_SEND_DELTA
  end

  return changed("steer")
    or changed("throttle")
    or changed("brake")
    or changed("gear")
    or changed("handbrake")
end

local function _shouldSendDelta(gameVid, posArr, rotArr, velArr, inputs)
  local last = M._lastSentState[gameVid]
  if not last then return true end

  local dx = posArr[1] - last.pos[1]
  local dy = posArr[2] - last.pos[2]
  local dz = posArr[3] - last.pos[3]
  local posDeltaSq = dx*dx + dy*dy + dz*dz
  if posDeltaSq > POS_SEND_DELTA_SQ then return true end

  local dvx = velArr[1] - last.vel[1]
  local dvy = velArr[2] - last.vel[2]
  local dvz = velArr[3] - last.vel[3]
  local velDeltaSq = dvx*dvx + dvy*dvy + dvz*dvz
  if velDeltaSq > VEL_SEND_DELTA_SQ then return true end

  local rotDelta = _rotErrorRad(rotArr, last.rot)
  if rotDelta > ROT_SEND_DELTA_RAD then return true end

  if _inputsChanged(last.inputs, inputs) then return true end

  return false
end

local function _cacheSentState(gameVid, posArr, rotArr, velArr, inputs, now)
  M._lastSentState[gameVid] = {
    pos = { posArr[1], posArr[2], posArr[3] },
    rot = { rotArr[1], rotArr[2], rotArr[3], rotArr[4] },
    vel = { velArr[1], velArr[2], velArr[3] },
    inputs = inputs and {
      steer = inputs.steer or 0,
      throttle = inputs.throttle or 0,
      brake = inputs.brake or 0,
      gear = inputs.gear or 0,
      handbrake = inputs.handbrake or 0,
    } or nil,
    sentAt = now,
  }
end

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

local function _verboseSyncLoggingEnabled()
  return config and config.get and config.get("verboseSyncLogging") == true
end

local function _getConfigNumber(key, fallback)
  local value = config and config.get and config.get(key)
  if type(value) == "number" then
    return value
  end
  return fallback
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

local function _getPlayerVehicleId()
  if not be or not be.getPlayerVehicle then return nil end
  local veh = be:getPlayerVehicle(0)
  if not veh or not veh.getID then return nil end
  local ok, vid = pcall(veh.getID, veh)
  if not ok then return nil end
  return vid
end

local function _reconcileLocalPlayerVehicle()
  if not connection or connection.getState() ~= connection.STATE_CONNECTED then return end

  local gameVid = _getPlayerVehicleId()
  if not gameVid then return end
  if M.localVehicles[gameVid] or M._inflightByGameVid[gameVid] then return end

  local allowed, reason = M.canRequestSpawn(gameVid)
  if not allowed and reason == "max_cars_reached" then
    for mappedGameVid, _ in pairs(M.localVehicles) do
      if mappedGameVid ~= gameVid then
        M.requestDelete(mappedGameVid)
        _playerVehicleReconcileDeleteCount = _playerVehicleReconcileDeleteCount + 1
        log('W', logTag, 'Reconcile deleted stale local map gameVid=' .. tostring(mappedGameVid)
          .. ' currentPlayerVid=' .. tostring(gameVid))
        break
      end
    end
    allowed, reason = M.canRequestSpawn(gameVid)
  end

  if not allowed then return end

  local veh = be:getObjectByID(gameVid)
  if not veh then return end

  local configData = M.captureVehicleConfig(veh)
  M.requestSpawn(gameVid, configData)
  _playerVehicleReconcileCount = _playerVehicleReconcileCount + 1
  log('I', logTag, 'Reconcile requested spawn for active player vehicle gameVid=' .. tostring(gameVid))
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
      M._inflightByGameVid[gameVid] = nil
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

  _playerVehicleReconcileTimer = _playerVehicleReconcileTimer + dt
  local reconcileInterval = math.max(0.25, math.min(5.0, _getConfigNumber("localVehicleReconcileSec", DEFAULT_LOCAL_VEHICLE_RECONCILE_SEC)))
  if _playerVehicleReconcileTimer >= reconcileInterval then
    _playerVehicleReconcileTimer = 0
    _reconcileLocalPlayerVehicle()
  end

  -- Adaptive send rate with conservative caps to reduce script + network load.
  -- <1 m/s = 12Hz, 1-20 m/s = 24Hz, >=20 m/s = maxAdaptiveSendRate (default 45Hz).
  local adaptiveSendRate = config and config.get("adaptiveSendRate")
  local maxAdaptiveSendRate = math.max(20, math.min(60, math.floor(_getConfigNumber("maxAdaptiveSendRate", 45))))
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
    local maxSpeed = math.sqrt(maxSpeedSq)
    if maxSpeed < 1.0 then
      updateRate = 12
    elseif maxSpeed < 20.0 then
      updateRate = 24
    else
      updateRate = maxAdaptiveSendRate
    end
  end

  -- Hard cap protects runtime from malformed/legacy saved config values.
  updateRate = math.max(5, math.min(ABSOLUTE_SEND_RATE_CAP, math.floor(updateRate + 0.5)))

  -- If TCP is connected but inbound UDP isn't confirmed yet, run in a
  -- conservative mode to reduce encode/send overhead while bind settles.
  if connection and connection._udpBindConfirmed == false then
    updateRate = math.min(updateRate, 10)
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
      local posArr = nil
      local rotArr = nil
      local velArr = nil
      local speed = 0

      local veFresh = _veDataReady[gameVid] and _veLastDataAt[gameVid] and ((now - _veLastDataAt[gameVid]) <= 0.5)
      if veFresh and _vePos[gameVid] and _veRot[gameVid] and _veVel[gameVid] then
        posArr = { _vePos[gameVid][1], _vePos[gameVid][2], _vePos[gameVid][3] }
        rotArr = { _veRot[gameVid][1], _veRot[gameVid][2], _veRot[gameVid][3], _veRot[gameVid][4] }
        velArr = { _veVel[gameVid][1], _veVel[gameVid][2], _veVel[gameVid][3] }
        speed = math.sqrt((velArr[1] or 0)*(velArr[1] or 0) + (velArr[2] or 0)*(velArr[2] or 0) + (velArr[3] or 0)*(velArr[3] or 0))
      else
        local pos = veh:getPosition()
        local vel = veh:getVelocity()

        local cachedRot = M._cachedVluaRot[gameVid]
        local rot
        if cachedRot then
          rot = cachedRot
        else
          local geRot = veh:getRotation()
          rot = { x = geRot.x, y = geRot.y, z = geRot.z, w = geRot.w }
        end

        posArr = { pos.x, pos.y, pos.z }
        rotArr = { rot.x, rot.y, rot.z, rot.w }
        velArr = { vel.x, vel.y, vel.z }
        speed = math.sqrt((velArr[1] or 0)*(velArr[1] or 0) + (velArr[2] or 0)*(velArr[2] or 0) + (velArr[3] or 0)*(velArr[3] or 0))
      end

      -- Capture input state for input-augmented extrapolation
      -- NOTE: electrics are in vlua context, so we read from cached data
      -- populated by _pollInputs via queueLuaCommand callback
      local inputs = M._cachedInputs and M._cachedInputs[gameVid] or nil
      local angVel = M._cachedAngVel and M._cachedAngVel[gameVid] or nil

      local forceReason = nil
      local lastSent = M._lastSentState[gameVid]
      if lastSent then
        local forceKeyframeInterval = math.max(0.2, math.min(2.0, _getConfigNumber("forceKeyframeIntervalSec", DEFAULT_FORCE_KEYFRAME_INTERVAL_SEC)))
        local motionWatchdogSec = math.max(0.2, math.min(3.0, _getConfigNumber("motionWatchdogSec", DEFAULT_MOTION_WATCHDOG_SEC)))
        local motionWatchdogMinSpeed = math.max(0.0, math.min(20.0, _getConfigNumber("motionWatchdogMinSpeed", DEFAULT_MOTION_WATCHDOG_MIN_SPEED)))

        local sinceLastSent = now - (lastSent.sentAt or 0)
        if sinceLastSent >= forceKeyframeInterval then
          forceReason = "keyframe"
        elseif speed >= motionWatchdogMinSpeed and sinceLastSent >= motionWatchdogSec then
          forceReason = "watchdog"
        end
      end

      if not forceReason and not _shouldSendDelta(gameVid, posArr, rotArr, velArr, inputs) then
        _udpSkippedUnchangedCount = _udpSkippedUnchangedCount + 1
        _skipStreakByVehicle[gameVid] = (_skipStreakByVehicle[gameVid] or 0) + 1
        goto continue_local_vehicle
      end

      _skipStreakByVehicle[gameVid] = 0
      if forceReason == "keyframe" then
        _forcedKeyframeCount = _forcedKeyframeCount + 1
      elseif forceReason == "watchdog" then
        _forcedWatchdogCount = _forcedWatchdogCount + 1
      end

      local okEncode, dataOrErr = pcall(
        protocol.encodePositionUpdate,
        sessionHash,
        serverVid,
        posArr,
        rotArr,
        velArr,
        now,
        inputs,
        angVel
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
          _sendSpeedAccum = _sendSpeedAccum + speed
          _sendSpeedSamples = _sendSpeedSamples + 1
          _cacheSentState(gameVid, posArr, rotArr, velArr, inputs, now)
        end
      end

      if connection and connection._udpBindConfirmed == false then
        local fallbackInterval = math.max(0.1, math.min(0.5, _getConfigNumber("tcpPoseFallbackIntervalSec", DEFAULT_TCP_POSE_FALLBACK_INTERVAL_SEC)))
        local lastPoseAt = _lastTcpPoseSentAt[gameVid] or 0
        if (now - lastPoseAt) >= fallbackInterval then
          _lastTcpPoseSentAt[gameVid] = now

          local poseData = '{"pos":['
            .. tostring(posArr[1]) .. ',' .. tostring(posArr[2]) .. ',' .. tostring(posArr[3])
            .. '],"rot":['
            .. tostring(rotArr[1]) .. ',' .. tostring(rotArr[2]) .. ',' .. tostring(rotArr[3]) .. ',' .. tostring(rotArr[4])
            .. '],"vel":['
            .. tostring(velArr[1]) .. ',' .. tostring(velArr[2]) .. ',' .. tostring(velArr[3])
            .. '],"time":' .. tostring(now)
          if inputs then
            poseData = poseData
              .. ',"inputs":{"steer":' .. tostring(inputs.steer or 0)
              .. ',"throttle":' .. tostring(inputs.throttle or 0)
              .. ',"brake":' .. tostring(inputs.brake or 0)
              .. ',"gear":' .. tostring(inputs.gear or 0)
              .. ',"handbrake":' .. tostring(inputs.handbrake or 0)
              .. '}'
          end
          if angVel then
            poseData = poseData
              .. ',"angVel":['
              .. tostring(angVel[1] or 0) .. ',' .. tostring(angVel[2] or 0) .. ',' .. tostring(angVel[3] or 0)
              .. ']'
          end
          poseData = poseData .. '}'

          local sent = connection._sendPacket({
            type = "vehicle_pose",
            vehicle_id = serverVid,
            data = poseData,
          })
          if sent then
            _tcpPoseSentCount = _tcpPoseSentCount + 1
          else
            _tcpPoseSendErrorCount = _tcpPoseSendErrorCount + 1
          end
        end
      end
    end
    ::continue_local_vehicle::
  end

  _diagLogTimer = _diagLogTimer + dt
  if _diagLogTimer >= _diagLogIntervalSec then
    _diagLogTimer = 0
    log('I', logTag,
      'Sync stats locals=' .. tostring(_countLocalVehicles())
      .. ' pendingSpawns=' .. tostring(_countPendingSpawns())
      .. ' udpSent=' .. tostring(_udpSentCount)
      .. ' udpSkippedUnchanged=' .. tostring(_udpSkippedUnchangedCount)
      .. ' udpEncodeErr=' .. tostring(_udpEncodeErrorCount)
      .. ' udpSendErr=' .. tostring(_udpSendErrorCount)
      .. ' udpForcedKeyframe=' .. tostring(_forcedKeyframeCount)
      .. ' udpForcedWatchdog=' .. tostring(_forcedWatchdogCount)
      .. ' tcpPoseSent=' .. tostring(_tcpPoseSentCount)
      .. ' tcpPoseErr=' .. tostring(_tcpPoseSendErrorCount)
      .. ' reconcileSpawn=' .. tostring(_playerVehicleReconcileCount)
      .. ' reconcileDelete=' .. tostring(_playerVehicleReconcileDeleteCount)
      .. ' pollLuaCmd=' .. tostring(_pollLuaCommandCount)
      .. ' pollLuaErr=' .. tostring(_pollLuaCommandErrorCount)
      .. ' dmgSent=' .. tostring(_componentTxStats.damage_sent)
      .. ' dmgThr=' .. tostring(_componentTxStats.damage_throttled)
      .. ' dmgNoMap=' .. tostring(_componentTxStats.damage_no_server_vid)
      .. ' elecSent=' .. tostring(_componentTxStats.electrics_sent)
      .. ' elecUnchanged=' .. tostring(_componentTxStats.electrics_unchanged)
      .. ' elecNoMap=' .. tostring(_componentTxStats.electrics_no_server_vid)
      .. ' inpSent=' .. tostring(_componentTxStats.inputs_sent)
      .. ' inpFail=' .. tostring(_componentTxStats.inputs_send_failed)
      .. ' pwrSent=' .. tostring(_componentTxStats.powertrain_sent)
      .. ' pwrFail=' .. tostring(_componentTxStats.powertrain_send_failed)
    )
    M._debugStats = {
      sendRateHz = updateRate,
      skippedUnchanged = _udpSkippedUnchangedCount,
      sentPackets = _udpSentCount,
      avgSendSpeed = _sendSpeedSamples > 0 and (_sendSpeedAccum / _sendSpeedSamples) or 0,
    }
    _udpSentCount = 0
    _udpSkippedUnchangedCount = 0
    _udpEncodeErrorCount = 0
    _udpSendErrorCount = 0
    _forcedKeyframeCount = 0
    _forcedWatchdogCount = 0
    _playerVehicleReconcileCount = 0
    _playerVehicleReconcileDeleteCount = 0
    _sendSpeedAccum = 0
    _sendSpeedSamples = 0
    _pollLuaCommandCount = 0
    _pollLuaCommandErrorCount = 0
    _componentTxStats = {
      damage_sent = 0,
      damage_throttled = 0,
      damage_no_server_vid = 0,
      damage_send_failed = 0,
      electrics_sent = 0,
      electrics_unchanged = 0,
      electrics_no_server_vid = 0,
      electrics_send_failed = 0,
      inputs_sent = 0,
      inputs_send_failed = 0,
      powertrain_sent = 0,
      powertrain_send_failed = 0,
    }
  end

  -- ── Damage polling (every 1000ms on dirty vehicles) ───────────────
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

  -- Fallback damage polling runs sparsely and round-robin to avoid frame spikes.
  local damageFallbackInterval = math.max(1.0, math.min(20.0, _getConfigNumber("damageFallbackPollSec", 2.0)))
  _damageFallbackTimer = _damageFallbackTimer + dt
  if _damageFallbackTimer >= damageFallbackInterval then
    _damageFallbackTimer = 0
    local localIds = {}
    for gameVid, _ in pairs(M.localVehicles) do
      table.insert(localIds, gameVid)
    end
    table.sort(localIds)
    if #localIds > 0 then
      _damageFallbackCursor = (_damageFallbackCursor % #localIds) + 1
      M._pollDamage(localIds[_damageFallbackCursor])
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

  -- ── Electrics polling (default every 750ms) ───────────────────────
  local electricsInterval = math.max(0.2, math.min(2.0, _getConfigNumber("electricsPollIntervalSec", 0.75)))
  _electricsTimer = _electricsTimer + dt
  if _electricsTimer >= electricsInterval then
    _electricsTimer = 0
    for gameVid, serverVid in pairs(M.localVehicles) do
      local veFresh = _veDataReady[gameVid] and _veLastDataAt[gameVid] and ((os.clock() - _veLastDataAt[gameVid]) <= 2.0)
      if not veFresh then
        M._pollElectrics(gameVid, serverVid)
      end
    end
  end

  -- ── Input + vlua rotation polling (single command, default 150ms) ─
  local inputPollInterval = math.max(0.05, math.min(0.5, _getConfigNumber("inputPollIntervalSec", 0.15)))
  _inputsTimer = _inputsTimer + dt
  if _inputsTimer >= inputPollInterval then
    _inputsTimer = 0
    for gameVid, _ in pairs(M.localVehicles) do
      local veFresh = _veDataReady[gameVid] and _veLastDataAt[gameVid] and ((os.clock() - _veLastDataAt[gameVid]) <= 0.5)
      if not veFresh then
        M._pollInputsAndRotation(gameVid)
      end
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
  -- Bug #3b: Also collect node positions for nodes connected to damaged beams.
  local ok = pcall(function()
    veh:queueLuaCommand(
      'local d = {} '
      .. 'd.broken = {} '
      .. 'local _damagedNodes = {} '
      .. 'for i = 0, obj:getBeamCount() - 1 do '
      .. '  if obj:beamIsBroken(i) then '
      .. '    table.insert(d.broken, i) '
      .. '    local n1,n2 = obj:getBeamNode1(i),obj:getBeamNode2(i) '
      .. '    if n1 then _damagedNodes[n1] = true end '
      .. '    if n2 then _damagedNodes[n2] = true end '
      .. '  end '
      .. 'end '
      .. 'd.deform = {} '
      .. 'for i = 0, obj:getBeamCount() - 1 do '
      .. '  if not obj:beamIsBroken(i) then '
      .. '    local def = obj:getBeamDeformation(i) '
      .. '    if def > 0.001 then '
      .. '      local rl = obj:getBeamRestLength(i) '
      .. '      d.deform[tostring(i)] = {math.floor(def * 1000) / 1000, math.floor(rl * 1000) / 1000} '
      .. '      local n1,n2 = obj:getBeamNode1(i),obj:getBeamNode2(i) '
      .. '      if n1 then _damagedNodes[n1] = true end '
      .. '      if n2 then _damagedNodes[n2] = true end '
      .. '    end '
      .. '  end '
      .. 'end '
      .. 'd.nodes = {} '
      .. 'for nid,_ in pairs(_damagedNodes) do '
      .. '  local np = obj:getNodePosition(nid) '
      .. '  if np then '
      .. '    local op = obj:getOriginalNodePosition(nid) '
      .. '    if op then '
      .. '      local dx2 = (np.x-op.x)*(np.x-op.x)+(np.y-op.y)*(np.y-op.y)+(np.z-op.z)*(np.z-op.z) '
      .. '      if dx2 > 0.0001 then '
      .. '        d.nodes[tostring(nid)] = {math.floor(np.x*1000)/1000,math.floor(np.y*1000)/1000,math.floor(np.z*1000)/1000} '
      .. '      end '
      .. '    end '
      .. '  end '
      .. 'end '
      .. 'obj:queueGameEngineLua("extensions.highbeam.onVehicleDamageReport(' .. gameVid .. ', \'" .. (jsonEncode and jsonEncode(d) or "{}") .. "\')")'
    )
  end)
  _pollLuaCommandCount = _pollLuaCommandCount + 1
  if not ok then
    _pollLuaCommandErrorCount = _pollLuaCommandErrorCount + 1
  end
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
  local ok = pcall(function()
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
      .. 's.steering = e.steering_input or e.steering or 0 '
      .. 's.rpm = e.rpm or 0 '
      .. 's.wheelspeed = e.wheelspeed or 0 '
      .. 's.clutch = e.clutch or 0 '
      .. 's.ignition = e.ignitionLevel or 0 '
      .. 'obj:queueGameEngineLua("extensions.highbeam.onElectricsReport(' .. gameVid .. ', \'" .. (jsonEncode and jsonEncode(s) or "{}") .. "\')")'
    )
  end)
  _pollLuaCommandCount = _pollLuaCommandCount + 1
  if not ok then
    _pollLuaCommandErrorCount = _pollLuaCommandErrorCount + 1
  end
end

-- Called back from vehicle-side Lua with electrics state
M.onElectricsReport = function(gameVid, electricsJson)
  local serverVid = M.localVehicles[gameVid]
  if not serverVid then
    _componentTxStats.electrics_no_server_vid = _componentTxStats.electrics_no_server_vid + 1
    if _verboseSyncLoggingEnabled() then
      log('D', logTag, 'Electrics drop: no server mapping for gameVid=' .. tostring(gameVid))
    end
    return
  end

  -- Delta detection: only send if state changed
  if _lastElectrics[gameVid] == electricsJson then
    _componentTxStats.electrics_unchanged = _componentTxStats.electrics_unchanged + 1
    return
  end
  _lastElectrics[gameVid] = electricsJson

  local sent = connection._sendPacket({
    type = "vehicle_electrics",
    vehicle_id = serverVid,
    data = electricsJson,
  })
  if sent then
    _componentTxStats.electrics_sent = _componentTxStats.electrics_sent + 1
    if _verboseSyncLoggingEnabled() then
      log('D', logTag, 'Electrics sent gameVid=' .. tostring(gameVid)
        .. ' serverVid=' .. tostring(serverVid)
        .. ' payloadBytes=' .. tostring(#(electricsJson or '')))
    end
  else
    _componentTxStats.electrics_send_failed = _componentTxStats.electrics_send_failed + 1
  end
end

-- ── Input polling (for input-augmented extrapolation) ───────────────
-- Fetches steering/throttle/brake from vlua electrics and caches in GE.
M._pollInputsAndRotation = function(gameVid)
  local veh = scenetree.findObjectById(gameVid)
  if not veh then return end

  local ok = pcall(function()
    veh:queueLuaCommand(
      'local e = electrics.values '
      .. 'local st = e.steering_input or e.steering or 0 '
      .. 'local th = e.throttle_input or e.throttle or 0 '
      .. 'local br = e.brake_input or e.brake or 0 '
      .. 'local ga = e.gear_A or 0 '
      .. 'local hb = (e.parkingbrake and e.parkingbrake > 0.5) and 1 or 0 '
      .. 'local r = quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp())) '
      .. 'obj:queueGameEngineLua("extensions.highbeam.onInputsAndRotationReport(' .. gameVid .. '," .. st .. "," .. th .. "," .. br .. "," .. ga .. "," .. hb .. "," .. r.x .. "," .. r.y .. "," .. r.z .. "," .. r.w .. ")")'
    )
  end)
  _pollLuaCommandCount = _pollLuaCommandCount + 1
  if not ok then
    _pollLuaCommandErrorCount = _pollLuaCommandErrorCount + 1
  end
end

M._pollInputs = M._pollInputsAndRotation

-- Called back from vehicle-side Lua with input values
M.onInputsReport = function(gameVid, steer, throttle, brake, gear, handbrake)
  M._cachedInputs[gameVid] = {
    steer = steer or 0,
    throttle = throttle or 0,
    brake = brake or 0,
    gear = gear or 0,
    handbrake = handbrake or 0,
  }
end

-- ── Vlua rotation polling ───────────────────────────────────────────
-- veh:getRotation() returns the SceneObject transform rotation which does NOT
-- track physics orientation on soft-body vehicles.  This polls the actual
-- physics rotation from vlua using direction vectors (same as BeamMP).
M._pollVluaRotation = function(gameVid)
  M._pollInputsAndRotation(gameVid)
end

M.onInputsAndRotationReport = function(gameVid, steer, throttle, brake, gear, handbrake, rx, ry, rz, rw)
  M.onInputsReport(gameVid, steer, throttle, brake, gear, handbrake)
  M.onVluaRotationReport(gameVid, rx, ry, rz, rw)
end

-- Called back from vehicle-side Lua with physics rotation quaternion
M.onVluaRotationReport = function(gameVid, rx, ry, rz, rw)
  local now = os.clock()
  local current = { rx or 0, ry or 0, rz or 0, rw or 1 }
  current = syncMath.normalizeQuat(current)

  local prev = M._cachedVluaRot[gameVid]
  local prevAt = M._cachedVluaRotTime[gameVid]
  if prev and prevAt then
    local dt = now - prevAt
    if dt > 0.0001 then
      local av = syncMath.angularVelocityFromQuats(
        { prev.x or 0, prev.y or 0, prev.z or 0, prev.w or 1 },
        current,
        dt
      )
      M._cachedAngVel[gameVid] = { av[1] or 0, av[2] or 0, av[3] or 0 }
    end
  end

  M._cachedVluaRot[gameVid] = { x = current[1], y = current[2], z = current[3], w = current[4] }
  M._cachedVluaRotTime[gameVid] = now
end

M.onVEData = function(gameVid, px, py, pz, rx, ry, rz, rw, vx, vy, vz, avx, avy, avz,
    steer, throttle, brake, gear, handbrake)
  _vePos[gameVid] = { tonumber(px) or 0, tonumber(py) or 0, tonumber(pz) or 0 }
  _veRot[gameVid] = { tonumber(rx) or 0, tonumber(ry) or 0, tonumber(rz) or 0, tonumber(rw) or 1 }
  _veVel[gameVid] = { tonumber(vx) or 0, tonumber(vy) or 0, tonumber(vz) or 0 }
  _veDataReady[gameVid] = true
  _veLastDataAt[gameVid] = os.clock()

  M._cachedInputs[gameVid] = {
    steer = tonumber(steer) or 0,
    throttle = tonumber(throttle) or 0,
    brake = tonumber(brake) or 0,
    gear = tonumber(gear) or 0,
    handbrake = tonumber(handbrake) or 0,
  }

  M._cachedVluaRot[gameVid] = {
    x = tonumber(rx) or 0,
    y = tonumber(ry) or 0,
    z = tonumber(rz) or 0,
    w = tonumber(rw) or 1,
  }
  M._cachedVluaRotTime[gameVid] = os.clock()
  M._cachedAngVel[gameVid] = {
    tonumber(avx) or 0,
    tonumber(avy) or 0,
    tonumber(avz) or 0,
  }
end

local function _parseInputDeltaStr(deltaStr)
  local out = {}
  if type(deltaStr) ~= "string" or deltaStr == "" then
    return out
  end
  for part in string.gmatch(deltaStr, "[^,]+") do
    local key, val = string.match(part, "^([%a]+)=([^,]+)$")
    if key and val then
      out[key] = tonumber(val) or 0
    end
  end
  return out
end

M.onVEInputs = function(gameVid, deltaStr)
  if not connection or connection.getState() ~= connection.STATE_CONNECTED then return end
  local serverVid = M.localVehicles[gameVid]
  if not serverVid then return end
  local sent = connection._sendPacket({
    type = "vehicle_inputs",
    vehicle_id = serverVid,
    data = tostring(deltaStr or ""),
  })
  if sent then
    _componentTxStats.inputs_sent = _componentTxStats.inputs_sent + 1
  else
    _componentTxStats.inputs_send_failed = _componentTxStats.inputs_send_failed + 1
  end

  local delta = _parseInputDeltaStr(deltaStr)
  local cached = M._cachedInputs[gameVid] or { steer = 0, throttle = 0, brake = 0, gear = 0, handbrake = 0 }
  if delta.s ~= nil then cached.steer = delta.s end
  if delta.t ~= nil then cached.throttle = delta.t end
  if delta.b ~= nil then cached.brake = delta.b end
  if delta.g ~= nil then cached.gear = delta.g end
  if delta.p ~= nil then cached.handbrake = delta.p end
  M._cachedInputs[gameVid] = cached
end

M.onVEElectrics = function(gameVid, jsonStr)
  if not connection or connection.getState() ~= connection.STATE_CONNECTED then return end
  local serverVid = M.localVehicles[gameVid]
  if not serverVid then
    _componentTxStats.electrics_no_server_vid = _componentTxStats.electrics_no_server_vid + 1
    return
  end

  if _lastElectrics[gameVid] == jsonStr then
    _componentTxStats.electrics_unchanged = _componentTxStats.electrics_unchanged + 1
    return
  end
  _lastElectrics[gameVid] = jsonStr

  local sent = connection._sendPacket({
    type = "vehicle_electrics",
    vehicle_id = serverVid,
    data = tostring(jsonStr or "{}"),
  })
  if sent then
    _componentTxStats.electrics_sent = _componentTxStats.electrics_sent + 1
  else
    _componentTxStats.electrics_send_failed = _componentTxStats.electrics_send_failed + 1
  end
end

M.onVEPowertrain = function(gameVid, jsonStr)
  if not connection or connection.getState() ~= connection.STATE_CONNECTED then return end
  local serverVid = M.localVehicles[gameVid]
  if not serverVid then return end
  local sent = connection._sendPacket({
    type = "vehicle_powertrain",
    vehicle_id = serverVid,
    data = tostring(jsonStr or "{}"),
  })
  if sent then
    _componentTxStats.powertrain_sent = _componentTxStats.powertrain_sent + 1
  else
    _componentTxStats.powertrain_send_failed = _componentTxStats.powertrain_send_failed + 1
  end
end

M.onVEDamage = function(gameVid, jsonStr)
  if not M.localVehicles[gameVid] then return end
  local hash = tostring(jsonStr or "")
  if _lastDamageHashes[gameVid] == hash then return end
  _lastDamageHashes[gameVid] = hash
  if hash == '' or hash == '{}' or hash == '{"broken":[],"deform":{}}' then return end
  M.sendDamage(gameVid, hash)
end

-- P3.2: Mark a vehicle as needing a damage poll on the next cycle.
-- Called from the main extension's onBeamBroke / collision hooks.
M.markDamageDirty = function(gameVid)
  if M.localVehicles[gameVid] then
    M._damageDirty[gameVid] = true
  end
end

-- Bug #3a: Clear damage hash so next poll detects fresh state after reset.
M.clearDamageHash = function(gameVid)
  _lastDamageHashes[gameVid] = nil
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
    M._inflightByGameVid[gameVid] = nil
  end

  if gameVid then
    local previousServerVid = M.localVehicles[gameVid]
    if previousServerVid and previousServerVid ~= serverVehicleId then
      log('W', logTag, 'Superseding local map game=' .. tostring(gameVid)
        .. ' oldServer=' .. tostring(previousServerVid)
        .. ' newServer=' .. tostring(serverVehicleId)
        .. ' reqId=' .. tostring(spawnRequestId)
        .. ' — deleting old server vehicle')
      if connection and connection.getState() == connection.STATE_CONNECTED then
        connection._sendPacket({
          type = "vehicle_delete",
          vehicle_id = previousServerVid,
        })
      end
    end
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
    M._inflightByGameVid[gameVid] = nil
    log('W', logTag, 'Spawn rejected reqId=' .. tostring(spawnRequestId)
      .. ' gameVid=' .. tostring(gameVid) .. ' reason=' .. tostring(reason))
  else
    log('W', logTag, 'Spawn rejected for unknown reqId=' .. tostring(spawnRequestId)
      .. ' reason=' .. tostring(reason))
  end
end

M.isSpawnInFlight = function(gameVehicleId)
  return M._inflightByGameVid[gameVehicleId] ~= nil
end

M.canRequestSpawn = function(gameVehicleId)
  if M.localVehicles[gameVehicleId] then
    return false, "already_mapped"
  end
  if M._inflightByGameVid[gameVehicleId] then
    return false, "in_flight"
  end

  if connection and connection.getServerMaxCars then
    local maxCars = connection.getServerMaxCars()
    if maxCars and maxCars > 0 then
      local mappedCount = 0
      for _, _ in pairs(M.localVehicles) do
        mappedCount = mappedCount + 1
      end
      local inflightCount = 0
      for _, _ in pairs(M._inflightByGameVid) do
        inflightCount = inflightCount + 1
      end
      if (mappedCount + inflightCount) >= maxCars then
        return false, "max_cars_reached"
      end
    end
  end

  return true
end

M.requestSpawn = function(gameVehicleId, configData)
  if not connection or connection.getState() ~= connection.STATE_CONNECTED then return end
  local allowed, reason = M.canRequestSpawn(gameVehicleId)
  if not allowed then
    log('D', logTag, 'Skipping spawn request gameVid=' .. tostring(gameVehicleId)
      .. ' reason=' .. tostring(reason))
    return
  end
  local requestId = M._nextSpawnRequestId
  M._nextSpawnRequestId = M._nextSpawnRequestId + 1
  M._pendingSpawns[requestId] = {
    gameVid = gameVehicleId,
    sentAt = os.clock(),
  }
  M._inflightByGameVid[gameVehicleId] = requestId
  local sent = connection._sendPacket({
    type = "vehicle_spawn",
    vehicle_id = 0,  -- Server will assign
    data = configData,
    spawn_request_id = requestId,
  })
  if not sent then
    M._pendingSpawns[requestId] = nil
    M._inflightByGameVid[gameVehicleId] = nil
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
  M._inflightByGameVid[gameVehicleId] = nil
end

-- Send damage state for a local vehicle (called on collision events)
M.sendDamage = function(gameVehicleId, damageData)
  if not connection or connection.getState() ~= connection.STATE_CONNECTED then
    return
  end
  local serverVid = M.localVehicles[gameVehicleId]
  if not serverVid then
    _componentTxStats.damage_no_server_vid = _componentTxStats.damage_no_server_vid + 1
    if _verboseSyncLoggingEnabled() then
      log('D', logTag, 'Damage drop: no server mapping for gameVid=' .. tostring(gameVehicleId))
    end
    return
  end

  -- Throttle damage sends: at most once per 200ms per vehicle
  local now = os.clock()
  if _damageTimers[gameVehicleId] and (now - _damageTimers[gameVehicleId]) < 0.2 then
    _componentTxStats.damage_throttled = _componentTxStats.damage_throttled + 1
    return
  end
  _damageTimers[gameVehicleId] = now

  local sent = connection._sendPacket({
    type = "vehicle_damage",
    vehicle_id = serverVid,
    data = damageData,
  })
  if sent then
    _componentTxStats.damage_sent = _componentTxStats.damage_sent + 1
  else
    _componentTxStats.damage_send_failed = _componentTxStats.damage_send_failed + 1
  end
end

M.onDisconnect = function()
  log('I', logTag, 'Clearing local vehicle state on disconnect')
  M.localVehicles = {}
  M._pendingSpawns = {}
  M._inflightByGameVid = {}
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
  _vePos = {}
  _veRot = {}
  _veVel = {}
  _veDataReady = {}
  _veLastDataAt = {}
  M._cachedInputs = {}
  M._cachedVluaRot = {}
  M._cachedVluaRotTime = {}
  M._cachedAngVel = {}
  M._lastSentState = {}
  M._damageDirty = {}
  M._damageFullTimer = 0
  _lastUdpErrorLogAt = -math.huge
  _diagLogTimer = 0
  _udpSentCount = 0
  _udpSkippedUnchangedCount = 0
  _udpEncodeErrorCount = 0
  _udpSendErrorCount = 0
  _sendSpeedAccum = 0
  _sendSpeedSamples = 0
  _componentTxStats = {
    damage_sent = 0,
    damage_throttled = 0,
    damage_no_server_vid = 0,
    damage_send_failed = 0,
    electrics_sent = 0,
    electrics_unchanged = 0,
    electrics_no_server_vid = 0,
    electrics_send_failed = 0,
    inputs_sent = 0,
    inputs_send_failed = 0,
    powertrain_sent = 0,
    powertrain_send_failed = 0,
  }
  _pollLuaCommandCount = 0
  _pollLuaCommandErrorCount = 0
  _damageFallbackTimer = 0
  _damageFallbackCursor = 0
  _tcpPoseSentCount = 0
  _tcpPoseSendErrorCount = 0
  _lastTcpPoseSentAt = {}
end

return M
