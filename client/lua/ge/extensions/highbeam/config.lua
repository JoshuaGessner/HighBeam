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
  showChat = true,
}

M.current = {}

M.load = function()
  -- Copy defaults as starting config
  for k, v in pairs(M.defaults) do
    M.current[k] = v
  end
  log('I', logTag, 'Configuration loaded')
end

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
