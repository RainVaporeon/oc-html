-- Tests for lib/html/guard.lua against spec/guard.md and spec/probe.md.

local t = require("test")
local computer = require("computer")

local T = {}

local RESERVE = 192 * 1024
local STOP_TEXT = "html: page too large for available memory"

-- Resets the computer shim too, because one table test runs many rows.
local function setup(start)
  computer.test.reset()
  local clock = t.fake_clock(start or 0)
  local guard = require("html.guard")
  guard.reset()
  return guard, clock
end

local function stop_text(lines)
  return STOP_TEXT .. " (rendered " .. lines .. " lines before stopping)"
end

-- Yields (spec/guard.md "Yields"). A number advances the CPU clock by that
-- many seconds and ticks once. "reset" calls guard.reset(). The result is
-- the yield count after each tick.
local YIELD = {
  { "no yield before 0.25 s", { 0.2 }, { 0 } },
  { "no yield at exactly 0.25 s", { 0.25 }, { 0 } },
  { "yield after 0.25 s", { 0.26 }, { 1 } },
  { "the old 1 s interval is too long", { 0.9 }, { 1 } },
  { "the yield restarts the timer", { 0.3, 0 }, { 1, 1 } },
  { "yield again after the next interval", { 0.3, 0.3 }, { 1, 2 } },
  { "CPU time adds up across ticks", { 0.1, 0.1, 0.1 }, { 0, 0, 1 } },
  { "reset restarts the timer", { 0.2, "reset", 0.2 }, { 0, 0 } },
}

