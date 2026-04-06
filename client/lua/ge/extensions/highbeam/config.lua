local M = {}
local logTag = "HighBeam.Config"

M.defaults = {
  updateRate = 20,
  interpolation = true,
  interpolationDelayMs = 100,       -- P2.1: was 50; 100ms = 2 packets at 20Hz
  extrapolationMs = 120,
  jitterBufferSnapshots = 8,         -- P2.1: was 5; more headroom for jitter
  directConnectHost = "",
  directConnectPort = 18860,
  username = "",
  communityNodes = {},
  showChat = true,
  overlayVisible = true,
  overlayRefreshHz = 8,
  nametagRenderDistance = 200,
  nametagFadeNear = 30,
  nametagFontScale = 1.0,
  -- P0/P2/P3/P4: Sync optimization defaults
  debugOverlay = false,              -- P0: Show sync debug panel in overlay
  correctionBlendFactor = 0.10,      -- Fraction of error corrected per frame (smooth anti-jitter)
  correctionTeleportDist = 10.0,     -- P2.2: Distance (m) threshold for instant teleport
  adaptiveSendRate = true,           -- P3.1: Enable speed-based send rate
  maxAdaptiveSendRate = 45,          -- Cap adaptive update rate to reduce script load
  inputPollIntervalSec = 0.15,       -- Combined inputs + rotation poll interval
  electricsPollIntervalSec = 0.75,   -- Electrics poll interval
  damageFallbackPollSec = 8.0,       -- Sparse fallback damage scan interval
  lodDistanceNear = 200,             -- P3.4: Full-rate update distance (m)
  lodDistanceFar = 500,              -- P3.4: Reduced-rate update distance (m)
  directSteering = true,             -- P4.1: Use direct electrics instead of input.event
  verboseSyncLogging = false,        -- Enable detailed sync diagnostics in logs
  persistRemoteDamageOnReset = true, -- Keep remote damage after reset packets
  localResetDebounceSec = 0.75,      -- Debounce local reset packet emission
  remoteResetMinIntervalSec = 0.5,   -- Suppress duplicate inbound reset bursts
  veForceController = true,
  vePosCorrectMul = 5,
  vePosForceMul = 5,
  veMaxPosForce = 100,
  veRotCorrectMul = 7,
  veRotForceMul = 7,
  veMaxRotForce = 50,
  veTeleportBaseDist = 1.0,
  veTeleportSpeedScale = 0.1,
  inputSyncRate = 30,
  inputSmoothing = true,
  inputSmoothRate = 30,
  electricsSyncRate = 15,
}

M.current = {}
M._loadClampCount = 0

-- ──────────────────────── File helpers ───────────────────────────────

local CONFIG_DIR  = "userdata/highbeam"
local CONFIG_FILE = CONFIG_DIR .. "/config.json"

local function _ensureDir()
  if FS and FS.directoryCreate then
    pcall(function() FS:directoryCreate(CONFIG_DIR) end)
    return
  end
  local ok, lfs = pcall(require, 'lfs')
  if ok and lfs then pcall(lfs.mkdir, CONFIG_DIR); return end
  local sep = package.config:sub(1, 1)
  if sep == '\\' then
    pcall(function()
      os.execute('mkdir "' .. CONFIG_DIR:gsub('/', '\\') .. '" 2>nul')
    end)
  else
    pcall(function()
      os.execute('mkdir -p "' .. CONFIG_DIR .. '" 2>/dev/null')
    end)
  end
end

local function _readFile(path)
  if FS and FS.readFileToString then
    local ok, c = pcall(function() return FS:readFileToString(path) end)
    if ok and type(c) == "string" and c ~= "" then return c end
  end
  -- BeamNG global readFile fallback
  if readFile then
    local ok, c = pcall(readFile, path)
    if ok and type(c) == "string" and c ~= "" then return c end
  end
  local f = io.open(path, "r")
  if f then
    local c = f:read("*all")
    f:close()
    return c
  end
  return nil
