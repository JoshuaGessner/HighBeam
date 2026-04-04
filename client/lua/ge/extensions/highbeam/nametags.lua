local M = {}
local logTag = "HighBeam.Nametags"

local _im = nil  -- ui_imgui reference (loaded lazily)
local _enabled = true

-- Configurable distances (meters)
local RENDER_DISTANCE = 200   -- Beyond this, no tag shown
local FADE_FAR = 200          -- Start fading out at this distance
local FADE_NEAR_START = 30    -- Start fading in below this (full opacity zone: 30-200m)
local FADE_NEAR_END = 10      -- Fully faded out below this distance
local FONT_SCALE = 1.0

-- References set by init()
local vehicles = nil
local connection = nil
local config = nil

M.init = function(vehiclesRef, connectionRef, configRef)
  vehicles = vehiclesRef
  connection = connectionRef
  config = configRef

  -- Apply config overrides if present
  if config and config.get then
    local rd = config.get("nametagRenderDistance")
    if type(rd) == "number" then RENDER_DISTANCE = rd; FADE_FAR = rd end
    local fn = config.get("nametagFadeNear")
    if type(fn) == "number" then FADE_NEAR_START = fn end
    local fs = config.get("nametagFontScale")
    if type(fs) == "number" then FONT_SCALE = fs end
  end
end

M.setEnabled = function(enabled)
  _enabled = enabled
end

-- Render name tags for all visible remote vehicles.
-- Called from onPreRender (every frame).
M.render = function()
  if not _enabled then return end
  if not vehicles or not connection then return end
  if connection.getState() ~= connection.STATE_CONNECTED then return end

  -- Lazy-load ImGui
  if not _im then
    _im = ui_imgui
    if not _im then return end
  end

  local players = connection.getPlayers()
  if not players then return end

  -- Get local camera position
  local camPos = nil
  if core_camera then
    local cp = core_camera.getPosition()
    if cp then camPos = { cp.x, cp.y, cp.z } end
  end
  if not camPos then return end

  -- Get camera forward direction for behind-camera culling
  local camDir = nil
  if core_camera then
    local cd = core_camera.getForward()
    if cd then camDir = { cd.x, cd.y, cd.z } end
  end

  for _, rv in pairs(vehicles.remoteVehicles) do
    if rv.gameVehicle or rv.gameVehicleId then
      local veh = rv.gameVehicle or scenetree.findObjectById(rv.gameVehicleId)
      if veh then
        local vpos = veh:getPosition()
        local vx, vy, vz = vpos.x, vpos.y, vpos.z

        -- Distance check
        local dx = vx - camPos[1]
        local dy = vy - camPos[2]
        local dz = vz - camPos[3]
        local distSq = dx * dx + dy * dy + dz * dz

        if distSq <= RENDER_DISTANCE * RENDER_DISTANCE and distSq > FADE_NEAR_END * FADE_NEAR_END then
          local dist = math.sqrt(distSq)

          -- Behind-camera culling: skip if dot product with camera forward is negative
          if camDir then
            local dot = dx * camDir[1] + dy * camDir[2] + dz * camDir[3]
            if dot < 0 then goto continue end
          end

          -- Compute alpha based on distance
          local alpha = 1.0
          if dist > FADE_FAR then
            alpha = 0.0
          elseif dist > FADE_NEAR_START then
            -- In the full-visibility zone
            alpha = 1.0 - (dist - FADE_NEAR_START) / (FADE_FAR - FADE_NEAR_START)
          elseif dist < FADE_NEAR_END then
            alpha = 0.0
          elseif dist < FADE_NEAR_START then
            -- Fade in as you approach
            alpha = (dist - FADE_NEAR_END) / (FADE_NEAR_START - FADE_NEAR_END)
          end

          if alpha > 0.01 then
            -- Project world position to screen (offset up above vehicle)
            local tagPos = vec3(vx, vy, vz + 2.0)  -- 2m above vehicle origin
            local screenPos = nil

            if core_camera and core_camera.worldToScreen then
              screenPos = core_camera.worldToScreen(tagPos)
            end

            if screenPos and screenPos.x and screenPos.z and screenPos.z > 0 then
              -- screenPos.z > 0 means in front of camera
              local sx = screenPos.x
              local sy = screenPos.y

              -- Look up player name
              local playerInfo = players[rv.playerId]
              local name = playerInfo and playerInfo.name or ("Player " .. tostring(rv.playerId))

              -- Render using ImGui overlay
              _im.SetNextWindowPos(_im.ImVec2(sx - 60, sy - 12))
              _im.SetNextWindowSize(_im.ImVec2(120, 0))
              local windowFlags = 1    -- NoTitleBar
                + 2                    -- NoResize
                + 4                    -- NoMove
                + 8                    -- NoScrollbar
                + 16                   -- NoScrollWithMouse
                + 32                   -- NoCollapse
                + 128                  -- NoBackground (transparent)
                + 512                  -- NoFocusOnAppearing
                + 1048576              -- NoNavInputs
                + 2048                 -- NoBringToFrontOnFocus
                + 4194304              -- NoNavFocus
                + 64                   -- AlwaysAutoResize
                + 256                  -- NoSavedSettings

              local windowId = "##hb_tag_" .. tostring(rv.playerId) .. "_" .. tostring(rv.vehicleId)
              _im.PushStyleVar1(_im.StyleVar_Alpha, alpha)
              _im.PushStyleVar2(_im.StyleVar_WindowPadding, _im.ImVec2(6, 2))

              if _im.Begin(windowId, nil, windowFlags) then
                -- Background pill
                local drawList = _im.GetWindowDrawList()
                local wp = _im.GetWindowPos()
                local ws = _im.GetWindowSize()
                if drawList and wp and ws then
                  local bgColor = _im.GetColorU322(_im.ImVec4(0.0, 0.0, 0.0, 0.55 * alpha))
                  _im.ImDrawList_AddRectFilled(
                    drawList,
                    _im.ImVec2(wp.x, wp.y),
                    _im.ImVec2(wp.x + ws.x, wp.y + ws.y),
                    bgColor, 6.0
                  )
                end

                -- Scale font if needed
                if FONT_SCALE ~= 1.0 then
                  _im.SetWindowFontScale(FONT_SCALE)
                end

                -- Center the name text
                local textSize = _im.CalcTextSize(name)
                local windowWidth = _im.GetWindowSize().x
                if textSize and windowWidth then
                  local indent = (windowWidth - textSize.x) * 0.5
                  if indent > 0 then
                    _im.SetCursorPosX(indent)
                  end
                end

                _im.TextColored(_im.ImVec4(1.0, 1.0, 1.0, alpha), name)
              end
              _im.End()
              _im.PopStyleVar()
              _im.PopStyleVar()
            end
          end
        end

        ::continue::
      end
    end
  end
end

return M
