local positionPath = assert(arg[1], "usage: luajit highbeam_position_math_test.lua <highbeamPositionVE.lua>")

HIGHBEAM_TEST = true
local position = assert(dofile(positionPath))

local EPS = 1e-5
local PI = math.pi

local function approx(actual, expected, label)
  if math.abs(actual - expected) > EPS then
    error(string.format("%s: expected %.9f, got %.9f", label, expected, actual), 2)
  end
end

local function approxQuat(actual, expected, label)
  local dot = actual[1] * expected[1] + actual[2] * expected[2]
    + actual[3] * expected[3] + actual[4] * expected[4]
  local sign = dot < 0 and -1 or 1
  for i = 1, 4 do
    approx(actual[i] * sign, expected[i], label .. "[" .. tostring(i) .. "]")
  end
end

local identity = { 0, 0, 0, 1 }
local half = math.sqrt(0.5)
local yaw90 = { 0, 0, half, half }

do
  local x, y, z = position._testRotationErrorAngVel(identity, yaw90, 1)
  approx(x, 0, "identity->yaw90 x")
  approx(y, 0, "identity->yaw90 y")
  approx(z, -PI / 2, "identity->yaw90 getter z")
end

do
  local x, y, z = position._testRotationErrorAngVel(identity,
    { -yaw90[1], -yaw90[2], -yaw90[3], -yaw90[4] }, 1)
  approx(x, 0, "antipodal target x")
  approx(y, 0, "antipodal target y")
  approx(z, -PI / 2, "antipodal target getter z")
end

do
  local x, y, z = position._testRotationErrorAngVel(yaw90, identity, 1)
  approx(x, 0, "yaw90->identity x")
  approx(y, 0, "yaw90->identity y")
  approx(z, PI / 2, "yaw90->identity getter z")
end

-- A +90-degree physical rotation about WORLD X, starting from +90 WORLD Z.
-- target = deltaWorldX * current. The correction must stay on world X rather
-- than being rotated into the vehicle/body frame.
local worldXAfterYaw = { 0.5, -0.5, 0.5, 0.5 }
do
  local x, y, z = position._testRotationErrorAngVel(yaw90, worldXAfterYaw, 1)
  approx(x, -PI / 2, "world-frame error x")
  approx(y, 0, "world-frame error y")
  approx(z, 0, "world-frame error z")
end

do
  local predicted = position._testPredictRot(identity, { 0, 0, -PI / 2 }, 1)
  approxQuat(predicted, yaw90, "getter prediction yaw90")
end

do
  local predicted = position._testPredictRot(yaw90, { -PI / 2, 0, 0 }, 1)
  approxQuat(predicted, worldXAfterYaw, "world-frame prediction")
end

do
  local normalized = position._testNormalizeQuat4(0, 0, 0, 2)
  approxQuat(normalized, identity, "normalization")
  local fallback = position._testNormalizeQuat4(0, 0, 0, 0)
  approxQuat(fallback, identity, "degenerate normalization")
end

print("highbeam position math tests passed")
