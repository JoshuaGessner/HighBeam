local M = {}
M.type = "auxiliary"

local isRemote = false
local isActive = false
local gameVehicleId = 0
local initialized = false

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
-- applyInputs runs per received input packet (remote updateGFX early-returns),
-- so the smoothing timestep is the real wall-clock gap between packets rather
-- than a fixed frame time. Clamp it to stay stable across jitter and long gaps.
local _lastApplyAt = nil
local APPLY_DT_MIN = 0.005
local APPLY_DT_MAX = 0.1

local INPUT_NAMES = { "steering", "throttle", "brake", "parkingbrake", "clutch" }
local _diag = {
  gearAttempts = 0,
  gearApplied = 0,
  gearSkipped = 0,
  invalidRatio = 0,
  unsupportedGearbox = 0,
  inputsApplied = 0,
}
local _diagTimer = 0
local _diagIntervalSec = 5.0
local _loggedSkip = {}

local GEARBOX_HANDLER = {
  manualGearbox = "index",
  sequentialGearbox = "index",
  dctGearbox = "controller",
  automaticGearbox = "controller",
  cvtGearbox = "controller",
  electricMotor = "controller",
}

local GEAR_MODE_INDEX = {
  R = -1,
  N = 0,
  P = 1,
  D = 2,
  S = 3,
  ["2"] = 4,
  ["1"] = 5,
  M = 6,
}

local function _verboseSyncLoggingEnabled()
  local okCfg, cfg = pcall(require, "highbeam/config")
  return okCfg and cfg and cfg.get and cfg.get("verboseSyncLogging") == true
end

local function _bump(name)
  _diag[name] = (_diag[name] or 0) + 1
end

local function _logVerbose(key, message)
  if not _verboseSyncLoggingEnabled() then return end
  if _loggedSkip[key] then return end
  _loggedSkip[key] = true
  log('D', 'HighBeam.InputsVE', message)
end

