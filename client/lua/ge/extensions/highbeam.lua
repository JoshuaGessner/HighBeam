-- HighBeam - Decentralized multiplayer for BeamNG.drive
-- Main extension entry point (GELUA)

local M = {}
local logTag = "HighBeam"

-- Subsystem references (loaded in onExtensionLoaded)
local connection   -- highbeam/connection.lua
local protocol     -- highbeam/protocol.lua
local vehicles     -- highbeam/vehicles.lua
local state        -- highbeam/state.lua
local chat         -- highbeam/chat.lua
local config       -- highbeam/config.lua

local function _safeRequire(moduleName)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    log('E', logTag, 'Failed to load module ' .. moduleName .. ': ' .. tostring(mod))
    return nil
  end
  return mod
end

M.onExtensionLoaded = function()
  log('I', logTag, 'HighBeam extension loaded')

  connection = _safeRequire("highbeam/connection")
  protocol   = _safeRequire("highbeam/protocol")
  vehicles   = _safeRequire("highbeam/vehicles")
  state      = _safeRequire("highbeam/state")
  chat       = _safeRequire("highbeam/chat")
  config     = _safeRequire("highbeam/config")

  if not connection or not protocol or not vehicles or not state or not chat or not config then
    log('E', logTag, 'HighBeam startup aborted due to module load failure')
    return
  end

  connection.setErrorCallback(function(context, message, level)
    log(level or 'E', logTag, '[ConnectionError][' .. tostring(context) .. '] ' .. tostring(message))
  end)

  -- Wire subsystem cross-references
  connection.setSubsystems(vehicles, state)
  state.setSubsystems(connection, config)

  config.load()
end

M.onExtensionUnloaded = function()
  log('I', logTag, 'HighBeam extension unloaded')
  if connection then
    connection.disconnect()
  end
end

M.onUpdate = function(dtReal, dtSim, dtRaw)
  -- Network tick: process incoming, send outgoing
  if connection then
    connection.tick(dtReal)
  end
  -- Position sending
  if state then
    state.tick(dtReal)
  end
  -- Remote vehicle interpolation
  if vehicles then
    vehicles.tick(dtReal)
  end
end

return M
