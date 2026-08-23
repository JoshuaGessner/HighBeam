local M = {}
M.type = "auxiliary"

local isRemote = false
local isActive = false
local gameVehicleId = 0
local initialized = false

local trackedDevices = {}
local trackedEngines = {}
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
local desiredRemoteState = {}
local pendingRemoteState = nil
local _applyPowertrainNow

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

local function _findEngine(name)
  if name and powertrain and powertrain.getDevice then
    local okNamed, named = pcall(powertrain.getDevice, name)
    if okNamed and named and named.type == "combustionEngine" then return named end
  end
  if not powertrain or not powertrain.getDevices then return nil end
  local ok, devices = pcall(powertrain.getDevices)
  if not ok or not devices then return nil end
  local names = {}
  for deviceName, dev in pairs(devices) do
    if dev and dev.type == "combustionEngine" then names[#names + 1] = tostring(deviceName) end
  end
  table.sort(names)
  if #names == 0 then return nil end
  if powertrain.getDevice then
    local okFirst, first = pcall(powertrain.getDevice, names[1])
    if okFirst and first then return first end
  end
  return devices[names[1]]
end

local function _mergeState(dst, src)
  dst = dst or {}
  if type(src) ~= "table" then return dst end
  for key, value in pairs(src) do
    if key == "engines" and type(value) == "table" then
      dst.engines = dst.engines or {}
      for engineName, engineState in pairs(value) do
        dst.engines[engineName] = dst.engines[engineName] or {}
        if type(engineState) == "table" then
          for stateKey, stateValue in pairs(engineState) do
            dst.engines[engineName][stateKey] = stateValue
          end
        end
      end
    else
      dst[key] = value
    end
  end
  return dst
end

local function _copyState(src)
  return _mergeState({}, src)
end

function M.onInit()
  if obj and obj.getID then
    gameVehicleId = obj:getID()
  end
  if initialized then return end
  initialized = true
  trackedEngines = {}
  desiredRemoteState = {}
  pendingRemoteState = nil
end

function M.setActive(active, remote)
  M.onInit()
  isActive = active and true or false
  isRemote = remote and true or false
  if isActive and isRemote then
    activationTime = os.clock()
    _applyBlockedCount = 0
    _applySuccessCount = 0
    pendingRemoteState = _copyState(desiredRemoteState)
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

  if not isActive then return end

  if isRemote then
    if pendingRemoteState and (os.clock() - activationTime) >= READINESS_DELAY_SEC then
      local pending = pendingRemoteState
      pendingRemoteState = nil
      _applyPowertrainNow(pending)
    end
    return
  end

  resyncTimer = resyncTimer + (dt or 0)
  local changed = false
  local delta = {}

  if powertrain and powertrain.getDevices then
    local ok, devices = pcall(powertrain.getDevices)
    if ok and devices then
      local engineStates = {}
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
          local engineName = tostring(name)
          local previous = trackedEngines[engineName] or {}
          local engineDelta = {}
          if previous.ignCoef ~= ignCoef then engineDelta.ignCoef = ignCoef end
          if previous.starterCoef ~= starterCoef then engineDelta.starterCoef = starterCoef end
          if previous.stalled ~= stalled then engineDelta.stalled = stalled end
          if next(engineDelta) then
            delta.engines = delta.engines or {}
            delta.engines[engineName] = engineDelta
            changed = true
          end
          trackedEngines[engineName] = { ignCoef = ignCoef, starterCoef = starterCoef, stalled = stalled }
          engineStates[engineName] = trackedEngines[engineName]
        end
      end

      -- Legacy peers understand only one set of top-level engine fields.
      -- Mirror the lexicographically first engine while newer peers use the
      -- lossless per-engine `engines` map above.
      local engineNames = {}
      for name, _ in pairs(engineStates) do engineNames[#engineNames + 1] = name end
      table.sort(engineNames)
      local legacy = engineStates[engineNames[1]]
      if legacy then
        if legacy.ignCoef ~= lastIgnitionCoef then delta.ignCoef = legacy.ignCoef; lastIgnitionCoef = legacy.ignCoef; changed = true end
        if legacy.starterCoef ~= lastStarterCoef then delta.starterCoef = legacy.starterCoef; lastStarterCoef = legacy.starterCoef; changed = true end
        if legacy.stalled ~= lastIsStalled then delta.stalled = legacy.stalled; lastIsStalled = legacy.stalled; changed = true end
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
    delta.engines = {}
    for name, engineState in pairs(trackedEngines) do
      delta.engines[name] = {
        ignCoef = engineState.ignCoef,
        starterCoef = engineState.starterCoef,
        stalled = engineState.stalled,
      }
    end
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

local function _applyEngineState(engineName, state)
  if type(state) ~= "table" then return end
  local eng = _findEngine(engineName)
  if not eng then
    _bump("unsupportedDevice")
    _logVerboseOnce("missing_engine_" .. tostring(engineName),
      'powertrain skip missing combustion engine=' .. tostring(engineName))
    return
  end

  if state.ignCoef ~= nil then
    if eng.setIgnition then
      pcall(eng.setIgnition, eng, tonumber(state.ignCoef) or 0)
      _bump("ignition")
    else
      _bump("unsafeField")
    end
  end
  if state.starterCoef ~= nil then
    local starter = tonumber(state.starterCoef) or 0
    if starter > 0 and eng.activateStarter then
      pcall(eng.activateStarter, eng)
      _bump("starter")
    elseif starter <= 0 and eng.deactivateStarter then
      pcall(eng.deactivateStarter, eng)
      _bump("starter")
    end
  end
  if tonumber(state.stalled) == 1 and eng.cutIgnition then
    pcall(eng.cutIgnition, eng)
    _bump("stalled")
  end
end

_applyPowertrainNow = function(data)
  local hasPerEngineState = type(data.engines) == "table"
  for key, val in pairs(data) do
    if key == "engines" and type(val) == "table" then
      for engineName, engineState in pairs(val) do
        _applyEngineState(tostring(engineName), engineState)
      end
    elseif type(key) == "string" and key:sub(1, 4) == "dev_" then
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
      if not hasPerEngineState then _applyEngineState(nil, { ignCoef = val }) end
    elseif key == "starterCoef" then
      if not hasPerEngineState then _applyEngineState(nil, { starterCoef = val }) end
    elseif key == "stalled" then
      if not hasPerEngineState then _applyEngineState(nil, { stalled = val }) end
    else
      _bump("skipped")
      _logVerboseOnce("unknown_key_" .. tostring(key), 'powertrain skip unknown key=' .. tostring(key))
    end
  end
end

function M.applyPowertrain(data)
  if not isRemote or type(data) ~= "table" then return false end

  desiredRemoteState = _mergeState(desiredRemoteState, data)
  if (os.clock() - activationTime) < READINESS_DELAY_SEC then
    pendingRemoteState = _mergeState(pendingRemoteState or {}, data)
    _applyBlockedCount = _applyBlockedCount + 1
    _bump("blocked")
    return false
  end

  if pendingRemoteState then
    pendingRemoteState = _mergeState(pendingRemoteState, data)
    local pending = pendingRemoteState
    pendingRemoteState = nil
    _applyPowertrainNow(_mergeState(_copyState(desiredRemoteState), pending))
    if type(data.engines) ~= "table" then _applyPowertrainNow(data) end
  else
    -- Apply the complete desired state. In particular, a stalled=0 delta must
    -- replay the retained ignition coefficient so an engine previously cut by
    -- stalled=1 can recover even though there is no universal "unstall" API.
    _applyPowertrainNow(desiredRemoteState)
    if type(data.engines) ~= "table" then _applyPowertrainNow(data) end
  end
  return true
end

function M.onHighBeamRemoteReset()
  activationTime = os.clock()
  pendingRemoteState = _copyState(desiredRemoteState)
end

function M.onReset()
  if isRemote then
    M.onHighBeamRemoteReset()
  else
    -- Vehicle Lua resets may recreate engine state without changing its values.
    -- Forget sender-side hashes so the next frame emits a complete snapshot.
    trackedDevices = {}
    trackedEngines = {}
    lastIgnitionCoef = -1
    lastStarterCoef = -1
    lastIsStalled = -1
    lastIgnitionLevel = -1
    resyncTimer = RESYNC_INTERVAL
  end
end

M.init = M.onInit
M.onExtensionLoaded = M.onInit

if rawget(_G, "HIGHBEAM_TEST") then
  M._testSetReady = function() activationTime = -1000000 end
  M._testGetPendingState = function() return pendingRemoteState end
  M._testGetDesiredState = function() return desiredRemoteState end
end

return M
