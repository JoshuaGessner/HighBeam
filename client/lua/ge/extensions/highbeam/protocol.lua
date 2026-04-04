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

local function write_u16_le(buf, offset, value)
  local v = math.floor(tonumber(value) or 0) % 65536
  buf[offset] = v % 256
  buf[offset + 1] = math.floor(v / 256)
end

local function read_u16_le(data, offset)
  local b1 = string.byte(data, offset + 1) or 0
  local b2 = string.byte(data, offset + 2) or 0
  return b1 + b2 * 256
end

local function write_f32_le(buf, offset, value)
  local tmp = ffi.new("float[1]", tonumber(value) or 0)
  local bytes = ffi.string(tmp, 4)
  buf[offset] = string.byte(bytes, 1)
  buf[offset + 1] = string.byte(bytes, 2)
  buf[offset + 2] = string.byte(bytes, 3)
  buf[offset + 3] = string.byte(bytes, 4)
end

local function read_f32_le(data, offset)
  local b1 = string.byte(data, offset + 1) or 0
  local b2 = string.byte(data, offset + 2) or 0
  local b3 = string.byte(data, offset + 3) or 0
  local b4 = string.byte(data, offset + 4) or 0
  local raw = string.char(b1, b2, b3, b4)
  local tmp = ffi.new("float[1]")
  ffi.copy(tmp, raw, 4)
  return tmp[0]
end

M.encodePositionUpdate = function(sessionHash, vehicleId, pos, rot, vel, simTime, inputs)
  if type(sessionHash) ~= "string" or #sessionHash ~= 16 then
    log('E', logTag, 'encodePositionUpdate: invalid session hash (expected 16 bytes)')
    return nil
  end

  local hasInputs = type(inputs) == "table"
    and (inputs.steer ~= nil or inputs.throttle ~= nil or inputs.brake ~= nil)
  local typeByte = hasInputs and 0x11 or 0x10

  local expectedSize = hasInputs and 69 or 63
  local buf = ffi.new("uint8_t[?]", expectedSize)
  ffi.copy(buf, sessionHash, 16)
  buf[16] = typeByte

  local o = 17
  write_u16_le(buf, o, vehicleId)
  o = o + 2

  write_f32_le(buf, o, pos and pos[1]); o = o + 4
  write_f32_le(buf, o, pos and pos[2]); o = o + 4
  write_f32_le(buf, o, pos and pos[3]); o = o + 4

  write_f32_le(buf, o, rot and rot[1]); o = o + 4
  write_f32_le(buf, o, rot and rot[2]); o = o + 4
  write_f32_le(buf, o, rot and rot[3]); o = o + 4
  write_f32_le(buf, o, (rot and rot[4]) or 1); o = o + 4

  write_f32_le(buf, o, vel and vel[1]); o = o + 4
  write_f32_le(buf, o, vel and vel[2]); o = o + 4
  write_f32_le(buf, o, vel and vel[3]); o = o + 4

  write_f32_le(buf, o, simTime); o = o + 4

  if hasInputs then
    write_u16_le(buf, o, f32_to_f16(inputs.steer or 0)); o = o + 2
    write_u16_le(buf, o, f32_to_f16(inputs.throttle or 0)); o = o + 2
    write_u16_le(buf, o, f32_to_f16(inputs.brake or 0)); o = o + 2
  end

  local packet = ffi.string(buf, expectedSize)
  if #packet ~= expectedSize then
    log('E', logTag, 'encodePositionUpdate: packet size mismatch (got ' .. tostring(#packet)
      .. ', expected ' .. tostring(expectedSize) .. ')')
    return nil
  end

  return packet
end

-- Decode relayed position update from server
-- Server-relayed layout adds pid:u16 after type byte
-- Type 0x10 -> 65 bytes total (legacy)
-- Type 0x11 -> 71 bytes total (extended with inputs)
M.decodePositionUpdate = function(data)
  if #data < 65 then return nil end
  local typeByte = string.byte(data, 17)

  local o = 17
  local pid = read_u16_le(data, o); o = o + 2
  local vid = read_u16_le(data, o); o = o + 2

  local p1 = read_f32_le(data, o); o = o + 4
  local p2 = read_f32_le(data, o); o = o + 4
  local p3 = read_f32_le(data, o); o = o + 4

  local r1 = read_f32_le(data, o); o = o + 4
  local r2 = read_f32_le(data, o); o = o + 4
  local r3 = read_f32_le(data, o); o = o + 4
  local r4 = read_f32_le(data, o); o = o + 4

  local v1 = read_f32_le(data, o); o = o + 4
  local v2 = read_f32_le(data, o); o = o + 4
  local v3 = read_f32_le(data, o); o = o + 4
  local simTime = read_f32_le(data, o); o = o + 4

  local result = {
    playerId  = pid,
    vehicleId = vid,
    pos  = { p1, p2, p3 },
    rot  = { r1, r2, r3, r4 },
    vel  = { v1, v2, v3 },
    time = simTime,
  }

  -- Decode inputs if present (type 0x11, 71 bytes)
  if typeByte == 0x11 and #data >= 71 then
    local iSteer = read_u16_le(data, o); o = o + 2
    local iThrottle = read_u16_le(data, o); o = o + 2
    local iBrake = read_u16_le(data, o); o = o + 2
    result.inputs = {
      steer = f16_to_f32(iSteer),
      throttle = f16_to_f32(iThrottle),
      brake = f16_to_f32(iBrake),
    }
  end

  return result
end

return M
