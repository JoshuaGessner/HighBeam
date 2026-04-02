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
local browser      -- highbeam/browser.lua

local MENU_ENTRY_ID = "highbeam.multiplayer"
local _menuRegistered = false

local function _safeRequire(moduleName)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    log('E', logTag, 'Failed to load module ' .. moduleName .. ': ' .. tostring(mod))
    return nil
  end
  return mod
end

local function _openBrowserFromMenu()
  if browser then
    browser.open()
  end
end

local function _menuController()
  return (extensions and extensions.core_quickAccess) or core_quickAccess
end

local function _registerMenuEntry()
  local qa = _menuController()
  if not qa then
    return false
  end

  local entry = {
    id = MENU_ENTRY_ID,
    title = "HighBeam Multiplayer",
    desc = "Open server browser",
    icon = "multiplayer_gamemode",
    onSelect = _openBrowserFromMenu,
  }

  -- BeamNG builds differ in addEntry/removeEntry signatures; try common variants.
  -- Try single-arg (table with id field) first to avoid triggering warnings from
  -- the two-arg form where the API misinterprets the ID string as the entry.
  local ok = false
  if qa.addEntry then
    ok = pcall(qa.addEntry, entry)
    if not ok then
      ok = pcall(qa.addEntry, MENU_ENTRY_ID, entry)
    end
  end

  if ok then
    _menuRegistered = true
    log('I', logTag, 'Registered More menu button: HighBeam Multiplayer')
  else
    log('W', logTag, 'Could not register More menu button (core_quickAccess API unavailable)')
  end

  return ok
end

local function _unregisterMenuEntry()
  if not _menuRegistered then
    return
  end

  local qa = _menuController()
  if qa and qa.removeEntry then
    local ok = pcall(qa.removeEntry, MENU_ENTRY_ID)
    if not ok then
      pcall(qa.removeEntry, "HighBeam Multiplayer")
    end
  end

  _menuRegistered = false
end

M.onExtensionLoaded = function()
  log('I', logTag, 'HighBeam extension loaded')

  connection = _safeRequire("highbeam/connection")
  protocol   = _safeRequire("highbeam/protocol")
  vehicles   = _safeRequire("highbeam/vehicles")
  state      = _safeRequire("highbeam/state")
  chat       = _safeRequire("highbeam/chat")
  config     = _safeRequire("highbeam/config")
  browser    = _safeRequire("highbeam/browser")

  if not connection or not protocol or not vehicles or not state or not chat or not config then
    log('E', logTag, 'HighBeam startup aborted due to module load failure')
    return
  end

  connection.setErrorCallback(function(context, message, level)
    log(level or 'E', logTag, '[ConnectionError][' .. tostring(context) .. '] ' .. tostring(message))
  end)

  -- Notify browser when connection succeeds so it can record the recent entry
  connection.setStatusCallback(function(status, detail)
    if status == "connected" and browser then
      browser.onConnected()
    end
  end)

  -- Wire subsystem cross-references
  connection.setSubsystems(vehicles, state)
  state.setSubsystems(connection, config)

  config.load()

  if browser then
    browser.load(connection, config)
  end

  _registerMenuEntry()
end

M.onExtensionUnloaded = function()
  log('I', logTag, 'HighBeam extension unloaded')

  _unregisterMenuEntry()

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

M.onPreRender = function(dtReal, dtSim, dtRaw)
  -- Render the server browser IMGUI window every frame when it is open
  if browser then
    browser.renderUI()
  end
end

-- ──────────────────── Public API (callable from GE Lua console) ──────────────

-- Open the server browser window
M.openBrowser = function()
  if browser then browser.open() end
end

-- Close the server browser window
M.closeBrowser = function()
  if browser then browser.close() end
end

-- Quick connect shortcut (for external scripts / launcher integration)
M.connect = function(host, port, username, password)
  if browser then
    return browser.connect(host, port, username, password)
  elseif connection then
    connection.connect(host, port, username, password)
    return true
  end
  return false, "not initialised"
end

return M

