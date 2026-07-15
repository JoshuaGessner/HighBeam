local M = {}
M.type = "auxiliary"

-- Applies velocity corrections to the vehicle by converting velocity deltas
-- into per-node forces (or a cluster acceleration) that reach the target
-- delta-v in exactly one physics tick: force = dv * nodeMass * physicsFPS.
-- Mirrors the approach used by BeamNG's own spawn code and BeamMP:
-- obj:applyClusterLinearAngularAccel(refNode, linAccel, angAccel) requires the
-- cluster's reference NODE ID as its first argument.

local nodeList = {}      -- array of { cid, nodeMass * physicsFPS }
local nodeCount = 0
local allNodeCount = 0
local connectedNodes = {} -- [node cid] = { { adjacent cid, beam cid }, ... }
local parentNodeId = nil
local cogRel = nil       -- vehicle-local COG offset; rotated to world at apply time
local physicsFPS = 2000
local refNodeId = 0
local needsRecalc = false
local recalcTimer = 0
local RECALC_DELAY = 0.2
local MAX_BEAM_LENGTH_RATIO = 2
local initialized = false

local function _makeVec(x, y, z)
  if float3 then return float3(x, y, z) end
  if vec3 then return vec3(x, y, z) end
  return { x = x, y = y, z = z }
end

local function _currentRotation()
  return quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))
end

