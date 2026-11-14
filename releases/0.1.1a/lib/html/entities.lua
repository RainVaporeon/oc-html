-- Named and numeric character references.
-- The caller cleans the text first: decode(text.clean(s)). Every
-- replacement is complete UTF-8 that already follows the cleaning rules,
-- so the result stays clean.

local M = {}

local byte, find, sub, char = string.byte, string.find, string.sub, utf8.char
local concat = table.concat

local MAX_NAME = 32
-- Eight hex or decimal digits are enough to pass U+10FFFF.
local MAX_DIGITS = 8

local NAMED = {
  amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
  -- Invisible marks; the cleaning rules remove zero-width characters.
  zwnj = "", zwj = "", lrm = "", rlm = "",
}

local LATIN1 = {
  "nbsp", "iexcl", "cent", "pound", "curren", "yen", "brvbar", "sect",
  "uml", "copy", "ordf", "laquo", "not", "shy", "reg", "macr",
  "deg", "plusmn", "sup2", "sup3", "acute", "micro", "para", "middot",
  "cedil", "sup1", "ordm", "raquo", "frac14", "frac12", "frac34", "iquest",
  "Agrave", "Aacute", "Acirc", "Atilde", "Auml", "Aring", "AElig", "Ccedil",
  "Egrave", "Eacute", "Ecirc", "Euml", "Igrave", "Iacute", "Icirc", "Iuml",
  "ETH", "Ntilde", "Ograve", "Oacute", "Ocirc", "Otilde", "Ouml", "times",
  "Oslash", "Ugrave", "Uacute", "Ucirc", "Uuml", "Yacute", "THORN", "szlig",
  "agrave", "aacute", "acirc", "atilde", "auml", "aring", "aelig", "ccedil",
  "egrave", "eacute", "ecirc", "euml", "igrave", "iacute", "icirc", "iuml",
  "eth", "ntilde", "ograve", "oacute", "ocirc", "otilde", "ouml", "divide",
  "oslash", "ugrave", "uacute", "ucirc", "uuml", "yacute", "thorn", "yuml",
}
for k, name in ipairs(LATIN1) do
  NAMED[name] = char(0x9F + k)
end
-- The soft hyphen is removed like the other invisible characters.
NAMED.shy = ""

local OTHER = {
  OElig = 0x152, oelig = 0x153, Scaron = 0x160, scaron = 0x161,
  Yuml = 0x178, fnof = 0x192, circ = 0x2C6, tilde = 0x2DC,
  ensp = 0x2002, emsp = 0x2003, thinsp = 0x2009,
  ndash = 0x2013, mdash = 0x2014, lsquo = 0x2018, rsquo = 0x2019,
  sbquo = 0x201A, ldquo = 0x201C, rdquo = 0x201D, bdquo = 0x201E,
  dagger = 0x2020, Dagger = 0x2021, bull = 0x2022, hellip = 0x2026,
  permil = 0x2030, prime = 0x2032, Prime = 0x2033, lsaquo = 0x2039,
  rsaquo = 0x203A, oline = 0x203E, euro = 0x20AC, trade = 0x2122,
  larr = 0x2190, uarr = 0x2191, rarr = 0x2192, darr = 0x2193,
  harr = 0x2194, minus = 0x2212, infin = 0x221E, asymp = 0x2248,
  ne = 0x2260, le = 0x2264, ge = 0x2265,
}
for name, cp in pairs(OTHER) do
  NAMED[name] = char(cp)
end

-- Legacy names that decode without ";" when the next byte is not
-- alphanumeric and not "=", as HTML does in attributes. This keeps
-- "?a=1&copy=2" and "&ampx" as written.
local LEGACY = { amp = true, lt = true, gt = true, quot = true, nbsp = true,
  copy = true, reg = true }

-- HTML maps references to 0x80..0x9F to Windows-1252 characters.
local WIN1252 = {
  [0x80] = 0x20AC, [0x82] = 0x201A, [0x83] = 0x0192, [0x84] = 0x201E,
  [0x85] = 0x2026, [0x86] = 0x2020, [0x87] = 0x2021, [0x88] = 0x02C6,
  [0x89] = 0x2030, [0x8A] = 0x0160, [0x8B] = 0x2039, [0x8C] = 0x0152,
  [0x8E] = 0x017D, [0x91] = 0x2018, [0x92] = 0x2019, [0x93] = 0x201C,
  [0x94] = 0x201D, [0x95] = 0x2022, [0x96] = 0x2013, [0x97] = 0x2014,
  [0x98] = 0x02DC, [0x99] = 0x2122, [0x9A] = 0x0161, [0x9B] = 0x203A,
  [0x9C] = 0x0153, [0x9E] = 0x017E, [0x9F] = 0x0178,
}

-- Applies the cleaning rules to one code point.
local function code_point(cp)
  if cp == 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
    return "?"
  end
  if cp >= 0x80 and cp <= 0x9F then
    cp = WIN1252[cp]
    return cp and char(cp) or ""
  end
  if (cp < 0x20 and cp ~= 0x09 and cp ~= 0x0A) or cp == 0x7F
      or cp == 0xAD or (cp >= 0x200B and cp <= 0x200F) or cp == 0xFEFF then
    return ""
  end
  return char(cp)
end

local function is_alnum(b)
  return b and ((b >= 0x30 and b <= 0x39) or (b >= 0x41 and b <= 0x5A)
    or (b >= 0x61 and b <= 0x7A))
end

-- Parses the reference at p ("&"). Returns the replacement and the index
-- after it, or nil when the text is not a reference.
local function reference(s, p)
  if byte(s, p + 1) == 0x23 then
    local q, digits, base = p + 2, "^%d+", 10
    local x = byte(s, q)
    if x == 0x78 or x == 0x58 then
      q, digits, base = q + 1, "^%x+", 16
    end
    local _, e = find(s, digits, q)
    if not e then
      return nil
    end
    -- Skip leading zeros so a long zero run still parses.
    local _, z = find(s, "^0+", q)
    local first = z and z < e and z + 1 or (z or q)
    local cp
    if e - first + 1 > MAX_DIGITS then
      cp = 0x110000
    else
      cp = tonumber(sub(s, first, e), base)
    end
    if byte(s, e + 1) == 0x3B then
      e = e + 1
    end
    return code_point(cp), e + 1
  end
  local _, e = find(s, "^%w+", p + 1)
  if not e or e - p > MAX_NAME then
    return nil
  end
  local name = sub(s, p + 1, e)
  local value = NAMED[name]
  if not value then
    return nil
  end
  if byte(s, e + 1) == 0x3B then
    return value, e + 2
  end
  local next_byte = byte(s, e + 1)
  if LEGACY[name] and not is_alnum(next_byte) and next_byte ~= 0x3D then
    return value, e + 1
  end
  return nil
end

-- Decodes references in s. Unknown references stay as written.
function M.decode(s)
  local p = find(s, "&", 1, true)
  if not p then
    return s
  end
  local parts, n = {}, 0
  local run = 1
  while p do
    local value, after = reference(s, p)
    if value and after then
      if p > run then
        n = n + 1
        parts[n] = sub(s, run, p - 1)
      end
      n = n + 1
      parts[n] = value
      run = after
      p = find(s, "&", after, true)
    else
      p = find(s, "&", p + 1, true)
    end
  end
  if run <= #s then
    n = n + 1
    parts[n] = sub(s, run)
  end
  return concat(parts)
end

return M
