-- Tests for lib/html/text.lua (SPEC.md "Text cleaning").

local t = require("test")
local text = require("html.text")
local entities = require("html.entities")

local T = {}

-- Strict UTF-8 check: no overlongs, no surrogates, nothing above U+10FFFF.
local function valid_utf8(s)
  local i, len = 1, #s
  while i <= len do
    local b = s:byte(i)
    local need, lo, hi
    if b < 0x80 then
      need = 0
    elseif b >= 0xC2 and b <= 0xDF then
      need, lo, hi = 1, 0x80, 0xBF
    elseif b == 0xE0 then
      need, lo, hi = 2, 0xA0, 0xBF
    elseif b == 0xED then
      need, lo, hi = 2, 0x80, 0x9F
    elseif b >= 0xE1 and b <= 0xEF then
      need, lo, hi = 2, 0x80, 0xBF
    elseif b == 0xF0 then
      need, lo, hi = 3, 0x90, 0xBF
    elseif b == 0xF4 then
      need, lo, hi = 3, 0x80, 0x8F
    elseif b >= 0xF1 and b <= 0xF3 then
      need, lo, hi = 3, 0x80, 0xBF
    else
      return false
    end
    for k = 1, need do
      local c = s:byte(i + k)
      if not c then
        return false
      end
      if k == 1 then
        if c < lo or c > hi then
          return false
        end
      elseif c < 0x80 or c > 0xBF then
        return false
      end
    end
    i = i + need + 1
  end
  return true
end

local function count(s, ch)
  local n = 0
  for k = 1, #s do
    if s:sub(k, k) == ch then
      n = n + 1
    end
  end
  return n
end

local function check_clean(s, msg)
  t.ok(valid_utf8(s), msg .. ": valid UTF-8")
  t.ok(not s:find("[\1-\5]"), msg .. ": no style byte")
  t.ok(not s:find("[\0\6-\8\11-\31\127]"), msg .. ": no control byte")
end

-- Every probe string in docs/probe/FACTS.md, with the expected output.
-- Bad sequences give one "?" per maximal invalid subpart.
local PROBE = {
  { "ascii", "abc", "abc" },
  { "e_acute", "\xC3\xA9", "\xC3\xA9" },
  { "box", "\xE2\x94\x80", "\xE2\x94\x80" },
  { "zh", "\xE4\xB8\xAD\xE6\x96\x87", "\xE4\xB8\xAD\xE6\x96\x87" },
  { "ja", "\xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E\xE3\x83\x86\xE3\x82\xAD"
    .. "\xE3\x82\xB9\xE3\x83\x88", "\xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E"
    .. "\xE3\x83\x86\xE3\x82\xAD\xE3\x82\xB9\xE3\x83\x88" },
  { "emoji", "\xF0\x9F\x98\x80", "\xF0\x9F\x98\x80" },
  { "combining", "e\xCC\x81", "e\xCC\x81" },
  { "lone_cont", "\x80", "?" },
  { "truncated", "\xE4\xB8", "?" },
  { "overlong", "\xC0\xAF", "??" },
  { "surrogate", "\xED\xA0\x80", "???" },
  { "zwsp", "\xE2\x80\x8B", "" },
}

function T.probe_strings()
  for _, row in ipairs(PROBE) do
    local name, input, expected = row[1], row[2], row[3]
    local out = text.clean(input)
    t.eq(out, expected, name)
    check_clean(out, name)
    t.eq(count(out, "?"), count(expected, "?"), name .. " ? count")
  end
end

function T.probe_strings_inside_text()
  for _, row in ipairs(PROBE) do
    t.eq(text.clean("a" .. row[2] .. "b"), "a" .. row[3] .. "b", row[1])
  end
end

function T.ascii_fast_path_returns_same_string()
  local s = "Hello,\tworld!\n~ "
  t.ok(rawequal(text.clean(s), s))
  t.eq(text.clean(""), "")
end

function T.invalid_sequences()
  t.eq(text.clean("\xFF"), "?", "FF")
  t.eq(text.clean("\xF5\x80\x80\x80"), "????", "F5 lead")
  t.eq(text.clean("\xC1\xBF"), "??", "C1 overlong")
  t.eq(text.clean("\xE0\x80\xAF"), "???", "E0 overlong")
  t.eq(text.clean("\xF0\x80\x80\xAF"), "????", "F0 overlong")
  t.eq(text.clean("\xF4\x90\x80\x80"), "????", "above U+10FFFF")
  t.eq(text.clean("\xED\xBF\xBF"), "???", "low surrogate")
  t.eq(text.clean("\xE4\xB8x"), "?x", "truncated before ASCII")
  t.eq(text.clean("\xF0\x9F\x98"), "?", "truncated 4-byte")
  t.eq(text.clean("\xF0\x9F\x98\xE4\xB8\xAD"), "?\xE4\xB8\xAD",
    "truncated before valid")
  t.eq(text.clean("\xC3"), "?", "lead at end")
  t.eq(text.clean("\x80\x80\x80"), "???", "continuation run")
end

