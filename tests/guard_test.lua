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
  t.eq(best, 1000000)
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

function T.trace_keeps_at_most_64_samples_across_the_run()
  local guard = setup()
  for i = 1, 10000 do
    computer.test.set_free(1800000 - i)
    guard.tick(i)
  end
  local list = trace_pairs(guard.trace_text())
  t.ok(#list <= 64, "samples: " .. #list)
  t.ok(#list >= 32, "samples: " .. #list)
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
  t.ok(#text < 2000, "length " .. #text)
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
end

return T