end

local function _writeFile(path, content)
  _ensureDir()
  if FS and FS.writeFile then
    local ok = pcall(function() FS:writeFile(path, content) end)
    if ok then return true end
  end
  -- BeamNG global writeFile fallback
  if writeFile then
    local ok = pcall(writeFile, path, content)
    if ok then return true end
  end
  local f = io.open(path, "w")
  if f then
    f:write(content)
    f:close()
    return true
  end
  return false
end

local function _jsonEncode(t)
  if jsonEncode then
    local ok, s = pcall(jsonEncode, t)
    if ok then return s end
  end
  if Engine and Engine.JSONEncode then
    local ok, s = pcall(Engine.JSONEncode, t)
    if ok then return s end
  end
  local ok, json = pcall(require, "json")
  if ok and json then return json.encode(t) end
  return "{}"
end

local function _jsonDecode(s)
  if not s or s == "" then return nil end
  if jsonDecode then
    local ok, t = pcall(jsonDecode, s)
    if ok then return t end
  end
  if Engine and Engine.JSONDecode then
    local ok, t = pcall(Engine.JSONDecode, s)
    if ok then return t end
  end
  local ok, json = pcall(require, "json")
  if ok and json then
    local ok2, t = pcall(json.decode, s)
    if ok2 then return t end
  end
  return nil
end

local function _sanitizeNumber(key, value)
  if type(value) ~= "number" then return value, false end

  if key == "updateRate" then
    local out = math.max(5, math.min(60, math.floor(value + 0.5)))
    return out, out ~= value
  end
  if key == "interpolationDelayMs" then
    local out = math.max(0, math.min(500, math.floor(value + 0.5)))
    return out, out ~= value
  end
  if key == "extrapolationMs" then
    local out = math.max(0, math.min(500, math.floor(value + 0.5)))
    return out, out ~= value
  end
  if key == "jitterBufferSnapshots" then
    local out = math.max(2, math.min(20, math.floor(value + 0.5)))
    return out, out ~= value
  end
  if key == "directConnectPort" then
    local out = math.max(1, math.min(65535, math.floor(value + 0.5)))
    return out, out ~= value
  end
  if key == "maxAdaptiveSendRate" then
    local out = math.max(20, math.min(60, math.floor(value + 0.5)))
    return out, out ~= value
  end
  if key == "inputPollIntervalSec" then
    local out = math.max(0.05, math.min(0.5, value))
    return out, out ~= value
  end
  if key == "electricsPollIntervalSec" then
    local out = math.max(0.2, math.min(2.0, value))
    return out, out ~= value
  end
  if key == "damageFallbackPollSec" then
    local out = math.max(2.0, math.min(20.0, value))
    return out, out ~= value
  end
  if key == "correctionBlendFactor" then
    local out = math.max(0.01, math.min(1.0, value))
    return out, out ~= value
  end
  if key == "correctionTeleportDist" then
    local out = math.max(1.0, math.min(100.0, value))
    return out, out ~= value
  end
  if key == "lodDistanceNear" then
    local out = math.max(25, math.min(2000, math.floor(value + 0.5)))
    return out, out ~= value
  end
  if key == "lodDistanceFar" then
    local out = math.max(50, math.min(5000, math.floor(value + 0.5)))
    return out, out ~= value
  end
  if key == "overlayRefreshHz" then
    local out = math.max(1, math.min(60, math.floor(value + 0.5)))
    return out, out ~= value
  end
  if key == "localResetDebounceSec" then
    local out = math.max(0.1, math.min(3.0, value))
    return out, out ~= value
  end
  if key == "remoteResetMinIntervalSec" then
    local out = math.max(0.0, math.min(3.0, value))
    return out, out ~= value
  end
  if key == "vePosCorrectMul" or key == "vePosForceMul" then
    local out = math.max(1, math.min(20, value))
    return out, out ~= value
  end
  if key == "veMaxPosForce" then
    local out = math.max(10, math.min(500, value))
    return out, out ~= value
  end
  if key == "veRotCorrectMul" or key == "veRotForceMul" then
    local out = math.max(1, math.min(20, value))
    return out, out ~= value
  end
  if key == "veMaxRotForce" then
    local out = math.max(10, math.min(200, value))
    return out, out ~= value
  end
  if key == "veTeleportBaseDist" then
    local out = math.max(0.5, math.min(10.0, value))
    return out, out ~= value
  end
  if key == "veTeleportSpeedScale" then
    local out = math.max(0.0, math.min(1.0, value))
    return out, out ~= value
  end
  if key == "inputSyncRate" then
    local out = math.max(10, math.min(60, math.floor(value + 0.5)))
    return out, out ~= value
  end
  if key == "inputSmoothRate" then
    local out = math.max(10, math.min(100, math.floor(value + 0.5)))
    return out, out ~= value
  end
  if key == "electricsSyncRate" then
    local out = math.max(5, math.min(30, math.floor(value + 0.5)))
    return out, out ~= value
  end

  return value, false
