local M = {}
M.type = "auxiliary"

local isRemote = false
local isActive = false
local gameVehicleId = 0
local initialized = false

local trackedDevices = {}
local lastIgnitionCoef = -1
local lastStarterCoef = -1
local lastIsStalled = -1
local lastIgnitionLevel = -1
local resyncTimer = 0
local RESYNC_INTERVAL = 10.0

-- Simple readiness guard: wait a short period after activation before applying
-- any powertrain writes, giving the stock powertrain time to fully initialize.
-- With the extension architecture, stock controllers are never corrupted, so
-- we only need a brief hold rather than the multi-phase warmup needed before.
local activationTime = 0
local READINESS_DELAY_SEC = 0.5

local _applyBlockedCount = 0
local _applySuccessCount = 0
local _diag = {
  applied = 0,
  skipped = 0,
  blocked = 0,
  unsupportedDevice = 0,
  unsupportedMode = 0,
  unsafeField = 0,
  starter = 0,
  ignition = 0,
  stalled = 0,
}
local _diagTimer = 0
local _diagIntervalSec = 5.0
local _unsupportedLogged = {}

local function _verboseSyncLoggingEnabled()
  local okCfg, cfg = pcall(require, "highbeam/config")
  return okCfg and cfg and cfg.get and cfg.get("verboseSyncLogging") == true
end

local function _bump(name)
  _diag[name] = (_diag[name] or 0) + 1
end

local function _logVerboseOnce(key, message)
  if not _verboseSyncLoggingEnabled() then return end
  if _unsupportedLogged[key] then return end
  _unsupportedLogged[key] = true
  log('D', 'HighBeam.PowertrainVE', message)
end

