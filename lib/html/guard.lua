local computer = require("computer")

local M = {}

-- OpenOS kills a program that runs for 5 s without yielding.
local YIELD_INTERVAL = 1
-- In freeMemory() units (real bytes / ramScale).
local MEMORY_RESERVE = 192 * 1024
-- A raw freeMemory() reading can be up to about 1.3 MB too low (measured),
-- because it includes garbage that is not collected yet. The OpenOS kernel
-- runs a full GC on every 10th resume of the main coroutine, so 11 yields
-- always include one GC.
local SETTLE_YIELDS = 11
-- A rise above the previous reading by more than this is a GC.
local GC_RISE_MIN = 16384
local GC_RISE_PART = 0.05
-- The rate limit waits at least this many lines between two settles.
local SETTLE_GAP_MIN = 25
-- The lowest and highest measured live cost per line in 0.0.3a (scaled).
local LINE_COST_MIN = 160
local LINE_COST_START = 410
-- The stats trace line must stay under about 1000 characters.
local TRACE_MAX = 60

local last_yield = os.clock()
-- The lowest freeMemory() reading since the last reset. It includes garbage
-- that is not collected yet, so it is a lower bound of the real free memory.
local lowest

-- The memory trace: line count, freeMemory() reading and mark of every
-- trace_every-th tick, and of every settle in tick(). The mark is "" for a
-- raw reading, "s" for a settle and "S" for a settle that saw a GC. When the
-- trace is full, every second sample is dropped and trace_every doubles, so
-- the samples spread across the whole run.
local trace_lines, trace_free, trace_mark = {}, {}, {}
local trace_every, trace_ticks = 1, 0
local last_lines = 0

-- Settle counters since the last reset.
local settle_count, gc_count, yield_count = 0, 0, 0
-- The last settle in tick(): progress value, result, and whether it saw a GC.
-- Progress is the line count, or the tick count for a tick() without lines.
local settle_at, settle_result, settle_gc
-- The last settle in tick() that saw a GC, for the live cost per line.
local gc_line, gc_free
local line_cost = LINE_COST_START
local cost_measured = false

local function trace_add(free, mark)
  local n = #trace_lines
  if n >= TRACE_MAX then
    local j = 0
    for i = 2, n, 2 do
      j = j + 1
      trace_lines[j], trace_free[j], trace_mark[j] =
        trace_lines[i], trace_free[i], trace_mark[i]
    end
    for i = n, j + 1, -1 do
      trace_lines[i], trace_free[i], trace_mark[i] = nil, nil, nil
    end
    trace_every = trace_every * 2
    n = j
  end
  trace_lines[n + 1], trace_free[n + 1], trace_mark[n + 1] =
    last_lines, free, mark
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

-- Yields until a GC is seen, at most SETTLE_YIELDS times. Returns the
-- highest reading and true when a GC was seen.
local function settle()
  local prev = read_free()
  local best = prev
  local gc = false
  for _ = 1, SETTLE_YIELDS do
    yield()
    yield_count = yield_count + 1
    local free = read_free()
    best = math.max(best, free)
    if free - prev > math.max(GC_RISE_MIN, prev * GC_RISE_PART) then
      gc = true
      break
    end
    prev = free
  end
  settle_count = settle_count + 1
  if gc then
    gc_count = gc_count + 1
  end
  return best, gc
end

-- The highest free memory reading over up to 11 yields. It stops at the
-- first GC it sees. The stats output uses it, because a single reading can
-- be up to about 1.3 MB too low.
function M.settled_free()
  return (settle())
end

-- The lowest reading seen by tick() and settled_free() since the last
-- reset, or nil when there was no reading.
function M.lowest_free()
  return lowest
end

-- The number of settles, the number of settles that saw a GC, and the
-- yields of all settles since the last reset.
function M.settles()
  return settle_count
end

function M.gc_seen()
  return gc_count
end

function M.settle_yields()
  return yield_count
end

-- The memory trace as "<line>:<free><mark>,...", oldest first, or "" when
-- there is no sample. <line> is the last line count given to tick(). <mark>
-- is "" for a raw reading, "s" for a settle, "S" for a settle with a GC.
function M.trace_text()
  local parts = {}
  for i = 1, #trace_lines do
    parts[i] = trace_lines[i] .. ":" .. trace_free[i] .. trace_mark[i]
  end
  return table.concat(parts, ",")
end

-- Starts the yield timer again and clears the lowest reading, the trace,
-- the settle state and the counters. Tests call this after they set the
-- clock.
function M.reset()
  last_yield = os.clock()
  lowest = nil
  trace_lines, trace_free, trace_mark = {}, {}, {}
  trace_every, trace_ticks = 1, 0
  last_lines = 0
  settle_count, gc_count, yield_count = 0, 0, 0
  settle_at, settle_result, settle_gc = nil, nil, nil
  gc_line, gc_free = nil, nil
  line_cost = LINE_COST_START
  cost_measured = false
end

local function stop(lines)
  local progress = ""
  if lines then
    progress = " (rendered " .. lines .. " lines before stopping)"
  end
  error("html: page too large for available memory" .. progress, 0)
end

-- Settle rule. A raw reading under the reserve settles only when the rate
-- limit allows it. After a settle at progress P with result F, the wait is
-- gap = max(25, (F - reserve) / (2 * B)). B is the live cost per line: 410
-- at the start, then the highest cost measured between two settles that saw
-- a GC, but at least 160. At B per line, one gap uses at most half of the
-- headroom F - reserve. The next settle comes when progress grew by gap, or
-- when progress grew by gap / 2 and a raw reading is under reserve / 2. The
-- second case covers lines that cost up to 2 * B. Between settles, a raw
-- reading under the reserve does not stop the render. A raw reading under
-- reserve / 2 after a settle that saw no GC stops the render at once:
-- without a GC, no settle lifts it over the reserve. Otherwise only a
-- settle result under the reserve stops the render. Every settle saw a GC
-- or used all 11 yields, so if the kernel stops its GC, the guard stops
-- early with the controlled message and never crashes.
local function check(free, lines)
  local progress = lines or trace_ticks
  if settle_at then
    if progress < settle_at then
      settle_at = progress
    end
    local low = free < MEMORY_RESERVE / 2
    if low and not settle_gc then
      stop(lines)
    end
    local gap = math.max(SETTLE_GAP_MIN,
      (settle_result - MEMORY_RESERVE) / (2 * line_cost))
    if low then
      gap = math.max(SETTLE_GAP_MIN, gap / 2)
    end
    if progress - settle_at < gap then
      return
    end
  end
  local best, gc = settle()
  trace_add(best, gc and "S" or "s")
  if best < MEMORY_RESERVE then
    stop(lines)
  end
  settle_at, settle_result, settle_gc = progress, best, gc
  if gc and lines then
    if gc_line and lines > gc_line then
      local cost = math.max(LINE_COST_MIN, (gc_free - best) / (lines - gc_line))
      if cost_measured then
        line_cost = math.max(line_cost, cost)
      else
        line_cost, cost_measured = cost, true
      end
    end
    gc_line, gc_free = lines, best
  end
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
    trace_add(free, "")
  end
  if free < MEMORY_RESERVE then
    check(free, lines)
  end
end

return M
