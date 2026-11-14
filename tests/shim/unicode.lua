-- Test replacement for the OpenOS unicode library.
-- Matches the measured results in docs/probe/FACTS.md ("Text").

local M = {}

local REPLACEMENT = 0xFFFD

-- Approximation of the game's wide character table. U+200B is wide in the
-- game (measured), so it is listed here.
local WIDE = {
  { 0x1100, 0x115F },   -- Hangul Jamo
  { 0x200B, 0x200B },   -- zero width space, measured as width 2
  { 0x2E80, 0x303E },   -- CJK radicals, punctuation
  { 0x3041, 0x33FF },   -- Hiragana, Katakana, CJK compatibility
  { 0x3400, 0x4DBF },   -- CJK extension A
  { 0x4E00, 0x9FFF },   -- CJK unified ideographs
  { 0xA000, 0xA4CF },   -- Yi
  { 0xAC00, 0xD7A3 },   -- Hangul syllables
  { 0xF900, 0xFAFF },   -- CJK compatibility ideographs
  { 0xFE30, 0xFE4F },   -- CJK compatibility forms
  { 0xFF00, 0xFF60 },   -- fullwidth forms
  { 0xFFE0, 0xFFE6 },   -- fullwidth signs
  { 0x1F300, 0x1F64F }, -- emoji, pictographs
  { 0x1F900, 0x1F9FF }, -- supplemental pictographs
  { 0x20000, 0x2FFFD }, -- CJK extension B and later
  { 0x30000, 0x3FFFD },
}

local function width_of(cp)
  for i = 1, #WIDE do
    local range = WIDE[i]
    if cp >= range[1] and cp <= range[2] then
      return 2
    end
  end
  return 1
end

-- Decodes bytes to code points. Each invalid unit becomes one U+FFFD:
-- a lone continuation byte, a bad lead byte (C0, C1, F5 to FF), a truncated
-- sequence (as one unit), an overlong form, an encoded surrogate, or a value
-- above U+10FFFF. The measured cases are 80, E4 B8, C0 AF and ED A0 80.
-- Other invalid forms follow the same rule but are not measured.
local function decode(s)
  local cps = {}
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    local need, cp, min
    if b < 0x80 then
      need, cp, min = 0, b, 0
    elseif b >= 0xC2 and b <= 0xDF then
      need, cp, min = 1, b & 0x1F, 0x80
    elseif b >= 0xE0 and b <= 0xEF then
      need, cp, min = 2, b & 0x0F, 0x800
    elseif b >= 0xF0 and b <= 0xF4 then
      need, cp, min = 3, b & 0x07, 0x10000
    end
    if not need then
      cps[#cps + 1] = REPLACEMENT
      i = i + 1
    else
      local j = i + 1
      local got = 0
      while got < need and j <= n do
        local c = s:byte(j)
        if c < 0x80 or c > 0xBF then
          break
        end
        cp = (cp << 6) | (c & 0x3F)
        got = got + 1
        j = j + 1
      end
      if got < need or cp < min or cp > 0x10FFFF
          or (cp >= 0xD800 and cp <= 0xDFFF) then
        cp = REPLACEMENT
      end
      cps[#cps + 1] = cp
      i = j
    end
  end
  return cps
end

local function encode(cps, from, to)
  local out = {}
  for k = from, to do
    out[#out + 1] = utf8.char(cps[k])
  end
  return table.concat(out)
end

local function check_string(s, name)
  if type(s) == "number" then
    return tostring(s)
  end
  if type(s) ~= "string" then
    error("bad argument #1 to '" .. name .. "' (string expected, got "
      .. type(s) .. ")", 3)
  end
  return s
end

function M.len(s)
  return #decode(check_string(s, "len"))
end

function M.wlen(s)
  local cps = decode(check_string(s, "wlen"))
  local w = 0
  for k = 1, #cps do
    w = w + width_of(cps[k])
  end
  return w
end

function M.charWidth(s)
  local cps = decode(check_string(s, "charWidth"))
  if #cps == 0 then
    return 1
  end
  return width_of(cps[1])
end

function M.isWide(s)
  return M.charWidth(s) > 1
end

-- Same index rules as string.sub, counted in characters.
function M.sub(s, i, j)
  local cps = decode(check_string(s, "sub"))
  local n = #cps
  i = math.tointeger(i) or 1
  j = math.tointeger(j) or -1
  if i < 0 then i = math.max(n + i + 1, 1) elseif i == 0 then i = 1 end
  if j < 0 then j = n + j + 1 elseif j > n then j = n end
  if i > j then
    return ""
  end
  return encode(cps, i, j)
end

function M.char(...)
  local out = {}
  for k = 1, select("#", ...) do
    local cp = math.tointeger((select(k, ...)))
    if not cp or cp < 0 or cp > 0x10FFFF then
      error(string.format("Not a valid Unicode code point: 0x%X",
        cp or 0), 0)
    end
    if cp >= 0xD800 and cp <= 0xDFFF then
      cp = REPLACEMENT
    end
    out[#out + 1] = utf8.char(cp)
  end
  return table.concat(out)
end

-- Keeps characters while the width so far is below n, then drops the last
-- one, like the game: wtrunc("中文abc", 3) is "中". The game behavior when n
-- exceeds the full width is not measured. This shim returns the whole string.
function M.wtrunc(s, n)
  local cps = decode(check_string(s, "wtrunc"))
  local width, stop = 0, 0
  while width < n do
    if stop >= #cps then
      return encode(cps, 1, #cps)
    end
    stop = stop + 1
    width = width + width_of(cps[stop])
  end
  return encode(cps, 1, stop - 1)
end

-- Case mapping covers ASCII, Latin-1, Greek and basic Cyrillic only.
local function map_case(s, to_upper)
  local cps = decode(s)
  for k = 1, #cps do
    local cp = cps[k]
    if to_upper then
      if (cp >= 0x61 and cp <= 0x7A) or (cp >= 0xE0 and cp <= 0xFE and cp ~= 0xF7)
          or (cp >= 0x3B1 and cp <= 0x3C9 and cp ~= 0x3C2)
          or (cp >= 0x430 and cp <= 0x44F) then
        cp = cp - 0x20
      elseif cp >= 0x450 and cp <= 0x45F then
        cp = cp - 0x50
      end
    else
      if (cp >= 0x41 and cp <= 0x5A) or (cp >= 0xC0 and cp <= 0xDE and cp ~= 0xD7)
          or (cp >= 0x391 and cp <= 0x3A9 and cp ~= 0x3A2)
          or (cp >= 0x410 and cp <= 0x42F) then
        cp = cp + 0x20
      elseif cp >= 0x400 and cp <= 0x40F then
        cp = cp + 0x50
      end
    end
    cps[k] = cp
  end
  return encode(cps, 1, #cps)
end

function M.lower(s)
  return map_case(check_string(s, "lower"), false)
end

function M.upper(s)
  return map_case(check_string(s, "upper"), true)
end

function M.reverse(s)
  local cps = decode(check_string(s, "reverse"))
  local out = {}
  for k = #cps, 1, -1 do
    out[#out + 1] = utf8.char(cps[k])
  end
  return table.concat(out)
end

return M
