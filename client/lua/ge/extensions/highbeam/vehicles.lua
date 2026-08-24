local M = {}
local logTag = "HighBeam.Vehicles"

M.remoteVehicles = {} -- [playerId_vehicleId] = vehicleData
M._pendingRemoteState = {} -- state received before a logical remote exists
M._deletedRemoteKeys = {} -- short-lived tombstones for deferred WorldState races
M._remoteGameIds = {} -- [gameVehicleId] = true  (quick lookup for isRemote)
M._spawningRemote = false -- Guard flag: true while core_vehicles.spawnNewVehicle is in-flight
M._debugStats = {}  -- P0: Exposed debug stats for overlay

local config = require("highbeam/config")
local _diagTimer = 0
local _diagIntervalSec = 5.0
local _staleDropCount = 0
local _packetInterArrival = {}
local _spawnRetryDropCount = 0
local _spawnRetryAttemptCount = 0
local _spawnRetrySuccessCount = 0
local SPAWN_RETRY_MAX_ATTEMPTS = 15
local SPAWN_RETRY_BASE_DELAY = 0.75
local VE_PROBE_RETRY_DELAY = 0.5      -- seconds between VE probe retries
local VE_PROBE_MAX_RETRIES = 6        -- max re-probes before giving up
local RESET_BURST_WINDOW_SEC = 0.75
local RESET_STABILIZE_SEC = 0.35
local VE_DEATH_WINDOW_SEC = 30.0
local VE_DEATH_RESPAWN_THRESHOLD = 3
local VE_RESPAWN_WINDOW_SEC = 60.0
local VE_RESPAWN_MAX_ATTEMPTS = 2
local _componentApplyStats = {}
local makeKey
local _spawnGameVehicle
local _queueRemoteVeBootstrap

local function _cogToOrigin(pos, rot, cogRel)
  if type(pos) ~= "table" or type(rot) ~= "table" or type(cogRel) ~= "table" then return pos end
  local ok, origin = pcall(function()
    local offset = vec3(cogRel[1] or 0, cogRel[2] or 0, cogRel[3] or 0)
      :rotated(quat(rot[1] or 0, rot[2] or 0, rot[3] or 0, rot[4] or 1))
    return { (pos[1] or 0) - offset.x, (pos[2] or 0) - offset.y, (pos[3] or 0) - offset.z }
  end)
  return ok and origin or pos
end

local function _isFinite(value, limit)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
    and math.abs(value) <= (limit or 1e20)
end

local INPUT_KEYS = { "l", "s", "t", "b", "p", "c", "k", "g" }
local INPUT_KEY_SET = { l = true, s = true, t = true, b = true, p = true, c = true, k = true, g = true }

local function _mergeInputState(state, deltaStr)
  state = state or {}
  if type(deltaStr) ~= "string" then return state end
  for part in string.gmatch(deltaStr, "[^,]+") do
    local key, raw = string.match(part, "^([%a]+)=([^,]+)$")
    if key and INPUT_KEY_SET[key] then
      local numeric = tonumber(raw)
      if numeric and _isFinite(numeric, 1e4) then
        state[key] = numeric
      elseif (key == "g" or key == "k") and #raw <= 16 and string.match(raw, "^[%w%+%-%.]+$") then
        state[key] = raw
      end
    end
  end
  return state
end

