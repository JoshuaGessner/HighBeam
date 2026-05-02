local M = {}

local velocityVE
local inputsVE

local targetPos = { 0, 0, 0 }
local targetVel = { 0, 0, 0 }
local targetAcc = { 0, 0, 0 }
local targetRot = { 0, 0, 0, 1 }
local targetAngVel = { 0, 0, 0 }
local targetAngAcc = { 0, 0, 0 }
local targetTime = 0
local hasTarget = false
local isRemote = false
local localMotionTimer = 0
local diagnosticsEnabled = false
local diagnosticsTimer = 0
local diagnosticsSummaryTimer = 0
local _diag = {
  hardInstant = 0,
  hardDelayed = 0,
  packetTimeout = 0,
  targetAgeDrops = 0,
  targets = 0,
}

local TELEPORT_BASE_DIST = 5.0
local TELEPORT_SPEED_SCALE = 0.5
local TELEPORT_DELAY_SEC = 0.45
local TELEPORT_INSTANT_DIST = 12.0

local CORRECTION_ACCEL_CLAMP = 20.0
local SMALL_ERROR_THRESHOLD = 0.5
local POS_CORRECT_GAIN = 8.0
local VEL_CORRECT_GAIN = 4.0

local teleportTimer = 0
local postTeleportGrace = 0
local POST_TELEPORT_GRACE_SEC = 0.20

local heartbeatTimer = 0
local HEARTBEAT_INTERVAL = 1.0

local timeOffset = 0
local offsetSamples = {}
local offsetSampleIdx = 1
local OFFSET_SAMPLE_COUNT = 10
local targetBuffer = {}
local TARGET_BUFFER_MAX = 8
local INTERP_BACK_TIME = 0.10
local MAX_EXTRAPOLATION_SEC = 0.15
local PACKET_TIMEOUT_SEC = 0.25

local refNodeId = 0

-- Smooth blend-on-arrival: when a new target arrives, we compute the
-- correction delta between where we predicted the car to be (from old target)
-- vs where the new target says it should be. This delta is blended in over
-- BLEND_DURATION seconds, preventing abrupt PD controller jumps when packets
-- arrive. The result is continuous smooth motion even at high latency.
local BLEND_DURATION = 0.06  -- seconds to blend correction (~120 physics steps)
local blendCorrX, blendCorrY, blendCorrZ = 0, 0, 0
local blendRemaining = 0
local prevTargetPos = nil
local prevTargetVel = nil
local prevTargetAngVel = nil
local prevTargetTime = nil
local lastLocalVel = nil
local localAcc = { 0, 0, 0 }

local function _resetSmoothers()
  teleportTimer = 0
  postTeleportGrace = 0
  timeOffset = 0
  offsetSamples = {}
  offsetSampleIdx = 1
  targetBuffer = {}
  blendCorrX, blendCorrY, blendCorrZ = 0, 0, 0
  blendRemaining = 0
  prevTargetPos = nil
  prevTargetVel = nil
  prevTargetAngVel = nil
  prevTargetTime = nil
  lastLocalVel = nil
  localAcc = { 0, 0, 0 }
end

local function _getVelocityModule()
  if velocityVE then return velocityVE end
  velocityVE = highbeamVelocityVE
  return velocityVE
end

local function _getInputsModule()
  if inputsVE then return inputsVE end
  inputsVE = highbeamInputsVE
  return inputsVE
end

local function _now()
  return localMotionTimer
end

local function _lerpValue(oldValue, newValue, alpha)
  return oldValue + (newValue - oldValue) * alpha
end

local function _smooth3(oldValue, newValue, alpha)
  return {
    _lerpValue(oldValue[1] or 0, newValue[1] or 0, alpha),
    _lerpValue(oldValue[2] or 0, newValue[2] or 0, alpha),
    _lerpValue(oldValue[3] or 0, newValue[3] or 0, alpha),
  }
end

