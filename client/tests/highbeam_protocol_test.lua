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

print("highbeam protocol tests passed")