local function _serializeInputState(state)
  local parts = {}
  for _, key in ipairs(INPUT_KEYS) do
    local value = state and state[key]
    if value ~= nil then parts[#parts + 1] = key .. "=" .. tostring(value) end
  end
  return table.concat(parts, ",")
end

local function _validMotion(decoded)
  if type(decoded) ~= "table" or type(decoded.pos) ~= "table"
    or type(decoded.rot) ~= "table" or type(decoded.vel) ~= "table" then return false end
  local limits = { 1e7, 4, 1e5 }
  for i = 1, 3 do
    if not _isFinite(tonumber(decoded.pos[i]), limits[1])
      or not _isFinite(tonumber(decoded.vel[i]), limits[3]) then return false end
  end
  for i = 1, 4 do
    if not _isFinite(tonumber(decoded.rot[i]), limits[2]) then return false end
  end
  if not _isFinite(tonumber(decoded.time), 1e9) then return false end
  if decoded.angVel then
    for i = 1, 3 do
      if not _isFinite(tonumber(decoded.angVel[i]), 1e4) then return false end
    end
  end
  return true
end

local function _verboseSyncLoggingEnabled()
  return config and config.get and config.get("verboseSyncLogging") == true
end

local function _bumpApplyStat(name)
  local key = tostring(name)
  _componentApplyStats[key] = (_componentApplyStats[key] or 0) + 1
end

local function _resetFingerprint(cfg)
  if type(cfg) ~= "table" or type(cfg.pos) ~= "table" or type(cfg.rot) ~= "table" then
    return "invalid"
  end
  return table.concat({
    string.format('%.2f', tonumber(cfg.pos[1]) or 0),
    string.format('%.2f', tonumber(cfg.pos[2]) or 0),
    string.format('%.2f', tonumber(cfg.pos[3]) or 0),
    string.format('%.3f', tonumber(cfg.rot[1]) or 0),
    string.format('%.3f', tonumber(cfg.rot[2]) or 0),
    string.format('%.3f', tonumber(cfg.rot[3]) or 0),
    string.format('%.3f', tonumber(cfg.rot[4]) or 1),
  }, ',')
end

local function _rememberTimedEvent(list, now, windowSec)
  list[#list + 1] = now
  local i = 1
  while i <= #list do
    if (now - list[i]) > windowSec then
      table.remove(list, i)
    else
      i = i + 1
    end
  end
  return #list
end

local function _isStabilizing(rv)
  return rv and rv._stabilizeUntil and os.clock() < rv._stabilizeUntil
end

-- A freshly spawned puppet needs a moment for its soft-body to settle before we
-- start breaking beams. Dropping a large bulk of beam breaks onto an unsettled
-- structure detonates it ("Instability detected"). We defer damage until the VE
-- is confirmed alive and a short settle window has elapsed since it became ready.
local DAMAGE_SETTLE_SEC = 2.0
local function _isSettling(rv)
  if not rv then return false end
  if not rv._hasVE or not rv._veReadyAt then return true end
  return (os.clock() - rv._veReadyAt) < DAMAGE_SETTLE_SEC
end

local function _applyDeferredAfterStabilize(rv, key)
  if not rv or _isStabilizing(rv) then return end
  if rv._pendingResetData and rv.gameVehicle then
    local pending = rv._pendingResetData
    M.resetRemote(rv.playerId, rv.vehicleId, pending)
    if rv._lastResetPayload == pending then rv._pendingResetData = nil end
    return
  end
  if rv._pendingPowertrainData then
    local pending = rv._pendingPowertrainData
    rv._pendingPowertrainData = nil
    M.applyPowertrain(rv.playerId, rv.vehicleId, pending)
    _bumpApplyStat("powertrain_replayed_after_reset")
  end
  if rv._pendingElectricsData and rv._hasVE then
    local pending = rv._pendingElectricsData
    rv._pendingElectricsData = nil
    M.applyElectrics(rv.playerId, rv.vehicleId, pending)
  end
  if rv._pendingInputsData and rv._hasVE then
    local pending = rv._pendingInputsData
    rv._pendingInputsData = nil
    M.applyInputs(rv.playerId, rv.vehicleId, pending)
  end
  if rv._pendingDamageData and not _isSettling(rv) then
    M.applyDamage(rv.playerId, rv.vehicleId, rv._pendingDamageData)
    _bumpApplyStat("damage_replay_attempt")
  end
end

local function _respawnRemoteVehicle(rv, key, reason)
  if not rv or not rv.spawnSpec then return false end
  local now = os.clock()
  rv._veRespawnEvents = rv._veRespawnEvents or {}
  local respawnsInWindow = _rememberTimedEvent(rv._veRespawnEvents, now, VE_RESPAWN_WINDOW_SEC)
  if respawnsInWindow > VE_RESPAWN_MAX_ATTEMPTS then
    rv._veUnhealthy = true
    rv._hasVE = false
    log('E', logTag, 'Remote VE marked unhealthy key=' .. tostring(key)
      .. ' reason=' .. tostring(reason)
      .. ' respawns=' .. tostring(respawnsInWindow)
      .. ' window=' .. tostring(VE_RESPAWN_WINDOW_SEC) .. 's')
    return false
  end

  local latest = rv.snapshots and rv.snapshots[#rv.snapshots]
  if latest then
    rv.spawnSpec.pos = _cogToOrigin(latest.pos, latest.rot, rv._cogRel)
    rv.spawnSpec.rot = latest.rot
    rv.spawnSpec.vel = latest.vel
  end

  if rv.gameVehicleId then
    M._remoteGameIds[rv.gameVehicleId] = nil
    pcall(function()
      local obj = be:getObjectByID(rv.gameVehicleId)
      if obj then obj:delete() end
    end)
  end

  rv.gameVehicleId = nil
  rv.gameVehicle = nil
  rv._hasVE = false
  rv._componentQueue = {}
  rv._componentQueueLen = 0
  -- Internal puppet respawns must preserve the latest authoritative damage.
  -- A player repair reset clears this state separately in resetRemote.
  rv._pendingDamageData = rv._lastDamageData
  rv._pendingPowertrainData = rv._lastPowertrainData
  rv._pendingElectricsData = rv._lastElectricsData
  rv._pendingInputsData = rv._lastInputsData
  rv._damageInFlight = nil
  rv._damageApplyErrors = 0
  rv._damageRetryAt = nil
  rv._appliedBrokenBeams = nil
  rv._appliedBreakGroups = nil
  rv._appliedDeformLengths = nil
  rv._stabilizeUntil = nil

  local vid, vehObj, spawnErr = _spawnGameVehicle(rv.spawnSpec)
  if vid then
    rv.gameVehicleId = vid
    rv.gameVehicle = vehObj
    M._remoteGameIds[vid] = true
    rv._veProbeRetries = 0
    rv._veProbeQueuedAt = nil
    rv._veLastHeartbeat = nil
    rv._veReadyAt = nil
    rv._veUnhealthy = false
    _queueRemoteVeBootstrap(rv, key)
    log('W', logTag, 'Remote VE respawned key=' .. tostring(key)
      .. ' gameVid=' .. tostring(vid)
      .. ' reason=' .. tostring(reason)
      .. ' respawns=' .. tostring(respawnsInWindow))
    return true
  end

  rv.spawnRetry = {
    attempts = 1,
    nextAt = now + SPAWN_RETRY_BASE_DELAY,
    lastError = spawnErr,
  }
  log('E', logTag, 'Remote VE respawn failed key=' .. tostring(key)
    .. ' reason=' .. tostring(reason)
    .. ' err=' .. tostring(spawnErr))
  return false
end

local function _withRemoteVehicle(playerId, vehicleId, stage)
  local key = makeKey(playerId, vehicleId)
  local rv = M.remoteVehicles[key]
  if not rv then
    _bumpApplyStat(stage .. "_drop_no_remote")
    if _verboseSyncLoggingEnabled() then
      log('D', logTag, stage .. ' drop no remote key=' .. key)
    end
    return nil, nil, key
  end

  local veh = rv.gameVehicle or (rv.gameVehicleId and scenetree.findObjectById(rv.gameVehicleId))
  if not veh then
    _bumpApplyStat(stage .. "_drop_no_game_vehicle")
    if _verboseSyncLoggingEnabled() then
      log('D', logTag, stage .. ' drop no game vehicle key=' .. key
        .. ' gameVehicleId=' .. tostring(rv.gameVehicleId))
    end
    return nil, rv, key
  end

  return veh, rv, key
end

local function _isMalformedVeLuaChunk(chunk)
  if type(chunk) ~= "string" or chunk == "" then
    return true, "empty_chunk"
  end
  if string.find(chunk, "thenif", 1, true) then
    return true, "token_thenif"
  end
  local badToken = string.match(chunk, "highbeam[%w_]+end")
  if badToken then
    return true, badToken
  end
  return false, nil
end

local function _queueVeLuaCommand(veh, chunk, stage)
  local malformed, reason = _isMalformedVeLuaChunk(chunk)
  if malformed then
    _bumpApplyStat((stage or "ve_cmd") .. "_drop_malformed")
    log('E', logTag, 'Dropped malformed VE command stage=' .. tostring(stage)
      .. ' reason=' .. tostring(reason)
      .. ' chunk=' .. tostring(chunk))
    return false
  end
  local ok = pcall(function()
    veh:queueLuaCommand(chunk)
  end)
  if not ok then
    _bumpApplyStat((stage or "ve_cmd") .. "_error_apply")
    return false
  end
  return true
end

local function _countPendingSpawnRetries()
  local count = 0
  for _, rv in pairs(M.remoteVehicles) do
    if rv.spawnRetry then
      count = count + 1
    end
  end
  return count
end

local function _getConfigNumber(key, fallback)
  local value = config and config.get and config.get(key) or nil
  if type(value) == "number" then
    return value
  end
  return fallback
end

local function _getMaxSnapshots()
  return 2  -- Only need latest + previous for spawn retry and nametag lookups
end

local COMPONENT_QUEUE_MAX = 50  -- max queued component packets per remote vehicle while VE boots

local function _enqueueComponent(rv, entry)
  if not rv._componentQueue then rv._componentQueue = {} end
  rv._componentQueueLen = (rv._componentQueueLen or 0) + 1
  if rv._componentQueueLen > COMPONENT_QUEUE_MAX then
    table.remove(rv._componentQueue, 1)
    rv._componentQueueLen = rv._componentQueueLen - 1
  end
  table.insert(rv._componentQueue, entry)
end

local function _flushComponentQueue(rv)
  if not rv._componentQueue or rv._componentQueueLen == 0 then return end
  local flushed = 0
  for _, entry in ipairs(rv._componentQueue) do
    if entry.kind == "inputs" then
      M.applyInputs(rv.playerId, rv.vehicleId, entry.data)
    elseif entry.kind == "electrics" then
      M.applyElectrics(rv.playerId, rv.vehicleId, entry.data)
    elseif entry.kind == "powertrain" then
      M.applyPowertrain(rv.playerId, rv.vehicleId, entry.data)
    end
    flushed = flushed + 1
  end
  rv._componentQueue = {}
  rv._componentQueueLen = 0
  if flushed > 0 then
    log('D', logTag, 'Flushed ' .. tostring(flushed) .. ' queued components for '
      .. tostring(rv.playerId) .. '_' .. tostring(rv.vehicleId))
  end
end

makeKey = function(playerId, vehicleId)
  return tostring(playerId) .. "_" .. tostring(vehicleId)
end

_queueRemoteVeBootstrap = function(rv, key)
  if not rv or not rv.gameVehicle then return end
  local vehObj = rv.gameVehicle
  pcall(function()
    vehObj:queueLuaCommand([[
      local function hbGetController(name)
        if not controller or not controller.getController then return nil end
        local ok, mod = pcall(controller.getController, name)
        if ok then return mod end
        return nil
      end
      local function hbLoadController(name)
        local mod = hbGetController(name)
        if mod then return mod end
        if not controller or not controller.loadControllerExternal then
          return nil, "controller.loadControllerExternal unavailable"
        end
        local ok, err = pcall(controller.loadControllerExternal, "highbeam/" .. name, name)
        if not ok then return nil, tostring(err) end
        mod = hbGetController(name)
        if not mod then return nil, "controller.getController returned nil after load" end
        return mod
      end
      local function hbRequireController(name, missing)
        local mod, err = hbLoadController(name)
        if not mod then table.insert(missing, name .. ":" .. tostring(err or "missing")) end
        return mod
      end
      local _missing = {}
      hbRequireController("highbeamVelocityVE", _missing)
      hbRequireController("highbeamPositionVE", _missing)
      hbRequireController("highbeamInputsVE", _missing)
      hbRequireController("highbeamElectricsVE", _missing)
      hbRequireController("highbeamPowertrainVE", _missing)
      hbRequireController("highbeamDamageVE", _missing)
      local highbeam = hbRequireController("highbeamVE", _missing)
      local _ready = false
      if highbeam and highbeam.setActive then
        local ok, err = pcall(highbeam.setActive, true, true)
        if ok then
          _ready = true
        else
          table.insert(_missing, "highbeamVE.setActive:" .. tostring(err))
        end
      elseif highbeam then
        table.insert(_missing, "highbeamVE.setActive:missing")
      end
      if #_missing > 0 then _ready = false end
      local _missingCsv = table.concat(_missing, ",")
      local _vel = hbGetController("highbeamVelocityVE")
      if _vel and _vel.getCogRel then
        local _okCog, _cog = pcall(_vel.getCogRel)
        if _okCog and _cog then
          obj:queueGameEngineLua(
            "if extensions and extensions.highbeam and extensions.highbeam.onRemoteVECog then extensions.highbeam.onRemoteVECog(" .. tostring(obj:getID()) .. "," .. tostring(_cog.x or 0) .. "," .. tostring(_cog.y or 0) .. "," .. tostring(_cog.z or 0) .. ") end"
          )
        end
      end
      obj:queueGameEngineLua(
        "if extensions and extensions.highbeam and extensions.highbeam.onRemoteVEReady then extensions.highbeam.onRemoteVEReady(" .. tostring(obj:getID()) .. "," .. tostring(_ready) .. "," .. string.format("%q", _missingCsv) .. ") end"
      )
    ]])
  end)
  rv._veProbeQueuedAt = os.clock()
  rv._veProbeMissing = nil
  rv._hasVE = false
  if _verboseSyncLoggingEnabled() then
    log('D', logTag, 'Queued remote VE bootstrap key=' .. tostring(key)
      .. ' gameVid=' .. tostring(rv.gameVehicleId))
  end
end

M.onRemoteVECog = function(gameVehicleId, x, y, z)
  for _, rv in pairs(M.remoteVehicles) do
    if rv.gameVehicleId == gameVehicleId then
      rv._cogRel = { tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0 }
      return
    end
  end
end

M.onRemoteVEReady = function(gameVehicleId, ready, missingCsv)
  if not gameVehicleId then return end
  local readyBool = (ready == true) or (ready == 1) or (tostring(ready) == "true")
  for key, rv in pairs(M.remoteVehicles) do
    if rv and rv.gameVehicleId == gameVehicleId then
      rv._hasVE = readyBool
      rv._veReadyAt = os.clock()
      rv._veLastHeartbeat = os.clock()
      rv._veProbeMissing = missingCsv
      if readyBool then
        rv._veProbeRetries = VE_PROBE_MAX_RETRIES  -- stop retrying
        log('I', logTag, 'Remote VE confirmed key=' .. tostring(key)
          .. ' gameVid=' .. tostring(gameVehicleId)
          .. ' retries=' .. tostring(rv._veProbeRetries or 0))
        _flushComponentQueue(rv)
      else
        local missing = tostring(missingCsv or '')
        local retries = rv._veProbeRetries or 0
        if retries < VE_PROBE_MAX_RETRIES then
          log('D', logTag, 'VE probe pending retry key=' .. tostring(key)
            .. ' gameVid=' .. tostring(gameVehicleId)
            .. ' attempt=' .. tostring(retries)
            .. ' missing=' .. (missing ~= '' and missing or 'unknown'))
        else
          log('W', logTag, 'Remote VE failed after retries key=' .. tostring(key)
            .. ' gameVid=' .. tostring(gameVehicleId)
            .. ' missing=' .. (missing ~= '' and missing or 'unknown'))
        end
      end
      return
    end
  end
end

-- Receive heartbeat from remote vehicle's positionVE (sent every ~1s while vlua alive).
-- Updates _veLastHeartbeat timestamp used by death detection in onUpdate.
local VE_DEATH_TIMEOUT_SEC = 5.0
M.onVEHeartbeat = function(gameVehicleId)
  if not gameVehicleId then return end
  for _, rv in pairs(M.remoteVehicles) do
    if rv and rv.gameVehicleId == gameVehicleId and rv._hasVE then
      rv._veLastHeartbeat = os.clock()
      return
    end
  end
end

-- Decode JSON config using available decoders
local function _decodeJson(str)
  if not str or str == '' then return nil end
  local decoded
  if jsonDecode then
    local ok, t = pcall(jsonDecode, str)
    if ok then return t end
  end
  if Engine and Engine.JSONDecode then
    local ok, t = pcall(Engine.JSONDecode, str)
    if ok then return t end
  end
  local ok, jsonLib = pcall(require, "json")
  if ok and jsonLib then
    local ok2, t = pcall(jsonLib.decode, str)
    if ok2 then return t end
  end
  return nil
end

local function _buildSpawnSpec(configData, snapshot)
  local cfg = _decodeJson(configData) or {}
  return {
    model = cfg.model or "pickup",
    partCfg = cfg.partConfig or "",
    pos = (snapshot and snapshot.position) or cfg.pos or { 0, 0, 0 },
    rot = (snapshot and snapshot.rotation) or cfg.rot or { 0, 0, 0, 1 },
    vel = (snapshot and snapshot.velocity) or { 0, 0, 0 },
    snapshotTimeMs = snapshot and snapshot.snapshotTimeMs,
  }
end

_spawnGameVehicle = function(spec)
  local vehObj = nil
  M._spawningRemote = true
  log('I', logTag, '_spawnGameVehicle: model=' .. tostring(spec.model)
    .. ' partCfg=' .. tostring(spec.partCfg and string.sub(spec.partCfg, 1, 60) or 'nil')
    .. ' pos=' .. tostring(spec.pos and spec.pos[1])
    .. ' core_vehicles=' .. tostring(core_vehicles ~= nil)
    .. ' spawnNewVehicle=' .. tostring(core_vehicles and core_vehicles.spawnNewVehicle ~= nil))

  -- Save the player's current vehicle so we can restore focus after spawn
  local savedPlayerVeh = be and be:getPlayerVehicle(0) or nil

  local ok, err = pcall(function()
    vehObj = core_vehicles.spawnNewVehicle(spec.model, {
      config = spec.partCfg,
      pos = vec3(spec.pos[1], spec.pos[2], spec.pos[3]),
      rot = quat(0, 0, 0, 1),
      autoEnterVehicle = false,
      cling = true,
    })
  end)

  log('I', logTag, '_spawnGameVehicle: primary pcall ok=' .. tostring(ok)
    .. ' vehObj=' .. tostring(vehObj) .. ' type=' .. type(vehObj)
    .. ' err=' .. tostring(err))

  if not ok or not vehObj then
    local firstErr = err
    local ok2
    log('I', logTag, '_spawnGameVehicle: primary failed, trying fallback pickup')
    ok2, err = pcall(function()
      vehObj = core_vehicles.spawnNewVehicle("pickup", {
        pos = vec3(spec.pos[1], spec.pos[2], spec.pos[3]),
        rot = quat(0, 0, 0, 1),
        autoEnterVehicle = false,
        cling = true,
      })
    end)
    log('I', logTag, '_spawnGameVehicle: fallback pcall ok2=' .. tostring(ok2)
      .. ' vehObj=' .. tostring(vehObj) .. ' type=' .. type(vehObj)
      .. ' err=' .. tostring(err))
    if not ok2 or not vehObj then
      M._spawningRemote = false
      return nil, nil, tostring(firstErr or err)
    end
  end
  M._spawningRemote = false

  -- Restore camera focus to the player's vehicle (spawn may steal it)
  if savedPlayerVeh and be then
    pcall(function() be:enterVehicle(0, savedPlayerVeh) end)
  end

  -- core_vehicles.spawnNewVehicle returns a vehicle object (userdata), not an ID
  local vid = nil
  if type(vehObj) == "userdata" and vehObj.getID then
    vid = vehObj:getID()
  elseif type(vehObj) == "number" then
    vid = vehObj
    vehObj = scenetree.findObjectById(vid)
  end

  log('I', logTag, '_spawnGameVehicle: extracted vid=' .. tostring(vid)
    .. ' vehObjType=' .. type(vehObj))

  if not vid then
    return nil, nil, "spawnNewVehicle returned unexpected type: " .. type(vehObj)
  end

  -- Apply authoritative transform after spawn to avoid constructor ordering ambiguity.
  pcall(function()
    if vehObj and spec and spec.pos and spec.rot then
      vehObj:setPositionRotation(
        spec.pos[1], spec.pos[2], spec.pos[3],
        spec.rot[1], spec.rot[2], spec.rot[3], spec.rot[4]
      )
    end
  end)

  return vid, vehObj
end

-- Check if a game vehicle ID belongs to a remote player
M.isRemote = function(gameVehicleId)
  return M._remoteGameIds[gameVehicleId] == true
end

-- BeamNG 0.39 may delete a repeatedly unstable vehicle automatically. If the
-- destroyed object is still tagged as a live remote puppet, preserve all
-- authoritative component snapshots and enter the existing bounded spawn
-- retry path. Intentional HighBeam deletes clear _remoteGameIds first.
M.onRemoteObjectDestroyed = function(gameVehicleId)
  if not M._remoteGameIds[gameVehicleId] then return false end
  M._remoteGameIds[gameVehicleId] = nil
  for key, rv in pairs(M.remoteVehicles) do
    if rv.gameVehicleId == gameVehicleId then
      rv.gameVehicleId = nil
      rv.gameVehicle = nil
      rv._hasVE = false
      rv._veReadyAt = nil
      rv._veLastHeartbeat = nil
      rv._veProbeQueuedAt = nil
      rv._componentQueue = {}
      rv._componentQueueLen = 0
      rv._pendingDamageData = rv._lastDamageData
      rv._pendingPowertrainData = rv._lastPowertrainData
      rv._pendingElectricsData = rv._lastElectricsData
      rv._pendingInputsData = rv._lastInputsData
      rv._damageInFlight = nil
      rv.spawnRetry = {
        attempts = 0,
        nextAt = os.clock(),
        lastError = "BeamNG destroyed remote object",
      }
      _bumpApplyStat("remote_object_destroyed_recovery")
      log('W', logTag, 'BeamNG destroyed remote puppet; scheduled recovery key=' .. tostring(key)
        .. ' oldGameVid=' .. tostring(gameVehicleId))
      return true
    end
  end
  return false
end

M.spawnRemote = function(playerId, vehicleId, configData, snapshot)
  local key = makeKey(playerId, vehicleId)
  local deletedAt = M._deletedRemoteKeys[key]
  if deletedAt and (os.clock() - deletedAt) < 10.0 then
    M._pendingRemoteState[key] = nil
    _bumpApplyStat("spawn_drop_delete_tombstone")
    return
  end
  M._deletedRemoteKeys[key] = nil
  local preSpawnState = M._pendingRemoteState[key]
  log('I', logTag, 'spawnRemote: key=' .. key
    .. ' playerId=' .. tostring(playerId)
    .. ' vehicleId=' .. tostring(vehicleId)
    .. ' hasConfig=' .. tostring(configData ~= nil)
    .. ' hasSnapshot=' .. tostring(snapshot ~= nil))
  if M.remoteVehicles[key] then
    log('W', logTag, 'Remote vehicle already exists: ' .. key)
    return
  end

  local effectiveConfigData = configData
  local preConfig = preSpawnState and preSpawnState.config and _decodeJson(preSpawnState.config) or nil
  if preConfig then
    local baseConfig = _decodeJson(configData) or {}
    for field, value in pairs(preConfig) do baseConfig[field] = value end
    if jsonEncode then
      local okEncoded, encoded = pcall(jsonEncode, baseConfig)
      if okEncoded and encoded then effectiveConfigData = encoded end
    end
  end
  local spec = _buildSpawnSpec(effectiveConfigData, snapshot)
  local effectiveConfig = _decodeJson(effectiveConfigData) or {}
  local preReset = preSpawnState and preSpawnState.reset and _decodeJson(preSpawnState.reset) or nil
  if preReset and type(preReset.pos) == "table" and type(preReset.rot) == "table" then
    spec.pos = preReset.pos
    spec.rot = preReset.rot
    spec.vel = { 0, 0, 0 }
  end
  local vid, vehObj, spawnErr = _spawnGameVehicle(spec)

  if vid then
    M._remoteGameIds[vid] = true
  end

  M.remoteVehicles[key] = {
    playerId = playerId,
    vehicleId = vehicleId,
    gameVehicleId = vid,
    gameVehicle = vehObj,
    snapshots = {},
    lastSeqTime = -1,  -- For out-of-order rejection
    motionEpoch = preReset and tonumber(preReset.motionEpoch) or nil,
    motionSequence = -1,
    spawnSpec = spec,
    spawnRetry = nil,
    _hasVE = false,
    _componentQueue = {},  -- ring buffer for components arriving before VE ready
    _componentQueueLen = 0,
    _lastDamageData = (preSpawnState and preSpawnState.damage) or (snapshot and snapshot.damage) or nil,
    _pendingDamageData = (preSpawnState and preSpawnState.damage) or (snapshot and snapshot.damage) or nil,
    _lastElectricsData = (preSpawnState and preSpawnState.electrics) or (snapshot and snapshot.electrics) or nil,
    _pendingElectricsData = (preSpawnState and preSpawnState.electrics) or (snapshot and snapshot.electrics) or nil,
    _inputState = preSpawnState and preSpawnState.inputState or nil,
    _pendingInputsData = preSpawnState and _serializeInputState(preSpawnState.inputState) or nil,
    _lastPowertrainData = (preSpawnState and preSpawnState.powertrain) or (snapshot and snapshot.powertrain) or nil,
    _pendingPowertrainData = (preSpawnState and preSpawnState.powertrain) or (snapshot and snapshot.powertrain) or nil,
    _pendingResetData = preSpawnState and preSpawnState.reset or nil,
    configRevision = math.max(0, math.floor(tonumber(effectiveConfig.configRevision) or 0)),
  }
  M._pendingRemoteState[key] = nil

  if snapshot or spec.snapshotTimeMs then
    table.insert(M.remoteVehicles[key].snapshots, {
      pos = spec.pos,
      rot = spec.rot,
      vel = spec.vel,
      time = (spec.snapshotTimeMs or 0) / 1000.0,
      received = os.clock(),
      inputs = nil,
      angVel = nil,
    })
  end

  if vid then
    _queueRemoteVeBootstrap(M.remoteVehicles[key], key)
    log('I', logTag, 'Spawned remote vehicle: ' .. key .. ' gameVid=' .. tostring(vid))
  else
    M.remoteVehicles[key].spawnRetry = {
      attempts = 1,
      nextAt = os.clock() + SPAWN_RETRY_BASE_DELAY,
      lastError = spawnErr,
    }
    log('W', logTag, 'Remote spawn failed: ' .. key .. ' gameVid=nil; queued retry attempts=' .. tostring(SPAWN_RETRY_MAX_ATTEMPTS))
  end
end

M.spawnRemoteFromSnapshot = function(vehicle)
  log('I', logTag, 'spawnRemoteFromSnapshot called: vehicle=' .. tostring(vehicle ~= nil)
    .. ' type=' .. type(vehicle))
  if not vehicle then
    log('E', logTag, 'spawnRemoteFromSnapshot: vehicle is nil/false!')
    return
  end
  log('I', logTag, 'spawnRemoteFromSnapshot: player_id=' .. tostring(vehicle.player_id)
    .. ' vehicle_id=' .. tostring(vehicle.vehicle_id)
    .. ' data=' .. tostring(vehicle.data and string.sub(vehicle.data, 1, 80) or 'nil'))
  M.spawnRemote(vehicle.player_id, vehicle.vehicle_id, vehicle.data, {
    position = vehicle.position,
    rotation = vehicle.rotation,
    velocity = vehicle.velocity,
    snapshotTimeMs = vehicle.snapshot_time_ms,
    damage = vehicle.damage,
    electrics = vehicle.electrics,
    powertrain = vehicle.powertrain,
  })
end

local _updateRemoteDropLog = 0
local function _epochIsNewer(incoming, current)
  if current == nil then return true end
  local delta = (incoming - current) % 4294967296
  return delta > 0 and delta < 2147483648
end

local function _acceptExplicitMotionOrder(rv, decoded)
  local incomingEpoch = math.floor(tonumber(decoded.motionEpoch) or -1)
  local incomingSequence = math.floor(tonumber(decoded.motionSequence) or -1)
  if incomingEpoch <= 0 or incomingSequence < 0 then
    return false, false, "invalid_order"
  end

  local epochRestart = false
  if rv.motionEpoch == nil or _epochIsNewer(incomingEpoch, rv.motionEpoch) then
    epochRestart = rv.motionEpoch ~= nil or (rv.lastSeqTime or -1) >= 0 or #(rv.snapshots or {}) > 0
    rv.motionEpoch = incomingEpoch
    rv.motionSequence = -1
    rv.lastSeqTime = -1
    rv.snapshots = {}
    rv._motionRestartPreviousTime = nil
    rv._motionRestartGuardUntil = nil
  elseif incomingEpoch ~= rv.motionEpoch then
    return false, false, "stale_epoch"
  elseif incomingSequence <= (rv.motionSequence or -1) then
    return false, false, "stale_sequence"
  end

  rv.motionSequence = incomingSequence
  return true, epochRestart, epochRestart and "epoch_restart" or "accepted"
end

M.updateRemote = function(decoded)
  if not _validMotion(decoded) then
    _bumpApplyStat("pose_drop_nonfinite")
    return
  end
  local key = makeKey(decoded.playerId, decoded.vehicleId)
  local rv = M.remoteVehicles[key]
  if not rv then
    _updateRemoteDropLog = _updateRemoteDropLog + 1
    if _updateRemoteDropLog <= 5 or _updateRemoteDropLog % 50 == 0 then
      log('W', logTag, 'updateRemote: no remote vehicle for key=' .. key
        .. ' (drops=' .. tostring(_updateRemoteDropLog) .. ')')
    end
    return
  end

  local recvTime = os.clock()
  local epochRestart = false
  local explicitOrder = decoded.motionEpoch ~= nil and decoded.motionSequence ~= nil

  if explicitOrder then
    local accepted, restarted, reason = _acceptExplicitMotionOrder(rv, decoded)
    if not accepted then
      _staleDropCount = _staleDropCount + 1
      _bumpApplyStat("pose_drop_" .. tostring(reason))
      return
    end
    epochRestart = restarted
    _bumpApplyStat(epochRestart and "pose_epoch_restart" or "pose_epoch_accept")
  end

  -- Compatibility recovery for senders whose VLua motion timer restarted.
  -- Keep a short guard against a delayed packet from the previous high-time
  -- epoch arriving after the first low-time packet from the new epoch.
  if not explicitOrder and rv._motionRestartGuardUntil and recvTime < rv._motionRestartGuardUntil
    and rv._motionRestartPreviousTime and decoded.time > (rv.lastSeqTime + 2.0)
    and decoded.time >= (rv._motionRestartPreviousTime - 1.0) then
    _staleDropCount = _staleDropCount + 1
    return
  end

  -- Out-of-order protection: reject packets older than newest received
  if not explicitOrder and decoded.time and rv.lastSeqTime and decoded.time < rv.lastSeqTime then
    local backwardJump = rv.lastSeqTime - decoded.time
    local receiveGap = rv._lastMotionReceivedAt and (recvTime - rv._lastMotionReceivedAt) or 0
    if backwardJump > 1.0 and (decoded.time < 3.0 or receiveGap > 0.75) then
      epochRestart = true
      rv._motionRestartPreviousTime = rv.lastSeqTime
      rv._motionRestartGuardUntil = recvTime + 3.0
      rv._legacyMotionEpoch = (rv._legacyMotionEpoch or 0) + 1
      rv.lastSeqTime = -1
      rv.snapshots = {}
      _bumpApplyStat("pose_epoch_restart")
      log('I', logTag, 'Detected remote motion epoch restart key=' .. key
        .. ' epoch=legacy-' .. tostring(rv._legacyMotionEpoch)
        .. ' backward=' .. string.format('%.3f', backwardJump)
        .. ' receiveGap=' .. string.format('%.3f', receiveGap))
    else
      _staleDropCount = _staleDropCount + 1
      return  -- Stale packet, discard
    end
  end
  if decoded.time then
    rv.lastSeqTime = decoded.time
  end
  rv._lastMotionReceivedAt = recvTime

  if _verboseSyncLoggingEnabled() then
    local prevArrival = _packetInterArrival[key]
    local arrivalDt = prevArrival and (recvTime - prevArrival) or 0
    _packetInterArrival[key] = recvTime
    log('D', logTag, 'UDP remote packet key=' .. key
      .. ' remoteTime=' .. string.format('%.6f', decoded.time or 0)
      .. ' epoch=' .. tostring(decoded.motionEpoch or 'legacy')
      .. ' seq=' .. tostring(decoded.motionSequence or 'legacy')
      .. ' interArrival=' .. string.format('%.4f', arrivalDt))
  end

  if rv._hasVE and rv.gameVehicle then
    local ax = decoded.angVel and decoded.angVel[1] or 0
    local ay = decoded.angVel and decoded.angVel[2] or 0
    local az = decoded.angVel and decoded.angVel[3] or 0
    local diagEnabled = _verboseSyncLoggingEnabled() and "true" or "false"
    local cmd = string.format(
      "local _hb=controller and controller.getController and controller.getController('highbeamPositionVE') or nil; if _hb and _hb.setDiagnostics then _hb.setDiagnostics(%s) end; if _hb and _hb.setTarget then _hb.setTarget(%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.6f,%.6f,%.6f,%.6f,%.4f,%.4f,%.4f,%.6f,%s) end",
      diagEnabled,
      decoded.pos[1], decoded.pos[2], decoded.pos[3],
      decoded.vel[1], decoded.vel[2], decoded.vel[3],
      decoded.rot[1], decoded.rot[2], decoded.rot[3], decoded.rot[4],
      ax, ay, az,
      decoded.time or 0,
      epochRestart and "true" or "false"
    )
    _queueVeLuaCommand(rv.gameVehicle, cmd, "position")

    -- A3: apply the UDP inputs visually for smoother remote animation
    -- (steering/throttle/brake/handbrake). Discrete gear changes deliberately
    -- stay on the reliable TCP path, so gear is intentionally excluded here.
    -- The UDP steer value uses the same 450-degree reference as TCP and carries
    -- sender lock metadata; feed both through the shared smoothing pipeline.
    if decoded.inputs then
      local di = decoded.inputs
      local deltaStr = string.format(
        "l=%d,s=%.4f,t=%.4f,b=%.4f,p=%.4f",
        math.max(1, math.min(4096, math.floor(tonumber(decoded.steeringLock) or 450))),
        tonumber(di.steer) or 0,
        tonumber(di.throttle) or 0,
        tonumber(di.brake) or 0,
        tonumber(di.handbrake) or 0
      )
      M.applyInputs(decoded.playerId, decoded.vehicleId, deltaStr)
    end
  elseif _verboseSyncLoggingEnabled() then
    log('D', logTag, 'Skipping remote pose until VE controller is ready key=' .. key)
  end

  -- Keep latest snapshot for spawn retry position and nametag lookups
  table.insert(rv.snapshots, {
    pos = decoded.pos,
    rot = decoded.rot,
    vel = decoded.vel,
    time = decoded.time,
    received = recvTime,
    motionEpoch = decoded.motionEpoch,
    motionSequence = decoded.motionSequence,
  })

  local maxSnapshots = _getMaxSnapshots()
  while #rv.snapshots > maxSnapshots do
    table.remove(rv.snapshots, 1)
  end
end

M.updateRemoteConfig = function(playerId, vehicleId, configData)
  local key = makeKey(playerId, vehicleId)
  local cfg = _decodeJson(configData)
  if not cfg then
    _bumpApplyStat("config_drop_decode")
    if _verboseSyncLoggingEnabled() then
      log('D', logTag, 'config drop decode key=' .. key)
    end
    return
  end
  local rv = M.remoteVehicles[key]
  if not rv then
    M._pendingRemoteState[key] = M._pendingRemoteState[key] or {}
    M._pendingRemoteState[key].config = configData
    _bumpApplyStat("config_retained_pre_spawn")
    return
  end

  local topologyChanged = cfg.model ~= nil or cfg.partConfig ~= nil
  local incomingRevision = math.max(0, math.floor(tonumber(cfg.configRevision)
    or ((rv.configRevision or 0) + (topologyChanged and 1 or 0))))
  if incomingRevision < (rv.configRevision or 0) then
    _bumpApplyStat("config_drop_stale")
    return
  end

  if topologyChanged and incomingRevision == (rv.configRevision or 0) then
    local sameModel = cfg.model == nil or tostring(cfg.model) == tostring(rv.spawnSpec.model)
    local sameParts = cfg.partConfig == nil or tostring(cfg.partConfig) == tostring(rv.spawnSpec.partCfg)
    _bumpApplyStat(sameModel and sameParts and "config_duplicate" or "config_drop_revision_conflict")
    return
  end

  local veh = rv.gameVehicle or (rv.gameVehicleId and scenetree.findObjectById(rv.gameVehicleId))
  if cfg.color and veh then
    if not pcall(veh.setField, veh, 'color', '0', cfg.color) then
      _bumpApplyStat("config_error_color")
    end
  end

  if topologyChanged then
    if cfg.model ~= nil then rv.spawnSpec.model = tostring(cfg.model) end
    if cfg.partConfig ~= nil then rv.spawnSpec.partCfg = tostring(cfg.partConfig) end
    rv.configRevision = incomingRevision
    if tonumber(cfg.damageEpoch) ~= nil then
      rv.damageEpoch = math.max(rv.damageEpoch or 0, math.floor(tonumber(cfg.damageEpoch)))
    else
      rv.damageEpoch = (rv.damageEpoch or 0) + 1
    end
    rv._lastDamageRevision = -1
    rv._appliedDamageRevision = -1
    rv._lastDamageData = nil
    rv._pendingDamageData = nil
    rv._damageInFlight = nil
    if veh then
      _respawnRemoteVehicle(rv, key, "config_topology_change")
    end
    local futureDamage = rv._futureDamageByConfig and rv._futureDamageByConfig[incomingRevision]
    if futureDamage then
      rv._futureDamageByConfig[incomingRevision] = nil
      M.applyDamage(playerId, vehicleId, futureDamage)
      _bumpApplyStat("damage_promoted_for_config")
    end
    _bumpApplyStat("config_respawned")
  elseif cfg.color then
    _bumpApplyStat("config_color_applied")
  else
    _bumpApplyStat("config_noop")
  end
end

M.resetRemote = function(playerId, vehicleId, data)
  local key = makeKey(playerId, vehicleId)
  local cfg = _decodeJson(data)
  if not cfg then
    _bumpApplyStat("reset_drop_decode")
    return
  end
  if type(cfg.pos) ~= "table" or type(cfg.rot) ~= "table"
    or not (_isFinite(tonumber(cfg.pos[1]), 1e7) and _isFinite(tonumber(cfg.pos[2]), 1e7)
      and _isFinite(tonumber(cfg.pos[3]), 1e7) and _isFinite(tonumber(cfg.rot[1]), 4)
      and _isFinite(tonumber(cfg.rot[2]), 4) and _isFinite(tonumber(cfg.rot[3]), 4)
      and _isFinite(tonumber(cfg.rot[4]), 4) and _isFinite(tonumber(cfg.time) or 0, 1e9)) then
    _bumpApplyStat("reset_drop_nonfinite")
    return
  end
  local resetQuatLenSq = tonumber(cfg.rot[1])^2 + tonumber(cfg.rot[2])^2
    + tonumber(cfg.rot[3])^2 + tonumber(cfg.rot[4])^2
  if resetQuatLenSq < 1e-8 then
    _bumpApplyStat("reset_drop_degenerate_rotation")
    return
  end
  local rv = M.remoteVehicles[key]
  if not rv then
    M._pendingRemoteState[key] = M._pendingRemoteState[key] or {}
    M._pendingRemoteState[key].reset = data
    M._pendingRemoteState[key].damage = nil
    _bumpApplyStat("reset_retained_pre_spawn")
    return
  end
  local suppliedMotionEpoch = math.floor(tonumber(cfg.motionEpoch) or 0)
  if suppliedMotionEpoch > 0 then
    if rv.motionEpoch and suppliedMotionEpoch ~= rv.motionEpoch
      and not _epochIsNewer(suppliedMotionEpoch, rv.motionEpoch) then
      _bumpApplyStat("reset_drop_stale_motion_epoch")
      return
    end
    if rv.motionEpoch ~= suppliedMotionEpoch then
      rv.motionEpoch = suppliedMotionEpoch
      rv.motionSequence = -1
      rv.snapshots = {}
      rv.lastSeqTime = -1
    end
  end
  local veh = rv.gameVehicle or (rv.gameVehicleId and scenetree.findObjectById(rv.gameVehicleId))
  if not veh then
    rv._pendingResetData = data
    local suppliedEpoch = tonumber(cfg.damageEpoch)
    if suppliedEpoch ~= nil then
      rv.damageEpoch = math.max(rv.damageEpoch or 0, math.floor(suppliedEpoch))
    elseif rv._pendingResetEpochApplied ~= data then
      rv.damageEpoch = (rv.damageEpoch or 0) + 1
    end
    rv._pendingResetEpochApplied = data
    rv._lastDamageData = nil
    rv._pendingDamageData = nil
    rv._damageInFlight = nil
    _bumpApplyStat("reset_retained_no_vehicle")
    return
  end

  local now = os.clock()

  local resetMinInterval = math.max(0.0, math.min(3.0, _getConfigNumber("remoteResetMinIntervalSec", 0.5)))
  local resetUnchanged = (rv._lastResetPayload ~= nil and rv._lastResetPayload == data)
  local fingerprint = _resetFingerprint(cfg)
  local resetSamePoseBurst = rv._lastResetFingerprint == fingerprint
    and rv._lastResetAt
    and (now - rv._lastResetAt) < math.max(resetMinInterval, RESET_BURST_WINDOW_SEC)
  rv._resetBurstEvents = rv._resetBurstEvents or {}
  local burstCount = _rememberTimedEvent(rv._resetBurstEvents, now, RESET_BURST_WINDOW_SEC)
  if rv._lastResetAt and (now - rv._lastResetAt) < resetMinInterval and (resetUnchanged or resetSamePoseBurst) then
    _bumpApplyStat("reset_suppressed")
    if _verboseSyncLoggingEnabled() then
      log('D', logTag, 'Reset suppressed key=' .. key
        .. ' dt=' .. string.format('%.3f', now - rv._lastResetAt)
        .. ' burst=' .. tostring(burstCount)
        .. ' samePose=' .. tostring(resetSamePoseBurst)
        .. 's')
    end
    return
  end
  rv._lastResetAt = now
  rv._lastResetPayload = data
  rv._lastResetFingerprint = fingerprint
  rv._stabilizeUntil = now + RESET_STABILIZE_SEC

  if cfg.pos and cfg.rot then
    local resetTime = tonumber(cfg.time) or 0
    if _verboseSyncLoggingEnabled() then
      log('D', logTag, 'Reset remote target key=' .. key
        .. ' time=' .. string.format('%.6f', resetTime)
        .. ' burst=' .. tostring(burstCount)
        .. ' stabilize=' .. string.format('%.2f', RESET_STABILIZE_SEC)
        .. ' source=reset')
    end
    if rv._hasVE and rv.gameVehicle then
      -- positionVE is a controller, not a vlua extension — extensions.hook()
      -- would never reach it; call it through the controller registry.
      _queueVeLuaCommand(rv.gameVehicle,
        "local _names={'highbeamPositionVE','highbeamInputsVE','highbeamPowertrainVE','highbeamDamageVE','highbeamVelocityVE'} "
        .. "for _,_n in ipairs(_names) do local _hb=controller and controller.getController and controller.getController(_n) or nil; "
        .. "if _hb then if _hb.onHighBeamRemoteReset then _hb.onHighBeamRemoteReset() elseif _hb.onReset then _hb.onReset() elseif _hb.reset then _hb.reset() end end end",
        "reset_hooks")
    end
    local okPos = pcall(function()
      veh:setPositionRotation(
        cfg.pos[1], cfg.pos[2], cfg.pos[3],
        cfg.rot[1], cfg.rot[2], cfg.rot[3], cfg.rot[4]
      )
      if veh.resetBrokenFlexMesh then
        veh:resetBrokenFlexMesh()
      end
    end)
    if not okPos then
      _bumpApplyStat("reset_error_pose")
    end
    -- Notify VE positionVE so it targets the reset pose instead of snapping back.
    if rv._hasVE and rv.gameVehicle then
      local diagEnabled = _verboseSyncLoggingEnabled() and "true" or "false"
      local cmd = string.format(
        "local _hb=controller and controller.getController and controller.getController('highbeamPositionVE') or nil; if _hb and _hb.setDiagnostics then _hb.setDiagnostics(%s) end; if _hb and _hb.resetToOrigin then _hb.resetToOrigin(%.4f,%.4f,%.4f,%.6f,%.6f,%.6f,%.6f,%.6f) elseif _hb and _hb.resetTo then _hb.resetTo(%.4f,%.4f,%.4f,%.6f,%.6f,%.6f,%.6f,%.6f) end",
        diagEnabled,
        cfg.pos[1], cfg.pos[2], cfg.pos[3],
        cfg.rot[1], cfg.rot[2], cfg.rot[3], cfg.rot[4],
        resetTime,
        cfg.pos[1], cfg.pos[2], cfg.pos[3],
        cfg.rot[1], cfg.rot[2], cfg.rot[3], cfg.rot[4],
        resetTime
      )
      _queueVeLuaCommand(rv.gameVehicle, cmd, "reset")
    end
  else
    _bumpApplyStat("reset_no_pose")
  end

  -- Clear snapshots so interpolation restarts from the new position
  rv.snapshots = {}
  rv.lastSeqTime = -1

  -- A player reset/repair is authoritative pristine state. Do not replay the
  -- pre-reset damage snapshot; that behavior made repaired remote vehicles
  -- immediately damage themselves again. Internal puppet respawns preserve
  -- _lastDamageData in _respawnRemoteVehicle instead.
  rv._appliedBrokenBeams = nil
  rv._appliedBreakGroups = nil
  rv._appliedDeformLengths = nil
  local suppliedEpoch = tonumber(cfg.damageEpoch)
  if suppliedEpoch ~= nil then
    -- Versioned reset epochs are authoritative and idempotent. A queued or
    -- duplicated reset must never advance the receiver past the sender.
    rv.damageEpoch = math.max(rv.damageEpoch or 0, math.floor(suppliedEpoch))
  elseif rv._pendingResetEpochApplied ~= data then
    rv.damageEpoch = (rv.damageEpoch or 0) + 1
  end
  rv._pendingResetEpochApplied = nil
  rv._lastDamageRevision = -1
  rv._appliedDamageRevision = -1
  rv._damageInFlight = nil
  rv._damageApplyErrors = 0
  rv._damageRetryAt = nil
  rv._lastDamageData = nil
  rv._lastDamageAt = nil
  rv._pendingDamageData = nil
  _bumpApplyStat("damage_cleared_by_reset")

  _bumpApplyStat("reset_applied")
  log('D', logTag, 'Reset remote vehicle: ' .. key
    .. ' burst=' .. tostring(burstCount)
    .. ' stabilizeUntil=' .. string.format('%.2f', rv._stabilizeUntil or 0))
end

local function _encodeJson(value)
  if jsonEncode then
    local ok, encoded = pcall(jsonEncode, value)
    if ok and type(encoded) == "string" then return encoded end
  end
  if Engine and Engine.JSONEncode then
    local ok, encoded = pcall(Engine.JSONEncode, value)
    if ok and type(encoded) == "string" then return encoded end
  end
  return nil
end

local function _validateDamageState(state)
  if type(state) ~= "table" then return false, "not_table" end
  local brokenCount, groupCount, deformCount = 0, 0, 0
  if state.broken ~= nil and type(state.broken) ~= "table" then return false, "broken_not_table" end
  for _, id in ipairs(state.broken or {}) do
    local n = tonumber(id)
    if not _isFinite(n, 1000000) or n ~= math.floor(n) or n < 0 then return false, "invalid_beam_id" end
    brokenCount = brokenCount + 1
    if brokenCount > 20000 then return false, "too_many_broken" end
  end
  if state.breakGroups ~= nil and type(state.breakGroups) ~= "table" then return false, "groups_not_table" end
  for _, group in ipairs(state.breakGroups or {}) do
    if type(group) ~= "string" or #group == 0 or #group > 128 then return false, "invalid_group" end
    groupCount = groupCount + 1
    if groupCount > 2048 then return false, "too_many_groups" end
  end
  if state.deform ~= nil and type(state.deform) ~= "table" then return false, "deform_not_table" end
  for rawId, value in pairs(state.deform or {}) do
    local id = tonumber(rawId)
    local deformation = type(value) == "table" and tonumber(value[1]) or 0
    local restLength = type(value) == "table" and tonumber(value[2]) or tonumber(value)
    if not _isFinite(id, 1000000) or id ~= math.floor(id) or id < 0
      or not _isFinite(deformation, 1000) or not _isFinite(restLength, 1000)
      or restLength <= 0.0001 then return false, "invalid_deform" end
    deformCount = deformCount + 1
    if deformCount > 20000 then return false, "too_many_deforms" end
  end
  return true
end

-- Durable, acknowledged damage path. Full snapshots remain pending until the
-- vehicle-side controller confirms that the actual beam operations executed.
M.applyDamage = function(playerId, vehicleId, damageData)
  local key = makeKey(playerId, vehicleId)
  local raw = tostring(damageData or "")
  local decoded = _decodeJson(raw)
  if not decoded then
    _bumpApplyStat("damage_drop_decode")
    return
  end

  local rv = M.remoteVehicles[key]
  if not rv then
    M._pendingRemoteState[key] = M._pendingRemoteState[key] or {}
    M._pendingRemoteState[key].damage = raw
    _bumpApplyStat("damage_retained_pre_spawn")
    return
  end

  local state = type(decoded.state) == "table" and decoded.state or decoded
  local valid, reason = _validateDamageState(state)
  if not valid then
    _bumpApplyStat("damage_drop_invalid_" .. tostring(reason))
    return
  end

  local damageConfigRevision = math.max(0, math.floor(tonumber(decoded.configRevision) or 0))
  if damageConfigRevision ~= (rv.configRevision or 0) then
    if damageConfigRevision < (rv.configRevision or 0) then
      _bumpApplyStat("damage_drop_old_config")
    else
      rv._futureDamageByConfig = rv._futureDamageByConfig or {}
      rv._futureDamageByConfig[damageConfigRevision] = raw
      _bumpApplyStat("damage_retained_future_config")
    end
    return
  end

  local epoch = math.max(0, math.floor(tonumber(decoded.epoch) or tonumber(rv.damageEpoch) or 0))
  local revision
  if decoded.revision ~= nil then
    revision = math.max(0, math.floor(tonumber(decoded.revision) or 0))
  elseif rv._lastDamageData == raw and rv._lastDamageRevision ~= nil then
    revision = rv._lastDamageRevision
  else
    revision = math.max(0, (rv._lastDamageRevision or -1) + 1)
  end

  if epoch < (rv.damageEpoch or 0)
    or (epoch == (rv.damageEpoch or 0) and revision < (rv._lastDamageRevision or -1)) then
    _bumpApplyStat("damage_drop_stale")
    return
  end
  if epoch > (rv.damageEpoch or 0) then
    rv.damageEpoch = epoch
    rv._appliedDamageRevision = -1
    rv._damageInFlight = nil
  end

  rv._lastDamageData = raw
  rv._lastDamageAt = os.clock()
  rv._lastDamageRevision = revision
  rv._pendingDamageData = raw

  local veh = rv.gameVehicle or (rv.gameVehicleId and scenetree.findObjectById(rv.gameVehicleId))
  if not veh or not rv._hasVE or rv._veUnhealthy or _isStabilizing(rv) or _isSettling(rv) then
    _bumpApplyStat("damage_retained_not_ready")
    return
  end

  local now = os.clock()
  if rv._damageRetryAt and now < rv._damageRetryAt then return end
  if rv._damageInFlight and rv._damageInFlight.epoch == epoch
    and rv._damageInFlight.revision == revision
    and (now - rv._damageInFlight.sentAt) < 1.0 then
    return
  end

  local stateJson = _encodeJson(state)
  if not stateJson then
    _bumpApplyStat("damage_error_encode")
    return
  end
  local cmd = "local _hb=controller and controller.getController and controller.getController('highbeamDamageVE') or nil; "
    .. "if _hb and _hb.applyRemoteDamage then local _hbd=(jsonDecode and jsonDecode(" .. string.format("%q", stateJson)
    .. ")) or nil; _hb.applyRemoteDamage(_hbd," .. tostring(epoch) .. "," .. tostring(revision) .. ") end"
  if _queueVeLuaCommand(veh, cmd, "damage_transaction") then
    rv._damageInFlight = { epoch = epoch, revision = revision, sentAt = now }
    _bumpApplyStat("damage_transaction_queued")
  else
    _bumpApplyStat("damage_transaction_queue_failed")
  end
end

M.onRemoteDamageApplied = function(gameVid, epoch, revision, brokenCount, groupCount, deformCount, errorCount)
  gameVid = tonumber(gameVid)
  epoch = math.floor(tonumber(epoch) or 0)
  revision = math.floor(tonumber(revision) or 0)
  errorCount = math.floor(tonumber(errorCount) or 0)
  for _, rv in pairs(M.remoteVehicles) do
    if rv.gameVehicleId == gameVid then
      local inflight = rv._damageInFlight
      if not inflight or inflight.epoch ~= epoch or inflight.revision ~= revision then
        _bumpApplyStat("damage_ack_stale")
        return
      end
      rv._damageInFlight = nil
      if errorCount == 0 then
        rv._damageApplyErrors = 0
        rv._damageRetryAt = nil
        rv._appliedDamageRevision = revision
        if rv._lastDamageRevision == revision and (rv.damageEpoch or 0) == epoch then
          rv._pendingDamageData = nil
        end
        _bumpApplyStat("damage_ack_applied")
      else
        rv._damageApplyErrors = (rv._damageApplyErrors or 0) + 1
        rv._damageRetryAt = os.clock() + math.min(4.0, 0.25 * (2 ^ math.min(rv._damageApplyErrors - 1, 4)))
        if rv._damageApplyErrors == 3 and rv.gameVehicle then
          _queueRemoteVeBootstrap(rv, makeKey(rv.playerId, rv.vehicleId))
          _bumpApplyStat("damage_controller_rebootstrap")
        elseif rv._damageApplyErrors >= 6 then
          _respawnRemoteVehicle(rv, makeKey(rv.playerId, rv.vehicleId), "damage_apply_errors")
          rv._damageApplyErrors = 0
          rv._damageRetryAt = nil
        end
        _bumpApplyStat("damage_ack_error")
      end
      if _verboseSyncLoggingEnabled() then
        log('D', logTag, 'damage ack key=' .. makeKey(rv.playerId, rv.vehicleId)
          .. ' epoch=' .. tostring(epoch) .. ' revision=' .. tostring(revision)
          .. ' broken=' .. tostring(brokenCount) .. ' groups=' .. tostring(groupCount)
          .. ' deform=' .. tostring(deformCount) .. ' errors=' .. tostring(errorCount))
      end
      return
    end
  end
  _bumpApplyStat("damage_ack_no_remote")
end

M.onRemoteDamageAudit = function(gameVid, epoch, revision, extraBroken, missingBroken, deformMismatch)
  gameVid = tonumber(gameVid)
  epoch = math.floor(tonumber(epoch) or 0)
  revision = math.floor(tonumber(revision) or 0)
  local divergence = math.max(0, math.floor(tonumber(extraBroken) or 0))
    + math.max(0, math.floor(tonumber(missingBroken) or 0))
    + math.max(0, math.floor(tonumber(deformMismatch) or 0))
  for key, rv in pairs(M.remoteVehicles) do
    if rv.gameVehicleId == gameVid and (rv.damageEpoch or 0) == epoch
      and (rv._appliedDamageRevision or -1) == revision then
      if divergence == 0 then
        rv._damageDivergenceCount = 0
      else
        rv._damageDivergenceCount = (rv._damageDivergenceCount or 0) + 1
        _bumpApplyStat("damage_audit_diverged")
        if rv._damageDivergenceCount >= 3 then
          rv._damageDivergenceCount = 0
          _respawnRemoteVehicle(rv, key, "persistent_damage_divergence")
          _bumpApplyStat("damage_audit_reconciled")
        end
      end
      return
    end
  end
end

-- Apply electrics state update to a remote vehicle
M.applyElectrics = function(playerId, vehicleId, electricsData)
  local key = makeKey(playerId, vehicleId)
  local rv = M.remoteVehicles[key]
  if not rv then
    M._pendingRemoteState[key] = M._pendingRemoteState[key] or {}
    M._pendingRemoteState[key].electrics = electricsData
    _bumpApplyStat("electrics_retained_pre_spawn")
    return
  end
  local veh = rv.gameVehicle or (rv.gameVehicleId and scenetree.findObjectById(rv.gameVehicleId))
  rv._lastElectricsData = electricsData
  if not veh or not rv._hasVE then
    rv._pendingElectricsData = electricsData
    _bumpApplyStat("electrics_retained_not_ready")
    return
  end
  if rv and rv._veUnhealthy then
    rv._pendingElectricsData = electricsData
    _bumpApplyStat("electrics_retained_unhealthy")
    return
  end

  local jsonPayload = string.format("%q", tostring(electricsData or "{}"))
  local cmd = "local _hb=controller and controller.getController and controller.getController('highbeamElectricsVE') or nil; if _hb and _hb.applyElectrics then local _hbj=" .. jsonPayload .. "; local _hbt=(jsonDecode and jsonDecode(_hbj)) or {}; _hb.applyElectrics(_hbt) end"
  local okForward = _queueVeLuaCommand(veh, cmd, "electrics")
  if okForward then
    _bumpApplyStat("electrics_applied")
    return
  end
  rv._pendingElectricsData = electricsData
  _bumpApplyStat("electrics_error_apply")
end

M.applyInputs = function(playerId, vehicleId, deltaStr)
  local key = makeKey(playerId, vehicleId)
  local rv = M.remoteVehicles[key]
  if not rv then
    M._pendingRemoteState[key] = M._pendingRemoteState[key] or {}
    local pending = M._pendingRemoteState[key]
    pending.inputState = _mergeInputState(pending.inputState, tostring(deltaStr or ""))
    _bumpApplyStat("inputs_retained_pre_spawn")
    return
  end
  local veh = rv.gameVehicle or (rv.gameVehicleId and scenetree.findObjectById(rv.gameVehicleId))
  rv._inputState = _mergeInputState(rv._inputState, tostring(deltaStr or ""))
  rv._lastInputsData = _serializeInputState(rv._inputState)
  if not veh then
    rv._pendingInputsData = rv._lastInputsData
    _bumpApplyStat("inputs_retained_no_vehicle")
    return
  end
  if rv._veUnhealthy then
    rv._pendingInputsData = rv._lastInputsData
    _bumpApplyStat("inputs_retained_unhealthy")
    return
  end
  if not rv._hasVE then
    rv._pendingInputsData = rv._lastInputsData
    _bumpApplyStat("inputs_retained_no_ve")
    return
  end

  if _isStabilizing(rv) then
    rv._pendingInputsData = rv._lastInputsData
    _bumpApplyStat("inputs_retained_stabilizing")
    if _verboseSyncLoggingEnabled() then
      log('D', logTag, 'inputs skipped during reset stabilization key=' .. key)
    end
    return
  end

  local function escapeLuaString(s)
    return string.format("%q", s or "")
  end

  local cmd = "local _hb=controller and controller.getController and controller.getController('highbeamInputsVE') or nil; if _hb and _hb.applyInputs then local d={} for part in string.gmatch(" .. escapeLuaString(deltaStr) .. ",'[^,]+') do local k,v=string.match(part,'^([%a]+)=([^,]+)$'); if k then if (k=='g' or k=='k') and tonumber(v)==nil then d[k]=v else d[k]=tonumber(v) or 0 end end end _hb.applyInputs(d) end"
  local ok = _queueVeLuaCommand(veh, cmd, "inputs")
  if ok then
    _bumpApplyStat("inputs_applied")
  else
    _bumpApplyStat("inputs_error_apply")
  end
end

M.applyPowertrain = function(playerId, vehicleId, powertrainData)
  local key = makeKey(playerId, vehicleId)
  local rv = M.remoteVehicles[key]
  if not rv then
    M._pendingRemoteState[key] = M._pendingRemoteState[key] or {}
    M._pendingRemoteState[key].powertrain = powertrainData
    _bumpApplyStat("powertrain_retained_pre_spawn")
    return
  end
  local veh = rv.gameVehicle or (rv.gameVehicleId and scenetree.findObjectById(rv.gameVehicleId))
  rv._lastPowertrainData = powertrainData
  if not veh then
    rv._pendingPowertrainData = powertrainData
    _bumpApplyStat("powertrain_retained_no_vehicle")
    return
  end
  if rv._veUnhealthy then
    rv._pendingPowertrainData = powertrainData
    _bumpApplyStat("powertrain_retained_unhealthy")
    return
  end

  if _isStabilizing(rv) then
    rv._pendingPowertrainData = powertrainData
    _bumpApplyStat("powertrain_deferred_stabilizing")
    if _verboseSyncLoggingEnabled() then
      log('D', logTag, 'powertrain deferred during reset stabilization key=' .. key)
    end
    return
  end

  if not rv._hasVE then
    rv._pendingPowertrainData = powertrainData
    _bumpApplyStat("powertrain_retained_no_ve")
    return
  end

  local jsonPayload = string.format("%q", tostring(powertrainData or "{}"))
  local cmd = "local _hb=controller and controller.getController and controller.getController('highbeamPowertrainVE') or nil; if _hb and _hb.applyPowertrain then local _hbj=" .. jsonPayload .. "; local _hbt=(jsonDecode and jsonDecode(_hbj)) or {}; _hb.applyPowertrain(_hbt) end"
  local ok = _queueVeLuaCommand(veh, cmd, "powertrain")
  if ok then
    _bumpApplyStat("powertrain_applied")
  else
    _bumpApplyStat("powertrain_error_apply")
  end
end

-- Apply low-rate TCP pose fallback update while UDP is not yet active.
M.applyPose = function(playerId, vehicleId, poseData)
  local pose = _decodeJson(poseData)
  if not pose then
    _bumpApplyStat("pose_drop_decode")
    return
  end

  local decoded = {
    playerId = playerId,
    vehicleId = vehicleId,
    pos = pose.pos,
    rot = pose.rot,
    vel = pose.vel,
    time = tonumber(pose.time),
    inputs = pose.inputs,
    angVel = pose.angVel,
    motionEpoch = tonumber(pose.motionEpoch),
    motionSequence = tonumber(pose.motionSequence),
    steeringLock = tonumber(pose.steeringLock),
  }

  if type(decoded.pos) ~= "table" or #decoded.pos < 3
    or type(decoded.rot) ~= "table" or #decoded.rot < 4
    or type(decoded.vel) ~= "table" or #decoded.vel < 3
    or type(decoded.time) ~= "number" then
    _bumpApplyStat("pose_drop_invalid")
    return
  end

  M.updateRemote(decoded)
  _bumpApplyStat("pose_applied")
end

-- Apply coupling/trailer state
M.applyCoupling = function(playerId, vehicleId, targetVehicleId, coupled, nodeId, targetNodeId)
  -- Find both remote vehicles by server vehicle ID.
  -- NOTE: the target is matched by vehicleId alone (server vehicle IDs are
  -- currently globally unique — see server next_vehicle_id atomic in world.rs),
  -- which is why this is safe today. If server IDs ever become per-player, also
  -- match the target's owning playerId here to avoid coupling to the wrong car.
  local sourceRv = nil
  local targetRv = nil
  for _, rv in pairs(M.remoteVehicles) do
    if rv.playerId == playerId and rv.vehicleId == vehicleId then
      sourceRv = rv
    end
    -- Target could belong to any player
    if rv.vehicleId == targetVehicleId then
      targetRv = rv
    end
  end

  if not sourceRv or not targetRv then
    _bumpApplyStat("coupling_drop_missing_remote")
    return
  end
  local sourceVeh = sourceRv.gameVehicle or (sourceRv.gameVehicleId and scenetree.findObjectById(sourceRv.gameVehicleId))
  local targetVeh = targetRv.gameVehicle or (targetRv.gameVehicleId and scenetree.findObjectById(targetRv.gameVehicleId))
  if not sourceVeh or not targetVeh then
    _bumpApplyStat("coupling_drop_missing_game_vehicle")
    return
  end

  -- BeamNG's public beamstate API exposes auto-coupling (attach any couplers
  -- currently within range) and detachCouplers (release all), matching BeamMP.
  -- There is no by-node-id attach in vehicle Lua, so node_id/target_node_id
  -- cannot be honored precisely; the local physics simulation resolves which
  -- couplers actually engage. (The previous beamstate.attachCouplerByNodeId /
  -- beamstate.detachCoupler calls did not exist and silently failed.)
  if coupled then
    local ok = pcall(function()
      sourceVeh:queueLuaCommand('if beamstate and beamstate.activateAutoCoupling then beamstate.activateAutoCoupling() end')
    end)
    if ok then
      _bumpApplyStat("coupling_applied")
    else
      _bumpApplyStat("coupling_error_apply")
    end
    log('D', logTag, 'Applied coupling: ' .. tostring(sourceRv.gameVehicleId) .. ' -> ' .. tostring(targetRv.gameVehicleId))
  else
    local ok = pcall(function()
      sourceVeh:queueLuaCommand('if beamstate then if beamstate.disableAutoCoupling then beamstate.disableAutoCoupling() end if beamstate.detachCouplers then beamstate.detachCouplers() end end')
    end)
    if ok then
      _bumpApplyStat("coupling_applied")
    else
      _bumpApplyStat("coupling_error_apply")
    end
    log('D', logTag, 'Applied decoupling: ' .. tostring(sourceRv.gameVehicleId))
  end
end

M._escapeForLuaCmd = function(s)
  if type(s) ~= "string" then return tostring(s) end
  return string.format("%q", s)
end

M.removeRemote = function(playerId, vehicleId)
  local key = makeKey(playerId, vehicleId)
  M._deletedRemoteKeys[key] = os.clock()
  M._pendingRemoteState[key] = nil
  local rv = M.remoteVehicles[key]
  if not rv then
    return
  end

  if rv.gameVehicleId then
    M._remoteGameIds[rv.gameVehicleId] = nil
    pcall(function()
      local obj = be:getObjectByID(rv.gameVehicleId)
      if obj then obj:delete() end
    end)
  end

  M.remoteVehicles[key] = nil
  M._pendingRemoteState[key] = nil
  log('I', logTag, 'Removed remote vehicle: ' .. key)
end

M.removeAllForPlayer = function(playerId)
  local prefix = tostring(playerId) .. "_"
  local toRemove = {}

  for key, rv in pairs(M.remoteVehicles) do
    if key:sub(1, #prefix) == prefix then
      table.insert(toRemove, key)
      if rv.gameVehicleId then
        M._remoteGameIds[rv.gameVehicleId] = nil
        pcall(function()
          local obj = be:getObjectByID(rv.gameVehicleId)
          if obj then obj:delete() end
        end)
      end
    end
  end

  for _, key in ipairs(toRemove) do
    M._deletedRemoteKeys[key] = os.clock()
    M.remoteVehicles[key] = nil
    M._pendingRemoteState[key] = nil
  end
  for key, _ in pairs(M._pendingRemoteState) do
    if key:sub(1, #prefix) == prefix then
      M._deletedRemoteKeys[key] = os.clock()
      M._pendingRemoteState[key] = nil
    end
  end

  if #toRemove > 0 then
    log('I', logTag, 'Removed ' .. tostring(#toRemove) .. ' vehicles for player ' .. tostring(playerId))
  end
end

-- P3.4: Helper to get camera position for LOD distance
M.tick = function(dt)
  local now = os.clock()

  for _, rv in pairs(M.remoteVehicles) do
    local keyForRv = tostring(rv.playerId) .. '_' .. tostring(rv.vehicleId)
    _applyDeferredAfterStabilize(rv, keyForRv)

    if rv._hasVE and rv.gameVehicle and rv._lastDamageData
      and rv._appliedDamageRevision ~= nil and now >= (rv._damageAuditNextAt or 0) then
      rv._damageAuditNextAt = now + 5.0
      local envelope = _decodeJson(rv._lastDamageData)
      local state = envelope and (type(envelope.state) == "table" and envelope.state or envelope) or nil
      local stateJson = state and _encodeJson(state) or nil
      if stateJson then
        local cmd = "local _hb=controller and controller.getController and controller.getController('highbeamDamageVE') or nil; "
          .. "if _hb and _hb.auditRemoteDamage then local _hbd=(jsonDecode and jsonDecode(" .. string.format("%q", stateJson)
          .. ")) or nil; _hb.auditRemoteDamage(_hbd," .. tostring(rv.damageEpoch or 0) .. ","
          .. tostring(rv._appliedDamageRevision or 0) .. ") end"
        _queueVeLuaCommand(rv.gameVehicle, cmd, "damage_audit")
      end
    end

    if rv._veUnhealthy then
      goto continue_vehicle
    end

    if (not rv.gameVehicleId) and rv.spawnRetry then
      if now >= rv.spawnRetry.nextAt then
        local latest = rv.snapshots[#rv.snapshots]
        if latest then
          rv.spawnSpec.pos = latest.pos
          rv.spawnSpec.rot = latest.rot
          rv.spawnSpec.vel = latest.vel
        end

        local vid, vehObj, spawnErr = _spawnGameVehicle(rv.spawnSpec)
        _spawnRetryAttemptCount = _spawnRetryAttemptCount + 1
        if vid then
          rv.gameVehicleId = vid
          rv.gameVehicle = vehObj
          rv.spawnRetry = nil
          M._remoteGameIds[vid] = true
          rv._hasVE = false
          _queueRemoteVeBootstrap(rv, keyForRv)
          _spawnRetrySuccessCount = _spawnRetrySuccessCount + 1
          log('I', logTag, 'Remote spawn recovered: ' .. keyForRv .. ' gameVid=' .. tostring(vid))
        else
          rv.spawnRetry.attempts = rv.spawnRetry.attempts + 1
          rv.spawnRetry.lastError = spawnErr
          if rv.spawnRetry.attempts > SPAWN_RETRY_MAX_ATTEMPTS then
            _spawnRetryDropCount = _spawnRetryDropCount + 1
            log('E', logTag, 'Remote spawn permanently failed: ' .. tostring(rv.playerId) .. '_' .. tostring(rv.vehicleId)
              .. ' err=' .. tostring(rv.spawnRetry.lastError))
            rv.spawnRetry = nil
          else
            local backoff = math.min(4.0, SPAWN_RETRY_BASE_DELAY * rv.spawnRetry.attempts)
            rv.spawnRetry.nextAt = now + backoff
          end
        end
      end
    end

    if not rv.gameVehicle and rv.gameVehicleId then
      rv.gameVehicle = scenetree.findObjectById(rv.gameVehicleId)
    end

    -- VE probe retry: if previous probe failed and enough time has passed, re-probe
    if rv.gameVehicle and not rv._hasVE and rv._veProbeQueuedAt then
      local probeAge = now - rv._veProbeQueuedAt
      local retries = rv._veProbeRetries or 0
      if probeAge >= VE_PROBE_RETRY_DELAY and retries < VE_PROBE_MAX_RETRIES then
        rv._veProbeRetries = retries + 1
        if _verboseSyncLoggingEnabled() then
          log('D', logTag, 'VE probe retry #' .. tostring(rv._veProbeRetries) .. ' key=' .. keyForRv)
        end
        _queueRemoteVeBootstrap(rv, keyForRv)
      end
    end

    -- VE death detection: if heartbeat stops arriving for VE_DEATH_TIMEOUT_SEC,
    -- the remote vlua has crashed. Re-bootstrap to recover.
    if rv._hasVE and rv._veLastHeartbeat then
      local hbAge = now - rv._veLastHeartbeat
      if hbAge > VE_DEATH_TIMEOUT_SEC then
        rv._veDeathEvents = rv._veDeathEvents or {}
        local deathsInWindow = _rememberTimedEvent(rv._veDeathEvents, now, VE_DEATH_WINDOW_SEC)
        log('W', logTag, 'VE death detected: heartbeat timeout key=' .. keyForRv
          .. ' gameVid=' .. tostring(rv.gameVehicleId)
          .. ' lastHB=' .. string.format('%.2f', rv._veLastHeartbeat)
          .. ' age=' .. string.format('%.2f', hbAge) .. 's'
          .. ' readyAt=' .. string.format('%.2f', rv._veReadyAt or 0)
          .. ' deathsInWindow=' .. tostring(deathsInWindow))
        rv._hasVE = false
        rv._veDeathAt = now
        rv._veDeathCount = (rv._veDeathCount or 0) + 1
        rv._veLastHeartbeat = nil
        if deathsInWindow >= VE_DEATH_RESPAWN_THRESHOLD then
          _bumpApplyStat("ve_recovery_respawn")
          if not _respawnRemoteVehicle(rv, keyForRv, "heartbeat_death_loop") then
            _bumpApplyStat("ve_recovery_unhealthy")
          end
        else
          rv._veProbeRetries = 0
          rv._veProbeQueuedAt = nil
          _queueRemoteVeBootstrap(rv, keyForRv)
          _bumpApplyStat("ve_recovery_bootstrap")
          log('I', logTag, 'VE recovery queued key=' .. keyForRv
            .. ' deathCount=' .. tostring(rv._veDeathCount)
            .. ' deathsInWindow=' .. tostring(deathsInWindow))
        end
      end
    end

    ::continue_vehicle::
  end

  _diagTimer = _diagTimer + dt
  if _diagTimer >= _diagIntervalSec then
    _diagTimer = 0
    if _staleDropCount > 0 then
      log('I', logTag, 'Dropped stale remote snapshots=' .. tostring(_staleDropCount))
      _staleDropCount = 0
    end
    if _spawnRetryDropCount > 0 then
      log('W', logTag, 'Remote spawns abandoned after retries=' .. tostring(_spawnRetryDropCount))
      _spawnRetryDropCount = 0
    end
    local pendingRetries = _countPendingSpawnRetries()
    if pendingRetries > 0 or _spawnRetryAttemptCount > 0 or _spawnRetrySuccessCount > 0 then
      log('I', logTag, 'Spawn retry diag pending=' .. tostring(pendingRetries)
        .. ' attempts=' .. tostring(_spawnRetryAttemptCount)
        .. ' recovered=' .. tostring(_spawnRetrySuccessCount))
      _spawnRetryAttemptCount = 0
      _spawnRetrySuccessCount = 0
    end

    -- P0: Update debug stats for overlay
    M._debugStats = {
      staleDrops = _staleDropCount,
    }

    if next(_componentApplyStats) then
      log('I', logTag, 'Component apply diag=' .. (function()
        local parts = {}
        for k, v in pairs(_componentApplyStats) do
          if v and v > 0 then
            table.insert(parts, k .. '=' .. tostring(v))
          end
        end
        table.sort(parts)
        return #parts > 0 and table.concat(parts, ',') or 'none'
      end)())
      _componentApplyStats = {}
    end

    -- VE health dump: log per-vehicle VE state for diagnostics
    for key, rv in pairs(M.remoteVehicles) do
      if rv.gameVehicleId then
        local veInfo = 'hasVE=' .. tostring(rv._hasVE)
        if rv._veReadyAt then
          veInfo = veInfo .. ' readyAge=' .. string.format('%.1f', now - rv._veReadyAt) .. 's'
        end
        if rv._veLastHeartbeat then
          veInfo = veInfo .. ' hbAge=' .. string.format('%.1f', now - rv._veLastHeartbeat) .. 's'
        else
          veInfo = veInfo .. ' hbAge=never'
        end
        if rv._veDeathCount and rv._veDeathCount > 0 then
          veInfo = veInfo .. ' deaths=' .. tostring(rv._veDeathCount)
        end
        if rv._veDeathAt then
          veInfo = veInfo .. ' lastDeath=' .. string.format('%.1f', now - rv._veDeathAt) .. 's_ago'
        end
        log('I', logTag, 'VE diag key=' .. tostring(key)
          .. ' gvid=' .. tostring(rv.gameVehicleId)
          .. ' ' .. veInfo)
      end
    end
  end
end

-- Returns the best current vehicle summary for a player based on newest snapshot.
M.getPlayerActiveVehicle = function(playerId)
  local selected = nil
  local newest = -math.huge

  for _, rv in pairs(M.remoteVehicles) do
    if rv.playerId == playerId then
      local s = rv.snapshots and rv.snapshots[#rv.snapshots] or nil
      local ts = (s and s.received) or 0
      if ts >= newest then
        newest = ts
        local pos = nil
        if s and s.pos then
          pos = { s.pos[1], s.pos[2], s.pos[3] }
        elseif rv.gameVehicle then
          local p = rv.gameVehicle:getPosition()
          if p then pos = { p.x, p.y, p.z } end
        elseif rv.gameVehicleId then
          local obj = scenetree.findObjectById(rv.gameVehicleId)
          if obj then
            local p = obj:getPosition()
            if p then pos = { p.x, p.y, p.z } end
          end
        end

        selected = {
          playerId = rv.playerId,
          vehicleId = rv.vehicleId,
          model = (rv.spawnSpec and rv.spawnSpec.model) or "unknown",
          position = pos,
        }
      end
    end
  end

  return selected
end

if rawget(_G, "HIGHBEAM_TEST") then
  M._testAcceptExplicitMotionOrder = _acceptExplicitMotionOrder
end

return M
