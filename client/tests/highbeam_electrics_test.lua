HIGHBEAM_TEST = true

local transbrakeCalls = {}
local queued = nil

electrics = { values = { lights_state = 1, transbrake = 0 } }
controller = {
  getControllerSafe = function(name)
    if name ~= "transbrake" then return nil end
    return {
      setTransbrake = function(value) transbrakeCalls[#transbrakeCalls + 1] = value end,
    }
  end,
}
obj = {
  getID = function() return 91 end,
  queueGameEngineLua = function(_, command) queued = command end,
}
jsonEncode = function(value)
  return string.format('{"lights_state":%s,"transbrake":%s}',
    tostring(value.lights_state or 0), tostring(value.transbrake or 0))
end
log = function() end

local modulePath = assert(arg[1], "electrics module path required")
local electricsVE = assert(dofile(modulePath))

electricsVE.setActive(true, true)
electricsVE.applyElectrics({ lights_state = 2, transbrake = 1 })
electricsVE.applyElectrics({ transbrake = 0 })
assert(electrics.values.lights_state == 2)
assert(#transbrakeCalls == 2 and transbrakeCalls[1] == 1 and transbrakeCalls[2] == 0,
  "transbrake off must be applied explicitly through its controller")
assert(electrics.values.transbrake == 0,
  "receiver must not overwrite the locally simulated transbrake electric directly")

electricsVE.setActive(true, false)
electricsVE.updateGFX(1)
assert(queued and queued:find("transbrake", 1, true),
  "sender snapshot must include transbrake state")

print("highbeam electrics tests passed")
