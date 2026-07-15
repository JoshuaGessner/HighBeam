HIGHBEAM_TEST = true

jsonEncode = function(packet)
  return '{"type":"' .. tostring(packet.type) .. '"}'
end

local connectionPath = assert(arg[1], "connection module path required")
local connection = assert(dofile(connectionPath))
local calls = {}
local fakeTcp = {}

function fakeTcp:send(data, offset)
  calls[#calls + 1] = { data = data, offset = offset }
  if #calls == 1 then
    return nil, "timeout", 5
  end
  return #data
end

connection._testSetTcp(fakeTcp, connection.STATE_CONNECTED)
assert(connection._sendPacket({ type = "vehicle_damage" }) == true,
  "non-blocking partial write should remain queued, not fail")

local queued, offset, bytes = connection._testTcpSendQueueState()
assert(queued == 1, "partial frame was not retained")
assert(offset == 6, "partial frame resume offset was not retained")
assert(bytes > 0, "queued byte accounting was lost")

assert(connection._testFlushTcpSendQueue() == true, "queued suffix flush failed")
queued, offset, bytes = connection._testTcpSendQueueState()
assert(queued == 0 and offset == 1 and bytes == 0, "send queue did not fully drain")
assert(calls[2] and calls[2].offset == 6, "send resumed from the wrong byte")

print("highbeam connection send tests passed")
