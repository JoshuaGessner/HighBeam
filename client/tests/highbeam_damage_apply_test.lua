HIGHBEAM_TEST = true
log = function() end

local broken = {}
local restLengths = { [0] = 1, [1] = 1, [2] = 1, [3] = 1, [4] = 1 }
local queued = {}
local beamStateBroken = {}
local beamStateDeformed = {}
local groups = {}

obj = {
  getID = function() return 42 end,
  getBeamCount = function() return 5 end,
  breakBeam = function(_, id) broken[id] = (broken[id] or 0) + 1 end,
  beamIsBroken = function(_, id) return broken[id] ~= nil end,
  setBeamLength = function(_, id, length) restLengths[id] = length end,
  getBeamRestLength = function(_, id) return restLengths[id] end,
  queueGameEngineLua = function(_, command) queued[#queued + 1] = command end,
}
beamstate = {
  beamBroken = function(id) beamStateBroken[id] = true end,
  beamDeformed = function(id, value) beamStateDeformed[id] = value end,
  breakBreakGroup = function(group) groups[group] = true end,
}
props = { hidePropsInBreakGroup = function(group) groups["prop:" .. group] = true end }

local modulePath = assert(arg[1], "damage controller path required")
local damage = assert(dofile(modulePath))
damage.setActive(true, true)

local snapshot = {
  broken = { 1, 99 }, -- out-of-topology IDs are safely ignored and acknowledged
  breakGroups = { "door" },
  deform = { ["2"] = { 0.25, 1.2345 } },
}
assert(damage.applyRemoteDamage(snapshot, 3, 7) == true)
assert(broken[1] == 1 and broken[99] == nil)
assert(beamStateBroken[1] == true)
assert(restLengths[2] == 1.2345 and beamStateDeformed[2] == 0.25)
assert(groups.door and groups["prop:door"])
assert(queued[#queued]:find("onRemoteDamageApplied%(42,3,7,1,1,1,0%)"), "missing success ack")

-- A repeated cumulative snapshot/revision is idempotent.
assert(damage.applyRemoteDamage(snapshot, 3, 7) == true)
assert(broken[1] == 1)

print("highbeam damage apply tests passed")
