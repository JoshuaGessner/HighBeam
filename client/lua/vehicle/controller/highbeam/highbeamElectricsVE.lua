local M = {}
M.name = "highbeam_highbeamElectricsVE"

local isRemote = false
local isActive = false
local gameVehicleId = 0

local lastSentValues = {}
local ROUND_FACTOR = 10000
local sendTimer = 0
local SEND_INTERVAL = 1 / 15

local DENY_LIST = {
  rpm = true, rpmTacho = true, engineLoad = true, turboBoost = true,
  turboRPM = true, turboSpin = true, engineThrottle = true,
  oiltemp = true, watertemp = true, fuel = true,
  wheelspeed = true, airspeed = true, airflowspeed = true,
  avgWheelAV = true, driveshaft = true, rpmspin = true,
  wheelThermalBR = true, wheelThermalBL = true,
  wheelThermalFR = true, wheelThermalFL = true,
  throttle = true, throttle_input = true,
  brake = true, brake_input = true,
  steering = true, steering_input = true,
  clutch = true, clutch_input = true,
  parkingbrake = true, parkingbrake_input = true,
  gear = true, gear_A = true, gear_M = true, gearIndex = true,
  odometer = true, trip = true, altitude = true,
  virtualAirspeed = true, smoothShiftLogicAV = true,
  accXSmooth = true, accYSmooth = true, accZSmooth = true,
  dseColor = true, isShifting = true,
  checkengine = true, lowfuel = true, lowpressure = true,
  brakelights = true,
  ignitionLevel = true,
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
  lastSentValues = {}
end

function M.setActive(active, remote)
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

  -- Report via GE if any keys were unexpectedly denied (debugging aid)
  if deniedCount > 0 and obj and obj.queueGameEngineLua then
    obj:queueGameEngineLua(string.format(
      "log('D','highbeamElectricsVE','applied=%d denied=%d vid=%d')",
      appliedCount, deniedCount, gameVehicleId
    ))
  end
end

-- Controller system dispatches init(), not onInit().
M.init = M.onInit

return M
