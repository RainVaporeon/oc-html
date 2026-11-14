-- Tests for lib/html/text.lua (spec/text.md "Text cleaning").

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

local function check_clean(s, msg)
  t.ok(valid_utf8(s), msg .. ": valid UTF-8")
  t.ok(not s:find("[\1-\5]"), msg .. ": no style byte")
  t.ok(not s:find("[\0\6-\8\11-\31\127]"), msg .. ": no control byte")
end

-- Each row also runs inside "a" .. input .. "b".
local CLEAN = {
  -- Valid text stays. The probe strings of docs/probe/FACTS.md come first.
  { "ascii", "abc", "abc" },
  { "e_acute", "\xC3\xA9", "\xC3\xA9" },
  { "box", "\xE2\x94\x80", "\xE2\x94\x80" },
  { "zh", "\xE4\xB8\xAD\xE6\x96\x87", "\xE4\xB8\xAD\xE6\x96\x87" },
  { "ja", "\xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E\xE3\x83\x86\xE3\x82\xAD"
    .. "\xE3\x82\xB9\xE3\x83\x88", "\xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E"
    .. "\xE3\x83\x86\xE3\x82\xAD\xE3\x82\xB9\xE3\x83\x88" },
  { "emoji", "\xF0\x9F\x98\x80", "\xF0\x9F\x98\x80" },
  { "combining", "e\xCC\x81", "e\xCC\x81" },
  { "printable ASCII, tab and newline", "Hello,\tworld!\n~ ",
    "Hello,\tworld!\n~ " },
  { "empty", "", "" },
  { "U+00A0", "\xC2\xA0", "\xC2\xA0" },
  { "U+D7FF", "\xED\x9F\xBF", "\xED\x9F\xBF" },
  { "U+E000", "\xEE\x80\x80", "\xEE\x80\x80" },
  { "U+10FFFF", "\xF4\x8F\xBF\xBF", "\xF4\x8F\xBF\xBF" },
  -- One "?" per maximal invalid subpart.
  { "lone_cont", "\x80", "?" },
  { "truncated", "\xE4\xB8", "?" },
  { "overlong", "\xC0\xAF", "??" },
  { "surrogate", "\xED\xA0\x80", "???" },
  { "FF", "\xFF", "?" },
  { "F5 lead", "\xF5\x80\x80\x80", "????" },
  { "C1 overlong", "\xC1\xBF", "??" },
  { "E0 overlong", "\xE0\x80\xAF", "???" },
  { "F0 overlong", "\xF0\x80\x80\xAF", "????" },
  { "above U+10FFFF", "\xF4\x90\x80\x80", "????" },
  { "low surrogate", "\xED\xBF\xBF", "???" },
  { "truncated before ASCII", "\xE4\xB8x", "?x" },
  { "truncated 4-byte", "\xF0\x9F\x98", "?" },
  { "truncated before valid", "\xF0\x9F\x98\xE4\xB8\xAD", "?\xE4\xB8\xAD" },
  { "lead at end", "\xC3", "?" },
  { "continuation run", "\x80\x80\x80", "???" },
  { "long mixed", string.rep("ab\xE4\xB8\xAD\r\x80", 20000),
    string.rep("ab\xE4\xB8\xAD?", 20000) },
  -- Removed zero-width and invisible characters.
  { "zwsp", "\xE2\x80\x8B", "" },
  { "zero-width run", "a\xE2\x80\x8Bb\xE2\x80\x8Cc\xE2\x80\x8Dd\xEF\xBB\xBFe",
    "abcde" },
  { "BOM", "\xEF\xBB\xBFstart", "start" },
  { "U+00AD soft hyphen", "a\xC2\xADb", "ab" },
  { "U+200E", "a\xE2\x80\x8Eb", "ab" },
  { "U+200F", "a\xE2\x80\x8Fb", "ab" },
  -- Variation selectors U+FE00 to U+FE0F.
  { "U+FE00", "a\xEF\xB8\x80b", "ab" },
  { "U+FE0F", "\xE2\x98\xBA\xEF\xB8\x8F!", "\xE2\x98\xBA!" },
  { "U+FE10 kept", "a\xEF\xB8\x90b", "a\xEF\xB8\x90b" },
  { "U+FDFF kept", "a\xEF\xB7\xBFb", "a\xEF\xB7\xBFb" },
  -- Control bytes, DEL and C1 controls.
  { "control bytes", "a\0b\1c\2d\3e\4f\5g\6h\27i\31j", "abcdefghij" },
  { "CR", "line\r\nnext", "line\nnext" },
  { "DEL", "a\127b", "ab" },
  { "C1 controls", "a\xC2\x80b\xC2\x9Fc", "abc" },
}

local rows = {}
for _, row in ipairs(CLEAN) do
  rows[#rows + 1] = row
  rows[#rows + 1] = { row[1] .. " inside text", "a" .. row[2] .. "b",
    "a" .. row[3] .. "b" }
end
t.cases(T, "clean", rows, function(input)
  return text.clean(input)
end)

-- spec/text.md: cleaning removes all control bytes, so text never contains
-- the style bytes. Decoded entities pass through the same rules.
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

-- spec/text.md: a partial UTF-8 sequence or entity at a chunk end is held
-- back with text.split_tail. Output: { head, held back tail }.
local SPLIT_TAIL = {
  { "cut 3-byte after 2", "ab\xE4\xB8", { "ab", "\xE4\xB8" } },
  { "cut 3-byte after 1", "ab\xE4", { "ab", "\xE4" } },
  { "cut 4-byte", "ab\xF0\x9F\x98", { "ab", "\xF0\x9F\x98" } },
  { "whole 3-byte", "ab\xE4\xB8\xAD", { "ab\xE4\xB8\xAD", "" } },
  { "lone continuation", "ab\x80", { "ab\x80", "" } },
  { "empty", "", { "", "" } },
  { "cut named entity", "a &am", { "a ", "&am" } },
  { "lone &", "a &", { "a ", "&" } },
  { "cut hex entity", "a &#x1F6", { "a ", "&#x1F6" } },
  { "whole entity", "a &amp;", { "a &amp;", "" } },
  { "& then space", "a & b", { "a & b", "" } },
  { "too long for an entity", "&" .. string.rep("a", 40),
    { "&" .. string.rep("a", 40), "" } },
}

t.cases(T, "split_tail", SPLIT_TAIL, function(input)
  return { text.split_tail(input) }
end)

return T
