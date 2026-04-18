local M = {}

local velocityVE
local inputsVE

local targetPos = { 0, 0, 0 }
local targetVel = { 0, 0, 0 }
local targetRot = { 0, 0, 0, 1 }
local targetAngVel = { 0, 0, 0 }
local targetTime = 0
local hasTarget = false
local isRemote = false

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
local prevTargetTime = nil

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
  return os.clock()
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

local function _bufferTargetSnapshot(pos, vel, rot, angVel, t)
  targetBuffer[#targetBuffer + 1] = {
    pos = { pos[1] or 0, pos[2] or 0, pos[3] or 0 },
    vel = { vel[1] or 0, vel[2] or 0, vel[3] or 0 },
    rot = { rot[1] or 0, rot[2] or 0, rot[3] or 0, rot[4] or 1 },
    angVel = { angVel[1] or 0, angVel[2] or 0, angVel[3] or 0 },
    time = t or 0,
    received = _now(),
  }
  while #targetBuffer > TARGET_BUFFER_MAX do
    table.remove(targetBuffer, 1)
  end
end

local function _resolveBufferedTarget(now)
  if #targetBuffer == 0 then
    return targetPos, targetVel, targetRot, targetAngVel, 0
  end

  local sampleTime = now - timeOffset - INTERP_BACK_TIME
  local oldest = targetBuffer[1]
  local newest = targetBuffer[#targetBuffer]

  if sampleTime <= (oldest.time or 0) then
    return oldest.pos, oldest.vel, oldest.rot, oldest.angVel, 0
  end

  for i = 1, #targetBuffer - 1 do
    local a = targetBuffer[i]
    local b = targetBuffer[i + 1]
    if sampleTime >= (a.time or 0) and sampleTime <= (b.time or 0) then
      local span = math.max((b.time or 0) - (a.time or 0), 0.0001)
      local t = math.max(0, math.min(1, (sampleTime - (a.time or 0)) / span))
      return _lerp3(a.pos, b.pos, t), _lerp3(a.vel, b.vel, t), _nlerpQuat(a.rot, b.rot, t), _lerp3(a.angVel, b.angVel, t), 0
    end
  end

  local dt = sampleTime - (newest.time or 0)
  if dt < 0 then dt = 0 end
  if dt > MAX_EXTRAPOLATION_SEC then dt = MAX_EXTRAPOLATION_SEC end
  return {
    (newest.pos[1] or 0) + (newest.vel[1] or 0) * dt,
    (newest.pos[2] or 0) + (newest.vel[2] or 0) * dt,
    (newest.pos[3] or 0) + (newest.vel[3] or 0) * dt,
  }, newest.vel, _predictRot(newest.rot, newest.angVel, dt), newest.angVel, dt
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
  teleportTimer = 0
  postTeleportGrace = 0
  timeOffset = 0
  offsetSamples = {}
  offsetSampleIdx = 1
  targetBuffer = {}
  prevTargetPos = nil
  prevTargetVel = nil
  prevTargetTime = nil
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

function M.setTarget(px, py, pz, vx, vy, vz, rx, ry, rz, rw, avx, avy, avz, t)
  local newPos = { px or 0, py or 0, pz or 0 }
  local newVel = { vx or 0, vy or 0, vz or 0 }
  local newTime = t or 0

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
  prevTargetTime = newTime

  targetPos = newPos
  targetVel = newVel
  targetRot = { rx or 0, ry or 0, rz or 0, rw or 1 }
  targetAngVel = { avx or 0, avy or 0, avz or 0 }
  targetTime = newTime
  hasTarget = true

  M.updateTimeOffset(targetTime, _now())
  _bufferTargetSnapshot(targetPos, targetVel, targetRot, targetAngVel, targetTime)
end

-- updateGFX is called by the extension framework unconditionally, so the
-- heartbeat fires even if the physics hook is somehow not registered.
function M.updateGFX(dt)
  if not isRemote or not obj then return end
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
  if not isRemote or not hasTarget then return end
  if not obj then return end

  local curPos = obj:getPosition()
  local curVel = obj:getVelocity()
  if not curPos or not curVel then return end

  local now = _now()
  local d = dtSim or 0.0005

  if postTeleportGrace > 0 then
    postTeleportGrace = math.max(0, postTeleportGrace - d)
  end

  local newest = targetBuffer[#targetBuffer]
  if newest and (now - (newest.received or now)) > PACKET_TIMEOUT_SEC then
    return
  end

  local predPos, predVel, predRot, predAngVel = _resolveBufferedTarget(now)
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
    if obj.queueGameEngineLua then
      obj:queueGameEngineLua(string.format(
        "extensions.highbeam.onVETeleportRequest(%d,%.4f,%.4f,%.4f,%.6f,%.6f,%.6f,%.6f)",
        obj:getID(), predX, predY, predZ, predRot[1], predRot[2], predRot[3], predRot[4]
      ))
    elseif obj.setClusterPosRelRot then
      pcall(obj.setClusterPosRelRot, obj, refNodeId, predX, predY, predZ, predRot[1], predRot[2], predRot[3], predRot[4])
    end
    if velMod and velMod.setVelocity then
      velMod.setVelocity(predVel[1] or 0, predVel[2] or 0, predVel[3] or 0)
    end
    teleportTimer = 0
    postTeleportGrace = POST_TELEPORT_GRACE_SEC
    blendRemaining = 0
    blendCorrX, blendCorrY, blendCorrZ = 0, 0, 0
    return
  end

  if errDist > teleportDist then
    teleportTimer = teleportTimer + d
    local delayNeeded = TELEPORT_DELAY_SEC + 0.1 * speed
    if teleportTimer > delayNeeded then
      if obj.queueGameEngineLua then
        obj:queueGameEngineLua(string.format(
          "extensions.highbeam.onVETeleportRequest(%d,%.4f,%.4f,%.4f,%.6f,%.6f,%.6f,%.6f)",
          obj:getID(), predX, predY, predZ, predRot[1], predRot[2], predRot[3], predRot[4]
        ))
      elseif obj.setClusterPosRelRot then
        pcall(obj.setClusterPosRelRot, obj, refNodeId, predX, predY, predZ, predRot[1], predRot[2], predRot[3], predRot[4])
      end
      if velMod and velMod.setVelocity then
        velMod.setVelocity(predVel[1] or 0, predVel[2] or 0, predVel[3] or 0)
      end
      teleportTimer = 0
      postTeleportGrace = POST_TELEPORT_GRACE_SEC
      blendRemaining = 0
      blendCorrX, blendCorrY, blendCorrZ = 0, 0, 0
      return
    end
  else
    teleportTimer = 0
  end

  local velErrX = (predVel[1] or 0) - (curVel.x or 0)
  local velErrY = (predVel[2] or 0) - (curVel.y or 0)
  local velErrZ = (predVel[3] or 0) - (curVel.z or 0)

  -- Keep correction active while the remote driver is moving so the vehicle
  -- stays live instead of drifting and later hard-snapping into place.
  local inMod = _getInputsModule()
  local inputActivity = (inMod and inMod.getInputActivity) and inMod.getInputActivity() or 0
  local posGainScale = 1.0 - 0.2 * inputActivity
  local velGainScale = 1.0 - 0.3 * inputActivity

  local accX = errX * POS_CORRECT_GAIN * posGainScale + velErrX * VEL_CORRECT_GAIN * velGainScale
  local accY = errY * POS_CORRECT_GAIN * posGainScale + velErrY * VEL_CORRECT_GAIN * velGainScale
  local accZ = errZ * POS_CORRECT_GAIN * posGainScale + velErrZ * VEL_CORRECT_GAIN * velGainScale

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
