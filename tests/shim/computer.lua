-- Test replacement for the OpenOS computer library.
-- Values follow docs/probe/FACTS.md. M.test holds the test controls.

local M = {}

-- computer.uptime() moves in 50 ms steps in the game.
local UPTIME_STEP = 0.05
local TOTAL_MEMORY = 2097152
-- Free memory measured on a 2 MiB machine.
local FREE_MEMORY = 1800000
-- Measured readings after the low first one differ by about 6 KB.
local SMALL_NOISE = 6116

local state

local function reset()
  state = {
    clock = 0,
    free = FREE_MEMORY,
    total = TOTAL_MEMORY,
    jitter = 0,
    jitter_period = nil,
    readings = 0,
    sleeps = 0,
    model = nil,
  }
end

-- A small fixed-seed random generator, so model runs repeat exactly.
local function next_random(m)
  m.seed = (m.seed * 1103515245 + 12345) % 2147483648
  return m.seed
end

local function next_incremental(m)
  local span = m.incremental_max - m.incremental_min + 1
  m.countdown = m.incremental_min + next_random(m) % span
end

function M.uptime()
  return math.floor(state.clock / UPTIME_STEP + 1e-9) * UPTIME_STEP
end

-- With jitter, the first reading is low by the jitter amount, as measured.
-- With a period, every period-th reading after it is low again.
function M.freeMemory()
  state.readings = state.readings + 1
  local m = state.model
  if m then
    return math.max(0, math.floor(m.capacity - m.live - m.garbage))
  end
  local free = state.free
  if state.jitter > 0 then
    local n = state.readings - 1
    local period = state.jitter_period
    if n == 0 or (period and n % period == 0) then
      free = free - state.jitter
    elseif n % 2 == 1 then
      free = free - math.min(SMALL_NOISE, state.jitter)
    end
  end
  return math.max(0, math.floor(free))
end

function M.totalMemory()
  return state.total
end

M.test = {}

function M.test.reset()
  reset()
end

-- Sets the fake clock in seconds. uptime() rounds it down to 50 ms steps.
function M.test.set_clock(seconds)
  state.clock = seconds
end

function M.test.advance(seconds)
  state.clock = state.clock + seconds
end

function M.test.set_free(bytes)
  state.free = bytes
end

function M.test.set_total(bytes)
  state.total = bytes
end

-- Enables freeMemory() jitter. The measured spread was 213499 bytes.
function M.test.set_jitter(bytes, period)
  state.jitter = bytes or 213499
  state.jitter_period = period
  state.readings = 0
end

-- Called by the env os.sleep. os.sleep(0) took 10 ms wall time in the game.
-- With a model, every 10th sleep runs a full GC, as the OpenOS kernel does.
function M.test.sleep(seconds)
  state.sleeps = state.sleeps + 1
  state.clock = state.clock + math.max(seconds, 0.01)
  local m = state.model
  if m and m.yield_gc and state.sleeps % 10 == m.phase % 10 then
    m.garbage = 0
    m.full_gcs = m.full_gcs + 1
  end
end

-- The saw-tooth memory model, in freeMemory() units. freeMemory() reads
-- capacity - live - garbage. work() adds live memory and garbage. An
-- incremental GC frees all garbage after a random number of work() calls
-- (fixed seed). A full GC frees all garbage on every 10th sleep: the first
-- one comes at sleep number phase (1 to 10). An allocation that does not fit
-- runs a full GC first, as in the game. Live memory that does not fit raises
-- "not enough memory", like a real out-of-memory error.
-- opts: capacity, live, garbage, live_per_work, garbage_per_work,
-- incremental_min, incremental_max (work calls), phase, yield_gc, seed.
function M.test.model(opts)
  opts = opts or {}
  local m = {
    capacity = opts.capacity or FREE_MEMORY,
    live = opts.live or 0,
    garbage = opts.garbage or 0,
    live_per_work = opts.live_per_work or 0,
    garbage_per_work = opts.garbage_per_work or 0,
    incremental_min = opts.incremental_min or 50,
    incremental_max = opts.incremental_max or 500,
    phase = opts.phase or 10,
    yield_gc = opts.yield_gc ~= false,
    seed = opts.seed or 12345,
    full_gcs = 0,
    incremental_gcs = 0,
  }
  next_incremental(m)
  state.model = m
end

-- Turns the 10th-sleep GC on or off.
function M.test.set_yield_gc(on)
  state.model.yield_gc = on
end

-- Does n work steps (default 1).
function M.test.work(n)
  local m = state.model
  for _ = 1, n or 1 do
    local need = m.live_per_work + m.garbage_per_work
    if m.live + m.garbage + need > m.capacity then
      m.garbage = 0
      m.full_gcs = m.full_gcs + 1
    end
    if m.live + m.live_per_work > m.capacity then
      error("not enough memory", 0)
    end
    m.live = m.live + m.live_per_work
    m.garbage = math.min(m.garbage + m.garbage_per_work, m.capacity - m.live)
    m.countdown = m.countdown - 1
    if m.countdown <= 0 then
      m.garbage = 0
      m.incremental_gcs = m.incremental_gcs + 1
      next_incremental(m)
    end
  end
end

-- The model state: live, garbage, capacity, full_gcs, incremental_gcs.
function M.test.model_state()
  return state.model
end

function M.test.sleeps()
  return state.sleeps
end

function M.test.readings()
  return state.readings
end

reset()

return M