local function _formatDiag()
  local parts = {}
  for k, v in pairs(_diag) do
    if v and v > 0 then
      parts[#parts + 1] = k .. '=' .. tostring(v)
    end
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

local function _findEngine()
  if not powertrain or not powertrain.getDevices then return nil end
  local ok, devices = pcall(powertrain.getDevices)
  if not ok or not devices then return nil end
  for _, dev in pairs(devices) do
    if dev.type == "combustionEngine" then
      return dev
    end
  end
  return nil
end

function M.onInit()
  if obj and obj.getID then
    gameVehicleId = obj:getID()
  end
  if initialized then return end
  initialized = true
end

function M.setActive(active, remote)
  M.onInit()
  isActive = active and true or false
  isRemote = remote and true or false
  if isActive and isRemote then
    activationTime = os.clock()
    _applyBlockedCount = 0
    _applySuccessCount = 0
  end
end

function M.updateGFX(dt)
  _diagTimer = _diagTimer + (dt or 0)
  if _diagTimer >= _diagIntervalSec then
    _diagTimer = 0
    if _hasDiagValues() then
      log('I', 'HighBeam.PowertrainVE', 'Powertrain apply diag=' .. _formatDiag())
      _diag = {
        applied = 0,
        skipped = 0,
        blocked = 0,
        unsupportedDevice = 0,
        unsupportedMode = 0,
        unsafeField = 0,
        starter = 0,
        ignition = 0,
        stalled = 0,
      }
    end
  end

  if not isActive or isRemote then return end

  resyncTimer = resyncTimer + (dt or 0)
  local changed = false
  local delta = {}

  if powertrain and powertrain.getDevices then
    local ok, devices = pcall(powertrain.getDevices)
    if ok and devices then
      for name, dev in pairs(devices) do
        if dev.mode and trackedDevices[name] ~= dev.mode then
          delta["dev_" .. tostring(name)] = dev.mode
          trackedDevices[name] = dev.mode
          changed = true
        end

        if dev.type == "combustionEngine" then
          local ignCoef = tonumber(dev.ignitionCoef or 0) or 0
          local starterCoef = tonumber(dev.starterEngagedCoef or 0) or 0
          local stalled = dev.isStalled and 1 or 0

          if ignCoef ~= lastIgnitionCoef then delta.ignCoef = ignCoef; lastIgnitionCoef = ignCoef; changed = true end
          if starterCoef ~= lastStarterCoef then delta.starterCoef = starterCoef; lastStarterCoef = starterCoef; changed = true end
          if stalled ~= lastIsStalled then delta.stalled = stalled; lastIsStalled = stalled; changed = true end
        end
      end
    end
  end

  local ignLevel = electrics and electrics.values and tonumber(electrics.values.ignitionLevel or 0) or 0
  if ignLevel ~= lastIgnitionLevel then
    delta.ignLevel = ignLevel
    lastIgnitionLevel = ignLevel
    changed = true
  end

  if resyncTimer >= RESYNC_INTERVAL then
    resyncTimer = 0
    for name, mode in pairs(trackedDevices) do
      delta["dev_" .. tostring(name)] = mode
    end
    delta.ignCoef = lastIgnitionCoef
    delta.starterCoef = lastStarterCoef
    delta.stalled = lastIsStalled
    delta.ignLevel = lastIgnitionLevel
    changed = true
  end

  if changed and obj and obj.queueGameEngineLua then
    obj:queueGameEngineLua(string.format(
      "extensions.highbeam.onVEPowertrain(%d,%q)",
      gameVehicleId,
      _jsonEncode(delta)
    ))
  end
end

function M.applyPowertrain(data)
  if not isRemote or type(data) ~= "table" then return end

  local now = os.clock()
  local elapsed = now - activationTime

  -- Brief readiness hold so stock powertrain finishes init after spawn.
  if elapsed < READINESS_DELAY_SEC then
    _applyBlockedCount = _applyBlockedCount + 1
    _bump("blocked")
    return
  end

  for key, val in pairs(data) do
    if key:sub(1, 4) == "dev_" then
      local devName = key:sub(5)
      if powertrain and powertrain.getDevice and type(val) == "string" then
        local ok, dev = pcall(powertrain.getDevice, devName)
        if not ok or not dev then
          _bump("unsupportedDevice")
          _logVerboseOnce("missing_device_" .. devName, 'powertrain skip missing device=' .. tostring(devName))
        elseif not dev.setMode then
          _bump("unsupportedMode")
          _logVerboseOnce("missing_setmode_" .. devName, 'powertrain skip device without setMode device=' .. tostring(devName)
            .. ' type=' .. tostring(dev.type))
        else
          local okMode = pcall(dev.setMode, dev, val)
          if okMode then
            _applySuccessCount = _applySuccessCount + 1
            _bump("applied")
          else
            _bump("unsupportedMode")
            _logVerboseOnce("mode_failed_" .. devName .. '_' .. tostring(val), 'powertrain mode failed device=' .. tostring(devName)
              .. ' type=' .. tostring(dev.type)
              .. ' mode=' .. tostring(val))
          end
        end
      else
        _bump("skipped")
      end
    elseif key == "ignLevel" then
      local level = tonumber(val) or 0
      if electrics and electrics.setIgnitionLevel then
        pcall(electrics.setIgnitionLevel, level)
        _bump("ignition")
      elseif electrics and electrics.values then
        electrics.values.ignitionLevel = level
        _bump("ignition")
      else
        _bump("skipped")
        _logVerboseOnce("missing_electrics_ignition", 'powertrain skip ignitionLevel no electrics API')
      end
    elseif key == "ignCoef" then
      local eng = _findEngine()
      if eng and eng.setIgnition then
        pcall(eng.setIgnition, eng, tonumber(val) or 0)
        _bump("ignition")
      else
        _bump("unsafeField")
        _logVerboseOnce("unsafe_ignCoef", 'powertrain skipped unsafe direct ignitionCoef write hasEngine=' .. tostring(eng ~= nil))
      end
    elseif key == "starterCoef" then
      local eng = _findEngine()
      if eng then
        if val and val > 0 and eng.activateStarter then pcall(eng.activateStarter, eng); _bump("starter") end
        if (not val or val <= 0) and eng.deactivateStarter then pcall(eng.deactivateStarter, eng); _bump("starter") end
      else
        _bump("skipped")
        _logVerboseOnce("missing_engine_starter", 'powertrain skip starter no combustion engine')
      end
    elseif key == "stalled" then
      local eng = _findEngine()
      if eng and val == 1 and eng.cutIgnition then
        pcall(eng.cutIgnition, eng)
        _bump("stalled")
      else
        _bump("skipped")
      end
    else
      _bump("skipped")
      _logVerboseOnce("unknown_key_" .. tostring(key), 'powertrain skip unknown key=' .. tostring(key))
    end
  end
end

function M.onHighBeamRemoteReset()
  activationTime = os.clock()
end

M.init = M.onInit
M.onExtensionLoaded = M.onInit

return M