local function _buildConnectivityGraph()
  connectedNodes = {}
  parentNodeId = nil
  if not v or not v.data then return end

  for _, beam in pairs(v.data.beams or {}) do
    -- Pressure, L-beam, and support constraints are not durable structural
    -- links. Treating them as such keeps detached panels in the correction set.
    if beam.id1 ~= nil and beam.id2 ~= nil and beam.cid ~= nil
      and beam.beamType ~= 3 and beam.beamType ~= 4 and beam.beamType ~= 7 then
      connectedNodes[beam.id1] = connectedNodes[beam.id1] or {}
      connectedNodes[beam.id2] = connectedNodes[beam.id2] or {}
      connectedNodes[beam.id1][#connectedNodes[beam.id1] + 1] = { beam.id2, beam.cid }
      connectedNodes[beam.id2][#connectedNodes[beam.id2] + 1] = { beam.id1, beam.cid }
    end
  end

  local refs = v.data.refNodes and v.data.refNodes[0]
  if refs then
    local candidates = { refs.ref, refs.back, refs.left, refs.up }
    for _, cid in ipairs(candidates) do
      if cid ~= nil and connectedNodes[cid] then
        parentNodeId = cid
        break
      end
    end
  end
end

local function _beamConnects(beamCid)
  if obj.beamIsBroken then
    local ok, broken = pcall(obj.beamIsBroken, obj, beamCid)
    if ok and broken then return false end
  end
  if obj.getBeamCurLengthRefRatio then
    local ok, ratio = pcall(obj.getBeamCurLengthRefRatio, obj, beamCid)
    if ok and type(ratio) == "number" and ratio >= MAX_BEAM_LENGTH_RATIO then
      return false
    end
  end
  return true
end

local function _rebuildNodes()
  nodeList = {}
  nodeCount = 0
  allNodeCount = 0
  cogRel = nil
  if not obj or not v or not v.data or not v.data.nodes then return end

  for _, n in pairs(v.data.nodes) do
    local okMass, mass = pcall(obj.getNodeMass, obj, n.cid)
    if okMass and type(mass) == "number" and mass > 0 then
      allNodeCount = allNodeCount + 1
    end
  end

  local included = nil
  if parentNodeId then
    included = {}
    local stack = { parentNodeId }
    included[parentNodeId] = true
    while #stack > 0 do
      local cid = stack[#stack]
      stack[#stack] = nil
      for _, edge in ipairs(connectedNodes[cid] or {}) do
        local adjacent, beamCid = edge[1], edge[2]
        if not included[adjacent] and _beamConnects(beamCid) then
          included[adjacent] = true
          stack[#stack + 1] = adjacent
        end
      end
    end
  end

  local totalMass = 0
  local cog = vec3(0, 0, 0)
  for _, n in pairs(v.data.nodes) do
    local cid = n.cid
    local okMass, mass = pcall(obj.getNodeMass, obj, cid)
    if (not included or included[cid]) and okMass and type(mass) == "number" and mass > 0 then
      nodeCount = nodeCount + 1
      nodeList[nodeCount] = { cid, mass * physicsFPS }
      local p = obj:getNodePosition(cid)
      cog:setAdd(vec3(p) * mass)
      totalMass = totalMass + mass
    end
  end

  if totalMass > 0 then
    cog:setScaled(1 / totalMass)
    -- Node positions are vehicle-origin/world-orientation; store the COG in the
    -- vehicle's local frame so it stays valid as the vehicle rotates.
    cogRel = cog:rotated(_currentRotation():inversed())
  end
end

function M.recalcConnectivity()
  _rebuildNodes()
  needsRecalc = false
  recalcTimer = 0
end

function M.onInit()
  if initialized then return end
  if not obj then return end
  initialized = true
  local okFps, fps = pcall(obj.getPhysicsFPS, obj)
  if okFps and type(fps) == "number" and fps > 0 then
    physicsFPS = fps
  end
  refNodeId = 0
  if v and v.data and v.data.refNodes and v.data.refNodes[0] and v.data.refNodes[0].ref then
    refNodeId = v.data.refNodes[0].ref
  end
  _buildConnectivityGraph()
  M.recalcConnectivity()
end

function M.onBeamBroke(id, energy)
  needsRecalc = true
  recalcTimer = 0
end

function M.updateGFX(dt)
  if needsRecalc then
    recalcTimer = recalcTimer + (dt or 0)
    if recalcTimer >= RECALC_DELAY then
      M.recalcConnectivity()
    end
  end
end

-- Apply a combined linear + angular velocity delta as per-node forces.
-- dv* is the world-frame linear delta-v of the COG (m/s); dav* is the
-- angular delta-v about the COG (rad/s) in the convention of BeamNG's
-- pitch/roll/yaw angular velocity getters. Each node receives
-- force = mass * physicsFPS * (dv + r x dav), reaching the target delta in
-- one physics tick so the soft body is not torn apart.
-- NOTE: the tangential term is r x dav (not the textbook dav x r) — BeamNG's
-- angular velocity getters are negated relative to the right-handed world
-- frame, and this matches BeamMP's field-proven addAngularForce formula.
local function _applyNodeForces(dvx, dvy, dvz, davx, davy, davz)
  if nodeCount == 0 then return end
  local cx, cy, cz = 0, 0, 0
  if cogRel then
    local cog = cogRel:rotated(_currentRotation())
    cx, cy, cz = cog.x, cog.y, cog.z
  end
  for i = 1, nodeCount do
    local node = nodeList[i]
    local cid = node[1]
    local mulFps = node[2]
    local p = obj:getNodePosition(cid)
    local rx = p.x - cx
    local ry = p.y - cy
    local rz = p.z - cz
    local fx = (dvx + ry * davz - rz * davy) * mulFps
    local fy = (dvy + rz * davx - rx * davz) * mulFps
    local fz = (dvz + rx * davy - ry * davx) * mulFps
    obj:applyForceVector(cid, _makeVec(fx, fy, fz))
  end
end

local function _ensureNodes()
  if not initialized then M.onInit() end
  if nodeCount == 0 then M.recalcConnectivity() end
  return nodeCount > 0
end

function M.addVelocity(vx, vy, vz)
  if not obj then return end
  if not _ensureNodes() then return end
  -- Pure translation: the cluster API is cheap and unambiguous. Signature is
  -- (clusterNodeId, linearAccel, angularAccel); falls back to per-node forces
  -- if the binding is unavailable or rejects the call.
  -- Cluster acceleration also moves structurally disconnected nodes that still
  -- share the physics cluster briefly. Use it only while the full structure is
  -- connected; after damage, target the BFS-connected chassis nodes directly.
  if nodeCount == allNodeCount and obj.applyClusterLinearAngularAccel then
    local ok = pcall(obj.applyClusterLinearAngularAccel, obj, refNodeId,
      vec3(vx, vy, vz) * physicsFPS, vec3(0, 0, 0))
    if ok then return end
  end
  _applyNodeForces(vx, vy, vz, 0, 0, 0)
end

-- Combined linear + angular correction (world frame, about the COG).
function M.addCorrection(vx, vy, vz, avx, avy, avz)
  if not obj then return end
  if not _ensureNodes() then return end
  _applyNodeForces(vx or 0, vy or 0, vz or 0, avx or 0, avy or 0, avz or 0)
end

-- Back-compat wrapper: pure angular delta about the COG.
function M.addAngularVelocity(avx, avy, avz)
  M.addCorrection(0, 0, 0, avx, avy, avz)
end

function M.setVelocity(vx, vy, vz)
  if not obj then return end
  if not _ensureNodes() then return end
  local curVel = obj:getVelocity()
  if not curVel then return end
  M.addVelocity((vx or 0) - (curVel.x or 0), (vy or 0) - (curVel.y or 0), (vz or 0) - (curVel.z or 0))
end

-- Set the world-frame angular velocity (used after GE-side teleports, which
-- can set linear but not angular velocity).
function M.setAngularVelocity(avx, avy, avz)
  if not obj then return end
  if not _ensureNodes() then return end
  local cavx, cavy, cavz = 0, 0, 0
  if obj.getPitchAngularVelocity and obj.getRollAngularVelocity and obj.getYawAngularVelocity then
    local ok, av = pcall(function()
      return vec3(obj:getPitchAngularVelocity(), obj:getRollAngularVelocity(), obj:getYawAngularVelocity())
        :rotated(_currentRotation())
    end)
    if ok and av then
      cavx, cavy, cavz = av.x or 0, av.y or 0, av.z or 0
    end
  end
  _applyNodeForces(0, 0, 0, (avx or 0) - cavx, (avy or 0) - cavy, (avz or 0) - cavz)
end

function M.getConnectedNodeCount()
  return nodeCount
end

function M.reset()
  M.recalcConnectivity()
end

M.init = M.onInit
M.onExtensionLoaded = M.onInit
M.onReset = M.reset

return M
