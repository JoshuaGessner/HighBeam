local M = {}
M.type = "auxiliary"

local isRemote = false
local isActive = false
local gameVehicleId = 0
local initialized = false

local lastSent = { s = 0, t = 0, b = 0, p = 0, c = 0, g = 0, l = 450, k = nil }
local ROUND_FACTOR = 10000
local SEND_THRESHOLD = 0.001
local gearResyncTimer = 0
local GEAR_RESYNC_INTERVAL = 5.0

-- Readiness guard: wait after activation before applying gear changes,
-- giving the gearbox time to fully initialize its ratio tables.
local activationTime = 0
local READINESS_DELAY_SEC = 0.5

local smoothing = { s = 0, t = 0, b = 0, p = 0, c = 0 }
local desiredInputs = { s = 0, t = 0, b = 0, p = 0, c = 0 }
local desiredGear = nil
local desiredGearSchema = nil
local remoteSteeringLock = 450
local gearPending = false
local gearRetryTimer = 0
local SMOOTH_RATE = 30
local SNAP_THRESHOLD = 0.2
local LIMIT_SNAP = 0.05
local APPLY_DT_MIN = 0.005
local APPLY_DT_MAX = 0.1

local INPUT_NAMES = { "steering", "throttle", "brake", "parkingbrake", "clutch" }
local INPUT_KEYS = { "s", "t", "b", "p", "c" }
local INPUT_NAME_BY_KEY = { s = "steering", t = "throttle", b = "brake", p = "parkingbrake", c = "clutch" }
local INPUT_SOURCE = "HighBeam"
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

