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

local deformPollCursor = 0
local deformPollTimer = 0
local DEFORM_POLL_INTERVAL = 0.2
local DEFORM_POLL_BATCH = 10
local DEFORM_THRESHOLD = 0.002

local function _clearDamageState(markDirty)
  brokenBeams = {}
  brokenGroups = {}
  damageTimer = 0
  dirty = markDirty and true or false
  deformPollCursor = 0
  deformPollTimer = 0
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

function M.updateGFX(dt)
  if not isActive or isRemote then return end

  deformPollTimer = deformPollTimer + (dt or 0)
  if not dirty and deformPollTimer >= DEFORM_POLL_INTERVAL then
    deformPollTimer = 0
    if obj and obj.getBeamCount and obj.getBeamDeformation then
      local okCount, beamCount = pcall(obj.getBeamCount, obj)
      if okCount and type(beamCount) == "number" and beamCount > 0 then
        local startIdx = deformPollCursor
        for i = 0, DEFORM_POLL_BATCH - 1 do
          local beamIdx = (startIdx + i) % beamCount
          local okDef, deform = pcall(obj.getBeamDeformation, obj, beamIdx)
          if okDef and deform and deform > DEFORM_THRESHOLD then
            dirty = true
            if obj.queueGameEngineLua then
              obj:queueGameEngineLua("extensions.highbeam.onVEDamageDirty(" .. gameVehicleId .. ")")
            end
            break
          end
        end
        deformPollCursor = (startIdx + DEFORM_POLL_BATCH) % beamCount
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

  local groups = {}
  for group, _ in pairs(brokenGroups) do
    groups[#groups + 1] = group
  end

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
              deforms[tostring(beamId)] = { deform, restLen }
            end
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
