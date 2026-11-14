-- Streaming, forgiving tokenizer. It reads chunks from a reader function
-- and returns one token per call. It scans with plain string.find and
-- string.byte. A pattern find runs only on a tag name. gsub and gmatch are
-- slow on large text and do not yield.
--
-- Tokens (the values a call returns):
--   "start", name, attrs, self_closing
--   "end", name
--   "text", s           (cleaned and decoded, maybe empty)
--   nil                 (end of input)
-- Names are lowercase. attrs is nil in this version.
-- Comments, doctype, CDATA and processing instructions are skipped.
-- The content of script and style is skipped up to the matching end tag.

local guard = require("html.guard")
local text = require("html.text")
local entities = require("html.entities")

local M = {}

local byte, find, sub, lower = string.byte, string.find, string.sub,
  string.lower
local max = math.max
local clean, split_tail, decode = text.clean, text.split_tail,
  entities.decode

-- A "<" with no ">" within this many bytes is text. This bounds the buffer.
M.MAX_TAG = 16384

-- Raw text elements. Their content is never markup.
local RAW = { script = true, style = true }

local function is_letter(b)
  return b ~= nil and ((b >= 65 and b <= 90) or (b >= 97 and b <= 122))
end

local function is_alnum(b)
  return is_letter(b) or (b ~= nil and b >= 48 and b <= 57)
end

-- read() returns the next chunk, or nil at the end of input.
-- progress() is optional. Its result is the line count in a memory error.
-- Returns a function that returns the next token.
function M.new(read, progress)
  local buf, pos, eof = "", 1, false
  -- Terminator of a skipped comment or bogus tag.
  local skip_to
  -- Name of the raw text element whose content is skipped.
  local raw

  local function tick()
    guard.tick(progress and progress())
  end

  -- Keeps the bytes from pos and appends the next chunk. Positions in buf
  -- move: pos becomes 1. Returns false at the end of input.
  local function fill()
    if eof then
      return false
    end
    local chunk = read()
    if chunk == nil then
      eof = true
      return false
    end
    if pos > #buf then
      buf = chunk
    else
      buf = sub(buf, pos) .. chunk
    end
    pos = 1
    return true
  end

  -- Makes sure that n bytes from pos are in buf. False at the end of input.
  local function want(n)
    while #buf - pos + 1 < n do
      tick()
      if not fill() then
        return false
      end
    end
    return true
  end

  local function text_token(s)
    return "text", decode(clean(s))
  end

  -- Skips to the end of a comment or bogus tag.
  local function skip()
    local _, e = find(buf, skip_to, pos, true)
    if e then
      pos = e + 1
      skip_to = nil
      return
    end
    -- Keep the bytes that can start the terminator.
    pos = max(pos, #buf - #skip_to + 2)
    if not fill() then
      pos = #buf + 1
      skip_to = nil
    end
  end

  -- Skips raw text up to "</name" followed by a non-alphanumeric byte.
  local function skip_raw()
    local k = find(buf, "</", pos, true)
    if not k then
      -- Keep a last "<".
      pos = max(pos, #buf)
      if not fill() then
        pos = #buf + 1
        raw = nil
      end
      return
    end
    pos = k
    if not want(#raw + 3) then
      -- Too short for an end tag. Unclosed raw text ends with the input.
      pos = #buf + 1
      raw = nil
      return
    end
    if lower(sub(buf, pos + 2, pos + 1 + #raw)) == raw
        and not is_alnum(byte(buf, pos + 2 + #raw)) then
      raw = nil
    else
      pos = pos + 2
    end
  end

  -- Reads the markup at pos, which is "<". Returns a token, or nil when the
  -- markup was skipped.
  local function tag()
    if not want(2) then
      pos = #buf + 1
      return "text", "<"
    end
    local b = byte(buf, pos + 1)
    if b == 33 then -- "!"
      if want(4) and sub(buf, pos, pos + 3) == "<!--" then
        skip_to, pos = "-->", pos + 4
      else
        skip_to, pos = ">", pos + 2
      end
      return nil
    end
    if b == 63 then -- "?"
      skip_to, pos = ">", pos + 2
      return nil
    end
    local closing = b == 47 -- "/"
    local rel = closing and 2 or 1
    if closing and not want(3) then
      pos = #buf + 1
      return "text", "</"
    end
    if not is_letter(byte(buf, pos + rel)) then
      if closing then
        skip_to, pos = ">", pos + 2
        return nil
      end
      pos = pos + 1
      return "text", "<"
    end
    local gt = find(buf, ">", pos + rel, true)
    while not gt do
      local scanned = #buf - pos + 1
      if scanned > M.MAX_TAG then
        pos = pos + 1
        return "text", "<"
      end
      tick()
      if not fill() then
        -- A tag cut by the end of input is dropped.
        pos = #buf + 1
        return nil
      end
      gt = find(buf, ">", pos + scanned, true)
    end
    local start = pos + rel
    local _, e = find(buf, "^[^%s/>]+", start)
    local name = lower(sub(buf, start, e))
    local self_closing = byte(buf, gt - 1) == 47 and gt - 1 > e
    pos = gt + 1
    if closing then
      return "end", name
    end
    if RAW[name] then
      raw = name
    end
    return "start", name, nil, self_closing
  end

  return function()
    while true do
      tick()
      if skip_to then
        skip()
      elseif raw then
        skip_raw()
      else
        if pos > #buf and not fill() then
          return nil
        end
        local lt = find(buf, "<", pos, true)
        if not lt then
          if eof then
            local s = sub(buf, pos)
            pos = #buf + 1
            return text_token(s)
          end
          -- A UTF-8 sequence or entity cut by the chunk end waits for the
          -- next chunk.
          local head, tail = split_tail(sub(buf, pos))
          buf, pos = tail, 1
          fill()
          if head ~= "" then
            return text_token(head)
          end
        elseif lt > pos then
          local s = sub(buf, pos, lt - 1)
          pos = lt
          return text_token(s)
        else
          local kind, name, attrs, self_closing = tag()
          if kind then
            return kind, name, attrs, self_closing
          end
        end
      end
    end
  end
end

return M
