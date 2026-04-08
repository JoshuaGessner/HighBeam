local M = {}
M.name = "highbeam_highbeamPowertrainVE"

local isRemote = false
local isActive = false
local gameVehicleId = 0

local trackedDevices = {}
local lastIgnitionCoef = -1
local lastStarterCoef = -1
local lastIsStalled = -1
local lastIgnitionLevel = -1
local resyncTimer = 0
local RESYNC_INTERVAL = 10.0

-- Warmup timers to prevent gearbox crash on remote vehicles.
-- BeamNG's automaticGearbox needs time after spawn to compute desiredGearRatio;
-- setting device modes or ignition before that causes FATAL LUA ERROR.
local activationTime = 0           -- os.clock() when setActive(true, true) was called
local WARMUP_FULL_SEC = 1.0        -- block ALL powertrain writes for this long
local WARMUP_GEARBOX_SEC = 3.0     -- block gearbox setMode for this long
local WARMUP_IGNITION_PHASE1_SEC = 2.0  -- allow ignLevel<=1 after FULL; ignLevel 2 after this

local GEARBOX_TYPES = {
  automaticGearbox = true,
  manualGearbox = true,
  dctGearbox = true,
  cvtGearbox = true,
}

local _applyBlockedCount = 0
local _applyGearboxBlockedCount = 0
local _applyIgnitionClampedCount = 0
local _applySuccessCount = 0
local _warmupPhaseLogged = 0  -- tracks which phase transitions have been logged

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
end

function M.setActive(active, remote)
  isActive = active and true or false
  isRemote = remote and true or false
  if isActive and isRemote then
    activationTime = os.clock()
    _applyBlockedCount = 0
    _applyGearboxBlockedCount = 0
    _applyIgnitionClampedCount = 0
    _applySuccessCount = 0
    _warmupPhaseLogged = 0
  end
end

function M.updateGFX(dt)
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

  -- Phase 1: Block ALL writes for WARMUP_FULL_SEC after activation.
  -- This gives BeamNG's stock powertrain time to fully initialize.
  if elapsed < WARMUP_FULL_SEC then
    _applyBlockedCount = _applyBlockedCount + 1
    return
  end

  -- Log phase transitions (once each)
  if _warmupPhaseLogged < 1 and elapsed >= WARMUP_FULL_SEC then
    _warmupPhaseLogged = 1
    if obj and obj.queueGameEngineLua then
      obj:queueGameEngineLua(string.format(
        "log('I','highbeamPowertrainVE','warmup phase 1 complete (%.2fs) vid=%d blocked=%d')",
        elapsed, gameVehicleId, _applyBlockedCount
      ))
    end
  end

  for key, val in pairs(data) do
    if key:sub(1, 4) == "dev_" then
      local devName = key:sub(5)
      if powertrain and powertrain.getDevice then
        local ok, dev = pcall(powertrain.getDevice, devName)
        if ok and dev and dev.setMode then
          -- Phase 2: Block gearbox mode changes until WARMUP_GEARBOX_SEC.
          -- automaticGearbox.desiredGearRatio is nil until the gearbox runs
          -- its own updateGFX cycle several times after ignition.
          if dev.type and GEARBOX_TYPES[dev.type] and elapsed < WARMUP_GEARBOX_SEC then
            _applyGearboxBlockedCount = _applyGearboxBlockedCount + 1
          else
            if _warmupPhaseLogged < 3 and dev.type and GEARBOX_TYPES[dev.type] and elapsed >= WARMUP_GEARBOX_SEC then
              _warmupPhaseLogged = 3
              if obj and obj.queueGameEngineLua then
                obj:queueGameEngineLua(string.format(
                  "log('I','highbeamPowertrainVE','gearbox warmup complete (%.2fs) vid=%d gearboxBlocked=%d')",
                  elapsed, gameVehicleId, _applyGearboxBlockedCount
                ))
              end
            end
            pcall(dev.setMode, dev, val)
            _applySuccessCount = _applySuccessCount + 1
          end
        end
      end
    elseif key == "ignLevel" then
      -- Phase 3: Clamp ignition level during warmup.
      -- Allow ignLevel 0-1 after WARMUP_FULL_SEC (accessories on).
      -- Allow ignLevel 2 (crank/run) only after WARMUP_IGNITION_PHASE1_SEC.
      local level = tonumber(val) or 0
      if level >= 2 and elapsed < WARMUP_IGNITION_PHASE1_SEC then
        level = 1
        _applyIgnitionClampedCount = _applyIgnitionClampedCount + 1
      elseif _warmupPhaseLogged < 2 and level >= 2 and elapsed >= WARMUP_IGNITION_PHASE1_SEC then
        _warmupPhaseLogged = math.max(_warmupPhaseLogged, 2)
        if obj and obj.queueGameEngineLua then
          obj:queueGameEngineLua(string.format(
            "log('I','highbeamPowertrainVE','ignition phase complete (%.2fs) vid=%d clamped=%d')",
            elapsed, gameVehicleId, _applyIgnitionClampedCount
          ))
        end
      end
      if electrics and electrics.setIgnitionLevel then
        pcall(electrics.setIgnitionLevel, level)
      elseif electrics and electrics.values then
        electrics.values.ignitionLevel = level
      end
    elseif key == "ignCoef" then
      local eng = _findEngine()
      if eng then eng.ignitionCoef = val end
    elseif key == "starterCoef" then
      local eng = _findEngine()
      if eng then
        if val and val > 0 and eng.activateStarter then pcall(eng.activateStarter, eng) end
        if (not val or val <= 0) and eng.deactivateStarter then pcall(eng.deactivateStarter, eng) end
      end
    elseif key == "stalled" then
      local eng = _findEngine()
      if eng and val == 1 and eng.cutIgnition then
        pcall(eng.cutIgnition, eng)
      end
    end
  end
end

function M.getWarmupDiag()
  local now = os.clock()
  local elapsed = now - activationTime
  return {
    elapsed = elapsed,
    fullBlocked = _applyBlockedCount,
    gearboxBlocked = _applyGearboxBlockedCount,
    ignitionClamped = _applyIgnitionClampedCount,
    applied = _applySuccessCount,
    warmupDone = elapsed >= WARMUP_GEARBOX_SEC,
  }
end

-- Controller system dispatches init(), not onInit().
M.init = M.onInit

return M
