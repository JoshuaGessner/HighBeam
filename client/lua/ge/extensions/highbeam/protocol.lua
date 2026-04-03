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

-- Position update: type 0x10
-- Layout: [vid:u16] [pos:3xf32] [rot:4xf32] [vel:3xf32] [time:f32]
-- Total payload (after session hash + type byte): 46 bytes

M.encodePositionUpdate = function(sessionHash, vehicleId, pos, rot, vel, simTime)
  local buf = ffi.new("uint8_t[63]")  -- 16 hash + 1 type + 46 payload
  ffi.copy(buf, sessionHash, 16)
  buf[16] = 0x10  -- type byte

  local ptr = ffi.cast("uint16_t*", buf + 17)
  ptr[0] = vehicleId

  local fp = ffi.cast("float*", buf + 19)
  fp[0], fp[1], fp[2] = pos[1], pos[2], pos[3]          -- pos  (12B)
  fp[3], fp[4], fp[5], fp[6] = rot[1], rot[2], rot[3], rot[4]  -- rot  (16B)
  fp[7], fp[8], fp[9] = vel[1], vel[2], vel[3]          -- vel  (12B)
  fp[10] = simTime                                        -- time (4B)

  return ffi.string(buf, 63)
end

-- Decode relayed position update from server
-- Server-relayed layout adds pid:u16 after type byte -> 65 bytes total
M.decodePositionUpdate = function(data)
  if #data < 65 then return nil end
  local buf = ffi.cast("const uint8_t*", data)
  -- buf[0..15] = session hash (already validated by caller)
  -- buf[16] = 0x10 type (already matched by caller)

  local pid = ffi.cast("const uint16_t*", buf + 17)[0]
  local vid = ffi.cast("const uint16_t*", buf + 19)[0]
  local fp  = ffi.cast("const float*", buf + 21)

  return {
    playerId  = pid,
    vehicleId = vid,
    pos  = { fp[0], fp[1], fp[2] },
    rot  = { fp[3], fp[4], fp[5], fp[6] },
    vel  = { fp[7], fp[8], fp[9] },
    time = fp[10],
  }
end

return M
