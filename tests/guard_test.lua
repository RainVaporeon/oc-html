local t = require("test")
local computer = require("computer")

local T = {}

local function setup(start)
  local clock = t.fake_clock(start or 0)
  local guard = require("html.guard")
  guard.reset()
  return guard, clock
end

function T.no_yield_before_interval()
  local guard, clock = setup()
  clock.advance(0.9)
  guard.tick(0)
  t.eq(computer.test.sleeps(), 0)
end

function T.yields_once_after_interval()
  local guard, clock = setup()
  clock.advance(1.1)
  guard.tick(0)
  t.eq(computer.test.sleeps(), 1)
  guard.tick(0)
  t.eq(computer.test.sleeps(), 1, "timer restarted by the yield")
end

function T.yields_again_after_next_interval()
  local guard, clock = setup()
  clock.advance(1.1)
  guard.tick(0)
  clock.advance(1.1)
  guard.tick(0)
  t.eq(computer.test.sleeps(), 2)
end

function T.low_memory_raises_controlled_string()
  local guard = setup()
  computer.test.set_free(100 * 1024)
  local ok, err = pcall(guard.tick, 42)
  t.eq(ok, false)
  t.eq(type(err), "string")
  local msg = tostring(err)
  t.eq(msg:sub(1, 6), "html: ")
  t.ok(msg:find("42 lines", 1, true), msg)
  t.ok(computer.test.sleeps() >= 1, "settled before the error")
end

function T.low_memory_error_without_progress()
  local guard = setup()
  computer.test.set_free(100 * 1024)
  local ok, err = pcall(guard.tick)
  t.eq(ok, false)
  t.eq(tostring(err):sub(1, 6), "html: ")
end

function T.jitter_drop_does_not_raise()
  local guard = setup()
  computer.test.set_free(300 * 1024)
  computer.test.set_jitter(213499)
  guard.tick(1)
  t.ok(computer.test.sleeps() >= 1, "recheck ran")
end

function T.normal_memory_does_not_settle()
  local guard = setup()
  guard.tick(1)
  t.eq(computer.test.sleeps(), 0)
end

function T.lowest_free_is_nil_after_reset()
  local guard = setup()
  t.eq(guard.lowest_free(), nil)
  guard.tick(1)
  t.eq(guard.lowest_free(), 1800000)
  guard.reset()
  t.eq(guard.lowest_free(), nil)
end

function T.lowest_free_tracks_tick_minimum()
  local guard = setup()
  computer.test.set_free(900000)
  guard.tick(1)
  computer.test.set_free(500000)
  guard.tick(2)
  computer.test.set_free(700000)
  guard.tick(3)
  t.eq(guard.lowest_free(), 500000)
end

function T.lowest_free_includes_settle_readings()
  local guard = setup()
  computer.test.set_free(1000000)
  computer.test.set_jitter(200000)
  local best = guard.settled_free()
  -- The rise after the first yield counts as a GC, so the settle stops there.
  t.eq(best, 1000000 - 6116)
  t.eq(guard.gc_seen(), 1)
  t.eq(guard.settle_yields(), 1)
  t.eq(guard.lowest_free(), 800000, "first low reading kept")
end

function T.lowest_free_includes_low_memory_settle()
  local guard = setup()
  computer.test.set_free(100 * 1024)
  pcall(guard.tick, 1)
  t.eq(guard.lowest_free(), 100 * 1024)
end

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

function T.trace_is_empty_after_reset()
  local guard = setup()
  t.eq(guard.trace_text(), "")
  guard.tick(1)
  t.ok(guard.trace_text() ~= "")
  guard.reset()
  t.eq(guard.trace_text(), "")
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
  for i = 1, 5000 do
    computer.test.set_free(2097152 + i)
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

-- Guard v2 tests with the saw-tooth model of tests/shim/computer.lua.

local RESERVE = 192 * 1024
-- Measured in 0.0.3a: free memory after GC before a render, and the fixed
-- overhead of a render (scaled units).
local CAPACITY = 1828996
local OVERHEAD = 280 * 1024

function T.settle_sees_gc_at_every_phase()
  for phase = 1, 10 do
    computer.test.reset()
    local guard = setup()
    computer.test.model({ live = 1000000, garbage = 600000, phase = phase })
    local best = guard.settled_free()
    t.eq(best, 800000, "phase " .. phase)
    t.eq(guard.settles(), 1)
    t.eq(guard.gc_seen(), 1, "phase " .. phase)
    t.eq(guard.settle_yields(), phase, "stops at the GC, phase " .. phase)
  end
end

function T.settle_without_gc_uses_11_yields()
  local guard = setup()
  computer.test.model({ live = 1000000, garbage = 600000, yield_gc = false })
  t.eq(guard.settled_free(), 200000)
  t.eq(guard.gc_seen(), 0)
  t.eq(guard.settle_yields(), 11)
end

function T.reset_clears_counters()
  local guard = setup()
  computer.test.model({ live = 1000000, garbage = 600000, phase = 3 })
  guard.settled_free()
  guard.reset()
  t.eq({ guard.settles(), guard.gc_seen(), guard.settle_yields() },
    { 0, 0, 0 })
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
  t.ok(guard.trace_text():find("100:1050000S", 1, true), guard.trace_text())
end

-- Runs a render model: ticks per line, live and garbage cost per line in
-- scaled units, and 1 ms CPU time per line. Returns the line count reached,
-- the error or nil, and the simulated settle wall time.
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

return T