local function _rotationErrorAngVel(curRot, tgtRot, dt)
  if not curRot or not tgtRot or dt <= 0 then return 0, 0, 0 end
  local cx, cy, cz, cw = curRot[1], curRot[2], curRot[3], curRot[4]
  local tx, ty, tz, tw = tgtRot[1], tgtRot[2], tgtRot[3], tgtRot[4]

  local dot = cx * tx + cy * ty + cz * tz + cw * tw
  if dot < 0 then
    tx, ty, tz, tw = -tx, -ty, -tz, -tw
  end

  local ex = tw * cx - tx * cw - ty * cz + tz * cy
  local ey = tw * cy + tx * cz - ty * cw - tz * cx
  local ez = tw * cz - tx * cy + ty * cx - tz * cw
  local ew = tw * cw + tx * cx + ty * cy + tz * cz

  local sinHalf = math.sqrt(ex * ex + ey * ey + ez * ez)
  if sinHalf < 0.0001 then return 0, 0, 0 end

  local angle = 2 * math.atan2(sinHalf, math.abs(ew))
  if ew < 0 then angle = -angle end

  local invSin = 1 / sinHalf
  local ax = ex * invSin
  local ay = ey * invSin
  local az = ez * invSin

  local scale = angle / dt
  return ax * scale, ay * scale, az * scale
end

local function _predictRot(baseRot, angVel, dt)
  if not baseRot or not angVel or dt <= 0 then return baseRot end
  local wx, wy, wz = angVel[1] or 0, angVel[2] or 0, angVel[3] or 0
  local speed = math.sqrt(wx * wx + wy * wy + wz * wz)
  if speed < 0.0001 then return baseRot end

  local half = 0.5 * speed * dt
  local s = math.sin(half)
  local c = math.cos(half)
  local ax, ay, az = wx / speed, wy / speed, wz / speed
  local dx, dy, dz, dw = ax * s, ay * s, az * s, c

  local bx, by, bz, bw = baseRot[1], baseRot[2], baseRot[3], baseRot[4]
  local ox = dw * bx + dx * bw + dy * bz - dz * by
  local oy = dw * by - dx * bz + dy * bw + dz * bx
  local oz = dw * bz + dx * by - dy * bx + dz * bw
  local ow = dw * bw - dx * bx - dy * by - dz * bz
  local len = math.sqrt(ox * ox + oy * oy + oz * oz + ow * ow)
  if len > 0.0001 then
    return { ox / len, oy / len, oz / len, ow / len }
  end
  return baseRot
end

local function _lerp(a, b, t)
  return a + (b - a) * t
end

local function _lerp3(a, b, t)
  return {
    _lerp(a[1] or 0, b[1] or 0, t),
    _lerp(a[2] or 0, b[2] or 0, t),
    _lerp(a[3] or 0, b[3] or 0, t),
  }
end

local function _nlerpQuat(a, b, t)
  local ax, ay, az, aw = a[1] or 0, a[2] or 0, a[3] or 0, a[4] or 1
  local bx, by, bz, bw = b[1] or 0, b[2] or 0, b[3] or 0, b[4] or 1
  local dot = ax * bx + ay * by + az * bz + aw * bw
  if dot < 0 then
    bx, by, bz, bw = -bx, -by, -bz, -bw
  end
  local ox = _lerp(ax, bx, t)
  local oy = _lerp(ay, by, t)
  local oz = _lerp(az, bz, t)
  local ow = _lerp(aw, bw, t)
  local len = math.sqrt(ox * ox + oy * oy + oz * oz + ow * ow)
  if len > 0.0001 then
    return { ox / len, oy / len, oz / len, ow / len }
  end
  return { ox, oy, oz, ow }
end

local function _bufferTargetSnapshot(pos, vel, acc, rot, angVel, angAcc, t)
  targetBuffer[#targetBuffer + 1] = {
    pos = { pos[1] or 0, pos[2] or 0, pos[3] or 0 },
    vel = { vel[1] or 0, vel[2] or 0, vel[3] or 0 },
    acc = { acc[1] or 0, acc[2] or 0, acc[3] or 0 },
    rot = { rot[1] or 0, rot[2] or 0, rot[3] or 0, rot[4] or 1 },
    angVel = { angVel[1] or 0, angVel[2] or 0, angVel[3] or 0 },
    angAcc = { angAcc[1] or 0, angAcc[2] or 0, angAcc[3] or 0 },
    time = t or 0,
    received = _now(),
  }
  while #targetBuffer > TARGET_BUFFER_MAX do
    table.remove(targetBuffer, 1)
  end
end

