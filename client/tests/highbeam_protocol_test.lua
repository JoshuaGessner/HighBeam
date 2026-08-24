HIGHBEAM_TEST = true

local modulePath = assert(arg[1], "protocol module path required")
local protocol = assert(dofile(modulePath))

local ok, packet = pcall(protocol.encodePositionUpdate,
  string.rep("x", 16),
  7,
  { 1, 2, 3 },
  { 0, 0, 0, 1 },
  { 4, 5, 6 },
  1.25,
  { steer = 0.1, throttle = 0.5, brake = 0, gear = "D", handbrake = 0 },
  { 0, 0, 0 })

assert(ok, "automatic gear strings must not crash the numeric UDP codec")
assert(type(packet) == "string" and #packet > 0)

local versioned = assert(protocol.encodePositionUpdate(
  string.rep("x", 16),
  7,
  { 1, 2, 3 },
  { 0, 0, 0, 1 },
  { 4, 5, 6 },
  1.25,
  { steer = 2.4, throttle = 0.5, brake = 0.1, gear = 2, handbrake = 0 },
  { 0.25, -0.5, 0.75 },
  12,
  345,
  1080
))
assert(#versioned == 95 and versioned:byte(17) == 0x12,
  "versioned pose must use the exact 0x12 client layout")

-- Mirror the server relay operation: insert pid:u16 after the type byte.
local relayed = versioned:sub(1, 17) .. string.char(9, 0) .. versioned:sub(18)
local decoded = assert(protocol.decodePositionUpdate(relayed))
assert(decoded.playerId == 9 and decoded.vehicleId == 7)
assert(decoded.motionEpoch == 12 and decoded.motionSequence == 345)
assert(decoded.steeringLock == 1080)
assert(math.abs(decoded.inputs.steer - 2.4) < 0.001,
  "1080-degree full-lock steering must survive the fixed-point codec")
assert(math.abs(decoded.angVel[3] - 0.75) < 0.0001)
assert(protocol.decodePositionUpdate(relayed .. "x") == nil,
  "0x12 decoder must reject trailing bytes")

print("highbeam protocol tests passed")
