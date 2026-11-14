-- Text cleaning. Runs in plain Lua before any unicode.* call, because
-- unicode.* turns bad bytes into U+FFFD silently and utf8.len accepts
-- encoded surrogates.

local M = {}

local byte, find, sub = string.byte, string.find, string.sub
local concat = table.concat

-- Any byte that is not printable ASCII, tab or newline.
local SPECIAL = "[^\t\n\32-\126]"

-- An entity name or numeric reference is never longer than this.
M.MAX_ENTITY = 32

-- Returns the length of the valid UTF-8 sequence at i, or nil and the
-- length of the maximal invalid subpart (Unicode recommended practice).
local function sequence(s, i, b)
  local need, lo, hi
  if b >= 0xC2 and b <= 0xDF then
    need, lo, hi = 1, 0x80, 0xBF
  elseif b == 0xE0 then
    need, lo, hi = 2, 0xA0, 0xBF
  elseif b == 0xED then
    -- A0..BF here would encode a surrogate.
    need, lo, hi = 2, 0x80, 0x9F
  elseif b >= 0xE1 and b <= 0xEF then
    need, lo, hi = 2, 0x80, 0xBF
  elseif b == 0xF0 then
    need, lo, hi = 3, 0x90, 0xBF
  elseif b == 0xF4 then
    -- 90..BF here would be above U+10FFFF.
    need, lo, hi = 3, 0x80, 0x8F
  elseif b >= 0xF1 and b <= 0xF3 then
    need, lo, hi = 3, 0x80, 0xBF
  else
    return nil, 1
  end
  local c = byte(s, i + 1)
  if not c or c < lo or c > hi then
    return nil, 1
  end
  for k = 2, need do
    c = byte(s, i + k)
    if not c or c < 0x80 or c > 0xBF then
      return nil, k
    end
  end
  return need + 1
end

-- True for C1 controls (U+0080..U+009F), the soft hyphen (U+00AD),
-- zero-width or invisible characters (U+200B..U+200F, U+FEFF) and the
-- variation selectors (U+FE00..U+FE0F). unicode.wlen counts U+200B and
-- U+FE0F as width 2 (measured).
local function removed(s, i, len)
  local b1, b2, b3 = byte(s, i, i + 2)
  if len == 2 then
    return b1 == 0xC2 and (b2 <= 0x9F or b2 == 0xAD)
  end
  if len == 3 then
    return (b1 == 0xE2 and b2 == 0x80 and b3 >= 0x8B and b3 <= 0x8F)
      or (b1 == 0xEF and b2 == 0xBB and b3 == 0xBF)
      or (b1 == 0xEF and b2 == 0xB8 and b3 >= 0x80 and b3 <= 0x8F)
  end
  return false
end

-- Returns s as valid UTF-8 with no control bytes except tab and newline.
-- Bad sequences become one "?" per maximal invalid subpart.
function M.clean(s)
  local i = find(s, SPECIAL)
  if not i then
    return s
  end
  local parts, n = {}, 0
  local run = 1
  local len = #s
  while i do
    local b = byte(s, i)
    local keep, skip, mark
    if b < 0x80 then
      -- Control bytes (0x01-0x05 are style bytes), \r and DEL.
      skip = 1
    else
      local ok, bad = sequence(s, i, b)
      if ok then
        if removed(s, i, ok) then
          skip = ok
        else
          keep = ok
        end
      else
        skip, mark = bad, true
      end
    end
    if keep then
      i = i + keep
    else
      if i > run then
        n = n + 1
        parts[n] = sub(s, run, i - 1)
      end
      if mark then
        n = n + 1
        parts[n] = "?"
      end
      i = i + skip
      run = i
    end
    if i > len then
      break
    end
    i = find(s, SPECIAL, i)
  end
  if run <= len then
    n = n + 1
    parts[n] = sub(s, run)
  end
  return concat(parts)
end

-- Returns the start of a partial UTF-8 sequence at the end of s[i..j], or
-- j + 1 when there is none. A partial sequence is a lead byte in the last
-- 3 bytes with too few followers. Bytes before the result can be cleaned
-- apart from the bytes after it: clean(a .. b) == clean(a) .. clean(b).
function M.utf8_cut(s, i, j)
  for k = j, math.max(i, j - 2), -1 do
    local b = byte(s, k)
    if b < 0x80 or b >= 0xC0 then
      local need = b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC2 and 2 or 1
      if j - k + 1 < need then
        return k
      end
      return j + 1
    end
  end
  return j + 1
end

-- Splits s into head and tail. The tail is a trailing piece that the next
-- chunk may complete: a partial UTF-8 sequence or a partial entity. A
-- streaming caller cleans the head and puts the tail before the next chunk.
-- At the end of a text run the caller passes the whole rest, not split.
function M.split_tail(s)
  local len = #s
  local cut = M.utf8_cut(s, 1, len)
  -- Partial entity: "&" then only "#" and alphanumerics up to the end.
  for k = cut - 1, math.max(1, cut - 1 - M.MAX_ENTITY), -1 do
    local b = byte(s, k)
    if b == 0x26 then
      cut = k
      break
    end
    if not (b == 0x23 or (b >= 0x30 and b <= 0x39)
        or (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A)) then
      break
    end
  end
  if cut > len then
    return s, ""
  end
  return sub(s, 1, cut - 1), sub(s, cut)
end

return M
