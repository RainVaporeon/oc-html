-- Checks the shims against docs/probe/FACTS.md.

local t = require("test")
local unicode = require("unicode")
local computer = require("computer")

local T = {}

local FFFD = "\xEF\xBF\xBD"

-- Probe strings and the measured values (probe key text.<name>.*).
local TEXT = {
  { "ascii", "abc", len = 3, wlen = 3, width = 1, wide = false, sub = "ab" },
  { "e_acute", "\xC3\xA9", len = 1, wlen = 1, width = 1, wide = false,
    sub = "\xC3\xA9" },
  { "box", "\xE2\x94\x80", len = 1, wlen = 1, width = 1, wide = false,
    sub = "\xE2\x94\x80" },
  { "zh", "\xE4\xB8\xAD\xE6\x96\x87", len = 2, wlen = 4, width = 2,
    wide = true, sub = "\xE4\xB8\xAD\xE6\x96\x87" },
  { "ja", "\xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E\xE3\x83\x86\xE3\x82\xAD"
    .. "\xE3\x82\xB9\xE3\x83\x88", len = 7, wlen = 14, width = 2, wide = true,
    sub = "\xE6\x97\xA5\xE6\x9C\xAC" },
  { "emoji", "\xF0\x9F\x98\x80", len = 1, wlen = 2, width = 2, wide = true,
    sub = "\xF0\x9F\x98\x80" },
  { "combining", "e\xCC\x81", len = 2, wlen = 2, width = 1, wide = false,
    sub = "e\xCC\x81" },
  { "lone_cont", "\x80", len = 1, wlen = 1, width = 1, wide = false,
    sub = FFFD },
  { "truncated", "\xE4\xB8", len = 1, wlen = 1, width = 1, wide = false,
    sub = FFFD },
  { "overlong", "\xC0\xAF", len = 2, wlen = 2, width = 1, wide = false,
    sub = FFFD .. FFFD },
  { "surrogate", "\xED\xA0\x80", len = 1, wlen = 1, width = 1, wide = false,
    sub = FFFD },
  { "zwsp", "\xE2\x80\x8B", len = 1, wlen = 2, width = 2, wide = true,
    sub = "\xE2\x80\x8B" },
}

function T.unicode_matches_probe_text_table()
  for _, row in ipairs(TEXT) do
    local name, s = row[1], row[2]
    t.eq(unicode.len(s), row.len, name .. " len")
    t.eq(unicode.wlen(s), row.wlen, name .. " wlen")
    t.eq(unicode.charWidth(s), row.width, name .. " charWidth")
    t.eq(unicode.isWide(s), row.wide, name .. " isWide")
    t.eq(unicode.sub(s, 1, 2), row.sub, name .. " sub(1, 2)")
  end
end

function T.unicode_char_matches_probe()
  t.eq(unicode.char(0x41), "A")
  t.eq(unicode.char(0x2500), "\xE2\x94\x80")
  t.eq(unicode.char(0x1F600), "\xF0\x9F\x98\x80")
  t.raises(function() unicode.char(0x110000) end,
    "^Not a valid Unicode code point: 0x110000$")
end

function T.unicode_wtrunc_matches_probe()
  t.eq(unicode.wtrunc("\xE4\xB8\xAD\xE6\x96\x87abc", 3), "\xE4\xB8\xAD")
end

function T.unicode_other_functions()
  t.eq(unicode.sub("abcdef", -2), "ef")
  t.eq(unicode.sub("\xE4\xB8\xAD\xE6\x96\x87", 2), "\xE6\x96\x87")
  t.eq(unicode.reverse("a\xE4\xB8\xADb"), "b\xE4\xB8\xADa")
  t.eq(unicode.upper("abc\xC3\xA9"), "ABC\xC3\x89")
  t.eq(unicode.lower("ABC\xC3\x89"), "abc\xC3\xA9")
  t.eq(unicode.wtrunc("abcdef", 4), "abc")
end

function T.uptime_moves_in_50ms_steps()
  computer.test.set_clock(1.0)
  t.eq(computer.uptime(), 1.0)
  computer.test.advance(0.049)
  t.eq(computer.uptime(), 1.0, "below one step")
  computer.test.advance(0.001)
  t.ok(math.abs(computer.uptime() - 1.05) < 1e-9, "one step")
end

function T.memory_defaults()
  t.eq(computer.totalMemory(), 2097152)
  t.ok(computer.freeMemory() > 1700000, "about 1.8 MB free")
end

function T.memory_jitter_first_reading_lowest()
  computer.test.set_free(1808337)
  computer.test.set_jitter(213499)
  local first = computer.freeMemory()
  t.eq(first, 1808337 - 213499)
  for _ = 1, 4 do
    t.ok(computer.freeMemory() > first, "later readings are higher")
  end
end

function T.shim_state_resets_between_tests()
  t.eq(computer.uptime(), 0)
  t.eq(computer.test.readings(), 0)
end

function T.os_sleep_advances_uptime()
  os.sleep(0)
  t.eq(computer.test.sleeps(), 1)
  os.sleep(1)
  t.ok(computer.uptime() >= 1, "uptime moved")
end

return T
