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

local TELEPORT_BASE_DIST = 3.0
local TELEPORT_SPEED_SCALE = 0.5
local TELEPORT_DELAY_SEC = 0.3
local TELEPORT_INSTANT_DIST = 8.0

local CORRECTION_ACCEL_CLAMP = 12.0
local SMALL_ERROR_THRESHOLD = 0.5
local POS_CORRECT_GAIN = 8.0
local VEL_CORRECT_GAIN = 4.0

local teleportTimer = 0

local heartbeatTimer = 0
local HEARTBEAT_INTERVAL = 1.0

local timeOffset = 0
local offsetSamples = {}
local offsetSampleIdx = 1
local OFFSET_SAMPLE_COUNT = 10

local refNodeId = 0

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
  -- Register for physics-rate updates via orchestrator hook
  if highbeamVE and highbeamVE.addPhysUpdateHandler then
    highbeamVE.addPhysUpdateHandler("positionVE", M.onPhysicsStep)
  end
end

function M.setRemote(remote)
  isRemote = remote and true or false
  hasTarget = false
  teleportTimer = 0
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
  targetPos = { px or 0, py or 0, pz or 0 }
  targetVel = { vx or 0, vy or 0, vz or 0 }
  targetRot = { rx or 0, ry or 0, rz or 0, rw or 1 }
  targetAngVel = { avx or 0, avy or 0, avz or 0 }
  targetTime = t or 0
  hasTarget = true

  M.updateTimeOffset(targetTime, _now())
end

function M.onPhysicsStep(dtSim)
  local velMod = _getVelocityModule()
  if not isRemote or not hasTarget then return end
  if not obj then return end

  -- VE heartbeat: signal GE that this vlua is alive.
  local d0 = dtSim or 0.0005
  heartbeatTimer = heartbeatTimer + d0
  if heartbeatTimer >= HEARTBEAT_INTERVAL then
    heartbeatTimer = 0
    if obj.queueGameEngineLua then
      obj:queueGameEngineLua(string.format(
        "extensions.highbeam.onVEHeartbeat(%d)", obj:getID()
      ))
    end
  end

  local curPos = obj:getPosition()
  local curVel = obj:getVelocity()
  if not curPos or not curVel then return end

  local now = _now()
  local dtPred = now - targetTime - timeOffset
  if dtPred < 0 then dtPred = 0 end
  if dtPred > 0.5 then dtPred = 0.5 end

  local predX = targetPos[1] + targetVel[1] * dtPred
  local predY = targetPos[2] + targetVel[2] * dtPred
  local predZ = targetPos[3] + targetVel[3] * dtPred
  local predRot = _predictRot(targetRot, targetAngVel, dtPred)

  local errX = predX - (curPos.x or 0)
  local errY = predY - (curPos.y or 0)
  local errZ = predZ - (curPos.z or 0)
  local errDist = math.sqrt(errX * errX + errY * errY + errZ * errZ)

  local speed = math.sqrt(
    (curVel.x or 0) * (curVel.x or 0) +
    (curVel.y or 0) * (curVel.y or 0) +
    (curVel.z or 0) * (curVel.z or 0)
  )

  local d = dtSim or 0.0005
  local teleportDist = TELEPORT_BASE_DIST + TELEPORT_SPEED_SCALE * speed
  local instantTeleportDist = TELEPORT_INSTANT_DIST + TELEPORT_SPEED_SCALE * speed

  if errDist > instantTeleportDist then
    if obj.setClusterPosRelRot then
      pcall(obj.setClusterPosRelRot, obj, refNodeId, predX, predY, predZ, predRot[1], predRot[2], predRot[3], predRot[4])
    elseif obj.queueGameEngineLua then
      obj:queueGameEngineLua(string.format(
        "extensions.highbeam.onVETeleportRequest(%d,%.4f,%.4f,%.4f,%.6f,%.6f,%.6f,%.6f)",
        obj:getID(), predX, predY, predZ, predRot[1], predRot[2], predRot[3], predRot[4]
      ))
    end
    if velMod and velMod.setVelocity then
      velMod.setVelocity(targetVel[1], targetVel[2], targetVel[3])
    end
    teleportTimer = 0
    return
  end

  if errDist > teleportDist then
    teleportTimer = teleportTimer + d
    local delayNeeded = TELEPORT_DELAY_SEC + 0.1 * speed
    if teleportTimer > delayNeeded then
      if obj.setClusterPosRelRot then
        pcall(obj.setClusterPosRelRot, obj, refNodeId, predX, predY, predZ, predRot[1], predRot[2], predRot[3], predRot[4])
      elseif obj.queueGameEngineLua then
        obj:queueGameEngineLua(string.format(
          "extensions.highbeam.onVETeleportRequest(%d,%.4f,%.4f,%.4f,%.6f,%.6f,%.6f,%.6f)",
          obj:getID(), predX, predY, predZ, predRot[1], predRot[2], predRot[3], predRot[4]
        ))
      end
      if velMod and velMod.setVelocity then
        velMod.setVelocity(targetVel[1], targetVel[2], targetVel[3])
      end
      teleportTimer = 0
      return
    end
  else
    teleportTimer = 0
  end

  local velErrX = targetVel[1] - (curVel.x or 0)
  local velErrY = targetVel[2] - (curVel.y or 0)
  local velErrZ = targetVel[3] - (curVel.z or 0)

  -- Scale down PD correction when vehicle is under driver input to avoid
  -- body forces fighting engine/tire physics.
  local inMod = _getInputsModule()
  local inputActivity = (inMod and inMod.getInputActivity) and inMod.getInputActivity() or 0
  local posGainScale = 1.0 - 0.5 * inputActivity   -- 100% at rest, 50% at full input
  local velGainScale = 1.0 - 0.7 * inputActivity   -- 100% at rest, 30% at full input

  local accX = errX * POS_CORRECT_GAIN * posGainScale + velErrX * VEL_CORRECT_GAIN * velGainScale
  local accY = errY * POS_CORRECT_GAIN * posGainScale + velErrY * VEL_CORRECT_GAIN * velGainScale
  local accZ = errZ * POS_CORRECT_GAIN * posGainScale + velErrZ * VEL_CORRECT_GAIN * velGainScale

  local accMag = math.sqrt(accX * accX + accY * accY + accZ * accZ)
  local clamp = CORRECTION_ACCEL_CLAMP * (1.0 - 0.5 * inputActivity)
  if errDist < SMALL_ERROR_THRESHOLD then
    clamp = clamp * 0.5
  end
  if accMag > clamp and accMag > 0 then
    local scale = clamp / accMag
    accX = accX * scale
    accY = accY * scale
    accZ = accZ * scale
  end

  if velMod and velMod.addVelocity then
    velMod.addVelocity(accX * d, accY * d, accZ * d)
  end

  local curRot = _currentRotation()
  if curRot and velMod and velMod.addAngularVelocity then
    local reX, reY, reZ = _rotationErrorAngVel(curRot, predRot, 0.15)

    local finalAVX = reX * 0.7 + (targetAngVel[1] or 0) * 0.3
    local finalAVY = reY * 0.7 + (targetAngVel[2] or 0) * 0.3
    local finalAVZ = reZ * 0.7 + (targetAngVel[3] or 0) * 0.3

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