local function _formatDiag()
  local parts = {}
  for k, v in pairs(_diag) do
    if v and v > 0 then parts[#parts + 1] = k .. '=' .. tostring(v) end
  end
  table.sort(parts)
  return #parts > 0 and table.concat(parts, ',') or 'none'
end

local function _hasDiagValues()
  for _, v in pairs(_diag) do
    if v and v > 0 then return true end
  end
  return false
end

local function _findGearbox()
  if powertrain and powertrain.getDevice then
    local names = { "gearbox", "frontMotor", "rearMotor", "mainMotor" }
    for _, name in ipairs(names) do
      local ok, dev = pcall(powertrain.getDevice, name)
      if ok and dev then return dev, name end
    end
  end
  if powertrain and powertrain.getDevices then
    local ok, devices = pcall(powertrain.getDevices)
    if ok and devices then
      for name, dev in pairs(devices) do
        if dev and GEARBOX_HANDLER[dev.type] then return dev, name end
      end
    end
  end
  return nil, nil
end

local function _ratioExists(dev, gearIndex)
  if gearIndex == 0 then return true end
  if not dev or not dev.gearRatios then return true end
  return dev.gearRatios[gearIndex] ~= nil
end

local function _parseGearMode(value)
  local s = tostring(value or "")
  local mode = string.sub(s, 1, 1)
  local index = tonumber(string.sub(s, 2))
  if mode == "" then mode = nil end
  return mode, index
end

local function _round4(v)
  return math.floor((v or 0) * ROUND_FACTOR + 0.5) / ROUND_FACTOR
end

local function _getSteeringLock()
  if v and v.data and v.data.input and v.data.input.steeringWheelLock then
    return tonumber(v.data.input.steeringWheelLock) or 450
  end
  return 450
end

local function _shouldSnapInput(key, targetVal, current)
  local delta = math.abs(targetVal - current)
  local atLimit
  if key == "s" then
    -- Steering spans -1..1. Limit detection must be symmetric around zero.
    local magnitude = math.abs(targetVal)
    atLimit = magnitude < LIMIT_SNAP or magnitude > (1 - LIMIT_SNAP)
  else
    atLimit = targetVal < LIMIT_SNAP or targetVal > (1 - LIMIT_SNAP)
  end
  return delta > SNAP_THRESHOLD or atLimit
end

function M.onInit()
  if obj and obj.getID then
    gameVehicleId = obj:getID()
  end
  if initialized then return end
  initialized = true
  lastSent = { s = 0, t = 0, b = 0, p = 0, c = 0, g = 0 }
  smoothing = { s = 0, t = 0, b = 0, p = 0, c = 0 }
end

function M.setActive(active, remote)
  M.onInit()
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
  _diagTimer = _diagTimer + (dt or 0)
  if _diagTimer >= _diagIntervalSec then
    _diagTimer = 0
    if _hasDiagValues() then
      log('I', 'HighBeam.InputsVE', 'Input apply diag=' .. _formatDiag())
      _diag = {
        gearAttempts = 0,
        gearApplied = 0,
        gearSkipped = 0,
        invalidRatio = 0,
        unsupportedGearbox = 0,
        inputsApplied = 0,
      }
    end
  end

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
  _bump("gearAttempts")
  local dev, devName = _findGearbox()
  if not dev then
    _bump("unsupportedGearbox")
    _logVerbose("missing_gearbox", 'gear skip no supported gearbox device value=' .. tostring(gearValue))
    return
  end

  local handler = GEARBOX_HANDLER[dev.type]
  if not handler then
    _bump("unsupportedGearbox")
    _logVerbose("unsupported_" .. tostring(dev.type), 'gear skip unsupported gearbox type=' .. tostring(dev.type)
      .. ' device=' .. tostring(devName)
      .. ' value=' .. tostring(gearValue))
    return
  end

  local numericGear = tonumber(gearValue)
  if handler == "index" then
    if not numericGear then
      _bump("gearSkipped")
      _logVerbose("invalid_numeric_" .. tostring(gearValue), 'gear skip nonnumeric value=' .. tostring(gearValue)
        .. ' type=' .. tostring(dev.type))
      return
    end
    local minGear = tonumber(dev.minGearIndex) or -1
    local maxGear = tonumber(dev.maxGearIndex) or 6
    local clamped = math.max(minGear, math.min(maxGear, math.floor(numericGear)))
    if not _ratioExists(dev, clamped) then
      _bump("invalidRatio")
      _logVerbose("ratio_" .. tostring(dev.type) .. '_' .. tostring(clamped), 'gear skip missing ratio value=' .. tostring(gearValue)
        .. ' clamped=' .. tostring(clamped)
        .. ' type=' .. tostring(dev.type)
        .. ' min=' .. tostring(minGear)
        .. ' max=' .. tostring(maxGear))
      return
    end
    if dev.setGearIndex then
      local ok = pcall(dev.setGearIndex, dev, clamped)
      if ok then _bump("gearApplied") else _bump("gearSkipped") end
      return
    end
  end

  if handler == "controller" then
    if electrics and electrics.values and electrics.values.isShifting then
      _bump("gearSkipped")
      return
    end
    local main = controller and controller.mainController or nil
    local gearString = tostring(gearValue or "")
    local mode, remoteIndex = _parseGearMode(gearString)
    if numericGear and gearString == tostring(numericGear) and dev.setGearIndex then
      local minGear = tonumber(dev.minGearIndex) or -1
      local maxGear = tonumber(dev.maxGearIndex) or 6
      local clamped = math.max(minGear, math.min(maxGear, math.floor(numericGear)))
      if not _ratioExists(dev, clamped) then
        _bump("invalidRatio")
        _logVerbose("ratio_controller_" .. tostring(clamped), 'gear skip missing controller ratio value=' .. tostring(gearValue)
          .. ' clamped=' .. tostring(clamped)
          .. ' type=' .. tostring(dev.type))
        return
      end
      local ok = pcall(dev.setGearIndex, dev, clamped)
      if ok then _bump("gearApplied") else _bump("gearSkipped") end
      return
    elseif main and mode and mode == "M" and remoteIndex and electrics and electrics.values and electrics.values.gearIndex then
      if electrics.values.gearIndex < remoteIndex and main.shiftUpOnDown then
        pcall(main.shiftUpOnDown)
        _bump("gearApplied")
        return
      elseif electrics.values.gearIndex > remoteIndex and main.shiftDownOnDown then
        pcall(main.shiftDownOnDown)
        _bump("gearApplied")
        return
      end
      _bump("gearSkipped")
      return
    elseif main and mode and GEAR_MODE_INDEX[mode] and main.shiftToGearIndex then
      pcall(main.shiftToGearIndex, GEAR_MODE_INDEX[mode])
      _bump("gearApplied")
      return
    end
  end

  _bump("gearSkipped")
  _logVerbose("no_api_" .. tostring(dev.type), 'gear skip no safe API value=' .. tostring(gearValue)
    .. ' type=' .. tostring(dev.type)
    .. ' device=' .. tostring(devName))
  -- Do NOT write gear_A directly to electrics — the gearbox reads it on
  -- the next updateGFX and if the value is invalid, desiredGearRatio is nil.
end

function M.applyInputs(data)
  if not isRemote or type(data) ~= "table" then return end

  -- Readiness guard: skip gear changes until gearbox has initialized
  local now = os.clock()
  local ready = (now - activationTime) >= READINESS_DELAY_SEC

  -- Real elapsed time since the last applied input packet, used as the
  -- smoothing timestep so the animation rate is independent of packet cadence
  -- and framerate. Clamped to stay stable across jitter and long gaps.
  local applyDt = _lastApplyAt and math.max(APPLY_DT_MIN, math.min(APPLY_DT_MAX, now - _lastApplyAt)) or (1 / 60)
  _lastApplyAt = now

  for key, target in pairs(data) do
    if key == "s" or key == "t" or key == "b" or key == "p" or key == "c" then
      local inputName = ({ s = "steering", t = "throttle", b = "brake", p = "parkingbrake", c = "clutch" })[key]
      local current = smoothing[key] or 0
      local targetVal = tonumber(target) or 0

      if key == "s" then
        local lock = _getSteeringLock()
        targetVal = targetVal * 450 / lock
      end

      -- The old one-sided steering limit test snapped every negative value but
      -- smoothed positive values, producing asymmetric remote wheel motion.
      if _shouldSnapInput(key, targetVal, current) then
        smoothing[key] = targetVal
      else
        local alpha = 1 - math.exp(-SMOOTH_RATE * applyDt)
        smoothing[key] = current + (targetVal - current) * alpha
      end

      if input and input.event then
        pcall(input.event, inputName, smoothing[key], 1, nil, nil, nil, "HighBeam")
        _bump("inputsApplied")
      end
    elseif key == "g" and ready then
      M._applyGear(tonumber(target) or 0)
    elseif key == "g" then
      _bump("gearSkipped")
    end
  end
end

function M.getInputActivity()
  if not isRemote then return 0 end
  local t = math.abs(smoothing.t or 0)
  local b = math.abs(smoothing.b or 0)
  return math.max(t, b)
end

function M.onHighBeamRemoteReset()
  smoothing = { s = 0, t = 0, b = 0, p = 0, c = 0 }
end

M.init = M.onInit
M.onExtensionLoaded = M.onInit

if rawget(_G, "HIGHBEAM_TEST") then
  M._testShouldSnapInput = _shouldSnapInput
end

return M
