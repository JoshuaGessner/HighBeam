local M = {}
M.name = "highbeam_highbeamVelocityVE"

local connectedNodes = {}
local connectedNodeCount = 0
local totalConnectedMass = 0
local cogX, cogY, cogZ = 0, 0, 0
local needsRecalc = false
local recalcTimer = 0
local RECALC_DELAY = 0.2

local lastDtSim = 0.0005

local function _makeVec(x, y, z)
  if float3 then return float3(x, y, z) end
  if Point3F then return Point3F(x, y, z) end
  if vec3 then return vec3(x, y, z) end
  return { x = x, y = y, z = z }
end

local function _nodePos(nodeId)
  if not obj or not obj.getNodePosition then return nil end
  local ok, p = pcall(obj.getNodePosition, obj, nodeId)
  if not ok or not p then return nil end
  return p
end

local function _nodeMass(nodeId)
  if not obj or not obj.getNodeMass then return 0 end
  local ok, m = pcall(obj.getNodeMass, obj, nodeId)
  if not ok or type(m) ~= "number" then return 0 end
  return m
end

local function _setAllNodesConnected()
  connectedNodes = {}
  connectedNodeCount = 0
  totalConnectedMass = 0
  cogX, cogY, cogZ = 0, 0, 0

  if not obj or not obj.getNodeCount then return end
  local okCount, nodeCount = pcall(obj.getNodeCount, obj)
  if not okCount or type(nodeCount) ~= "number" or nodeCount <= 0 then return end

  local mx, my, mz = 0, 0, 0
  for nodeId = 0, nodeCount - 1 do
    connectedNodes[nodeId] = true
    connectedNodeCount = connectedNodeCount + 1

    local mass = _nodeMass(nodeId)
    local p = _nodePos(nodeId)
    if p and mass > 0 then
      mx = mx + (p.x or 0) * mass
      my = my + (p.y or 0) * mass
      mz = mz + (p.z or 0) * mass
      totalConnectedMass = totalConnectedMass + mass
    end
  end

  if totalConnectedMass > 0 then
    cogX = mx / totalConnectedMass
    cogY = my / totalConnectedMass
    cogZ = mz / totalConnectedMass
  else
    cogX, cogY, cogZ = 0, 0, 0
  end
end

function M.recalcConnectivity()
  _setAllNodesConnected()
  needsRecalc = false
  recalcTimer = 0
end

function M.onInit()
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

function M.onPhysicsStep(dtSim)
  if dtSim and dtSim > 0 then
    lastDtSim = dtSim
  end
end

function M.addVelocity(vx, vy, vz)
  if not obj then return end
  -- Auto-recover if onInit ran before physics mesh was ready (zero nodes)
  if connectedNodeCount == 0 then
    M.recalcConnectivity()
    if connectedNodeCount == 0 then return end
  end
  local dtSim = math.max(0.0001, lastDtSim or 0.0005)
  local physicsFps = 1 / dtSim

  if obj.applyClusterLinearAngularAccel and connectedNodeCount > 0 and obj.getNodeCount then
    local okNodeCount, nodeCount = pcall(obj.getNodeCount, obj)
    if okNodeCount and nodeCount and nodeCount > 0 and (connectedNodeCount / nodeCount) > 0.9 then
      pcall(obj.applyClusterLinearAngularAccel, obj, vx * physicsFps, vy * physicsFps, vz * physicsFps, 0, 0, 0)
      return
    end
  end

  if obj.applyForceVector then
    for nodeId, _ in pairs(connectedNodes) do
      local mass = _nodeMass(nodeId)
      if mass > 0 then
        local fx = vx * mass * physicsFps
        local fy = vy * mass * physicsFps
        local fz = vz * mass * physicsFps
        pcall(obj.applyForceVector, obj, nodeId, _makeVec(fx, fy, fz))
      end
    end
  end
end

function M.addAngularVelocity(avx, avy, avz, px, py, pz)
  if not obj then return end
  -- Auto-recover if onInit ran before physics mesh was ready (zero nodes)
  if connectedNodeCount == 0 then
    M.recalcConnectivity()
    if connectedNodeCount == 0 then return end
  end
  local dtSim = math.max(0.0001, lastDtSim or 0.0005)
  local physicsFps = 1 / dtSim

  if obj.applyClusterLinearAngularAccel and connectedNodeCount > 0 and obj.getNodeCount then
    local okNodeCount, nodeCount = pcall(obj.getNodeCount, obj)
    if okNodeCount and nodeCount and nodeCount > 0 and (connectedNodeCount / nodeCount) > 0.9 then
      pcall(obj.applyClusterLinearAngularAccel, obj, 0, 0, 0, avx * physicsFps, avy * physicsFps, avz * physicsFps)
      return
    end
  end

  local cx = px or cogX
  local cy = py or cogY
  local cz = pz or cogZ

  if obj.applyForceVector then
    for nodeId, _ in pairs(connectedNodes) do
      local p = _nodePos(nodeId)
      local mass = _nodeMass(nodeId)
      if p and mass > 0 then
        local rx = (p.x or 0) - cx
        local ry = (p.y or 0) - cy
        local rz = (p.z or 0) - cz

        local vx = avy * rz - avz * ry
        local vy = avz * rx - avx * rz
        local vz = avx * ry - avy * rx

        local fx = vx * mass * physicsFps
        local fy = vy * mass * physicsFps
        local fz = vz * mass * physicsFps
        pcall(obj.applyForceVector, obj, nodeId, _makeVec(fx, fy, fz))
      end
    end
  end
end

function M.getCOG()
  return cogX, cogY, cogZ
end

function M.getConnectedNodeCount()
  return connectedNodeCount
end

return M