end

-- ──────────────────────── Load / Save ────────────────────────────────

M.load = function()
  M._loadClampCount = 0
  -- Start from defaults
  for k, v in pairs(M.defaults) do
    M.current[k] = v
  end

  -- Overlay with persisted values
  local content = _readFile(CONFIG_FILE)
  if content then
    local saved = _jsonDecode(content)
    if type(saved) == "table" then
      for k, default in pairs(M.defaults) do
        local sv = saved[k]
        if sv ~= nil and type(sv) == type(default) then
          if type(default) == "number" then
            local sanitized, clamped = _sanitizeNumber(k, sv)
            M.current[k] = sanitized
            if clamped then
              M._loadClampCount = M._loadClampCount + 1
            end
          else
            M.current[k] = sv
          end
        end
      end
      log('I', logTag, 'Loaded saved config from disk'
        .. (M._loadClampCount > 0 and (' (clamped=' .. tostring(M._loadClampCount) .. ')') or ''))
    end
  else
    log('I', logTag, 'No saved config found; using defaults')
  end
end

M.save = function()
  local ok = pcall(function()
    _writeFile(CONFIG_FILE, _jsonEncode(M.current))
  end)
  if ok then
    log('I', logTag, 'Config saved to disk')
  else
    log('W', logTag, 'Failed to save config')
  end
end

-- ──────────────────────── Get / Set ──────────────────────────────────

M.get = function(key)
  return M.current[key]
end

