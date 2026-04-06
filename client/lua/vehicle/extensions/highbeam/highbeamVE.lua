local M = {}
M.name = "highbeam_highbeamVE"

local isRemote = false
local isActive = false
local gameVehicleId = 0

local sendTimer = 0
local SEND_INTERVAL = 1 / 60

local function _safeController(name)
  if controller and controller.getController then
    local ok, mod = pcall(controller.getController, name)
    if ok and mod then return mod end
  end
  return rawget(_G, name)
end

function M.onInit()
  if obj and obj.getID then
    gameVehicleId = obj:getID()
  end
end

function M.setActive(active, remote)
  isActive = active and true or false
  isRemote = remote and true or false

  local posVE = _safeController("highbeam_highbeamPositionVE")
  if posVE and posVE.setRemote then
    pcall(posVE.setRemote, isRemote)
  end

  local inputsVE = _safeController("highbeam_highbeamInputsVE")
  if inputsVE and inputsVE.setActive then
    pcall(inputsVE.setActive, isActive, isRemote)
  end

  local electricsVE = _safeController("highbeam_highbeamElectricsVE")
  if electricsVE and electricsVE.setActive then
    pcall(electricsVE.setActive, isActive, isRemote)
  end

  local powertrainVE = _safeController("highbeam_highbeamPowertrainVE")
  if powertrainVE and powertrainVE.setActive then
    pcall(powertrainVE.setActive, isActive, isRemote)
  end

  local damageVE = _safeController("highbeam_highbeamDamageVE")
  if damageVE and damageVE.setActive then
    pcall(damageVE.setActive, isActive, isRemote)
  end
end

function M.onBeamBroke(beamId, energy)
  local damageVE = _safeController("highbeam_highbeamDamageVE")
  if damageVE and damageVE.onBeamBroke then
    pcall(damageVE.onBeamBroke, beamId, energy)
  else
    if obj and obj.queueGameEngineLua then
      obj:queueGameEngineLua(string.format("extensions.highbeam.onVEDamageDirty(%d)", gameVehicleId))
    end
  end
end

function M.updateGFX(dt)
  if not isActive or isRemote then return end

  sendTimer = sendTimer + (dt or 0)
  if sendTimer < SEND_INTERVAL then
    return
  end
  sendTimer = 0

  if not obj then return end

  local pos = obj:getPosition()
  local vel = obj:getVelocity()
  if not pos or not vel then return end

  local dir = obj:getDirectionVector()
  local up = obj:getDirectionVectorUp()
  if not dir or not up then return end

  local rot = quatFromDir(-vec3(dir), vec3(up))

  local e = electrics and electrics.values or {}
  local steer = e.steering_input or e.steering or 0
  local throttle = e.throttle_input or e.throttle or 0
  local brake = e.brake_input or e.brake or 0
  local gear = e.gear_A or 0
  local handbrake = e.parkingbrake_input or e.parkingbrake or 0

  local avx, avy, avz = 0, 0, 0
  if obj.getClusterAngularVelocity then
    local ok, angVel = pcall(obj.getClusterAngularVelocity, obj)
    if ok and angVel then
      avx, avy, avz = angVel.x or 0, angVel.y or 0, angVel.z or 0
    end
  end

  if obj.queueGameEngineLua then
    obj:queueGameEngineLua(string.format(
      "extensions.highbeam.onVEData(%d,%.4f,%.4f,%.4f,%.6f,%.6f,%.6f,%.6f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.5f,%.5f,%.5f,%.0f,%.5f)",
      gameVehicleId,
      pos.x, pos.y, pos.z,
      rot.x, rot.y, rot.z, rot.w,
      vel.x, vel.y, vel.z,
      avx, avy, avz,
      steer, throttle, brake, gear, handbrake
    ))
  end
end

return M
