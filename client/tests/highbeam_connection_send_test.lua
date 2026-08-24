HIGHBEAM_TEST = true
log = function() end

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

-- A fully blocked socket retains one latest-value slot for each replaceable
-- component. A lifecycle barrier removes stale component state for its vehicle.
local blockedTcp = { send = function() return nil, "timeout" end }
connection._testSetTcp(blockedTcp, connection.STATE_CONNECTED)
assert(connection._sendPacket({ type = "vehicle_pose", vehicle_id = 7, data = "one" }))
assert(connection._sendPacket({ type = "vehicle_pose", vehicle_id = 7, data = "two" }))
queued = connection._testTcpSendQueueState()
assert(queued == 1, "replaceable snapshots must coalesce by type and vehicle")
local coalesced = connection._testTcpQueueMetrics()
assert(coalesced >= 1, "coalescing metric was not incremented")
assert(connection._sendPacket({ type = "vehicle_reset", vehicle_id = 7, data = "{}" }))
queued = connection._testTcpSendQueueState()
assert(queued == 1, "reset barrier must supersede queued replaceable state")

local closed = false
local fakeUdp = { close = function() closed = true end }
connection._testSetUdp(fakeUdp, connection.STATE_CONNECTED)
connection._testMarkUdpValid("test_ack")
assert(connection.isUdpHealthy(), "fresh validated UDP path should be healthy")
connection._testResetUdpSession(true, "inactive")
assert(closed, "UDP reset did not close the prior socket")
assert(connection._udpBindConfirmed == false and not connection.isUdpHealthy(),
  "UDP reset retained stale confirmation/health")

print("highbeam connection send tests passed")