M.set = function(key, value)
  if key == "updateRate" then
    local numeric = tonumber(value)
    if not numeric then return false end
    M.current.updateRate = math.max(5, math.min(60, math.floor(numeric + 0.5)))
    return true
  end

  if key == "interpolation" then
    M.current.interpolation = value and true or false
    return true
  end

  if key == "interpolationDelayMs" then
    local numeric = tonumber(value)
    if not numeric then return false end
    M.current.interpolationDelayMs = math.max(0, math.min(500, math.floor(numeric + 0.5)))
    return true
  end

  if key == "extrapolationMs" then
    local numeric = tonumber(value)
    if not numeric then return false end
    M.current.extrapolationMs = math.max(0, math.min(500, math.floor(numeric + 0.5)))
    return true
  end

  if key == "jitterBufferSnapshots" then
    local numeric = tonumber(value)
    if not numeric then return false end
    M.current.jitterBufferSnapshots = math.max(2, math.min(20, math.floor(numeric + 0.5)))
    return true
  end

  if key == "directConnectPort" then
    local numeric = tonumber(value)
    if not numeric then return false end
    M.current.directConnectPort = math.max(1, math.min(65535, math.floor(numeric + 0.5)))
    return true
  end

  if key == "maxAdaptiveSendRate" then
    local numeric = tonumber(value)
    if not numeric then return false end
    M.current.maxAdaptiveSendRate = math.max(20, math.min(60, math.floor(numeric + 0.5)))
    return true
  end

  if key == "inputPollIntervalSec" then
    local numeric = tonumber(value)
    if not numeric then return false end
    M.current.inputPollIntervalSec = math.max(0.05, math.min(0.5, numeric))
    return true
  end

  if key == "electricsPollIntervalSec" then
    local numeric = tonumber(value)
    if not numeric then return false end
    M.current.electricsPollIntervalSec = math.max(0.2, math.min(2.0, numeric))
    return true
  end

  if key == "damageFallbackPollSec" then
    local numeric = tonumber(value)
    if not numeric then return false end
    M.current.damageFallbackPollSec = math.max(2.0, math.min(20.0, numeric))
    return true
  end

  if key == "verboseSyncLogging" then
    M.current.verboseSyncLogging = value and true or false
    return true
  end

  if key == "persistRemoteDamageOnReset" then
    M.current.persistRemoteDamageOnReset = value and true or false
    return true
  end

  if key == "localResetDebounceSec" then
    local numeric = tonumber(value)
    if not numeric then return false end
    M.current.localResetDebounceSec = math.max(0.1, math.min(3.0, numeric))
    return true
  end

  if key == "remoteResetMinIntervalSec" then
    local numeric = tonumber(value)
    if not numeric then return false end
    M.current.remoteResetMinIntervalSec = math.max(0.0, math.min(3.0, numeric))
    return true
  end

  if key == "veForceController" or key == "inputSmoothing" then
    M.current[key] = value and true or false
    return true
  end

  if key == "vePosCorrectMul" or key == "vePosForceMul" then
    local numeric = tonumber(value)
    if not numeric then return false end
    M.current[key] = math.max(1, math.min(20, numeric))
    return true
  end

  if key == "veMaxPosForce" then
    local numeric = tonumber(value)
    if not numeric then return false end
    M.current.veMaxPosForce = math.max(10, math.min(500, numeric))
    return true
  end

  if key == "veRotCorrectMul" or key == "veRotForceMul" then
    local numeric = tonumber(value)
    if not numeric then return false end
    M.current[key] = math.max(1, math.min(20, numeric))
    return true
  end

  if key == "veMaxRotForce" then
    local numeric = tonumber(value)
    if not numeric then return false end
    M.current.veMaxRotForce = math.max(10, math.min(200, numeric))
    return true
  end

  if key == "veTeleportBaseDist" then
    local numeric = tonumber(value)
    if not numeric then return false end
    M.current.veTeleportBaseDist = math.max(0.5, math.min(10.0, numeric))
    return true
  end

  if key == "veTeleportSpeedScale" then
    local numeric = tonumber(value)
    if not numeric then return false end
    M.current.veTeleportSpeedScale = math.max(0.0, math.min(1.0, numeric))
    return true
  end

  if key == "inputSyncRate" then
    local numeric = tonumber(value)
    if not numeric then return false end
    M.current.inputSyncRate = math.max(10, math.min(60, math.floor(numeric + 0.5)))
    return true
  end

  if key == "inputSmoothRate" then
    local numeric = tonumber(value)
    if not numeric then return false end
    M.current.inputSmoothRate = math.max(10, math.min(100, math.floor(numeric + 0.5)))
    return true
  end

  if key == "electricsSyncRate" then
    local numeric = tonumber(value)
    if not numeric then return false end
    M.current.electricsSyncRate = math.max(5, math.min(30, math.floor(numeric + 0.5)))
    return true
  end

  M.current[key] = value
  return true
end

M.getDiagnostics = function()
  return {
    loadClampCount = M._loadClampCount or 0,
  }
end

M.getUiSettings = function()
  return {
    updateRate = M.current.updateRate,
    interpolation = M.current.interpolation,
  }
end

return M

