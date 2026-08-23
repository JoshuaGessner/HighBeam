HIGHBEAM_TEST = true

local allowedSources = {}
local inputEvents = {}
local shiftedMode = nil
local sentDelta = nil

input = {
  setAllowedInputSource = function(name, source, allowed)
    allowedSources[name .. ":" .. source] = allowed
  end,
  event = function(name, value, _, _, _, _, source)
    inputEvents[name] = { value = value, source = source }
  end,
}
obj = {
  getID = function() return 42 end,
  queueGameEngineLua = function(_, command) sentDelta = command end,
}
v = { data = { input = { steeringWheelLock = 450 } } }
electrics = { values = { gearIndex = 0 } }
controller = {
  mainController = {
    shiftToGearIndex = function(index) shiftedMode = index end,
  },
}
local gearbox = { type = "automaticGearbox" }
powertrain = {
  getDevice = function(name)
    if name == "gearbox" then return gearbox end
  end,
}
log = function() end

local inputsPath = assert(arg[1], "inputs module path required")
local inputs = assert(dofile(inputsPath))

assert(inputs._testShouldSnapInput("s", 0.1, 0) == false)
assert(inputs._testShouldSnapInput("s", -0.1, 0) == false,
  "negative steering must not snap when the equal positive input smooths")
assert(inputs._testShouldSnapInput("s", 0.5, 0) == true)
assert(inputs._testShouldSnapInput("s", -0.5, 0) == true)
assert(inputs._testShouldSnapInput("s", 0.01, 0.02) == true)
assert(inputs._testShouldSnapInput("t", 0.1, 0) == false)
assert(inputs._testShouldSnapInput("t", 0.99, 0.9) == true)

inputs.setActive(true, true)
assert(allowedSources["steering:HighBeam"] == true)
assert(allowedSources["steering:local"] == false)

-- Delta packets merge into a complete desired state, then updateGFX owns
-- frame-rate-independent smoothing and event delivery.
inputs.applyInputs({ t = 0.1 })
inputs.updateGFX(1 / 60)
inputs.applyInputs({ s = -0.1 })
inputs.updateGFX(1 / 60)
local desired = inputs._testGetState()
assert(desired.t == 0.1, "an omitted throttle field must retain its desired value")
assert(desired.s == -0.1)
assert(inputEvents.throttle and inputEvents.throttle.value > 0)
assert(inputEvents.throttle.source == "HighBeam")

-- Automatic gearbox strings must survive to the controller API, and a value
-- received during readiness must be retained until it can be applied.
inputs.applyInputs({ g = "D" })
local _, _, pendingGear, isPending = inputs._testGetState()
assert(pendingGear == "D" and isPending == true)
inputs._testSetReady()
inputs.updateGFX(0.1)
assert(shiftedMode == 2, "automatic D mode should map to shiftToGearIndex(2)")
local _, _, _, pendingAfter = inputs._testGetState()
assert(pendingAfter == false)

inputs.onHighBeamRemoteReset()
local resetDesired, resetSmoothing = inputs._testGetState()
assert(resetDesired.t == 0 and resetDesired.s == 0)
assert(resetSmoothing.t == 0 and resetSmoothing.s == 0)

inputs.setActive(false, false)
assert(allowedSources["steering:HighBeam"] == false)
assert(allowedSources["steering:local"] == true)

electrics.values.gear = "D"
inputs.setActive(true, false)
inputs.updateGFX(0.1)
assert(sentDelta and string.find(sentDelta, "g=D", 1, true),
  "sender must preserve automatic gearbox mode strings")

print("highbeam input tests passed")
