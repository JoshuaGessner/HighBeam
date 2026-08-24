local M = {}
M.type = "auxiliary"

local isRemote = false
local isActive = false
local gameVehicleId = 0
local initialized = false

local brokenBeams = {}
local brokenGroups = {}
local damageTimer = 0
local DAMAGE_SEND_INTERVAL = 1 / 15
local dirty = false
local appliedEpoch = -1
local appliedRevision = -1
local appliedBroken = {}
local appliedGroups = {}
local appliedDeforms = {}

local deformPollCursor = 0
local deformPollTimer = 0
local DEFORM_POLL_INTERVAL = 0.2
local DEFORM_FULL_SCAN_TARGET_SEC = 1.0
local DEFORM_THRESHOLD = 0.002
local lastDeformQuantized = {}
local deformGroupAuditTimer = 0
local lastDeformGroupSignature = nil
local DEFORM_GROUP_AUDIT_INTERVAL = 5.0

local function _deformGroupSignature()
  if not beamstate then return "unavailable", 0 end
  local groups = beamstate.deformGroupDamage
  if type(groups) ~= "table" then groups = beamstate.deformGroups end
  if type(groups) == "table" then
    local keys = {}
    for name, value in pairs(groups) do
      if type(value) == "number" or type(value) == "boolean" then
        keys[#keys + 1] = tostring(name) .. "=" .. tostring(value)
      elseif type(value) == "table" then
        keys[#keys + 1] = tostring(name) .. "=table"
      end
    end
    table.sort(keys)
    return table.concat(keys, ","), #keys
  end
  return "unavailable", 0
end

local function _isFinite(value, limit)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
    and math.abs(value) <= (limit or 1e20)
end

local function _ackRemoteDamage(epoch, revision, brokenCount, groupCount, deformCount, errorCount)
  if obj and obj.queueGameEngineLua then
    obj:queueGameEngineLua(string.format(
      "extensions.highbeam.onRemoteDamageApplied(%d,%d,%d,%d,%d,%d,%d)",
      gameVehicleId, epoch, revision, brokenCount, groupCount, deformCount, errorCount
    ))
  end
end

local function _clearDamageState(markDirty)
  brokenBeams = {}
  brokenGroups = {}
  damageTimer = 0
  dirty = markDirty and true or false
  deformPollCursor = 0
  deformPollTimer = 0
  lastDeformQuantized = {}
  deformGroupAuditTimer = 0
  lastDeformGroupSignature = nil
  appliedEpoch = -1
  appliedRevision = -1
  appliedBroken = {}
  appliedGroups = {}
  appliedDeforms = {}
end

local function _jsonEncode(v)
  if jsonEncode then
    local ok, out = pcall(jsonEncode, v)
    if ok then return out end
  end
  if Engine and Engine.JSONEncode then
    local ok, out = pcall(Engine.JSONEncode, v)
    if ok then return out end
  end
  local ok, json = pcall(require, "json")
  if ok and json then
    local ok2, out = pcall(json.encode, v)
    if ok2 then return out end
  end
  return "{}"
end

function M.onInit()
  if obj and obj.getID then
    gameVehicleId = obj:getID()
  end
  if initialized then return end
  initialized = true
  _clearDamageState(false)
end

function M.setActive(active, remote)
  M.onInit()
  isActive = active and true or false
  isRemote = remote and true or false
end

function M.onBeamBroke(beamId, energy)
  brokenBeams[beamId] = true
  if obj and obj.getBreakGroup then
    local ok, group = pcall(obj.getBreakGroup, obj, beamId)
    if ok and type(group) == "string" and group ~= "" then
      brokenGroups[group] = true
    end
  end
  dirty = true
end

function M.onReset()
  -- A player reset repairs the structure. Clear the accumulated break/group
  -- sets; GE sends the authoritative vehicle_reset packet and clears its
  -- delivered/pending damage bookkeeping for the new damage epoch.
  _clearDamageState(true)
end

-- Apply one authoritative structural snapshot inside VLua. GE advances its
-- bookkeeping only after the acknowledgement emitted here, so a controller
-- reload or rejected operation cannot make damage disappear permanently.
function M.applyRemoteDamage(snapshot, epoch, revision)
  if not isRemote or type(snapshot) ~= "table" then
    _ackRemoteDamage(tonumber(epoch) or 0, tonumber(revision) or 0, 0, 0, 0, 1)
    return false
  end

  epoch = math.max(0, math.floor(tonumber(epoch) or 0))
  revision = math.max(0, math.floor(tonumber(revision) or 0))
  if epoch < appliedEpoch or (epoch == appliedEpoch and revision <= appliedRevision) then
    _ackRemoteDamage(epoch, revision, 0, 0, 0, 0)
    return true
  end
  if epoch > appliedEpoch then
    appliedEpoch = epoch
    appliedRevision = -1
    appliedBroken = {}
    appliedGroups = {}
    appliedDeforms = {}
  end

  local beamCount = 0
  if obj and obj.getBeamCount then
    local okCount, count = pcall(obj.getBeamCount, obj)
    if okCount and type(count) == "number" then beamCount = math.max(0, math.floor(count)) end
  end
  if beamCount <= 0 then
    _ackRemoteDamage(epoch, revision, 0, 0, 0, 1)
    return false
  end

  local brokenCount, groupCount, deformCount, errors = 0, 0, 0, 0
  for _, rawId in ipairs(type(snapshot.broken) == "table" and snapshot.broken or {}) do
    local beamId = tonumber(rawId)
    if _isFinite(beamId, beamCount) and beamId == math.floor(beamId)
      and beamId >= 0 and beamId < beamCount then
      if not appliedBroken[beamId] then
        local okBreak = pcall(function()
          obj:breakBeam(beamId)
          if beamstate and beamstate.beamBroken then beamstate.beamBroken(beamId, 1) end
        end)
        if okBreak then
          appliedBroken[beamId] = true
          brokenCount = brokenCount + 1
        else
          errors = errors + 1
        end
      end
    end
  end

  for _, rawGroup in ipairs(type(snapshot.breakGroups) == "table" and snapshot.breakGroups or {}) do
    local group = tostring(rawGroup or "")
    if #group > 0 and #group <= 128 and not appliedGroups[group] then
      local okGroup = pcall(function()
        if beamstate and beamstate.breakBreakGroup then beamstate.breakBreakGroup(group) end
        if props and props.hidePropsInBreakGroup then props.hidePropsInBreakGroup(group) end
      end)
      if okGroup then
        appliedGroups[group] = true
        groupCount = groupCount + 1
      else
        errors = errors + 1
      end
    end
  end

  for rawId, value in pairs(type(snapshot.deform) == "table" and snapshot.deform or {}) do
    local beamId = tonumber(rawId)
    local deformation = type(value) == "table" and tonumber(value[1]) or nil
    local restLength = type(value) == "table" and tonumber(value[2]) or tonumber(value)
    if _isFinite(beamId, beamCount) and beamId == math.floor(beamId)
      and beamId >= 0 and beamId < beamCount
      and _isFinite(deformation or 0, 1000) and _isFinite(restLength, 1000)
      and restLength > 0.0001 then
      local quantized = math.floor(restLength * 10000 + 0.5) / 10000
      if appliedDeforms[beamId] ~= quantized then
        local okDeform = pcall(function()
          obj:setBeamLength(beamId, quantized)
          if beamstate and beamstate.beamDeformed and (deformation or 0) > 0 then
            beamstate.beamDeformed(beamId, deformation)
          end
        end)
        if okDeform then
          appliedDeforms[beamId] = quantized
          deformCount = deformCount + 1
        else
          errors = errors + 1
        end
      end
    end
  end

  if errors == 0 then appliedRevision = revision end
  _ackRemoteDamage(epoch, revision, brokenCount, groupCount, deformCount, errors)
  return errors == 0
end

function M.auditRemoteDamage(snapshot, epoch, revision)
  if not isRemote or type(snapshot) ~= "table" or not obj or not obj.getBeamCount then return end
  local authoritativeBroken = {}
  for _, rawId in ipairs(type(snapshot.broken) == "table" and snapshot.broken or {}) do
    local id = tonumber(rawId)
    if id then authoritativeBroken[math.floor(id)] = true end
  end

  local extraBroken, missingBroken, deformMismatch = 0, 0, 0
  local okCount, beamCount = pcall(obj.getBeamCount, obj)
  if not okCount or type(beamCount) ~= "number" then return end
  for beamId = 0, beamCount - 1 do
    local okBroken, broken = pcall(obj.beamIsBroken, obj, beamId)
    if okBroken then
      if broken and not authoritativeBroken[beamId] then extraBroken = extraBroken + 1 end
      if not broken and authoritativeBroken[beamId] then missingBroken = missingBroken + 1 end
    end
  end
  for rawId, value in pairs(type(snapshot.deform) == "table" and snapshot.deform or {}) do
    local beamId = tonumber(rawId)
    local expected = type(value) == "table" and tonumber(value[2]) or tonumber(value)
    if beamId and expected and beamId >= 0 and beamId < beamCount then
      local okRest, actual = pcall(obj.getBeamRestLength, obj, beamId)
      if not okRest or not actual or math.abs(actual - expected) > 0.002 then
        deformMismatch = deformMismatch + 1
      end
    end
  end
  if obj.queueGameEngineLua then
    obj:queueGameEngineLua(string.format(
      "extensions.highbeam.onRemoteDamageAudit(%d,%d,%d,%d,%d,%d)",
      gameVehicleId, math.floor(tonumber(epoch) or 0), math.floor(tonumber(revision) or 0),
      extraBroken, missingBroken, deformMismatch
    ))
  end
end

function M.updateGFX(dt)
  if not isActive or isRemote then return end

  deformGroupAuditTimer = deformGroupAuditTimer + (dt or 0)
  if deformGroupAuditTimer >= DEFORM_GROUP_AUDIT_INTERVAL then
    deformGroupAuditTimer = 0
    local signature, count = _deformGroupSignature()
    if signature ~= lastDeformGroupSignature then
      lastDeformGroupSignature = signature
      if obj and obj.queueGameEngineLua then
        obj:queueGameEngineLua(string.format(
          "extensions.highbeam.onVEDeformGroupAudit(%d,%d,%q)",
          gameVehicleId, count, signature:sub(1, 512)
        ))
      end
    end
  end

  deformPollTimer = deformPollTimer + (dt or 0)
  if not dirty and deformPollTimer >= DEFORM_POLL_INTERVAL then
    deformPollTimer = 0
    if obj and obj.getBeamCount and obj.getBeamDeformation then
      local okCount, beamCount = pcall(obj.getBeamCount, obj)
      if okCount and type(beamCount) == "number" and beamCount > 0 then
        local startIdx = deformPollCursor
        local pollBatch = math.max(10, math.ceil(beamCount * DEFORM_POLL_INTERVAL / DEFORM_FULL_SCAN_TARGET_SEC))
        for i = 0, pollBatch - 1 do
          local beamIdx = (startIdx + i) % beamCount
          local okDef, deform = pcall(obj.getBeamDeformation, obj, beamIdx)
          local quantized = (okDef and _isFinite(deform, 1000) and deform > DEFORM_THRESHOLD)
            and (math.floor(deform * 10000 + 0.5) / 10000) or 0
          if quantized ~= (lastDeformQuantized[beamIdx] or 0) then
            lastDeformQuantized[beamIdx] = quantized
            dirty = true
            if obj.queueGameEngineLua then
              obj:queueGameEngineLua("extensions.highbeam.onVEDamageDirty(" .. gameVehicleId .. ")")
            end
            break
          end
        end
        deformPollCursor = (startIdx + pollBatch) % beamCount
      end
    end
  end

  if not dirty then return end
  damageTimer = damageTimer + (dt or 0)
  if damageTimer < DAMAGE_SEND_INTERVAL then return end
  damageTimer = 0
  dirty = false

  local breaks = {}
  for beamId, _ in pairs(brokenBeams) do
    breaks[#breaks + 1] = beamId
  end
  table.sort(breaks)

  local groups = {}
  for group, _ in pairs(brokenGroups) do
    groups[#groups + 1] = group
  end
  table.sort(groups)

  local deforms = {}
  if obj and obj.getBeamCount and obj.beamIsBroken and obj.getBeamDeformation and obj.getBeamRestLength then
    local okCount, beamCount = pcall(obj.getBeamCount, obj)
    if okCount and type(beamCount) == "number" then
      for beamId = 0, beamCount - 1 do
        local okBroken, isBroken = pcall(obj.beamIsBroken, obj, beamId)
        if okBroken and not isBroken then
          local okDef, deform = pcall(obj.getBeamDeformation, obj, beamId)
          if okDef and deform and deform > 0.001 then
            local okRest, restLen = pcall(obj.getBeamRestLength, obj, beamId)
            if okRest and restLen then
              local quantizedDef = math.floor(deform * 10000 + 0.5) / 10000
              local quantizedRest = math.floor(restLen * 10000 + 0.5) / 10000
              lastDeformQuantized[beamId] = quantizedDef
              deforms[tostring(beamId)] = { quantizedDef, quantizedRest }
            end
          elseif okDef then
            lastDeformQuantized[beamId] = 0
          end
        end
      end
    end
  end

  if obj and obj.queueGameEngineLua then
    obj:queueGameEngineLua(string.format(
      "extensions.highbeam.onVEDamage(%d,%q)",
      gameVehicleId,
      _jsonEncode({ broken = breaks, breakGroups = groups, deform = deforms })
    ))
  end
end

M.init = M.onInit
M.onExtensionLoaded = M.onInit

return M
