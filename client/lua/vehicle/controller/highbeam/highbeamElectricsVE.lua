local M = {}
M.type = "auxiliary"

local isRemote = false
local isActive = false
local gameVehicleId = 0
local initialized = false

local lastSentValues = {}
local ROUND_FACTOR = 10000
local sendTimer = 0
local SEND_INTERVAL = 1 / 15

-- Keys that must NEVER be written onto a remote (puppet) vehicle.
--
-- These are LOCAL simulation OUTPUTS: the puppet runs its own full physics and
-- powertrain, so it regenerates every one of these each step from the synced
-- inputs (highbeamInputsVE), powertrain device calls (highbeamPowertrainVE) and
-- the position/velocity correction. Writing a remote's value over them — or
-- nulling one via the "isnil" sentinel — corrupts the running sim and can leave
-- a field that stock combustionEngine/powertrain code compares against as nil
-- (`combustionEngine.lua: attempt to compare number with nil`).
--
-- Over-blocking here is safe (the puppet derives the value itself); UNDER-blocking
-- is what breaks the engine sim. Lighting/signal keys are deliberately NOT listed
-- so they still replicate. Mirrors BeamMP's MPElectricsVE disallow set in intent.
local DENY_LIST = {
  -- Engine core
  rpm = true, rpmTacho = true, rpmspin = true,
  engineLoad = true, engineThrottle = true, engineRunning = true,
  throttle = true, throttle_input = true,
  throttleFactor = true, throttleFactorFront = true, throttleFactorRear = true,
  throttleOverride = true, regenThrottle = true,
  ignitionLevel = true, checkengine = true,
  oiltemp = true, watertemp = true,
  exhaustFlow = true, radiatorFanSpin = true,
  turboBoost = true, turboRPM = true, turboSpin = true, turboRpmRatio = true,
  boost = true, superchargerBoost = true,
  nitrousOxideActive = true,

  -- Fuel
  fuel = true, fuelCapacity = true, lowfuel = true,

  -- Clutch / transmission
  clutch = true, clutch_input = true,
  clutchRatio = true, clutchRatio1 = true, clutchRatio2 = true, lockupClutchRatio = true,
  gear = true, gear_A = true, gear_M = true, gearIndex = true,
  shouldShift = true, isShifting = true, intershaft = true,
  targetRPMRatioDecreate = true, smoothShiftLogicAV = true,
  disp_P = true, disp_R = true, disp_N = true, disp_D = true,
  disp_S = true, disp_L = true, disp_M = true,
  disp_1 = true, disp_2 = true, disp_3 = true, disp_4 = true,
  disp_5 = true, disp_6 = true, disp_7 = true, disp_8 = true,

  -- Driveline
  driveshaft = true, driveshaft_F = true, driveshaft_R = true, avgWheelAV = true,

  -- Brakes / stability control (state follows the synced brake input)
  brake = true, brake_input = true, brakelights = true,
  parkingbrake = true, parkingbrake_input = true,
  abs = true, absActive = true, hasABS = true,
  tcs = true, tcsActive = true, hasTCS = true,
  esc = true, escActive = true, hasESC = true,
  isYCBrakeActive = true, isTCBrakeActive = true,
  wheelThermalBR = true, wheelThermalBL = true,
  wheelThermalFR = true, wheelThermalFL = true,

  -- Steering (hydro output follows the synced steering input)
  steering = true, steering_input = true,
  steeringUnassisted = true, steering_timestamp = true,

  -- Cruise control
  cruiseControlActive = true, cruiseControlTarget = true,

  -- Speeds / physics readouts
  wheelspeed = true, airspeed = true, airflowspeed = true, virtualAirspeed = true,
  accXSmooth = true, accYSmooth = true, accZSmooth = true,
  odometer = true, trip = true, altitude = true,

  -- Misc locally-derived state
  dseColor = true, lowpressure = true,
}

local function _jsonEncode(v)
  if jsonEncode then
    local ok, out = pcall(jsonEncode, v)
    if ok then return out end
  end
  if Engine and Engine.JSONEncode then
    local ok, out = pcall(Engine.JSONEncode, v)
    if ok then return out end
  end
  local ok, json = pcall(require, "json")
  if ok and json then
    local ok2, out = pcall(json.encode, v)
    if ok2 then return out end
  end
  return "{}"
end

function M.onInit()
  if obj and obj.getID then
    gameVehicleId = obj:getID()
  end
  if initialized then return end
  initialized = true
  lastSentValues = {}
end

function M.setActive(active, remote)
  M.onInit()
  isActive = active and true or false
  isRemote = remote and true or false
end

function M.updateGFX(dt)
  if not isActive or isRemote or not electrics or not electrics.values then return end
  sendTimer = sendTimer + (dt or 0)
  if sendTimer < SEND_INTERVAL then return end
  sendTimer = 0

  local delta = {}
  local changed = false

  for key, val in pairs(electrics.values) do
    if not DENY_LIST[key] then
      local rounded = val
      if type(val) == "number" then
        rounded = math.floor(val * ROUND_FACTOR + 0.5) / ROUND_FACTOR
      end
      if lastSentValues[key] ~= rounded then
        delta[key] = rounded
        lastSentValues[key] = rounded
        changed = true
      end
    end
  end

  for key, _ in pairs(lastSentValues) do
    if electrics.values[key] == nil and not DENY_LIST[key] then
      delta[key] = "isnil"
      lastSentValues[key] = nil
      changed = true
    end
  end

  if changed and obj and obj.queueGameEngineLua then
    obj:queueGameEngineLua(string.format(
      "extensions.highbeam.onVEElectrics(%d,%q)",
      gameVehicleId,
      _jsonEncode(delta)
    ))
  end
end

function M.applyElectrics(data)
  if not isRemote or type(data) ~= "table" or not electrics or not electrics.values then return end

  local appliedCount = 0
  local deniedCount = 0
  for key, val in pairs(data) do
    if DENY_LIST[key] then
      deniedCount = deniedCount + 1
    elseif val == "isnil" then
      electrics.values[key] = nil
      appliedCount = appliedCount + 1
    else
      electrics.values[key] = val
      appliedCount = appliedCount + 1
    end
  end

  if deniedCount > 0 and obj and obj.queueGameEngineLua then
    obj:queueGameEngineLua(string.format(
      "log('D','highbeamElectricsVE','applied=%d denied=%d vid=%d')",
      appliedCount, deniedCount, gameVehicleId
    ))
  end
end

M.init = M.onInit
M.onExtensionLoaded = M.onInit

return M