local function _resolveBufferedTarget(now)
  if #targetBuffer == 0 then
    return targetPos, targetVel, targetAcc, targetRot, targetAngVel, targetAngAcc, 0
  end

  local sampleTime = now - timeOffset - INTERP_BACK_TIME
  local oldest = targetBuffer[1]
  local newest = targetBuffer[#targetBuffer]

  if sampleTime <= (oldest.time or 0) then
    return oldest.pos, oldest.vel, oldest.acc, oldest.rot, oldest.angVel, oldest.angAcc, 0
  end

  for i = 1, #targetBuffer - 1 do
    local a = targetBuffer[i]
    local b = targetBuffer[i + 1]
    if sampleTime >= (a.time or 0) and sampleTime <= (b.time or 0) then
      local span = math.max((b.time or 0) - (a.time or 0), 0.0001)
      local t = math.max(0, math.min(1, (sampleTime - (a.time or 0)) / span))
      return _lerp3(a.pos, b.pos, t), _lerp3(a.vel, b.vel, t), _lerp3(a.acc, b.acc, t), _nlerpQuat(a.rot, b.rot, t), _lerp3(a.angVel, b.angVel, t), _lerp3(a.angAcc, b.angAcc, t), 0
    end
  end

  local dt = sampleTime - (newest.time or 0)
  if dt < 0 then dt = 0 end
  if dt > MAX_EXTRAPOLATION_SEC then dt = MAX_EXTRAPOLATION_SEC end
  local predVel = {
    (newest.vel[1] or 0) + (newest.acc[1] or 0) * dt,
    (newest.vel[2] or 0) + (newest.acc[2] or 0) * dt,
    (newest.vel[3] or 0) + (newest.acc[3] or 0) * dt,
  }
  local predAngVel = {
    (newest.angVel[1] or 0) + (newest.angAcc[1] or 0) * dt,
    (newest.angVel[2] or 0) + (newest.angAcc[2] or 0) * dt,
    (newest.angVel[3] or 0) + (newest.angAcc[3] or 0) * dt,
  }
  return {
    (newest.pos[1] or 0) + (newest.vel[1] or 0) * dt + 0.5 * (newest.acc[1] or 0) * dt * dt,
    (newest.pos[2] or 0) + (newest.vel[2] or 0) * dt + 0.5 * (newest.acc[2] or 0) * dt * dt,
    (newest.pos[3] or 0) + (newest.vel[3] or 0) * dt + 0.5 * (newest.acc[3] or 0) * dt * dt,
  }, predVel, newest.acc, _predictRot(newest.rot, predAngVel, dt), predAngVel, newest.angAcc, dt
end

local function _currentRotation()
  if obj and obj.getClusterRotation then
    local okR, cr = pcall(obj.getClusterRotation, obj, refNodeId)
    if okR and cr then
      return { cr.x or cr[1] or 0, cr.y or cr[2] or 0, cr.z or cr[3] or 0, cr.w or cr[4] or 1 }
    end
  end
  if obj and obj.getDirectionVector and obj.getDirectionVectorUp and quatFromDir and vec3 then
    local dir = obj:getDirectionVector()
    local up = obj:getDirectionVectorUp()
    if dir and up then
      local q = quatFromDir(-vec3(dir), vec3(up))
      if q then
        return { q.x or q[1] or 0, q.y or q[2] or 0, q.z or q[3] or 0, q.w or q[4] or 1 }
      end
    end
  end
  return nil
end

function M.onInit()
  _getVelocityModule()
  _getInputsModule()
  refNodeId = 0
  -- enablePhysicsStepHook() is called by highbeamVE; the engine will
  -- natively dispatch onPhysicsStep to every loaded VE extension.
end

function M.setRemote(remote)
  isRemote = remote and true or false
  hasTarget = false
  _resetSmoothers()
end

function M.setDiagnostics(enabled)
  diagnosticsEnabled = enabled and true or false
end

function M.updateTimeOffset(remoteTime, localTime)
  if type(remoteTime) ~= "number" or remoteTime <= 0 then return end
  local now = localTime or _now()
  local instant = now - remoteTime

  offsetSamples[offsetSampleIdx] = instant
  offsetSampleIdx = (offsetSampleIdx % OFFSET_SAMPLE_COUNT) + 1

  local minOffset = math.huge
  for _, sample in pairs(offsetSamples) do
    if type(sample) == "number" and sample < minOffset then
      minOffset = sample
    end
  end

  if minOffset ~= math.huge then
    timeOffset = minOffset
  end
end

function M.setTarget(px, py, pz, vx, vy, vz, rx, ry, rz, rw, avx, avy, avz, t, isReset)
  local newPos = { px or 0, py or 0, pz or 0 }
  local newVel = { vx or 0, vy or 0, vz or 0 }
  local newAngVel = { avx or 0, avy or 0, avz or 0 }
  local newTime = t or 0
  _diag.targets = (_diag.targets or 0) + 1
  if (not isReset) and hasTarget and newTime > 0 and targetTime > 0 and newTime < targetTime then
    _diag.targetAgeDrops = (_diag.targetAgeDrops or 0) + 1
    if diagnosticsEnabled then
      log('D', 'HighBeam.PositionVE', 'target drop old remoteTime=' .. string.format('%.6f', newTime)
        .. ' last=' .. string.format('%.6f', targetTime))
    end
    return
  end

  local newAcc = { 0, 0, 0 }
  local newAngAcc = { 0, 0, 0 }

  if isReset then
    _resetSmoothers()
  elseif prevTargetVel and prevTargetAngVel and prevTargetTime and newTime > prevTargetTime then
    local remoteDt = math.max(0.001, math.min(0.25, newTime - prevTargetTime))
    newAcc = {
      ((newVel[1] or 0) - (prevTargetVel[1] or 0)) / remoteDt,
      ((newVel[2] or 0) - (prevTargetVel[2] or 0)) / remoteDt,
      ((newVel[3] or 0) - (prevTargetVel[3] or 0)) / remoteDt,
    }
    newAngAcc = {
      ((newAngVel[1] or 0) - (prevTargetAngVel[1] or 0)) / remoteDt,
      ((newAngVel[2] or 0) - (prevTargetAngVel[2] or 0)) / remoteDt,
      ((newAngVel[3] or 0) - (prevTargetAngVel[3] or 0)) / remoteDt,
    }
    if targetAcc then newAcc = _smooth3(targetAcc, newAcc, 0.35) end
    if targetAngAcc then newAngAcc = _smooth3(targetAngAcc, newAngAcc, 0.35) end
    if targetVel then newVel = _smooth3(targetVel, newVel, 0.55) end
    if targetAngVel then newAngVel = _smooth3(targetAngVel, newAngVel, 0.55) end
  end

  -- Smooth blend-on-arrival: compute where we predicted the car to be at this
  -- moment using the OLD target, compare with where the NEW target says it
  -- should be at this moment, and blend the difference over BLEND_DURATION.
  if prevTargetPos and prevTargetVel and prevTargetTime and newTime > 0 then
    local now = _now()
    local dtOld = now - prevTargetTime - timeOffset
    if dtOld < 0 then dtOld = 0 end
    if dtOld > 0.5 then dtOld = 0.5 end
    local dtNew = now - newTime - timeOffset
    if dtNew < 0 then dtNew = 0 end
    if dtNew > 0.5 then dtNew = 0.5 end

    -- Where old target predicted we'd be now
    local predOldX = prevTargetPos[1] + prevTargetVel[1] * dtOld
    local predOldY = prevTargetPos[2] + prevTargetVel[2] * dtOld
    local predOldZ = prevTargetPos[3] + prevTargetVel[3] * dtOld

    -- Where new target says we should be now
    local predNewX = newPos[1] + newVel[1] * dtNew
    local predNewY = newPos[2] + newVel[2] * dtNew
    local predNewZ = newPos[3] + newVel[3] * dtNew

    -- The correction to blend in (old prediction → new prediction)
    local corrX = predOldX - predNewX
    local corrY = predOldY - predNewY
    local corrZ = predOldZ - predNewZ

    -- Only blend if correction is small enough (large corrections = teleport)
    local corrDist = math.sqrt(corrX * corrX + corrY * corrY + corrZ * corrZ)
    if corrDist < TELEPORT_BASE_DIST then
      blendCorrX = corrX
      blendCorrY = corrY
      blendCorrZ = corrZ
      blendRemaining = BLEND_DURATION
    else
      blendCorrX, blendCorrY, blendCorrZ = 0, 0, 0
      blendRemaining = 0
    end
  end

  -- Save for next blend computation
  prevTargetPos = newPos
  prevTargetVel = newVel
  prevTargetAngVel = newAngVel
  prevTargetTime = newTime

  targetPos = newPos
  targetVel = newVel
  targetAcc = newAcc
  targetRot = { rx or 0, ry or 0, rz or 0, rw or 1 }
  targetAngVel = newAngVel
  targetAngAcc = newAngAcc
  targetTime = newTime
  hasTarget = true

  M.updateTimeOffset(targetTime, _now())
  _bufferTargetSnapshot(targetPos, targetVel, targetAcc, targetRot, targetAngVel, targetAngAcc, targetTime)

  if diagnosticsEnabled then
    local predictedSample = _now() - timeOffset - INTERP_BACK_TIME
    log('D', 'HighBeam.PositionVE', 'target timing remoteTime=' .. string.format('%.6f', targetTime or 0)
      .. ' localTime=' .. string.format('%.6f', _now())
      .. ' offset=' .. string.format('%.6f', timeOffset or 0)
      .. ' predictedSample=' .. string.format('%.6f', predictedSample)
      .. ' source=' .. (isReset and 'reset' or 'udp'))
  end
end

function M.resetTo(px, py, pz, rx, ry, rz, rw, t)
  M.setTarget(px, py, pz, 0, 0, 0, rx, ry, rz, rw, 0, 0, 0, t or 0, true)
end

function M.onHighBeamRemoteReset()
  _resetSmoothers()
end

-- updateGFX is called by the extension framework unconditionally, so the
-- heartbeat fires even if the physics hook is somehow not registered.
function M.updateGFX(dt)
  if not isRemote or not obj then return end
  diagnosticsSummaryTimer = diagnosticsSummaryTimer + (dt or 0)
  if diagnosticsSummaryTimer >= 5.0 then
    diagnosticsSummaryTimer = 0
    if diagnosticsEnabled then
      log('I', 'HighBeam.PositionVE', 'Position apply diag=hardInstant=' .. tostring(_diag.hardInstant or 0)
        .. ',hardDelayed=' .. tostring(_diag.hardDelayed or 0)
        .. ',packetTimeout=' .. tostring(_diag.packetTimeout or 0)
        .. ',targetAgeDrops=' .. tostring(_diag.targetAgeDrops or 0)
        .. ',targets=' .. tostring(_diag.targets or 0))
    end
    _diag = { hardInstant = 0, hardDelayed = 0, packetTimeout = 0, targetAgeDrops = 0, targets = 0 }
  end
  heartbeatTimer = heartbeatTimer + (dt or 0)
  if heartbeatTimer >= HEARTBEAT_INTERVAL then
    heartbeatTimer = 0
    if obj.queueGameEngineLua then
      obj:queueGameEngineLua(string.format(
        "extensions.highbeam.onVEHeartbeat(%d)", obj:getID()
      ))
    end
  end
end

function M.onPhysicsStep(dtSim)
  local velMod = _getVelocityModule()
  local d = dtSim or 0.0005
  if d > 0 then localMotionTimer = localMotionTimer + d end
  if diagnosticsTimer > 0 then diagnosticsTimer = math.max(0, diagnosticsTimer - d) end
  if not isRemote or not hasTarget then return end
  if not obj then return end

  local curPos = obj:getPosition()
  local curVel = obj:getVelocity()
  if not curPos or not curVel then return end

  local now = _now()

  if postTeleportGrace > 0 then
    postTeleportGrace = math.max(0, postTeleportGrace - d)
  end

  local newest = targetBuffer[#targetBuffer]
  if newest and (now - (newest.received or now)) > PACKET_TIMEOUT_SEC then
    _diag.packetTimeout = (_diag.packetTimeout or 0) + 1
    if diagnosticsEnabled and diagnosticsTimer <= 0 then
      diagnosticsTimer = 0.25
      log('D', 'HighBeam.PositionVE', 'packet timeout age=' .. string.format('%.3f', now - (newest.received or now))
        .. ' timeout=' .. string.format('%.3f', PACKET_TIMEOUT_SEC))
    end
    return
  end

  if lastLocalVel and d > 0 then
    localAcc = {
      ((curVel.x or 0) - (lastLocalVel[1] or 0)) / d,
      ((curVel.y or 0) - (lastLocalVel[2] or 0)) / d,
      ((curVel.z or 0) - (lastLocalVel[3] or 0)) / d,
    }
  end
  lastLocalVel = { curVel.x or 0, curVel.y or 0, curVel.z or 0 }

  local predPos, predVel, predAcc, predRot, predAngVel = _resolveBufferedTarget(now)
  local predX = predPos[1] or 0
  local predY = predPos[2] or 0
  local predZ = predPos[3] or 0

  -- Apply decaying blend correction for smooth packet-to-packet transitions.
  -- This offsets the predicted position by a correction that linearly fades
  -- to zero over BLEND_DURATION, smoothing out the jump when new data arrives.
  if blendRemaining > 0 then
    local blendFrac = blendRemaining / BLEND_DURATION
    predX = predX + blendCorrX * blendFrac
    predY = predY + blendCorrY * blendFrac
    predZ = predZ + blendCorrZ * blendFrac
    blendRemaining = blendRemaining - d
    if blendRemaining <= 0 then
      blendRemaining = 0
      blendCorrX, blendCorrY, blendCorrZ = 0, 0, 0
    end
  end

  local errX = predX - (curPos.x or 0)
  local errY = predY - (curPos.y or 0)
  local errZ = predZ - (curPos.z or 0)
  local errDist = math.sqrt(errX * errX + errY * errY + errZ * errZ)

  local speed = math.sqrt(
    (curVel.x or 0) * (curVel.x or 0) +
    (curVel.y or 0) * (curVel.y or 0) +
    (curVel.z or 0) * (curVel.z or 0)
  )

  local teleportDist = TELEPORT_BASE_DIST + TELEPORT_SPEED_SCALE * speed
  local instantTeleportDist = TELEPORT_INSTANT_DIST + TELEPORT_SPEED_SCALE * speed

  if errDist > instantTeleportDist then
    _diag.hardInstant = (_diag.hardInstant or 0) + 1
    if diagnosticsEnabled and diagnosticsTimer <= 0 then
      diagnosticsTimer = 0.25
      log('D', 'HighBeam.PositionVE', 'hard correction instant err=' .. string.format('%.3f', errDist)
        .. ' threshold=' .. string.format('%.3f', instantTeleportDist)
        .. ' targetAge=' .. string.format('%.3f', newest and (now - (newest.received or now)) or 0)
        .. ' timeOffset=' .. string.format('%.6f', timeOffset or 0)
        .. ' predictedTime=' .. string.format('%.6f', now - timeOffset - INTERP_BACK_TIME)
        .. ' reason=instant')
    end
    if obj.queueGameEngineLua then
      obj:queueGameEngineLua(string.format(
        "extensions.highbeam.onVETeleportRequest(%d,%.4f,%.4f,%.4f,%.6f,%.6f,%.6f,%.6f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f)",
        obj:getID(), predX, predY, predZ, predRot[1], predRot[2], predRot[3], predRot[4],
        predVel[1] or 0, predVel[2] or 0, predVel[3] or 0,
        predAngVel[1] or 0, predAngVel[2] or 0, predAngVel[3] or 0,
        errDist
      ))
    end
    if velMod and velMod.setVelocity then
      velMod.setVelocity(predVel[1] or 0, predVel[2] or 0, predVel[3] or 0)
    end
    teleportTimer = 0
    postTeleportGrace = POST_TELEPORT_GRACE_SEC
    blendRemaining = 0
    blendCorrX, blendCorrY, blendCorrZ = 0, 0, 0
    prevTargetPos, prevTargetVel, prevTargetAngVel, prevTargetTime = nil, nil, nil, nil
    return
  end

  if errDist > teleportDist then
    teleportTimer = teleportTimer + d
    local delayNeeded = TELEPORT_DELAY_SEC + 0.1 * speed
    if teleportTimer > delayNeeded then
      _diag.hardDelayed = (_diag.hardDelayed or 0) + 1
      if diagnosticsEnabled and diagnosticsTimer <= 0 then
        diagnosticsTimer = 0.25
        log('D', 'HighBeam.PositionVE', 'hard correction delayed err=' .. string.format('%.3f', errDist)
          .. ' threshold=' .. string.format('%.3f', teleportDist)
          .. ' targetAge=' .. string.format('%.3f', newest and (now - (newest.received or now)) or 0)
          .. ' timeOffset=' .. string.format('%.6f', timeOffset or 0)
          .. ' predictedTime=' .. string.format('%.6f', now - timeOffset - INTERP_BACK_TIME)
          .. ' reason=delayed')
      end
      if obj.queueGameEngineLua then
        obj:queueGameEngineLua(string.format(
          "extensions.highbeam.onVETeleportRequest(%d,%.4f,%.4f,%.4f,%.6f,%.6f,%.6f,%.6f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f)",
          obj:getID(), predX, predY, predZ, predRot[1], predRot[2], predRot[3], predRot[4],
          predVel[1] or 0, predVel[2] or 0, predVel[3] or 0,
          predAngVel[1] or 0, predAngVel[2] or 0, predAngVel[3] or 0,
          errDist
        ))
      end
      if velMod and velMod.setVelocity then
        velMod.setVelocity(predVel[1] or 0, predVel[2] or 0, predVel[3] or 0)
      end
      teleportTimer = 0
      postTeleportGrace = POST_TELEPORT_GRACE_SEC
      blendRemaining = 0
      blendCorrX, blendCorrY, blendCorrZ = 0, 0, 0
      prevTargetPos, prevTargetVel, prevTargetAngVel, prevTargetTime = nil, nil, nil, nil
      return
    end
  else
    teleportTimer = 0
  end

  local velErrX = (predVel[1] or 0) - (curVel.x or 0)
  local velErrY = (predVel[2] or 0) - (curVel.y or 0)
  local velErrZ = (predVel[3] or 0) - (curVel.z or 0)
  local accErrX = (predAcc[1] or 0) - (localAcc[1] or 0)
  local accErrY = (predAcc[2] or 0) - (localAcc[2] or 0)
  local accErrZ = (predAcc[3] or 0) - (localAcc[3] or 0)

  -- Keep correction active while the remote driver is moving so the vehicle
  -- stays live instead of drifting and later hard-snapping into place.
  local inMod = _getInputsModule()
  local inputActivity = (inMod and inMod.getInputActivity) and inMod.getInputActivity() or 0
  local posGainScale = 1.0 - 0.2 * inputActivity
  local velGainScale = 1.0 - 0.3 * inputActivity

  local accX = errX * POS_CORRECT_GAIN * posGainScale + velErrX * VEL_CORRECT_GAIN * velGainScale + accErrX * 0.08
  local accY = errY * POS_CORRECT_GAIN * posGainScale + velErrY * VEL_CORRECT_GAIN * velGainScale + accErrY * 0.08
  local accZ = errZ * POS_CORRECT_GAIN * posGainScale + velErrZ * VEL_CORRECT_GAIN * velGainScale + accErrZ * 0.08

  local accMag = math.sqrt(accX * accX + accY * accY + accZ * accZ)
  local clamp = CORRECTION_ACCEL_CLAMP * (1.0 - 0.2 * inputActivity)
  if errDist < SMALL_ERROR_THRESHOLD then
    clamp = clamp * 0.5
  end
  if accMag > clamp and accMag > 0 then
    local scale = clamp / accMag
    accX = accX * scale
    accY = accY * scale
    accZ = accZ * scale
  end

  if velMod and velMod.addVelocity and postTeleportGrace <= 0 then
    velMod.addVelocity(accX * d, accY * d, accZ * d)
  end

  local curRot = _currentRotation()
  if curRot and velMod and velMod.addAngularVelocity and postTeleportGrace <= 0 then
    local reX, reY, reZ = _rotationErrorAngVel(curRot, predRot, 0.15)

    local finalAVX = reX * 0.7 + (predAngVel[1] or 0) * 0.3
    local finalAVY = reY * 0.7 + (predAngVel[2] or 0) * 0.3
    local finalAVZ = reZ * 0.7 + (predAngVel[3] or 0) * 0.3

    local avMag = math.sqrt(finalAVX * finalAVX + finalAVY * finalAVY + finalAVZ * finalAVZ)
    local maxAngAcc = 30.0
    if avMag > maxAngAcc then
      local s = maxAngAcc / avMag
      finalAVX = finalAVX * s
      finalAVY = finalAVY * s
      finalAVZ = finalAVZ * s
    end

    local cogX, cogY, cogZ = 0, 0, 0
    if velMod.getCOG then
      cogX, cogY, cogZ = velMod.getCOG()
    end
    velMod.addAngularVelocity(finalAVX * d, finalAVY * d, finalAVZ * d, cogX, cogY, cogZ)
  end
end

M.onExtensionLoaded = M.onInit

return M
