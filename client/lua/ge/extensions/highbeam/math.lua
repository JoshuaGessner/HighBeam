local M = {}

local function clamp01(t)
  if t < 0 then return 0 end
  if t > 1 then return 1 end
  return t
end

M.lerp = function(a, b, t)
  t = clamp01(t)
  return a + (b - a) * t
end

M.lerpVec3 = function(a, b, t)
  return {
    M.lerp(a[1], b[1], t),
    M.lerp(a[2], b[2], t),
    M.lerp(a[3], b[3], t),
  }
end

M.slerpQuat = function(a, b, t)
  -- Use normalized lerp for stability in BeamNG update cadence.
  t = clamp01(t)
  local r = {
    a[1] + (b[1] - a[1]) * t,
    a[2] + (b[2] - a[2]) * t,
    a[3] + (b[3] - a[3]) * t,
    a[4] + (b[4] - a[4]) * t,
  }

  local len = math.sqrt(r[1] * r[1] + r[2] * r[2] + r[3] * r[3] + r[4] * r[4])
  if len > 0.0001 then
    r[1] = r[1] / len
    r[2] = r[2] / len
    r[3] = r[3] / len
    r[4] = r[4] / len
  end

  return r
end

return M
