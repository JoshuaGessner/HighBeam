local M = {}

local isRemote = false
local isActive = false
local gameVehicleId = 0

local lastSent = { s = 0, t = 0, b = 0, p = 0, c = 0, g = 0 }
local ROUND_FACTOR = 10000
local SEND_THRESHOLD = 0.001
local gearResyncTimer = 0
local GEAR_RESYNC_INTERVAL = 5.0

-- Readiness guard: wait after activation before applying gear changes,
-- giving the gearbox time to fully initialize its ratio tables.
local activationTime = 0
local READINESS_DELAY_SEC = 0.5

local smoothing = { s = 0, t = 0, b = 0, p = 0, c = 0 }
local SMOOTH_RATE = 30
local SNAP_THRESHOLD = 0.2
local LIMIT_SNAP = 0.05

local INPUT_NAMES = { "steering", "throttle", "brake", "parkingbrake", "clutch" }

local function _round4(v)
  return math.floor((v or 0) * ROUND_FACTOR + 0.5) / ROUND_FACTOR
end

local function _getSteeringLock()
  if v and v.data and v.data.input and v.data.input.steeringWheelLock then
    return tonumber(v.data.input.steeringWheelLock) or 450
  end
  return 450
end

function M.onInit()
  if obj and obj.getID then
    gameVehicleId = obj:getID()
  end
  lastSent = { s = 0, t = 0, b = 0, p = 0, c = 0, g = 0 }
  smoothing = { s = 0, t = 0, b = 0, p = 0, c = 0 }
end

function M.setActive(active, remote)
  isActive = active and true or false
  isRemote = remote and true or false
  if isActive and isRemote then
    activationTime = os.clock()
  end
  if isRemote and input and input.setAllowedInputSource then
    for _, name in ipairs(INPUT_NAMES) do
      pcall(input.setAllowedInputSource, name, "local", false)
    end
  end
end

function M.updateGFX(dt)
  if not isActive or isRemote then return end

  local e = electrics and electrics.values or {}
  local lock = _getSteeringLock()
  local s = _round4((e.steering_input or 0) * lock / 450)
  local t = _round4(e.throttle_input or 0)
  local b = _round4(e.brake_input or 0)
  local p = _round4(e.parkingbrake_input or 0)
  local c = _round4(e.clutch_input or 0)
  local g = tonumber(e.gear_A or 0) or 0

  local changed = false
  local delta = {}

  if math.abs(s - (lastSent.s or 0)) > SEND_THRESHOLD then delta.s = s; changed = true end
  if math.abs(t - (lastSent.t or 0)) > SEND_THRESHOLD then delta.t = t; changed = true end
  if math.abs(b - (lastSent.b or 0)) > SEND_THRESHOLD then delta.b = b; changed = true end
  if math.abs(p - (lastSent.p or 0)) > SEND_THRESHOLD then delta.p = p; changed = true end
  if math.abs(c - (lastSent.c or 0)) > SEND_THRESHOLD then delta.c = c; changed = true end

  gearResyncTimer = gearResyncTimer + (dt or 0)
  if g ~= lastSent.g or gearResyncTimer > GEAR_RESYNC_INTERVAL then
    delta.g = g
    changed = true
    gearResyncTimer = 0
  end

  if changed then
    for k, v in pairs(delta) do
      lastSent[k] = v
    end

    local parts = {}
    for k, v in pairs(delta) do
      parts[#parts + 1] = k .. "=" .. tostring(v)
    end

    if obj and obj.queueGameEngineLua then
      obj:queueGameEngineLua(string.format(
        "extensions.highbeam.onVEInputs(%d,%q)",
        gameVehicleId,
        table.concat(parts, ",")
      ))
    end
  end
end

function M._applyGear(gearValue)
  if powertrain and powertrain.getDevices then
    local ok, devices = pcall(powertrain.getDevices)
    if ok and devices then
      for _, dev in pairs(devices) do
        if (dev.type == "manualGearbox" or dev.type == "automaticGearbox" or dev.type == "dctGearbox") and dev.setGearIndex then
          -- Clamp gear index to valid range to prevent desiredGearRatio nil crash
          local minGear = dev.minGearIndex or -1
          local maxGear = dev.maxGearIndex or 6
          local clamped = math.max(minGear, math.min(maxGear, math.floor(gearValue)))
          -- Verify the gear has a valid ratio entry before applying
          if dev.gearRatios and dev.gearRatios[clamped] == nil and clamped ~= 0 then
            return
          end
          pcall(dev.setGearIndex, dev, clamped)
          return
        end
      end
    end
  end
  -- Do NOT write gear_A directly to electrics — the gearbox reads it on
  -- the next updateGFX and if the value is invalid, desiredGearRatio is nil.
end

function M.applyInputs(data)
  if not isRemote or type(data) ~= "table" then return end

  -- Readiness guard: skip gear changes until gearbox has initialized
  local now = os.clock()
  local ready = (now - activationTime) >= READINESS_DELAY_SEC

  for key, target in pairs(data) do
    if key == "s" or key == "t" or key == "b" or key == "p" or key == "c" then
      local inputName = ({ s = "steering", t = "throttle", b = "brake", p = "parkingbrake", c = "clutch" })[key]
      local current = smoothing[key] or 0
      local targetVal = tonumber(target) or 0

      if key == "s" then
        local lock = _getSteeringLock()
        targetVal = targetVal * 450 / lock
      end

      local delta = math.abs(targetVal - current)
      if delta > SNAP_THRESHOLD or targetVal < LIMIT_SNAP or targetVal > (1 - LIMIT_SNAP) then
        smoothing[key] = targetVal
      else
        local alpha = 1 - math.exp(-SMOOTH_RATE * (1 / 60))
        smoothing[key] = current + (targetVal - current) * alpha
      end

      if input and input.event then
        pcall(input.event, inputName, smoothing[key], 1, nil, nil, nil, "HighBeam")
      end
    elseif key == "g" and ready then
      M._applyGear(tonumber(target) or 0)
    end
  end
end

function M.getInputActivity()
  if not isRemote then return 0 end
  local t = math.abs(smoothing.t or 0)
  local b = math.abs(smoothing.b or 0)
  return math.max(t, b)
end

M.onExtensionLoaded = M.onInit

return M
