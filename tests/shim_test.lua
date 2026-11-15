-- Checks the shims against docs/probe/FACTS.md.
-- Rules: spec/testing.md "Environment" (the shims copy the measured
-- behavior exactly), docs/probe/FACTS.md.

local t = require("test")
local unicode = require("unicode")
local computer = require("computer")

local T = {}

local FFFD = "\xEF\xBF\xBD"

-- Probe strings and the measured values (probe key text.<name>.*). A row is
-- { name, { string, fields }, values }. fields lists what the row checks, in
-- order: len, wlen, width (charWidth), wide (isWide), sub (sub(s, 1, 2)). A
-- row with fewer fields has no measured value for the others.
local ALL = { "len", "wlen", "width", "wide", "sub" }
local LEN_WLEN = { "len", "wlen" }

local function fact(name, s, fields, ...)
  return { name, { s, fields }, { ... } }
end

t.cases(T, "unicode_facts", {
  fact("ascii", "abc", ALL, 3, 3, 1, false, "ab"),
  fact("e_acute", "\xC3\xA9", ALL, 1, 1, 1, false, "\xC3\xA9"),
  fact("box", "\xE2\x94\x80", ALL, 1, 1, 1, false, "\xE2\x94\x80"),
  fact("zh", "\xE4\xB8\xAD\xE6\x96\x87", ALL, 2, 4, 2, true,
    "\xE4\xB8\xAD\xE6\x96\x87"),
  fact("ja", "\xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E\xE3\x83\x86\xE3\x82\xAD"
    .. "\xE3\x82\xB9\xE3\x83\x88", ALL, 7, 14, 2, true,
    "\xE6\x97\xA5\xE6\x9C\xAC"),
  fact("emoji", "\xF0\x9F\x98\x80", ALL, 1, 2, 2, true, "\xF0\x9F\x98\x80"),
  fact("combining", "e\xCC\x81", ALL, 2, 2, 1, false, "e\xCC\x81"),
  fact("lone_cont", "\x80", ALL, 1, 1, 1, false, FFFD),
  fact("truncated", "\xE4\xB8", ALL, 1, 1, 1, false, FFFD),
  fact("overlong", "\xC0\xAF", ALL, 2, 2, 1, false, FFFD .. FFFD),
  fact("surrogate", "\xED\xA0\x80", ALL, 1, 1, 1, false, FFFD),
  fact("zwsp", "\xE2\x80\x8B", ALL, 1, 2, 2, true, "\xE2\x80\x8B"),
  -- Probe v2: wlen equals the screen columns.
  fact("tab in text", "a\tb", LEN_WLEN, 3, 4),
  fact("tab alone", "\t", LEN_WLEN, 1, 2),
  fact("vs16", "\xE2\x98\xBA\xEF\xB8\x8F", LEN_WLEN, 2, 3),
  fact("U+FE0F alone", "\xEF\xB8\x8F", { "wlen" }, 2),
  fact("hangul", "\xED\x95\x9C\xEA\xB5\xAD\xEC\x96\xB4", LEN_WLEN, 3, 6),
  fact("fullwidth", "\xEF\xBC\xA1", LEN_WLEN, 1, 2),
  fact("arabic", "\xD8\xB9\xD8\xB1\xD8\xA8\xD9\x8A", LEN_WLEN, 4, 4),
  fact("box line", "\xE2\x94\x8C\xE2\x94\x80\xE2\x94\x90", LEN_WLEN, 3, 3),
  fact("greek", "\xCE\xB1\xCE\xB2\xCE\xB3", LEN_WLEN, 3, 3),
}, function(input)
  local s = input[1]
  local get = {
    len = function() return unicode.len(s) end,
    wlen = function() return unicode.wlen(s) end,
    width = function() return unicode.charWidth(s) end,
    wide = function() return unicode.isWide(s) end,
    sub = function() return unicode.sub(s, 1, 2) end,
  }
  local r = {}
  for i, field in ipairs(input[2]) do
    r[i] = get[field]()
  end
  return r
end)

