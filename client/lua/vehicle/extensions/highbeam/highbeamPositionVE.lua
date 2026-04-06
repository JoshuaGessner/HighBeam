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

-- Teleport thresholds — tuned for collision awareness (Bug #2)
local TELEPORT_BASE_DIST = 3.0        -- base distance for instant teleport
local TELEPORT_SPEED_SCALE = 0.5      -- additional distance per m/s
local TELEPORT_DELAY_SEC = 0.3        -- wait before teleporting at moderate errors
local TELEPORT_INSTANT_DIST = 8.0     -- always teleport immediately above this

-- Correction thresholds (Bug #2: keep corrective accel below collision forces)
local CORRECTION_ACCEL_CLAMP = 12.0   -- m/s^2 max corrective acceleration (below collision ~50-200)
local SMALL_ERROR_THRESHOLD = 0.5     -- m; below this use accel-only corrections
local POS_CORRECT_GAIN = 8.0          -- proportional gain for position error -> acceleration
local VEL_CORRECT_GAIN = 4.0          -- proportional gain for velocity error -> acceleration

local teleportTimer = 0

local timeOffset = 0
local offsetSamples = {}
local offsetSampleIdx = 1
local OFFSET_SAMPLE_COUNT = 10

-- Reference node for cluster operations (typically node 0)
local refNodeId = 0

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

-- Compute rotation error as an angular velocity correction vector.
-- Returns axis-angle angular velocity (rad/s) to rotate from current to target.
local function _rotationErrorAngVel(curRot, tgtRot, dt)
  if not curRot or not tgtRot or dt <= 0 then return 0, 0, 0 end
  local cx, cy, cz, cw = curRot[1], curRot[2], curRot[3], curRot[4]
  local tx, ty, tz, tw = tgtRot[1], tgtRot[2], tgtRot[3], tgtRot[4]

  -- Ensure shortest path (flip if dot < 0)
  local dot = cx*tx + cy*ty + cz*tz + cw*tw
  if dot < 0 then
    tx, ty, tz, tw = -tx, -ty, -tz, -tw
    dot = -dot
  end

  -- Quaternion difference: q_err = q_target * q_current^-1
  -- For unit quaternions, inverse = conjugate
  local ex = tw*cx - tx*cw - ty*cz + tz*cy
  local ey = tw*cy + tx*cz - ty*cw - tz*cx
  local ez = tw*cz - tx*cy + ty*cx - tz*cw
  local ew = tw*cw + tx*cx + ty*cy + tz*cz

  -- Convert to axis-angle
  local sinHalf = math.sqrt(ex*ex + ey*ey + ez*ez)
  if sinHalf < 0.0001 then return 0, 0, 0 end

  local angle = 2 * math.atan2(sinHalf, math.abs(ew))
  if ew < 0 then angle = -angle end

  local invSin = 1 / sinHalf
  local ax = ex * invSin
  local ay = ey * invSin
  local az = ez * invSin

  -- Return as angular velocity (rad/s) to correct over dt
  local scale = angle / dt
  return ax * scale, ay * scale, az * scale
end

-- Predict target rotation using angular velocity
local function _predictRot(baseRot, angVel, dt)
  if not baseRot or not angVel or dt <= 0 then return baseRot end
  local wx, wy, wz = angVel[1] or 0, angVel[2] or 0, angVel[3] or 0
  local speed = math.sqrt(wx*wx + wy*wy + wz*wz)
  if speed < 0.0001 then return baseRot end

  local half = 0.5 * speed * dt
  local s = math.sin(half)
  local c = math.cos(half)
  local ax, ay, az = wx/speed, wy/speed, wz/speed
  local dx, dy, dz, dw = ax*s, ay*s, az*s, c

  local bx, by, bz, bw = baseRot[1], baseRot[2], baseRot[3], baseRot[4]
  local ox = dw*bx + dx*bw + dy*bz - dz*by
  local oy = dw*by - dx*bz + dy*bw + dz*bx
  local oz = dw*bz + dx*by - dy*bx + dz*bw
  local ow = dw*bw - dx*bx - dy*by - dz*bz
  local len = math.sqrt(ox*ox + oy*oy + oz*oz + ow*ow)
  if len > 0.0001 then
    return { ox/len, oy/len, oz/len, ow/len }
  end
  return baseRot
end

function M.onInit()
  _getVelocityModule()
  refNodeId = 0
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
  if not isRemote or not hasTarget then return end
  if not obj then return end

  local curPos = obj:getPosition()
  local curVel = obj:getVelocity()
  if not curPos or not curVel then return end

  local now = _now()
  local dtPred = now - targetTime - timeOffset
  if dtPred < 0 then dtPred = 0 end
  if dtPred > 0.5 then dtPred = 0.5 end

  -- Predicted target position using velocity extrapolation
  local predX = targetPos[1] + targetVel[1] * dtPred
  local predY = targetPos[2] + targetVel[2] * dtPred
  local predZ = targetPos[3] + targetVel[3] * dtPred

  -- Predicted target rotation using angular velocity
  local predRot = _predictRot(targetRot, targetAngVel, dtPred)

  -- Position error
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

  -- ── Teleport logic (Bug #2: collision-aware thresholds) ──
  local teleportDist = TELEPORT_BASE_DIST + TELEPORT_SPEED_SCALE * speed
  local instantTeleportDist = TELEPORT_INSTANT_DIST + TELEPORT_SPEED_SCALE * speed

  if errDist > instantTeleportDist then
    -- Very large error: teleport immediately via cluster positioning
    if obj.setClusterPosRelRot then
      pcall(obj.setClusterPosRelRot, obj, refNodeId,
        predX, predY, predZ,
        predRot[1], predRot[2], predRot[3], predRot[4])
    elseif obj.queueGameEngineLua then
      obj:queueGameEngineLua(string.format(
        "extensions.highbeam.onVETeleportRequest(%d,%.4f,%.4f,%.4f,%.6f,%.6f,%.6f,%.6f)",
        obj:getID(), predX, predY, predZ, predRot[1], predRot[2], predRot[3], predRot[4]
      ))
    end
    -- Set velocity after teleport
    if velMod and obj.applyClusterVelocityScaleAdd then
      pcall(obj.applyClusterVelocityScaleAdd, obj, refNodeId, 0,
        targetVel[1], targetVel[2], targetVel[3])
    elseif velMod then
      velMod.setVelocity(targetVel[1], targetVel[2], targetVel[3])
    end
    teleportTimer = 0
    return
  end

  if errDist > teleportDist then
    teleportTimer = teleportTimer + d
    local delayNeeded = TELEPORT_DELAY_SEC + 0.1 * speed
    if teleportTimer > delayNeeded then
      -- Delayed teleport via cluster positioning
      if obj.setClusterPosRelRot then
        pcall(obj.setClusterPosRelRot, obj, refNodeId,
          predX, predY, predZ,
          predRot[1], predRot[2], predRot[3], predRot[4])
      elseif obj.queueGameEngineLua then
        obj:queueGameEngineLua(string.format(
          "extensions.highbeam.onVETeleportRequest(%d,%.4f,%.4f,%.4f,%.6f,%.6f,%.6f,%.6f)",
          obj:getID(), predX, predY, predZ, predRot[1], predRot[2], predRot[3], predRot[4]
        ))
      end
      if velMod and obj.applyClusterVelocityScaleAdd then
        pcall(obj.applyClusterVelocityScaleAdd, obj, refNodeId, 0,
          targetVel[1], targetVel[2], targetVel[3])
      elseif velMod then
        velMod.setVelocity(targetVel[1], targetVel[2], targetVel[3])
      end
      teleportTimer = 0
      return
    end
  else
    teleportTimer = 0
  end

  -- ── Small/medium error: acceleration-based correction (Bug #2) ──
  -- When error is small (< SMALL_ERROR_THRESHOLD), use acceleration-only
  -- corrections clamped below collision separation forces.
  -- This lets physics handle collisions naturally.

  local velErrX = targetVel[1] - (curVel.x or 0)
  local velErrY = targetVel[2] - (curVel.y or 0)
  local velErrZ = targetVel[3] - (curVel.z or 0)

  -- PD-style corrective acceleration: P(pos error) + D(velocity error)
  local accX = errX * POS_CORRECT_GAIN + velErrX * VEL_CORRECT_GAIN
  local accY = errY * POS_CORRECT_GAIN + velErrY * VEL_CORRECT_GAIN
  local accZ = errZ * POS_CORRECT_GAIN + velErrZ * VEL_CORRECT_GAIN

  -- Clamp corrective acceleration (Bug #2: below collision forces)
  local accMag = math.sqrt(accX*accX + accY*accY + accZ*accZ)
  local clamp = CORRECTION_ACCEL_CLAMP
  if errDist < SMALL_ERROR_THRESHOLD then
    -- Extra-conservative near zero error to avoid fighting collisions
    clamp = clamp * 0.5
  end
  if accMag > clamp and accMag > 0 then
    local scale = clamp / accMag
    accX = accX * scale
    accY = accY * scale
    accZ = accZ * scale
  end

  -- Apply corrective acceleration as velocity delta (acc * dt)
  if velMod then
    velMod.addVelocity(accX * d, accY * d, accZ * d)
  end

  -- ── Rotation correction (Bug #5) ──
  -- Compute rotation error and blend with target angular velocity.
  -- Get current rotation from the velocity module's COG-relative frame
  local curRot = nil
  if obj.getClusterRotation then
    local okR, cr = pcall(obj.getClusterRotation, obj, refNodeId)
    if okR and cr then
      curRot = { cr.x or cr[1] or 0, cr.y or cr[2] or 0, cr.z or cr[3] or 0, cr.w or cr[4] or 1 }
    end
  end

  if curRot and velMod then
    -- Correction time horizon for rotation
    local rotCorrectionTime = 0.15
    local reX, reY, reZ = _rotationErrorAngVel(curRot, predRot, rotCorrectionTime)

    -- Blend rotation error correction (70%) with target angular velocity (30%)
    local blendErr = 0.7
    local blendTarget = 0.3
    local finalAVX = reX * blendErr + (targetAngVel[1] or 0) * blendTarget
    local finalAVY = reY * blendErr + (targetAngVel[2] or 0) * blendTarget
    local finalAVZ = reZ * blendErr + (targetAngVel[3] or 0) * blendTarget

    -- Clamp angular correction
    local avMag = math.sqrt(finalAVX*finalAVX + finalAVY*finalAVY + finalAVZ*finalAVZ)
    local maxAngAcc = 30.0 -- rad/s^2
    if avMag > maxAngAcc then
      local s = maxAngAcc / avMag
      finalAVX = finalAVX * s
      finalAVY = finalAVY * s
      finalAVZ = finalAVZ * s
    end

    local cogX, cogY, cogZ = velMod.getCOG()
    velMod.addAngularVelocity(finalAVX * d, finalAVY * d, finalAVZ * d, cogX, cogY, cogZ)
  if minOffset ~= math.huge then
    timeOffset = minOffset
  end
end

return M
