local M = {}
local logTag = "HighBeam.Protocol"

M.VERSION = 2

-- TCP packet encode/decode stubs
M.encodeTcp = function(packetType, data)
  return nil
end

M.decodeTcp = function(rawData)
  return nil
end

-- UDP packet encode/decode (binary, zero JSON overhead)
-- See PROTOCOL.md for packet layouts

local ffi = require("ffi")

-- Position update: type 0x10 (legacy) / 0x11 (extended with inputs)
-- Legacy layout: [vid:u16] [pos:3xf32] [rot:4xf32] [vel:3xf32] [time:f32]
-- Extended layout: [vid:u16] [pos:3xf32] [rot:4xf32] [vel:3xf32] [time:f32] [steer:f16] [throttle:f16] [brake:f16]
-- Legacy payload: 46 bytes  |  Extended payload: 52 bytes

-- float16 encode/decode helpers (IEEE 754 half-precision)
local function f32_to_f16(val)
  -- Clamp to [-1, 1] for input values, allow full range for steering
  local f = math.max(-2, math.min(2, val or 0))
  -- Simple conversion: store as fixed-point i16 scaled by 16384
  local i = math.floor(f * 16384 + 0.5)
  if i < -32768 then i = -32768 end
  if i > 32767 then i = 32767 end
  if i < 0 then i = i + 65536 end
  return i
end

local function f16_to_f32(u16)
  local i = u16
  if i >= 32768 then i = i - 65536 end
  return i / 16384.0
end

M.encodePositionUpdate = function(sessionHash, vehicleId, pos, rot, vel, simTime, inputs)
  local hasInputs = inputs and (inputs.steer or inputs.throttle or inputs.brake)
  local totalSize = hasInputs and 69 or 63  -- 16 hash + 1 type + payload
  local buf = ffi.new("uint8_t[?]", totalSize)
  ffi.copy(buf, sessionHash, 16)
  buf[16] = hasInputs and 0x11 or 0x10  -- type byte

  local ptr = ffi.cast("uint16_t*", buf + 17)
  ptr[0] = vehicleId

  local fp = ffi.cast("float*", buf + 19)
  fp[0], fp[1], fp[2] = pos[1], pos[2], pos[3]          -- pos  (12B)
  fp[3], fp[4], fp[5], fp[6] = rot[1], rot[2], rot[3], rot[4]  -- rot  (16B)
  fp[7], fp[8], fp[9] = vel[1], vel[2], vel[3]          -- vel  (12B)
  fp[10] = simTime                                        -- time (4B)

  if hasInputs then
    local ip = ffi.cast("uint16_t*", buf + 63)
    ip[0] = f32_to_f16(inputs.steer or 0)
    ip[1] = f32_to_f16(inputs.throttle or 0)
    ip[2] = f32_to_f16(inputs.brake or 0)
  end

  return ffi.string(buf, totalSize)
end

-- Decode relayed position update from server
-- Server-relayed layout adds pid:u16 after type byte
-- Type 0x10 -> 65 bytes total (legacy)
-- Type 0x11 -> 71 bytes total (extended with inputs)
M.decodePositionUpdate = function(data)
  if #data < 65 then return nil end
  local buf = ffi.cast("const uint8_t*", data)
  local typeByte = buf[16]

  local pid = ffi.cast("const uint16_t*", buf + 17)[0]
  local vid = ffi.cast("const uint16_t*", buf + 19)[0]
  local fp  = ffi.cast("const float*", buf + 21)

  local result = {
    playerId  = pid,
    vehicleId = vid,
    pos  = { fp[0], fp[1], fp[2] },
    rot  = { fp[3], fp[4], fp[5], fp[6] },
    vel  = { fp[7], fp[8], fp[9] },
    time = fp[10],
  }

  -- Decode inputs if present (type 0x11, 71 bytes)
  if typeByte == 0x11 and #data >= 71 then
    local ip = ffi.cast("const uint16_t*", buf + 65)
    result.inputs = {
      steer = f16_to_f32(ip[0]),
      throttle = f16_to_f32(ip[1]),
      brake = f16_to_f32(ip[2]),
    }
  end

  return result
end

return M
