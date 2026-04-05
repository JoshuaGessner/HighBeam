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

-- Cubic Hermite spline interpolation for a single component.
-- p0, p1: positions at t=0 and t=1
-- v0, v1: velocities at t=0 and t=1
-- duration: time span between the two samples (scales velocity tangents)
-- t: normalised interpolation parameter [0, 1]
M.hermite = function(p0, v0, p1, v1, duration, t)
  t = clamp01(t)
  local t2 = t * t
  local t3 = t2 * t
  -- Hermite basis functions
  local h00 = 2 * t3 - 3 * t2 + 1
  local h10 = t3 - 2 * t2 + t
  local h01 = -2 * t3 + 3 * t2
  local h11 = t3 - t2
  -- Scale velocity tangents by the time span
  local m0 = (v0 or 0) * duration
  local m1 = (v1 or 0) * duration
  return h00 * p0 + h10 * m0 + h01 * p1 + h11 * m1
end

-- Cubic Hermite for vec3 using velocity at both endpoints
M.hermiteVec3 = function(posA, velA, posB, velB, duration, t)
  if duration < 0.0001 then
    return M.lerpVec3(posA, posB, t)
  end
  return {
    M.hermite(posA[1], velA and velA[1] or 0, posB[1], velB and velB[1] or 0, duration, t),
    M.hermite(posA[2], velA and velA[2] or 0, posB[2], velB and velB[2] or 0, duration, t),
    M.hermite(posA[3], velA and velA[3] or 0, posB[3], velB and velB[3] or 0, duration, t),
  }
end

M.slerpQuat = function(a, b, t)
  -- P1.3: True spherical linear interpolation with nlerp fallback for small angles.
  t = clamp01(t)

  -- Ensure shortest path: flip b if dot product is negative
  local dot = a[1]*b[1] + a[2]*b[2] + a[3]*b[3] + a[4]*b[4]
  local b1, b2, b3, b4 = b[1], b[2], b[3], b[4]
  if dot < 0 then
    b1, b2, b3, b4 = -b1, -b2, -b3, -b4
    dot = -dot
  end

  -- For very small angles (dot > 0.9995 ≈ <~1.8°), use normalized lerp for stability
  if dot > 0.9995 then
    local r = {
      a[1] + (b1 - a[1]) * t,
      a[2] + (b2 - a[2]) * t,
      a[3] + (b3 - a[3]) * t,
      a[4] + (b4 - a[4]) * t,
    }
    local len = math.sqrt(r[1]*r[1] + r[2]*r[2] + r[3]*r[3] + r[4]*r[4])
    if len > 0.0001 then
      r[1] = r[1] / len
      r[2] = r[2] / len
      r[3] = r[3] / len
      r[4] = r[4] / len
    end
    return r
  end

  -- True spherical interpolation for larger angular differences
  local theta = math.acos(math.min(1, math.max(-1, dot)))
  local sinTheta = math.sin(theta)
  if sinTheta < 0.0001 then
    -- Degenerate case: quaternions are nearly opposite, just return a
    return { a[1], a[2], a[3], a[4] }
  end
  local wa = math.sin((1 - t) * theta) / sinTheta
  local wb = math.sin(t * theta) / sinTheta
  return {
    wa * a[1] + wb * b1,
    wa * a[2] + wb * b2,
    wa * a[3] + wb * b3,
    wa * a[4] + wb * b4,
  }
end

-- P1.1: Normalize a quaternion to unit length.
M.normalizeQuat = function(q)
  local len = math.sqrt(q[1]*q[1] + q[2]*q[2] + q[3]*q[3] + q[4]*q[4])
  if len < 0.0001 then return { 0, 0, 0, 1 } end
  return { q[1]/len, q[2]/len, q[3]/len, q[4]/len }
end

-- P1.2: Compute angular velocity from quaternion delta between two orientations.
-- Returns {wx, wy, wz} in rad/s, or {0,0,0} for degenerate cases.
-- Uses the small-angle approximation: angVel ≈ 2 * deltaQ.xyz / dt
-- where deltaQ = rotB * conjugate(rotA).
M.angularVelocityFromQuats = function(rotA, rotB, dt)
  if dt < 0.0001 then return { 0, 0, 0 } end
  -- conjugate(rotA) = {-x, -y, -z, w}
  local cax, cay, caz, caw = -rotA[1], -rotA[2], -rotA[3], rotA[4]
  -- Hamilton product: deltaQ = rotB * conjugate(rotA)
  local bx, by, bz, bw = rotB[1], rotB[2], rotB[3], rotB[4]
  local dw = bw*caw - bx*cax - by*cay - bz*caz
  local dx = bw*cax + bx*caw + by*caz - bz*cay
  local dy = bw*cay - bx*caz + by*caw + bz*cax
  local dz = bw*caz + bx*cay - by*cax + bz*caw
  -- Ensure shortest path (dw >= 0)
  if dw < 0 then dx, dy, dz = -dx, -dy, -dz end
  -- Small-angle approximation: angVel ≈ 2 * (dx, dy, dz) / dt
  return { 2*dx/dt, 2*dy/dt, 2*dz/dt }
end

return M