function T.boundary_code_points_kept()
  t.eq(text.clean("\xC2\xA0"), "\xC2\xA0", "U+00A0")
  t.eq(text.clean("\xED\x9F\xBF"), "\xED\x9F\xBF", "U+D7FF")
  t.eq(text.clean("\xEE\x80\x80"), "\xEE\x80\x80", "U+E000")
  t.eq(text.clean("\xF4\x8F\xBF\xBF"), "\xF4\x8F\xBF\xBF", "U+10FFFF")
end

function T.zero_width_removed()
  t.eq(text.clean("a\xE2\x80\x8Bb\xE2\x80\x8Cc\xE2\x80\x8Dd\xEF\xBB\xBFe"),
    "abcde")
  t.eq(text.clean("\xEF\xBB\xBFstart"), "start", "BOM")
  t.eq(text.clean("a\xC2\xADb"), "ab", "U+00AD soft hyphen")
  t.eq(text.clean("a\xE2\x80\x8Eb"), "ab", "U+200E")
  t.eq(text.clean("a\xE2\x80\x8Fb"), "ab", "U+200F")
end

function T.variation_selectors_removed()
  t.eq(text.clean("a\xEF\xB8\x80b"), "ab", "U+FE00")
  t.eq(text.clean("\xE2\x98\xBA\xEF\xB8\x8F!"), "\xE2\x98\xBA!", "U+FE0F")
  t.eq(text.clean("a\xEF\xB8\x90b"), "a\xEF\xB8\x90b", "U+FE10 kept")
  t.eq(text.clean("a\xEF\xB7\xBFb"), "a\xEF\xB7\xBFb", "U+FDFF kept")
end

function T.control_bytes_removed()
  t.eq(text.clean("a\0b\1c\2d\3e\4f\5g\6h\27i\31j"), "abcdefghij")
  t.eq(text.clean("line\r\nnext"), "line\nnext", "CR")
  t.eq(text.clean("a\tb\nc"), "a\tb\nc", "tab and newline kept")
  t.eq(text.clean("a\127b"), "ab", "DEL")
  t.eq(text.clean("a\xC2\x80b\xC2\x9Fc"), "abc", "C1 controls")
end

function T.long_string()
  local piece = "ab\xE4\xB8\xAD\r\x80"
  local s = string.rep(piece, 20000)
  local out = text.clean(s)
  t.eq(#out, 20000 * 6)
  t.eq(out, string.rep("ab\xE4\xB8\xAD?", 20000))
end

function T.random_bytes_never_give_style_bytes()
  local seed = 20261114
  math.randomseed(seed)
  local bytes = {}
  for round = 1, 2000 do
    local len = math.random(0, 40)
    for k = 1, len do
      -- Bias toward "&", "#", "x", digits, ";" and high bytes.
      local r = math.random(1, 10)
      if r == 1 then
        bytes[k] = 0x26
      elseif r == 2 then
        bytes[k] = ({ 0x23, 0x78, 0x3B, 0x31, 0x30 })[math.random(1, 5)]
      else
        bytes[k] = math.random(0, 255)
      end
    end
    local s = string.char(table.unpack(bytes, 1, len))
    local msg = "seed " .. seed .. " round " .. round
    local cleaned = text.clean(s)
    check_clean(cleaned, msg .. " clean")
    check_clean(entities.decode(cleaned), msg .. " decode")
  end
end

function T.split_tail_utf8()
  t.eq({ text.split_tail("ab\xE4\xB8") }, { "ab", "\xE4\xB8" })
  t.eq({ text.split_tail("ab\xE4") }, { "ab", "\xE4" })
  t.eq({ text.split_tail("ab\xF0\x9F\x98") }, { "ab", "\xF0\x9F\x98" })
  t.eq({ text.split_tail("ab\xE4\xB8\xAD") }, { "ab\xE4\xB8\xAD", "" })
  t.eq({ text.split_tail("ab\x80") }, { "ab\x80", "" })
  t.eq({ text.split_tail("") }, { "", "" })
end

function T.split_tail_entity()
  t.eq({ text.split_tail("a &am") }, { "a ", "&am" })
  t.eq({ text.split_tail("a &") }, { "a ", "&" })
  t.eq({ text.split_tail("a &#x1F6") }, { "a ", "&#x1F6" })
  t.eq({ text.split_tail("a &amp;") }, { "a &amp;", "" })
  t.eq({ text.split_tail("a & b") }, { "a & b", "" })
  t.eq({ text.split_tail("&" .. string.rep("a", 40)) },
    { "&" .. string.rep("a", 40), "" }, "too long for an entity")
end

-- Feeding a text run in chunks of any size gives the same result as one call.
function T.split_tail_streaming_matches_whole()
  local s = "x &eacute; \xE4\xB8\xAD&#x1F600;y &amp z\xF0\x9F\x98\x80&copy;"
  local whole = entities.decode(text.clean(s))
  for size = 1, 8 do
    local out, carry = {}, ""
    for k = 1, #s, size do
      local head
      head, carry = text.split_tail(carry .. s:sub(k, k + size - 1))
      out[#out + 1] = entities.decode(text.clean(head))
    end
    out[#out + 1] = entities.decode(text.clean(carry))
    t.eq(table.concat(out), whole, "chunk size " .. size)
  end
end

return T
