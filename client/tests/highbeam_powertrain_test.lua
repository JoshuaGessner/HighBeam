HIGHBEAM_TEST = true

local calls = {
  engineA = {},
  engineB = {},
}
local queued = nil
local actuations = {}
local beamRestLengths = { [5] = 1.0 }
local beamLengths = { [5] = 1.0 }

local function makeEngine(name, ignition, starter, stalled)
  return {
    type = "combustionEngine",
    ignitionCoef = ignition,
    starterEngagedCoef = starter,
    isStalled = stalled,
    setIgnition = function(_, value) calls[name].ignition = value end,
    activateStarter = function() calls[name].starter = "on" end,
    deactivateStarter = function() calls[name].starter = "off" end,
    cutIgnition = function() calls[name].stalled = true end,
  }
end

local devices = {
  engineA = makeEngine("engineA", 1, 0, false),
  engineB = makeEngine("engineB", 0.5, 1, true),
}

powertrain = {
  getDevices = function() return devices end,
  getDevice = function(name) return devices[name] end,
}
electrics = {
  values = { ignitionLevel = 0, armDirection = 0 },
  setIgnitionLevel = function(level) electrics.values.ignitionLevel = level end,
}
obj = {
  getID = function() return 77 end,
  queueGameEngineLua = function(_, command) queued = command end,
  getBeamRestLength = function(_, beamId) return beamRestLengths[beamId] end,
  getBeamLength = function(_, beamId) return beamLengths[beamId] end,
  actuateBeam = function(_, beamId, force, speed)
    actuations[#actuations + 1] = { beamId = beamId, force = force, speed = speed }
  end,
}
v = {
  data = {
    powertrainHydros = {
      { beamTags = { "arm" }, directionElectricsName = "armDirection", minimumDragCoef = 150,
        maxSpeed = 2, minExtend = 0.5, maxExtend = 2, virtualMass = 10 },
    },
    beams = { { cid = 5, tag = "arm" } },
  },
}
jsonEncode = function(value)
  if type(value) == "table" and type(value.engines) == "table" and type(value.hydraulics) == "table" then
    return '{"engines":{"engineA":{},"engineB":{}},"hydraulics":{"arm":1}}'
  end
  return "{}"
end
log = function() end

local modulePath = assert(arg[1], "powertrain module path required")
local powertrainVE = assert(dofile(modulePath))

powertrainVE.setActive(true, true)
local accepted = powertrainVE.applyPowertrain({
  engines = {
    engineA = { ignCoef = 0.25, starterCoef = 1, stalled = 0 },
    engineB = { ignCoef = 0.75, starterCoef = 0, stalled = 1 },
  },
  ignLevel = 2,
})
assert(accepted == false, "readiness-window state must be retained, not applied")
assert(calls.engineA.ignition == nil and calls.engineB.ignition == nil)
assert(powertrainVE._testGetPendingState() ~= nil)

powertrainVE._testSetReady()
powertrainVE.updateGFX(0.1)
assert(calls.engineA.ignition == 0.25)
assert(calls.engineA.starter == "on")
assert(calls.engineB.ignition == 0.75)
assert(calls.engineB.starter == "off")
assert(calls.engineB.stalled == true)
assert(electrics.values.ignitionLevel == 2)
assert(powertrainVE._testGetPendingState() == nil)

powertrainVE.applyPowertrain({ hydraulics = { arm = 1.5 } })
powertrainVE.updateGFX(0.1)
assert(#actuations > 0 and actuations[#actuations].beamId == 5,
  "remote hydraulic targets must use obj:actuateBeam")

-- Legacy single-engine fields remain supported and deterministically target
-- the first named combustion engine.
powertrainVE.applyPowertrain({ ignCoef = 0.4, starterCoef = 0 })
assert(calls.engineA.ignition == 0.4)
assert(calls.engineA.starter == "off")

-- Clearing a stall must replay retained ignition state; cutIgnition has no
-- universal inverse across BeamNG engine implementations.
calls.engineB.ignition = nil
powertrainVE.applyPowertrain({
  engines = { engineB = { stalled = 0, ignCoef = 0.8 } },
})
assert(calls.engineB.ignition == 0.8)

-- A remote reset must retain and replay the complete desired state after the
-- stock powertrain readiness window rather than waiting for a 10s resync.
calls.engineB.ignition = nil
powertrainVE.onHighBeamRemoteReset()
assert(powertrainVE._testGetPendingState() ~= nil)
powertrainVE._testSetReady()
powertrainVE.updateGFX(0.1)
assert(calls.engineB.ignition == 0.8)

-- Sender payloads carry the per-engine map while still including legacy data.
powertrainVE.setActive(true, false)
powertrainVE.updateGFX(0.1)
assert(queued and string.find(queued, 'engines', 1, true),
  "sender powertrain payload must include the per-engine state map")
assert(string.find(queued, 'hydraulics', 1, true),
  "sender powertrain payload must include hydraulic rest lengths")

print("highbeam powertrain tests passed")
