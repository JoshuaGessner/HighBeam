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
end

M.onExtensionUnloaded = function()
  log('I', logTag, 'HighBeam extension unloaded')
end

M.onUpdate = function(dtReal, dtSim, dtRaw)
  -- Network tick: process incoming, send outgoing
  if connection then
    connection.tick(dtReal)
  end
end

return M
