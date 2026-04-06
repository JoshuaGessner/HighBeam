local M = {}
M.name = "highbeam_highbeamPositionVE"

local velocityVE

local targetPos = { 0, 0, 0 }
local targetVel = { 0, 0, 0 }
local targetRot = { 0, 0, 0, 1 }
local targetAngVel = { 0, 0, 0 }
local targetTime = 0
local hasTarget = false
local isRemote = false

local posCorrectMul = 5
local posForceMul = 5
local maxPosForce = 100
local minPosForce = 0.01
local maxRotForce = 50

local teleportBaseDist = 1.0
local teleportSpeedScale = 0.1
local teleportDelaySec = 0.5
local teleportTimer = 0

local timeOffset = 0
local offsetSamples = {}
local offsetSampleIdx = 1
local OFFSET_SAMPLE_COUNT = 10

local function _getVelocityModule()
  if velocityVE then return velocityVE end
  if controller and controller.getController then
    local ok, mod = pcall(controller.getController, "highbeam_highbeamVelocityVE")
    if ok and mod then
      velocityVE = mod
      return velocityVE
    end
  end
  if rawget(_G, "highbeam_highbeamVelocityVE") then
    velocityVE = rawget(_G, "highbeam_highbeamVelocityVE")
    return velocityVE
  end
  return nil
end

local function _now()
  if obj and obj.getSimTime then
    local ok, t = pcall(obj.getSimTime, obj)
    if ok and type(t) == "number" then return t end
  end
  return os.clock()
end

function M.onInit()
  _getVelocityModule()
end

function M.setRemote(remote)
  isRemote = remote and true or false
  hasTarget = false
  teleportTimer = 0
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
  if not isRemote or not hasTarget or not velMod then return end
  if not obj then return end

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

  local errX = predX - (curPos.x or 0)
  local errY = predY - (curPos.y or 0)
  local errZ = predZ - (curPos.z or 0)
  local errDist = math.sqrt(errX * errX + errY * errY + errZ * errZ)

  local velErrX = targetVel[1] - (curVel.x or 0)
  local velErrY = targetVel[2] - (curVel.y or 0)
  local velErrZ = targetVel[3] - (curVel.z or 0)

  local speed = math.sqrt((curVel.x or 0) * (curVel.x or 0) + (curVel.y or 0) * (curVel.y or 0) + (curVel.z or 0) * (curVel.z or 0))
  local teleportDist = teleportBaseDist + teleportSpeedScale * speed
  if errDist > teleportDist then
    teleportTimer = teleportTimer + (dtSim or 0)
    if teleportTimer > teleportDelaySec then
      if obj.queueGameEngineLua then
        obj:queueGameEngineLua(string.format(
          "extensions.highbeam.onVETeleportRequest(%d,%.4f,%.4f,%.4f,%.6f,%.6f,%.6f,%.6f)",
          obj:getID(), predX, predY, predZ, targetRot[1], targetRot[2], targetRot[3], targetRot[4]
        ))
      end
      teleportTimer = 0
      return
    end
  else
    teleportTimer = 0
  end

  if errDist < minPosForce and
      math.abs(velErrX) < 0.01 and
      math.abs(velErrY) < 0.01 and
      math.abs(velErrZ) < 0.01 then
    return
  end

  local d = dtSim or 0.0005
  local accX = (velErrX + errX * posCorrectMul) * posForceMul * d
  local accY = (velErrY + errY * posCorrectMul) * posForceMul * d
  local accZ = (velErrZ + errZ * posCorrectMul) * posForceMul * d

  local accMag = math.sqrt(accX * accX + accY * accY + accZ * accZ)
  local maxAcc = maxPosForce * d
  if accMag > maxAcc and accMag > 0 then
    local scale = maxAcc / accMag
    accX = accX * scale
    accY = accY * scale
    accZ = accZ * scale
  end

  velMod.addVelocity(accX, accY, accZ)

  local cogX, cogY, cogZ = velMod.getCOG()
  local ravx = targetAngVel[1]
  local ravy = targetAngVel[2]
  local ravz = targetAngVel[3]
  local rotMag = math.sqrt(ravx * ravx + ravy * ravy + ravz * ravz)
  if rotMag > 0.01 then
    local rScale = math.min(1, (maxRotForce * d) / rotMag)
    velMod.addAngularVelocity(ravx * rScale * d, ravy * rScale * d, ravz * rScale * d, cogX, cogY, cogZ)
  end
end

function M.updateTimeOffset(senderTime, localRecvTime)
  if type(senderTime) ~= "number" or type(localRecvTime) ~= "number" then return end
  local sample = localRecvTime - senderTime
  offsetSamples[offsetSampleIdx] = sample
  offsetSampleIdx = (offsetSampleIdx % OFFSET_SAMPLE_COUNT) + 1

  local minOffset = math.huge
  for _, v in ipairs(offsetSamples) do
    if v < minOffset then minOffset = v end
  end
  if minOffset ~= math.huge then
    timeOffset = minOffset
  end
end

return M