local GEARBOX_SCHEMA = {
  manualGearbox = "manual",
  sequentialGearbox = "sequential",
  dctGearbox = "automatic",
  automaticGearbox = "automatic",
  cvtGearbox = "cvt",
  electricMotor = "electric",
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

local function _gearSchema(dev)
  return (dev and GEARBOX_SCHEMA[dev.type]) or "unknown"
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

local function _setInputSourceLifecycle(remoteEnabled)
  if not input or not input.setAllowedInputSource then return end
  local names = {}
  for _, name in ipairs(INPUT_NAMES) do names[name] = true end
  if type(input.state) == "table" then
    for name, _ in pairs(input.state) do names[name] = true end
  end
  for name, _ in pairs(names) do
    -- Remote puppets must accept only HighBeam's synthetic input while local
    -- vehicles must retain their normal local controls. Make both halves
    -- explicit so controller reloads and reconnects cannot leave a stale deny.
    pcall(input.setAllowedInputSource, name, INPUT_SOURCE, remoteEnabled and true or false)
    pcall(input.setAllowedInputSource, name, "local", not remoteEnabled)
  end
end

local function _emitContinuousInputs(dt)
  if not input or not input.event then return end
  local step = math.max(APPLY_DT_MIN, math.min(APPLY_DT_MAX, tonumber(dt) or (1 / 60)))
  for _, key in ipairs(INPUT_KEYS) do
    local targetVal = tonumber(desiredInputs[key]) or 0
    if key == "s" then
      -- The wire value is referenced to a 450-degree wheel. Convert it back
      -- using the sender's advertised lock; the receiver's lock must not
      -- change the driver's normalized steering command.
      targetVal = targetVal * 450 / math.max(remoteSteeringLock, 1)
      targetVal = math.max(-1, math.min(1, targetVal))
    else
      targetVal = math.max(0, math.min(1, targetVal))
    end

    local current = smoothing[key] or 0
    if _shouldSnapInput(key, targetVal, current) then
      smoothing[key] = targetVal
    else
      local alpha = 1 - math.exp(-SMOOTH_RATE * step)
      smoothing[key] = current + (targetVal - current) * alpha
    end
    pcall(input.event, INPUT_NAME_BY_KEY[key], smoothing[key], 1, nil, nil, nil, INPUT_SOURCE)
    _bump("inputsApplied")
  end
end

function M.onInit()
  if obj and obj.getID then
    gameVehicleId = obj:getID()
  end
  if initialized then return end
  initialized = true
  lastSent = { s = 0, t = 0, b = 0, p = 0, c = 0, g = 0, l = 450, k = nil }
  smoothing = { s = 0, t = 0, b = 0, p = 0, c = 0 }
  desiredInputs = { s = 0, t = 0, b = 0, p = 0, c = 0 }
end

function M.setActive(active, remote)
  M.onInit()
  local wasRemoteActive = isActive and isRemote
  isActive = active and true or false
  isRemote = remote and true or false
  if isActive and isRemote then
    activationTime = os.clock()
    gearRetryTimer = 0
  elseif isActive then
    -- Controller activation is a wire resynchronization boundary. Advertise a
    -- complete input state including steering lock and gearbox schema.
    lastSent = {}
    gearResyncTimer = GEAR_RESYNC_INTERVAL
  end
  if wasRemoteActive and not (isActive and isRemote) then
    desiredInputs = { s = 0, t = 0, b = 0, p = 0, c = 0 }
    _emitContinuousInputs(1 / 60)
  end
  _setInputSourceLifecycle(isActive and isRemote)
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

  if not isActive then return end

  if isRemote then
    _emitContinuousInputs(dt)
    gearRetryTimer = gearRetryTimer + (dt or 0)
    if gearPending and (os.clock() - activationTime) >= READINESS_DELAY_SEC and gearRetryTimer >= 0.05 then
      gearRetryTimer = 0
      local applied, retryable = M._applyGear(desiredGear)
      if applied or not retryable then gearPending = false end
    end
    return
  end

  local e = electrics and electrics.values or {}
  local lock = _getSteeringLock()
  local s = _round4((e.steering_input or 0) * lock / 450)
  local t = _round4(e.throttle_input or 0)
  local b = _round4(e.brake_input or 0)
  local p = _round4(e.parkingbrake_input or 0)
  local c = _round4(e.clutch_input or 0)
  -- `gear` carries automatic modes (P/R/N/D/S/M2); `gear_A` is the legacy
  -- numeric fallback used by manuals and older vehicles.
  local g = e.gear
  if g == nil or g == "" then g = tonumber(e.gear_A or 0) or 0 end
  local gearbox = _findGearbox()
  local schema = _gearSchema(gearbox)

  local changed = false
  local delta = {}

  if math.abs(s - (lastSent.s or 0)) > SEND_THRESHOLD then delta.s = s; changed = true end
  if math.abs(t - (lastSent.t or 0)) > SEND_THRESHOLD then delta.t = t; changed = true end
  if math.abs(b - (lastSent.b or 0)) > SEND_THRESHOLD then delta.b = b; changed = true end
  if math.abs(p - (lastSent.p or 0)) > SEND_THRESHOLD then delta.p = p; changed = true end
  if math.abs(c - (lastSent.c or 0)) > SEND_THRESHOLD then delta.c = c; changed = true end
  if math.abs(lock - (lastSent.l or 0)) >= 0.5 then delta.l = math.floor(lock + 0.5); changed = true end
  if schema ~= lastSent.k then delta.k = schema; changed = true end

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
    return false, true
  end

  local handler = GEARBOX_HANDLER[dev.type]
  if not handler then
    _bump("unsupportedGearbox")
    _logVerbose("unsupported_" .. tostring(dev.type), 'gear skip unsupported gearbox type=' .. tostring(dev.type)
      .. ' device=' .. tostring(devName)
      .. ' value=' .. tostring(gearValue))
    return false, false
  end

  local actualSchema = _gearSchema(dev)
  if desiredGearSchema and desiredGearSchema ~= "unknown" and actualSchema ~= desiredGearSchema then
    _bump("unsupportedGearbox")
    _logVerbose("schema_" .. tostring(desiredGearSchema) .. "_" .. tostring(actualSchema),
      'gear schema mismatch sender=' .. tostring(desiredGearSchema)
        .. ' receiver=' .. tostring(actualSchema) .. ' value=' .. tostring(gearValue))
    return false, false
  end

  local numericGear = tonumber(gearValue)
  if handler == "index" then
    if not numericGear then
      _bump("gearSkipped")
      _logVerbose("invalid_numeric_" .. tostring(gearValue), 'gear skip nonnumeric value=' .. tostring(gearValue)
        .. ' type=' .. tostring(dev.type))
      return false, false
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
      return false, false
    end
    if dev.setGearIndex then
      local ok = pcall(dev.setGearIndex, dev, clamped)
      if ok then _bump("gearApplied") else _bump("gearSkipped") end
      return ok, not ok
    end
  end

  if handler == "controller" then
    if electrics and electrics.values and electrics.values.isShifting then
      _bump("gearSkipped")
      return false, true
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
        return false, false
      end
      local ok = pcall(dev.setGearIndex, dev, clamped)
      if ok then _bump("gearApplied") else _bump("gearSkipped") end
      return ok, not ok
    elseif main and mode and mode == "M" and remoteIndex and electrics and electrics.values and electrics.values.gearIndex then
      if electrics.values.gearIndex < remoteIndex and main.shiftUpOnDown then
        pcall(main.shiftUpOnDown)
        _bump("gearApplied")
        return true, false
      elseif electrics.values.gearIndex > remoteIndex and main.shiftDownOnDown then
        pcall(main.shiftDownOnDown)
        _bump("gearApplied")
        return true, false
      end
      _bump("gearSkipped")
      return true, false
    elseif main and mode and GEAR_MODE_INDEX[mode] and main.shiftToGearIndex then
      local ok = pcall(main.shiftToGearIndex, GEAR_MODE_INDEX[mode])
      if ok then _bump("gearApplied") else _bump("gearSkipped") end
      return ok, not ok
    end
  end

  _bump("gearSkipped")
  _logVerbose("no_api_" .. tostring(dev.type), 'gear skip no safe API value=' .. tostring(gearValue)
    .. ' type=' .. tostring(dev.type)
    .. ' device=' .. tostring(devName))
  -- Do NOT write gear_A directly to electrics — the gearbox reads it on
  -- the next updateGFX and if the value is invalid, desiredGearRatio is nil.
  return false, false
end

function M.applyInputs(data)
  if not isRemote or type(data) ~= "table" then return end

  if data.l ~= nil then
    remoteSteeringLock = math.max(1, math.min(4096, tonumber(data.l) or 450))
  end
  if data.k ~= nil then
    local schema = tostring(data.k)
    if schema == "manual" or schema == "sequential" or schema == "automatic"
      or schema == "cvt" or schema == "electric" or schema == "unknown" then
      desiredGearSchema = schema
    end
  end

  for key, target in pairs(data) do
    if key == "s" or key == "t" or key == "b" or key == "p" or key == "c" then
      -- Network packets may be deltas. Merge them into a complete desired
      -- state; updateGFX owns smoothing and event delivery every frame.
      desiredInputs[key] = tonumber(target) or 0
    elseif key == "g" then
      -- Preserve strings such as D, R, S, and M2 for automatic gearboxes;
      -- legacy numeric gear indices remain accepted by _applyGear.
      desiredGear = target
      gearPending = true
      gearRetryTimer = 0.05
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
  -- Reset interpolation, but retain the complete authoritative desired state.
  -- A reset while throttle or steering is held must resume that command
  -- without waiting for another edge-triggered input change.
  smoothing = { s = 0, t = 0, b = 0, p = 0, c = 0 }
  activationTime = os.clock()
  gearPending = desiredGear ~= nil
  gearRetryTimer = 0
  if isActive and isRemote then _emitContinuousInputs(1 / 60) end
end

function M.onReset()
  if isRemote then
    M.onHighBeamRemoteReset()
  else
    -- Force a complete post-reset delta, including an unchanged gear mode.
    lastSent = {}
    gearResyncTimer = GEAR_RESYNC_INTERVAL
  end
end

M.init = M.onInit
M.onExtensionLoaded = M.onInit

if rawget(_G, "HIGHBEAM_TEST") then
  M._testShouldSnapInput = _shouldSnapInput
  M._testSetReady = function() activationTime = -1000000; gearRetryTimer = 1 end
  M._testGetState = function()
    return desiredInputs, smoothing, desiredGear, gearPending, remoteSteeringLock, desiredGearSchema
  end
end

return M