t.cases(T, "yield", YIELD, function(steps)
  local guard, clock = setup()
  local out = {}
  for _, step in ipairs(steps) do
    if step == "reset" then
      guard.reset()
    else
      clock.advance(step)
      guard.tick(0)
      out[#out + 1] = computer.test.sleeps()
    end
  end
  return out
end)

function T.normal_memory_does_not_settle()
  local guard = setup()
  guard.tick(1)
  t.eq(computer.test.sleeps(), 0)
  t.eq(guard.settles(), 0)
end

-- Stop rules (spec/guard.md "Settle rule in tick()" and "Stop rules").
-- The result is the error text or false, and the settle count.
local STOP = {
  { "a settle result under the reserve stops with the line count",
    "low", { stop_text(42), 1 } },
  { "a stop without a line count has the same message",
    "low_no_lines", { STOP_TEXT, 1 } },
  { "a raw reading under the reserve after a GC settle waits for the gap",
    "dip_after_gc", { false, 1 } },
  { "a raw reading under reserve/2 after a no-GC settle stops at once",
    "half_after_no_gc", { stop_text(2), 1 } },
  { "a raw reading over reserve/2 after a no-GC settle waits for the gap",
    "dip_after_no_gc", { false, 1 } },
}

t.cases(T, "stop_rules", STOP, function(scenario)
  local guard = setup()
  local ok, err
  if scenario == "low" then
    computer.test.set_free(100 * 1024)
    ok, err = pcall(guard.tick, 42)
  elseif scenario == "low_no_lines" then
    computer.test.set_free(100 * 1024)
    ok, err = pcall(guard.tick)
  else
    -- The first reading is low, so tick(1) settles. A rise of more than
    -- 16384 after a yield is a GC. A rise of 6116 is not.
    if scenario == "dip_after_gc" then
      -- Every second reading is low, so the settle sees a rise.
      computer.test.set_free(250000)
      computer.test.set_jitter(213499, 2)
    else
      computer.test.set_free(200000)
      computer.test.set_jitter(10000)
    end
    guard.tick(1)
    computer.test.set_jitter(0)
    if scenario == "dip_after_no_gc" then
      computer.test.set_free(150000)
    else
      computer.test.set_free(90000)
    end
    ok, err = pcall(guard.tick, 2)
  end
  return { not ok and tostring(err), guard.settles() }
end)

-- Raw dips with plenty of real free memory (spec/guard.md "Stop rules":
-- a raw reading under the reserve does not stop the render).
function T.jitter_dip_settles_and_does_not_stop()
  local guard = setup()
  computer.test.set_free(300 * 1024)
  computer.test.set_jitter(213499)
  t.ok(pcall(guard.tick, 1))
  t.eq(guard.settles(), 1)
end

function T.raw_dip_with_plenty_of_memory_does_not_stop()
  local guard = setup()
  -- Real free is about 1 MB, but garbage brings the raw reading to 50 K.
  computer.test.model({ live = 750000, garbage = 1000000, phase = 7 })
  guard.tick(100)
  t.eq(guard.settles(), 1)
  t.eq(guard.gc_seen(), 1)
  -- More dips right after the settle do not settle again.
  computer.test.model({ live = 750000, garbage = 900000, phase = 7 })
  for i = 101, 110 do
    guard.tick(i)
  end
  t.eq(guard.settles(), 1, "rate limit")
  t.ok(guard.trace_text():find("100:%d+S"), guard.trace_text())
end

-- lowest_free (spec/probe.md). A number sets free memory and ticks.
-- { "jitter", free, amount } sets free memory with a low first reading.
-- "settle" calls settled_free(). "reset" calls reset().
local LOWEST_FREE = {
  { "nil after reset", {}, nil },
  { "nil after a reset that follows ticks", { 900000, "reset" }, nil },
  { "the first tick reading", { 900000 }, 900000 },
  { "the minimum of tick readings", { 900000, 500000, 700000 }, 500000 },
  { "the reading that stops the render", { 100 * 1024 }, 100 * 1024 },
  { "settled_free readings count", { { "jitter", 700000, 0 }, "settle" },
    700000 },
  { "the low first reading of a settle counts",
    { { "jitter", 1000000, 200000 }, "settle" }, 800000 },
}

t.cases(T, "lowest_free", LOWEST_FREE, function(steps)
  local guard = setup()
  for i, step in ipairs(steps) do
    if step == "reset" then
      guard.reset()
    elseif step == "settle" then
      guard.settled_free()
    elseif type(step) == "table" then
      computer.test.set_free(step[2])
      computer.test.set_jitter(step[3])
    else
      computer.test.set_free(step)
      pcall(guard.tick, i)
    end
  end
  return guard.lowest_free()
end)

-- reset() clears the counters, lowest_free, the trace and the line count
-- of the reserve (spec/probe.md, spec/guard.md).
local AFTER_RESET = { settles = 0, gc = 0, yields = 0, trace = "",
  reserve = RESERVE }

local RESET = {
  { "after a settle with a GC", "settle_gc", AFTER_RESET },
  { "after a settle without a GC", "settle_no_gc", AFTER_RESET },
  { "after a low-memory stop", "stop", AFTER_RESET },
  { "after ticks past 8192 lines", "lines", AFTER_RESET },
}

t.cases(T, "reset", RESET, function(scenario)
  local guard = setup()
  if scenario == "settle_gc" then
    computer.test.model({ live = 1000000, garbage = 600000, phase = 3 })
    guard.settled_free()
  elseif scenario == "settle_no_gc" then
    computer.test.model({ live = 1000000, garbage = 600000,
      yield_gc = false })
    guard.settled_free()
  elseif scenario == "stop" then
    computer.test.set_free(100 * 1024)
    pcall(guard.tick, 5)
  else
    for i = 1, 3 do
      guard.tick(8190 + i)
    end
  end
  guard.reset()
  return { settles = guard.settles(), gc = guard.gc_seen(),
    yields = guard.settle_yields(), lowest = guard.lowest_free(),
    trace = guard.trace_text(), reserve = guard.reserve() }
end)

function T.never_calls_collectgarbage()
  t.eq(collectgarbage, nil)
  local guard, clock = setup()
  clock.advance(2)
  guard.tick(1)
  computer.test.set_free(100 * 1024)
  t.raises(function() guard.tick(1) end, "^html: ")
end

-- Splits the trace text into a list of { line, free } pairs.
local function trace_pairs(text)
  local list = {}
  for line, free in text:gmatch("(%d+):(%d+)") do
    list[#list + 1] = { tonumber(line), tonumber(free) }
  end
  return list
end

function T.trace_records_line_and_free()
  local guard = setup()
  computer.test.set_free(900000)
  guard.tick(3)
  computer.test.set_free(800000)
  guard.tick()
  t.eq(guard.trace_text(), "3:900000,3:800000", "tick() keeps the last line")
end

function T.trace_keeps_at_most_60_samples_across_the_run()
  local guard = setup()
  for i = 1, 10000 do
    computer.test.set_free(1800000 - i)
    guard.tick(i)
  end
  local list = trace_pairs(guard.trace_text())
  t.ok(#list <= 60, "samples: " .. #list)
  t.ok(#list >= 30, "samples: " .. #list)
  t.ok(list[1][1] <= 10000 / 32, "first sample early: " .. list[1][1])
  t.ok(list[#list][1] >= 10000 - 10000 / 16, "last sample late: "
    .. list[#list][1])
  for i = 2, #list do
    t.ok(list[i][1] > list[i - 1][1], "samples in order")
    t.eq(list[i][2], 1800000 - list[i][1], "free belongs to its line")
  end
end

function T.trace_text_stays_short()
  local guard = setup()
  -- Free memory stays over the reserve for 2^20 table slots (18.6 M).
  for i = 1, 5000 do
    computer.test.set_free(20000000 + i)
    guard.tick(900000 + i)
  end
  local text = guard.trace_text()
  t.ok(#text < 1000, "length " .. #text)
  t.ok(text:find("^%d+:%d+[,%d:]*$"), text)
end

function T.trace_ends_with_the_stopping_reading()
  local guard = setup()
  for i = 1, 300 do
    guard.tick(i)
  end
  computer.test.set_free(100 * 1024)
  pcall(guard.tick, 301)
  local list = trace_pairs(guard.trace_text())
  t.eq(list[#list], { 301, 100 * 1024 })
  t.ok(guard.trace_text():find(":" .. 100 * 1024 .. "s$"), "settle mark")
end

-- Settle (spec/guard.md "Settle"), with the saw-tooth model of
-- tests/shim/computer.lua: 1000000 live, 600000 garbage, 1800000 capacity.
-- The input is the yield number of the kernel GC, or false for no GC. The
-- result is the settle result, settles, settles with a GC and yields.
local SETTLE = {}
for phase = 1, 10 do
  SETTLE[phase] = { "GC at yield " .. phase, phase,
    { 800000, 1, 1, phase } }
end
SETTLE[11] = { "no GC uses 11 yields and returns the highest reading",
  false, { 200000, 1, 0, 11 } }

t.cases(T, "settle", SETTLE, function(phase)
  local guard = setup()
  computer.test.model({ live = 1000000, garbage = 600000,
    phase = phase or nil, yield_gc = phase ~= false })
  local best = guard.settled_free()
  return { best, guard.settles(), guard.gc_seen(), guard.settle_yields() }
end)

-- The effective reserve (spec/guard.md "Memory reserve"):
-- max(192 KB, 32 * c / 1.8), c the smallest power of two >= the line count,
-- at least 1024. The input is the line count given to tick().
local RESERVE_ROWS = {
  { "no line count", nil, RESERVE },
  { "1024 slots", 1000, RESERVE },
  { "8192 slots need less than the base", 8192, RESERVE },
  { "8193 lines need 16384 slots", 8193, math.floor(32 * 16384 / 1.8) },
  { "16385 lines need 32768 slots", 16385, math.floor(32 * 32768 / 1.8) },
}

t.cases(T, "reserve", RESERVE_ROWS, function(lines)
  local guard = setup()
  computer.test.set_free(20000000)
  if lines then
    guard.tick(lines)
  end
  return math.floor(guard.reserve())
end)

-- Guard v2 runs with the saw-tooth model of tests/shim/computer.lua.

-- Measured in 0.0.3a: free memory after GC before a render, and the fixed
-- overhead of a render (scaled units).
local CAPACITY = 1828996
local OVERHEAD = 280 * 1024

-- Runs a render model: ticks per line, live and garbage cost per line in
-- scaled units, and 1 ms CPU time per line. With opts.table, every line is
-- also stored in the model's lines table, which doubles its array. Returns
-- the line count reached, the error or nil, and the simulated settle wall
-- time.
local function run_model(guard, clock, opts)
  computer.test.model({
    capacity = CAPACITY, live = OVERHEAD,
    live_per_work = opts.live / opts.ticks,
    garbage_per_work = opts.garbage / opts.ticks,
    incremental_min = opts.ticks * (opts.gc_min or 30),
    incremental_max = opts.ticks * (opts.gc_max or 120),
    phase = opts.phase or 4, yield_gc = opts.yield_gc, seed = opts.seed,
  })
  local line = 0
  local ok, err = pcall(function()
    for i = 1, opts.lines do
      line = i
      for _ = 1, opts.ticks do
        computer.test.work()
        clock.advance(0.001 / opts.ticks)
        guard.tick(i)
      end
      if opts.table then
        computer.test.append(i)
      end
    end
  end)
  return line, (not ok) and tostring(err) or nil,
    guard.settle_yields() * 0.01
end

function T.real_exhaustion_stops_near_the_right_line()
  local guard, clock = setup()
  local cost = 290
  local line, err = run_model(guard, clock, { lines = 11302, ticks = 4,
    live = cost, garbage = 6000 })
  err = tostring(err)
  t.ok(err:find("^html: page too large"), err)
  t.ok(err:find("(rendered " .. line .. " lines", 1, true), err)
  -- The settle result falls under the reserve at this line.
  local expected = (CAPACITY - OVERHEAD - RESERVE) / cost
  t.ok(line >= expected - 30 and line <= expected + 30,
    "stopped at " .. line .. ", expected about " .. math.floor(expected))
  t.ok(guard.gc_seen() >= 1)
end

function T.fail_safe_without_kernel_gc()
  local guard, clock = setup()
  local cost = 290
  local line, err, wall = run_model(guard, clock, { lines = 11302,
    ticks = 4, live = cost, garbage = 6000, yield_gc = false })
  t.ok(err and err:find("^html: page too large"), tostring(err))
  -- The real limit is where live memory fills the capacity.
  local crash = (CAPACITY - OVERHEAD) / cost
  t.ok(line < crash, "stopped at " .. line .. " before " .. crash)
  t.eq(guard.gc_seen(), 0)
  t.ok(wall < 2, "settle wall " .. wall .. " s")
  print(string.format("fail-safe: stopped at line %d of 11302, settles=%d"
    .. " settle_yields=%d", line, guard.settles(), guard.settle_yields()))
end

function T.rate_limit_keeps_settles_few_on_a_full_run()
  local guard, clock = setup()
  local line, err, wall = run_model(guard, clock, { lines = 11302,
    ticks = 4, live = 110, garbage = 6000 })
  t.eq(err, nil)
  t.eq(line, 11302)
  print(string.format("11302 lines: settles=%d gc_seen=%d settle_yields=%d"
    .. " wall=%.2f s", guard.settles(), guard.gc_seen(),
    guard.settle_yields(), wall))
  t.ok(guard.settles() <= 20, "settles " .. guard.settles())
  t.ok(wall < 2, "settle wall " .. wall .. " s")
end

-- About 70 units per line, as measured, with little garbage. Free memory
-- stays over the base reserve up to line 16384, but the doubling from 16384
-- to 32768 slots needs 291271 units at once.
function T.run_past_16384_lines_stops_before_the_doubling()
  local guard, clock = setup()
  local line, err = run_model(guard, clock, { lines = 20000, ticks = 4,
    live = 70, garbage = 200, table = true })
  t.ok(err and err:find("^html: page too large"), tostring(err))
  t.ok(line <= 16384, "stopped at " .. line)
  t.ok(line > 15000, "stopped at " .. line)
end

function T.interrupt_check_raises_controlled_string()
  local guard = setup()
  local flag = false
  guard.set_interrupt_check(function() return flag end)
  local ok = pcall(guard.tick, 1)
  t.ok(ok, "no flag, no error")
  flag = true
  t.raises(function() guard.tick(2) end, "^html: interrupted$")
  guard.reset()
  t.raises(function() guard.tick(3) end, "^html: interrupted$",
    "reset keeps the check")
  guard.set_interrupt_check(nil)
  ok = pcall(guard.tick, 4)
  t.ok(ok, "check removed")
end

return T
