local computer = require("computer")

local M = {}

-- OpenOS kills a program that runs for 5 s without yielding.
local YIELD_INTERVAL = 1
local MEMORY_RESERVE = 128 * 1024
-- freeMemory() can read up to about 200 KB low until garbage is collected.
local SETTLE_TRIES = 3

local last_yield = os.clock()
-- The lowest freeMemory() reading since the last reset. It includes garbage
-- that is not collected yet, so it is a lower bound of the real free memory.
local lowest

local function yield()
  os.sleep(0)
  last_yield = os.clock()
end

local function read_free()
  local free = computer.freeMemory()
  if not lowest or free < lowest then
    lowest = free
  end
  return free
end

local function settled_free()
  local best = read_free()
  for _ = 1, SETTLE_TRIES do
    yield()
    best = math.max(best, read_free())
  end
  return best
end

-- The highest free memory reading over a few yields. The stats output
-- uses it, because a single reading can be about 200 KB too low.
M.settled_free = settled_free

-- The lowest reading seen by tick() and settled_free() since the last
-- reset, or nil when there was no reading.
function M.lowest_free()
  return lowest
end

-- Starts the yield timer again and clears the lowest reading. Tests call
-- this after they set the clock.
function M.reset()
  last_yield = os.clock()
  lowest = nil
end

-- lines is optional. It is the progress value in the memory error message.
function M.tick(lines)
  if os.clock() - last_yield > YIELD_INTERVAL then
    yield()
  end
  if read_free() < MEMORY_RESERVE and settled_free() < MEMORY_RESERVE then
    local progress = ""
    if lines then
      progress = " (rendered " .. lines .. " lines before stopping)"
    end
    error("html: page too large for available memory" .. progress, 0)
  end
end

return M
