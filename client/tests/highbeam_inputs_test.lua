HIGHBEAM_TEST = true

local inputsPath = assert(arg[1], "inputs module path required")
local inputs = assert(dofile(inputsPath))

assert(inputs._testShouldSnapInput("s", 0.1, 0) == false)
assert(inputs._testShouldSnapInput("s", -0.1, 0) == false,
  "negative steering must not snap when the equal positive input smooths")
assert(inputs._testShouldSnapInput("s", 0.5, 0) == true)
assert(inputs._testShouldSnapInput("s", -0.5, 0) == true)
assert(inputs._testShouldSnapInput("s", 0.01, 0.02) == true)
assert(inputs._testShouldSnapInput("t", 0.1, 0) == false)
assert(inputs._testShouldSnapInput("t", 0.99, 0.9) == true)

print("highbeam input tests passed")
