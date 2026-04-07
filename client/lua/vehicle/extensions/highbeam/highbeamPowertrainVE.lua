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

  for key, val in pairs(data) do
    if key:sub(1, 4) == "dev_" then
      local devName = key:sub(5)
      if powertrain and powertrain.getDevice then
        local ok, dev = pcall(powertrain.getDevice, devName)
        if ok and dev and dev.setMode then
          pcall(dev.setMode, dev, val)
        end
      end
    elseif key == "ignLevel" then
      if electrics and electrics.setIgnitionLevel then
        pcall(electrics.setIgnitionLevel, val)
      elseif electrics and electrics.values then
        electrics.values.ignitionLevel = val
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

-- Controller system dispatches init(), not onInit().
M.init = M.onInit

return M
