HIGHBEAM_TEST = true
log = function() end

local vehiclesPath = assert(arg[1], "vehicles module path required")
local extensionRoot = assert(arg[2], "GE extension root required")
package.path = extensionRoot .. "/?.lua;" .. package.path

local vehicles = assert(dofile(vehiclesPath))
local accept = assert(vehicles._testAcceptExplicitMotionOrder)
local rv = { snapshots = {}, lastSeqTime = -1, motionEpoch = nil, motionSequence = -1 }

local ok, restarted = accept(rv, { motionEpoch = 5, motionSequence = 1 })
assert(ok and not restarted and rv.motionEpoch == 5 and rv.motionSequence == 1)
assert(not accept(rv, { motionEpoch = 5, motionSequence = 1 }), "duplicate sequence must drop")
assert(not accept(rv, { motionEpoch = 5, motionSequence = 0 }), "older sequence must drop")

rv.snapshots = { { time = 10 } }
ok, restarted = accept(rv, { motionEpoch = 6, motionSequence = 0 })
assert(ok and restarted and #rv.snapshots == 0, "new epoch must atomically clear interpolation state")
assert(not accept(rv, { motionEpoch = 5, motionSequence = 999 }), "delayed prior epoch must drop")

rv.motionEpoch = 4294967295
rv.motionSequence = 99
ok, restarted = accept(rv, { motionEpoch = 1, motionSequence = 0 })
assert(ok and restarted, "u32 epoch wrap must be treated as a newer lifetime")

local remote = {
  gameVehicleId = 55,
  gameVehicle = {},
  _hasVE = true,
  _lastDamageData = "damage",
  _lastElectricsData = "electrics",
  _lastPowertrainData = "powertrain",
  _lastInputsData = "inputs",
}
vehicles.remoteVehicles["9_3"] = remote
vehicles._remoteGameIds[55] = true
assert(vehicles.onRemoteObjectDestroyed(55) == true)
assert(remote.gameVehicleId == nil and remote.gameVehicle == nil and remote._hasVE == false)
assert(remote._pendingDamageData == "damage" and remote._pendingElectricsData == "electrics")
assert(remote._pendingPowertrainData == "powertrain" and remote._pendingInputsData == "inputs")
assert(remote.spawnRetry and remote.spawnRetry.attempts == 0,
  "unexpected BeamNG deletion must enter bounded puppet recovery")

print("highbeam motion ordering tests passed")
