local computer = require("computer")

local M = {}

-- OpenOS kills a program that runs for 5 s without yielding.
local YIELD_INTERVAL = 1
local MEMORY_RESERVE = 128 * 1024
-- freeMemory() can read up to about 200 KB low until garbage is collected.
local SETTLE_TRIES = 3
-- The stats trace line must stay short: 64 samples are under 1000 chars.
local TRACE_MAX = 64

local last_yield = os.clock()
-- The lowest freeMemory() reading since the last reset. It includes garbage
-- that is not collected yet, so it is a lower bound of the real free memory.
local lowest

-- The memory trace: line count and freeMemory() reading of every
-- trace_every-th tick. When it is full, every second sample is dropped and
-- trace_every doubles, so the samples spread across the whole run.
local trace_lines, trace_free = {}, {}
local trace_every, trace_ticks = 1, 0
local last_lines = 0

local function trace_add(free)
  local n = #trace_lines
  if n >= TRACE_MAX then
    local j = 0
    for i = 2, n, 2 do
      j = j + 1
      trace_lines[j], trace_free[j] = trace_lines[i], trace_free[i]
    end
    for i = n, j + 1, -1 do
      trace_lines[i], trace_free[i] = nil, nil
    end
    trace_every = trace_every * 2
    n = j
  end
  trace_lines[n + 1], trace_free[n + 1] = last_lines, free
end

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

-- The memory trace as "<line>:<free>,<line>:<free>,...", oldest first, or
-- "" when there is no sample. <line> is the last line count given to tick().
function M.trace_text()
  local parts = {}
  for i = 1, #trace_lines do
    parts[i] = trace_lines[i] .. ":" .. trace_free[i]
  end
  return table.concat(parts, ",")
end

-- Starts the yield timer again and clears the lowest reading and the trace.
-- Tests call this after they set the clock.
function M.reset()
  last_yield = os.clock()
  lowest = nil
  trace_lines, trace_free = {}, {}
  trace_every, trace_ticks = 1, 0
  last_lines = 0
end

-- lines is optional. It is the progress value in the memory error message.
function M.tick(lines)
  if os.clock() - last_yield > YIELD_INTERVAL then
    yield()
  end
  if lines then
    last_lines = lines
  end
  local free = read_free()
  trace_ticks = trace_ticks + 1
  if trace_ticks % trace_every == 0 then
    trace_add(free)
  end
  if free < MEMORY_RESERVE and settled_free() < MEMORY_RESERVE then
    -- The reading that stops the render is always the last sample.
    if trace_ticks % trace_every ~= 0 then
      trace_add(free)
    end
    local progress = ""
    if lines then
      progress = " (rendered " .. lines .. " lines before stopping)"
    end
    error("html: page too large for available memory" .. progress, 0)
  end
end

return M
