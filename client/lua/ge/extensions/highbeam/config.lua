local M = {}
local logTag = "HighBeam.Config"

M.defaults = {
  updateRate = 20,
  interpolation = true,
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
  M.current[key] = value
end

return M
