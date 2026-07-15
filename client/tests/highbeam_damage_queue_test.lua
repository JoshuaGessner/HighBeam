HIGHBEAM_TEST = true
log = function() end

local statePath = assert(arg[1], "state module path required")
local extensionRoot = assert(arg[2], "GE extension root required")
package.path = extensionRoot .. "/?.lua;" .. package.path

local allowSend = true
local sends = {}
local connection = {
  STATE_CONNECTED = 3,
  getState = function() return 3 end,
  _sendPacket = function(packet)
    sends[#sends + 1] = packet
    return allowSend
  end,
}

local state = assert(dofile(statePath))
state.setSubsystems(connection, { get = function() return false end })

local gameVid = 10
local payload1 = '{"broken":[1],"breakGroups":[],"deform":{}}'
local payload2 = '{"broken":[1,2],"breakGroups":[],"deform":{}}'
local empty = '{"broken":[],"breakGroups":[],"deform":{}}'

-- A report may beat the server's local vehicle mapping. It must remain pending.
local ok, outcome = state._testQueueDamageSnapshot(gameVid, payload1)
assert(ok == false and outcome == "no_server_vid")
local pending, delivered = state._testPendingDamage(gameVid)
assert(pending == payload1 and delivered == nil)

state.localVehicles[gameVid] = 7
state._testClearDamageAttempt(gameVid)
state._testFlushPendingDamage(os.clock())
pending, delivered = state._testPendingDamage(gameVid)
assert(pending == nil and delivered == payload1)
assert(sends[#sends].vehicle_id == 7 and sends[#sends].data == payload1)

-- A failed local transport enqueue must not advance delivered suppression.
allowSend = false
state._testClearDamageAttempt(gameVid)
ok, outcome = state._testQueueDamageSnapshot(gameVid, payload2)
assert(ok == false and outcome == "send_failed")
pending, delivered = state._testPendingDamage(gameVid)
assert(pending == payload2 and delivered == payload1)

-- A late pristine callback cannot erase the newer damaged snapshot.
state._testQueueDamageSnapshot(gameVid, empty)
pending = state._testPendingDamage(gameVid)
assert(pending == payload2)

allowSend = true
state._testClearDamageAttempt(gameVid)
state._testFlushPendingDamage(os.clock())
pending, delivered = state._testPendingDamage(gameVid)
assert(pending == nil and delivered == payload2)

print("highbeam damage queue tests passed")
