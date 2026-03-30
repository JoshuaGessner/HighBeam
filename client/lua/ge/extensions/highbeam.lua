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

M.onExtensionLoaded = function()
  log('I', logTag, 'HighBeam extension loaded')

  connection = require("highbeam/connection")
  protocol   = require("highbeam/protocol")
  vehicles   = require("highbeam/vehicles")
  state      = require("highbeam/state")
  chat       = require("highbeam/chat")
  config     = require("highbeam/config")

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
