local M = {}
local logTag = "HighBeam.Config"

M.defaults = {
  updateRate = 20,
  interpolation = true,
  interpolationDelayMs = 50,
  extrapolationMs = 120,
  jitterBufferSnapshots = 5,
  directConnectHost = "",
  directConnectPort = 18860,
  username = "",
  relayUrl = "",
  showChat = true,
}

M.current = {}

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

-- ──────────────────────── Load / Save ────────────────────────────────

M.load = function()
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
          M.current[k] = sv
        end
      end
      log('I', logTag, 'Loaded saved config from disk')
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

  M.current[key] = value
  return true
end

M.getUiSettings = function()
  return {
    updateRate = M.current.updateRate,
    interpolation = M.current.interpolation,
  }
end

return M

