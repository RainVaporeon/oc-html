local computer = require("computer")

local M = {}

-- OpenOS kills a program that runs for 5 s without yielding.
local YIELD_INTERVAL = 1
local MEMORY_RESERVE = 128 * 1024
-- freeMemory() can read up to about 200 KB low until garbage is collected.
local SETTLE_TRIES = 3

local last_yield = os.clock()

local function yield()
  os.sleep(0)
  last_yield = os.clock()
end

local function settled_free()
  local best = computer.freeMemory()
  for _ = 1, SETTLE_TRIES do
    yield()
    best = math.max(best, computer.freeMemory())
  end
  return best
end

-- Starts the yield timer again. Tests call this after they set the clock.
function M.reset()
  last_yield = os.clock()
end

-- lines is optional. It is the progress value in the memory error message.
function M.tick(lines)
  if os.clock() - last_yield > YIELD_INTERVAL then
    yield()
  end
  if computer.freeMemory() < MEMORY_RESERVE and settled_free() < MEMORY_RESERVE then
    local progress = ""
    if lines then
      progress = " (rendered " .. lines .. " lines before stopping)"
    end
    error("html: page too large for available memory" .. progress, 0)
  end
end

return M
