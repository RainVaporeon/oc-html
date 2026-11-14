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
  }
end

function M.uptime()
  return math.floor(state.clock / UPTIME_STEP + 1e-9) * UPTIME_STEP
end

-- With jitter, the first reading is low by the jitter amount, as measured.
-- With a period, every period-th reading after it is low again.
function M.freeMemory()
  state.readings = state.readings + 1
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
function M.test.sleep(seconds)
  state.sleeps = state.sleeps + 1
  state.clock = state.clock + math.max(seconds, 0.01)
end

function M.test.sleeps()
  return state.sleeps
end

function M.test.readings()
  return state.readings
end

reset()

return M