-- Input: { function name, arguments }.
t.cases(T, "unicode_functions", {
  { "char ASCII", { "char", { 0x41 } }, "A" },
  { "char U+2500", { "char", { 0x2500 } }, "\xE2\x94\x80" },
  { "char U+1F600", { "char", { 0x1F600 } }, "\xF0\x9F\x98\x80" },
  { "char above U+10FFFF", { "char", { 0x110000 } },
    "error: Not a valid Unicode code point: 0x110000" },
  { "sub with a negative start", { "sub", { "abcdef", -2 } }, "ef" },
  { "sub counts characters", { "sub", { "\xE4\xB8\xAD\xE6\x96\x87", 2 } },
    "\xE6\x96\x87" },
  { "reverse", { "reverse", { "a\xE4\xB8\xADb" } }, "b\xE4\xB8\xADa" },
  { "upper", { "upper", { "abc\xC3\xA9" } }, "ABC\xC3\x89" },
  { "lower", { "lower", { "ABC\xC3\x89" } }, "abc\xC3\xA9" },
  { "wtrunc cuts before a wide character that does not fit",
    { "wtrunc", { "\xE4\xB8\xAD\xE6\x96\x87abc", 3 } }, "\xE4\xB8\xAD" },
  { "wtrunc ASCII", { "wtrunc", { "abcdef", 4 } }, "abc" },
}, function(input)
  local ok, r = pcall(unicode[input[1]], table.unpack(input[2]))
  return ok and r or ("error: " .. tostring(r))
end)

-- Each test below resets the computer shim first, so it does not depend on
-- an earlier test.

function T.uptime_moves_in_50ms_steps()
  computer.test.reset()
  computer.test.set_clock(1.0)
  t.eq(computer.uptime(), 1.0)
  computer.test.advance(0.049)
  t.eq(computer.uptime(), 1.0, "below one step")
  computer.test.advance(0.001)
  t.ok(math.abs(computer.uptime() - 1.05) < 1e-9, "one step")
end

function T.memory_defaults()
  computer.test.reset()
  t.eq(computer.totalMemory(), 2097152)
  t.ok(computer.freeMemory() > 1700000, "about 1.8 MB free")
end

function T.memory_jitter_first_reading_lowest()
  computer.test.reset()
  computer.test.set_free(1808337)
  computer.test.set_jitter(213499)
  local first = computer.freeMemory()
  t.eq(first, 1808337 - 213499)
  for _ = 1, 4 do
    t.ok(computer.freeMemory() > first, "later readings are higher")
  end
end

-- The reset puts back the state that a test changed. The test changes the
-- state itself first.
function T.shim_reset_restores_the_state()
  computer.test.set_clock(7.0)
  computer.freeMemory()
  os.sleep(0)
  t.eq(computer.test.readings(), 1, "state is changed")
  computer.test.reset()
  t.eq(computer.uptime(), 0)
  t.eq(computer.test.readings(), 0)
  t.eq(computer.test.sleeps(), 0)
end

function T.os_sleep_advances_uptime()
  computer.test.reset()
  os.sleep(0)
  t.eq(computer.test.sleeps(), 1)
  os.sleep(1)
  t.ok(computer.uptime() >= 1, "uptime moved")
end

-- OpenOS os.sleep pulls and discards the events that arrive during the
-- sleep (boot/02_os.lua). Only event.listen listeners see them.
local function sleep_seen(...)
  local event = require("event")
  event.test.reset()
  local seen = {}
  local function on(name, ...)
    seen[#seen + 1] = { name, ... }
  end
  event.listen("key_down", on)
  event.listen("interrupted", on)
  event.test.push(...)
  os.sleep(0)
  event.ignore("key_down", on)
  event.ignore("interrupted", on)
  return seen, event
end

function T.os_sleep_removes_queued_events()
  local _, event = sleep_seen("key_down", "kbd", 113, 16, "user")
  t.eq(event.test.size(), 0)
end

function T.os_sleep_gives_events_to_listeners()
  local seen = sleep_seen("key_down", "kbd", 113, 16, "user")
  t.eq(seen, { { "key_down", "kbd", 113, 16, "user" } })
end

function T.pull_after_sleep_returns_nothing()
  local _, event = sleep_seen("key_down", "kbd", 113, 16, "user")
  t.eq(event.pull(0), nil)
end

function T.os_sleep_delivers_interrupted()
  local seen = sleep_seen("interrupted", "interrupted")
  t.eq(seen, { { "interrupted", "interrupted" } })
end

function T.pull_without_sleep_keeps_the_event()
  local event = require("event")
  event.test.reset()
  event.test.push("key_down", "kbd", 113, 16, "user")
  t.eq({ event.pull(0) }, { "key_down", "kbd", 113, 16, "user" })
end

return T
