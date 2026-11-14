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

function T.never_calls_collectgarbage()
  t.eq(collectgarbage, nil)
  local guard, clock = setup()
  clock.advance(2)
  guard.tick(1)
  computer.test.set_free(100 * 1024)
  t.raises(function() guard.tick(1) end, "^html: ")
end

return T
