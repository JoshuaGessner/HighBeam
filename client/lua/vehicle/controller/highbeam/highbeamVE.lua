local M = {}
M.type = "auxiliary"

local isRemote = false
local isActive = false
local gameVehicleId = 0
local initialized = false

local sendTimer = 0
local motionTimer = 0
local lastSampleTime = 0
local SEND_INTERVAL = 1 / 60

local function _getController(name)
  if controller and controller.getController then
    local ok, mod = pcall(controller.getController, name)
    if ok then return mod end
  end
  return nil
end

local function _ensureControllerInit(mod)
  if not mod then return end
  if mod.init then
    pcall(mod.init)
  elseif mod.onInit then
    pcall(mod.onInit)
  end
end

function M.onInit()
  if obj and obj.getID then
    gameVehicleId = obj:getID()
  else
    return
  end
  if initialized then
    return
  end
  initialized = true
  -- Use one native BeamNG physics-step hook on the coordinator, then dispatch
  -- to child HighBeam controllers explicitly. Controller-loaded children do not
  -- receive native onPhysicsStep callbacks reliably in all runtime paths.
  if enablePhysicsStepHook then
    enablePhysicsStepHook()
  end
  if obj and obj.queueGameEngineLua then
    obj:queueGameEngineLua(string.format(
      "extensions.highbeam.onVEControllerInit(%d,%q,%s)",
      gameVehicleId,
      "highbeamVE",
      tostring(enablePhysicsStepHook ~= nil)
    ))
  end
end

function M.setActive(active, remote)
  M.onInit()
  isActive = active and true or false
  isRemote = remote and true or false

  local velVE = _getController("highbeamVelocityVE")
  _ensureControllerInit(velVE)

  local posVE = _getController("highbeamPositionVE")
  _ensureControllerInit(posVE)
  if posVE and posVE.setRemote then
    pcall(posVE.setRemote, isRemote)
  end

  local inputsVE = _getController("highbeamInputsVE")
  _ensureControllerInit(inputsVE)
  if inputsVE and inputsVE.setActive then
    pcall(inputsVE.setActive, isActive, isRemote)
  end

  local electricsVE = _getController("highbeamElectricsVE")
  _ensureControllerInit(electricsVE)
  if electricsVE and electricsVE.setActive then
    pcall(electricsVE.setActive, isActive, isRemote)
  end

  local powertrainVE = _getController("highbeamPowertrainVE")
  _ensureControllerInit(powertrainVE)
  if powertrainVE and powertrainVE.setActive then
    pcall(powertrainVE.setActive, isActive, isRemote)
  end

  local damageVE = _getController("highbeamDamageVE")
  _ensureControllerInit(damageVE)
  if damageVE and damageVE.setActive then
    pcall(damageVE.setActive, isActive, isRemote)
  end

  if obj and obj.queueGameEngineLua then
    obj:queueGameEngineLua(string.format(
      "extensions.highbeam.onVEControllerActive(%d,%s,%s)",
      gameVehicleId,
      tostring(isActive),
      tostring(isRemote)
    ))
  end
end

function M.onBeamBroke(beamId, energy)
  local damageVE = _getController("highbeamDamageVE")
  if damageVE and damageVE.onBeamBroke then
    pcall(damageVE.onBeamBroke, beamId, energy)
  else
    if obj and obj.queueGameEngineLua then
      obj:queueGameEngineLua(string.format("extensions.highbeam.onVEDamageDirty(%d)", gameVehicleId))
    end
  end

  local velVE = _getController("highbeamVelocityVE")
  if velVE and velVE.onBeamBroke then
    pcall(velVE.onBeamBroke, beamId, energy)
  end
end

function M.onPhysicsStep(dtSim)
  -- Controller-loaded HighBeam modules do not receive this callback reliably in
  -- BeamNG 0.38. Remote motion is driven from highbeamPositionVE.updateGFX.
end

function M.updateGFX(dt)
  if not isActive or isRemote then return end

  local frameDt = dt or 0
  motionTimer = motionTimer + frameDt

  sendTimer = sendTimer + frameDt
  if sendTimer < SEND_INTERVAL then
    return
  end
  sendTimer = 0

  local sampleTime = motionTimer
  local sampleDelta = sampleTime - lastSampleTime
  if sampleDelta <= 0 then sampleDelta = frameDt end
  lastSampleTime = sampleTime

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
      "extensions.highbeam.onVEData(%d,%.4f,%.4f,%.4f,%.6f,%.6f,%.6f,%.6f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.5f,%.5f,%.5f,%.0f,%.5f,%.6f,%.6f)",
      gameVehicleId,
      pos.x, pos.y, pos.z,
      rot.x, rot.y, rot.z, rot.w,
      vel.x, vel.y, vel.z,
      avx, avy, avz,
      steer, throttle, brake, gear, handbrake,
      sampleTime, sampleDelta
    ))
  end
end

M.init = M.onInit
M.onExtensionLoaded = M.onInit

return M
