local M = {}
M.type = "auxiliary"

local isRemote = false
local isActive = false
local gameVehicleId = 0
local initialized = false
local physicsHookActive = false
local lastPhysicsStepAt = nil
local PHYSICS_HOOK_STALE_SEC = 0.25

local sendTimer = 0
local motionTimer = 0
local lastSampleTime = 0
local SEND_INTERVAL = 1 / 60

local function _isFinite(value, limit)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
    and math.abs(value) <= (limit or 1e20)
end

local function _getSteeringLock()
  if v and v.data and v.data.input and v.data.input.steeringWheelLock then
    return tonumber(v.data.input.steeringWheelLock) or 450
  end
  return 450
end

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
  if enablePhysicsStepHook then
    local okHook = pcall(enablePhysicsStepHook)
    physicsHookActive = okHook and true or false
  end
  if obj and obj.queueGameEngineLua then
    obj:queueGameEngineLua(string.format(
      "extensions.highbeam.onVEControllerInit(%d,%q,%s)",
      gameVehicleId,
      "highbeamVE",
      tostring(physicsHookActive)
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

-- Re-arm sampling without reloading every controller. This is intentionally
-- idempotent: the GE watchdog can call it whenever vehicle-side samples go
-- stale, including the case where enablePhysicsStepHook succeeded but the hook
-- subsequently stopped firing.
function M.restartSampling()
  sendTimer = 0
  lastPhysicsStepAt = nil
  if enablePhysicsStepHook then
    local okHook = pcall(enablePhysicsStepHook)
    physicsHookActive = okHook and true or false
  else
    physicsHookActive = false
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

local function _sampleAndSend(dt)
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

  local originPos = obj:getPosition()
  local originVel = obj:getVelocity()
  if not originPos or not originVel then return end

  local dir = obj:getDirectionVector()
  local up = obj:getDirectionVectorUp()
  if not dir or not up then return end

  local rot = quatFromDir(-vec3(dir), vec3(up))

  if not (_isFinite(originPos.x, 1e7) and _isFinite(originPos.y, 1e7) and _isFinite(originPos.z, 1e7)
    and _isFinite(originVel.x, 1e5) and _isFinite(originVel.y, 1e5) and _isFinite(originVel.z, 1e5)
    and _isFinite(rot.x, 4) and _isFinite(rot.y, 4) and _isFinite(rot.z, 4) and _isFinite(rot.w, 4)) then
    return
  end

  local e = electrics and electrics.values or {}
  -- Match highbeamInputsVE's wire convention on both UDP and TCP: steering is
  -- normalized to BeamNG's 450-degree reference and inverted on receive.
  local steer = (e.steering_input or e.steering or 0) * _getSteeringLock() / 450
  local throttle = e.throttle_input or e.throttle or 0
  local brake = e.brake_input or e.brake or 0
  local gear = e.gear_A or 0
  local handbrake = e.parkingbrake_input or e.parkingbrake or 0

  -- World-frame angular velocity: the physics core exposes pitch/roll/yaw
  -- rates in the vehicle's local frame; rotate them by the vehicle rotation.
  -- (obj:getClusterAngularVelocity does not exist in BeamNG vlua.)
  local avx, avy, avz = 0, 0, 0
  if obj.getPitchAngularVelocity and obj.getRollAngularVelocity and obj.getYawAngularVelocity then
    local okAV, angVel = pcall(function()
      return vec3(obj:getPitchAngularVelocity(), obj:getRollAngularVelocity(), obj:getYawAngularVelocity())
        :rotated(rot)
    end)
    if okAV and angVel then
      avx, avy, avz = angVel.x or 0, angVel.y or 0, angVel.z or 0
    end
  end

  if not (_isFinite(avx, 1e4) and _isFinite(avy, 1e4) and _isFinite(avz, 1e4)
    and _isFinite(sampleTime, 1e9) and _isFinite(sampleDelta, 1)) then
    return
  end

  -- Synchronize the center of gravity consistently with the receiver. The
  -- origin velocity alone includes rotation/translation coupling for vehicles
  -- whose COG is offset from the reference node.
  local pos = vec3(originPos)
  local vel = vec3(originVel)
  local velVE = _getController("highbeamVelocityVE")
  if velVE and velVE.getCogRel then
    local okCog, cogRel = pcall(velVE.getCogRel)
    if okCog and cogRel then
      local cog = vec3(cogRel):rotated(rot)
      pos = pos + cog
      vel = vel + cog:cross(vec3(avx, avy, avz))
    end
  end
  if not (_isFinite(pos.x, 1e7) and _isFinite(pos.y, 1e7) and _isFinite(pos.z, 1e7)
    and _isFinite(vel.x, 1e5) and _isFinite(vel.y, 1e5) and _isFinite(vel.z, 1e5)) then
    return
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


function M.onPhysicsStep(dt)
  lastPhysicsStepAt = os.clock()
  if physicsHookActive then _sampleAndSend(dt) end
end

function M.updateGFX(dt)
  local hookSilent = not lastPhysicsStepAt
    or (os.clock() - lastPhysicsStepAt) > PHYSICS_HOOK_STALE_SEC
  if not physicsHookActive or hookSilent then _sampleAndSend(dt) end
end

M.init = M.onInit
M.onExtensionLoaded = M.onInit

return M
