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
    shiftUpOnDown = function() shiftedMode = "up" end,
    shiftDownOnDown = function() shiftedMode = "down" end,
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

-- Steering uses the sender's advertised lock. These three wire values all
-- represent the same normalized half-lock command.
for _, case in ipairs({ { 450, 0.5 }, { 900, 1.0 }, { 1080, 1.2 } }) do
  inputs.applyInputs({ l = case[1], s = case[2] })
  inputs.updateGFX(1 / 60)
  assert(math.abs(inputEvents.steering.value - 0.5) < 0.001,
    "steering normalization failed for sender lock " .. tostring(case[1]))
end

-- Automatic gearbox strings must survive to the controller API, and a value
-- received during readiness must be retained until it can be applied.
inputs.applyInputs({ k = "automatic", g = "D" })
local _, _, pendingGear, isPending = inputs._testGetState()
assert(pendingGear == "D" and isPending == true)
inputs._testSetReady()
inputs.updateGFX(0.1)
assert(shiftedMode == 2, "automatic D mode should map to shiftToGearIndex(2)")
local _, _, _, pendingAfter = inputs._testGetState()
assert(pendingAfter == false)

for mode, expected in pairs({ P = 1, R = -1, N = 0 }) do
  shiftedMode = nil
  inputs.applyInputs({ k = "automatic", g = mode })
  inputs._testSetReady()
  inputs.updateGFX(0.1)
  assert(shiftedMode == expected, "automatic " .. mode .. " mode was not applied")
end
electrics.values.gearIndex = 1
shiftedMode = nil
inputs.applyInputs({ k = "automatic", g = "M2" })
inputs._testSetReady()
inputs.updateGFX(0.1)
assert(shiftedMode == "up", "automatic M2 mode must preserve and apply its manual index")

-- Explicit schemas cover manual/sequential index gearboxes and controller-
-- driven CVT/electric layouts without guessing from the gear token.
local appliedIndex = nil
for _, schemaCase in ipairs({
  { schema = "manual", type = "manualGearbox", gear = 3 },
  { schema = "sequential", type = "sequentialGearbox", gear = 2 },
}) do
  gearbox = {
    type = schemaCase.type,
    minGearIndex = -1,
    maxGearIndex = 6,
    gearRatios = { [-1] = -3, [1] = 3, [2] = 2, [3] = 1.5 },
    setGearIndex = function(_, index) appliedIndex = index end,
  }
  inputs.applyInputs({ k = schemaCase.schema, g = schemaCase.gear })
  inputs._testSetReady()
  inputs.updateGFX(0.1)
  assert(appliedIndex == schemaCase.gear, schemaCase.schema .. " gear schema was not applied")
end

for _, schemaCase in ipairs({
  { schema = "cvt", type = "cvtGearbox" },
  { schema = "electric", type = "electricMotor" },
}) do
  shiftedMode = nil
  gearbox = { type = schemaCase.type }
  inputs.applyInputs({ k = schemaCase.schema, g = "D" })
  inputs._testSetReady()
  inputs.updateGFX(0.1)
  assert(shiftedMode == 2, schemaCase.schema .. " D mode was not applied")
end

local heldBeforeReset = inputs._testGetState()
inputs.onHighBeamRemoteReset()
local resetDesired, resetSmoothing = inputs._testGetState()
assert(resetDesired.t == heldBeforeReset.t and resetDesired.s == heldBeforeReset.s,
  "reset must retain held desired inputs")
assert(resetSmoothing.t >= 0 and resetSmoothing.s ~= nil)

inputs.setActive(false, false)
assert(allowedSources["steering:HighBeam"] == false)
assert(allowedSources["steering:local"] == true)

electrics.values.gear = "D"
gearbox = { type = "automaticGearbox" }
inputs.setActive(true, false)
inputs.updateGFX(0.1)
assert(sentDelta and string.find(sentDelta, "g=D", 1, true),
  "sender must preserve automatic gearbox mode strings")
assert(string.find(sentDelta, "k=automatic", 1, true),
  "sender must advertise its gearbox schema")
assert(string.find(sentDelta, "l=450", 1, true),
  "sender must advertise steering lock metadata")

print("highbeam input tests passed")
