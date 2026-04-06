local M = {}
M.name = "highbeam_highbeamDamageVE"

local isRemote = false
local isActive = false
local gameVehicleId = 0

local brokenBeams = {}
local damageTimer = 0
local DAMAGE_SEND_INTERVAL = 1 / 15
local dirty = false

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
  brokenBeams = {}
  damageTimer = 0
  dirty = false
end

function M.setActive(active, remote)
  isActive = active and true or false
  isRemote = remote and true or false
end

function M.onBeamBroke(beamId, energy)
  brokenBeams[beamId] = true
  dirty = true
end

function M.updateGFX(dt)
  if not isActive or isRemote or not dirty then return end
  damageTimer = damageTimer + (dt or 0)
  if damageTimer < DAMAGE_SEND_INTERVAL then return end
  damageTimer = 0
  dirty = false

  local breaks = {}
  for beamId, _ in pairs(brokenBeams) do
    breaks[#breaks + 1] = beamId
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
      _jsonEncode({ broken = breaks, deform = deforms })
    ))
  end
end

return M
