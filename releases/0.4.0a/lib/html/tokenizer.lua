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
-- Names are lowercase. attrs maps a lowercase name to its cleaned and
-- decoded value, or is nil when the tag has no attributes.
-- Comments, doctype, CDATA and processing instructions are skipped. The
-- content of script and style is skipped up to the matching end tag. The
-- content of title and textarea is text up to the matching end tag.
--
-- Recovery for broken markup:
--   "<" + non-letter is text. "</>" is dropped. "</" + non-letter is a bogus
--   comment up to ">".
--   A "<" with no ">" within MAX_TAG bytes or before the end of input is
--   text.
--   A broken quoted value ends the tag at the first ">" in the value. The
--   value's attribute is dropped. A quoted value is broken when it does not
--   close within MAX_TAG bytes of "<" or before the end of input, or when
--   it holds a ">" and then "</" (as in <a href="x>text</a>).
--   A tag that does not end within MAX_TAG bytes for another reason ends at
--   the first ">" after its "<", with no attributes.
--   An attribute name with a quote or "<", or one that starts with "=", is
--   dropped. For a duplicate name, the first value is kept.
--   An end tag ends at the first ">" after its "<", also inside quotes.
--   An unclosed comment, bogus comment, CDATA, script or style ends with
--   the input and gives no text. Unclosed title or textarea content is text.

local guard = require("html.guard")
local text = require("html.text")
local entities = require("html.entities")

local M = {}

local byte, find, sub, lower = string.byte, string.find, string.sub,
  string.lower
local max = math.max
local clean, split_tail, utf8_cut, decode = text.clean, text.split_tail,
  text.utf8_cut, entities.decode

-- A "<" with no ">" within this many bytes is text. This bounds the buffer.
M.MAX_TAG = 16384

-- Raw text elements. true: the content is text (RCDATA). false: the
-- content is skipped.
local RAW = { script = false, style = false, title = true, textarea = true }

-- HTML whitespace: tab, LF, FF, CR, space.
local WS = { [9] = true, [10] = true, [12] = true, [13] = true, [32] = true }

-- Attribute scanner states.
local BEFORE_NAME, NAME, AFTER_NAME, BEFORE_VALUE, UNQUOTED, QUOTED, SLASH =
  1, 2, 3, 4, 5, 6, 7

local function is_letter(b)
  return b ~= nil and ((b >= 65 and b <= 90) or (b >= 97 and b <= 122))
end

-- Adds one attribute. Returns the attrs table, made on the first call.
local function add(attrs, name, value)
  name = lower(name)
  attrs = attrs or {}
  if attrs[name] == nil then
    attrs[name] = value ~= "" and decode(clean(value)) or ""
  end
  return attrs
end

-- read() returns the next chunk, or nil at the end of input.
-- progress() is optional. Its result is the line count in a memory error.
-- Returns a function that returns the next token.
function M.new(read, progress)
  local buf, pos, eof = "", 1, false
  -- Stream offset of buf: byte i of buf is byte base + i of the input.
  local base = 0
  -- Stream offset of the last byte of a run with no ">". A later search
  -- for ">" starts after it, so many "<" with no ">" stay linear.
  local nogt
  -- Terminator of a skipped comment or bogus tag.
  local skip_to
  -- Name of the open raw text element, and true when its content is text.
  local raw, rcdata
  -- Cleaned end of the current text run that may start an entity. It waits
  -- for the rest of the run, so the run gives decode(clean(run)).
  local pend = ""

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
      base = base + #buf
      buf = chunk
    else
      base = base + pos - 1
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

  -- Takes buf[pos..j] as a part of a text run. A cut UTF-8 sequence at the
  -- end stays in buf, so clean never sees half a character. A possible
  -- entity at the end of the cleaned text goes to pend. Returns the decoded
  -- rest.
  local function take(j)
    local cut = utf8_cut(buf, pos, j)
    local s = clean(sub(buf, pos, cut - 1))
    pos = cut
    if pend ~= "" then
      s = pend .. s
    end
    s, pend = split_tail(s)
    return decode(s)
  end

  -- Ends a text run with buf[pos..j]. Returns the decoded text with pend.
  local function finish(j)
    local s = clean(sub(buf, pos, j))
    pos = j + 1
    if pend ~= "" then
      s, pend = pend .. s, ""
    end
    return decode(s)
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

  -- Streams the content of a raw text element up to "</name" followed by
  -- whitespace, "/" or ">". Returns a text token for RCDATA content.
  local function raw_step()
    if pos > #buf then
      if not fill() then
        raw = nil
        if pend ~= "" then
          return "text", finish(#buf)
        end
      end
      return nil
    end
    local k = find(buf, "</", pos, true)
    if not k then
      -- Keep a last "<" and, for text, a cut UTF-8 sequence or entity.
      local keep = byte(buf, #buf) == 60 and #buf or #buf + 1
      local s = ""
      if rcdata then
        s = take(keep - 1)
      else
        pos = keep
      end
      if not fill() then
        if rcdata then
          s = s .. finish(#buf)
        end
        pos = #buf + 1
        raw = nil
      end
      if s ~= "" then
        return "text", s
      end
      return nil
    end
    if rcdata and (k > pos or pend ~= "") then
      return "text", finish(k - 1)
    end
    pos = k
    if not want(#raw + 3) then
      -- Too short for an end tag. The rest of the input is content.
      local s = sub(buf, pos)
      pos = #buf + 1
      raw = nil
      if rcdata then
        return "text", decode(clean(s))
      end
      return nil
    end
    local c = byte(buf, pos + 2 + #raw)
    if lower(sub(buf, pos + 2, pos + 1 + #raw)) == raw
        and (WS[c] or c == 47 or c == 62) then
      -- The main loop reads the end tag.
      raw = nil
      return nil
    end
    pos = pos + 2
    if rcdata then
      return "text", "</"
    end
    return nil
  end

  -- Ends a broken tag. In a broken quoted value (vs is its start), the tag
  -- ends at the first ">" in the value and keeps the attributes before it.
  -- Otherwise it ends at gt, the first ">" after "<", with no attributes.
  local function cut(attrs, vs, gt)
    if vs then
      local g = find(buf, ">", vs, true)
      if g and g - pos <= M.MAX_TAG then
        pos = g + 1
        return attrs, false
      end
    end
    pos = gt + 1
    return nil, false
  end

  -- Scans the attributes from i up to the ">" that ends the tag. gt is the
  -- first ">" after the "<" at pos. Sets pos after the tag. Returns attrs
  -- and the self-closing flag.
  -- A quoted value is broken when it does not close within MAX_TAG bytes of
  -- "<" or before the end of input, or when it holds a ">" and then "</"
  -- (as in <a href="x>text</a>).
  local function attributes(i, gt)
    local state = BEFORE_NAME
    local attrs, name, ns, vs, quote, bad
    while true do
      if i - pos > M.MAX_TAG then
        return cut(attrs, state == QUOTED and vs, gt)
      end
      if i > #buf then
        -- Only a quoted value can carry the scan past gt.
        tick()
        local old = pos
        if not fill() then
          return cut(attrs, state == QUOTED and vs, gt)
        end
        local d = old - 1
        i, gt = i - d, gt - d
        if ns then
          ns = ns - d
        end
        if vs then
          vs = vs - d
        end
      end
      local b = byte(buf, i)
      if state == QUOTED then
        local k = find(buf, quote, i, true)
        if not k then
          i = #buf + 1
        elseif k - pos > M.MAX_TAG then
          -- The same result as a scan that never sees this quote.
          return cut(attrs, vs, gt)
        else
          if k > gt then
            -- The value may hold ">" and then "</".
            -- Search only inside the tag, from the value start up to k.
            local seg = sub(buf, vs, k - 1)
            local g = find(seg, ">", 1, true)
            if g and find(seg, "</", g, true) then
              return cut(attrs, vs, gt)
            end
          end
          if not bad then
            attrs = add(attrs, name, sub(buf, vs, k - 1))
          end
          state, vs, i = BEFORE_NAME, nil, k + 1
        end
      elseif state == BEFORE_NAME then
        if b == 62 then
          break
        elseif b == 47 then
          state = SLASH
        elseif not WS[b] then
          state, ns = NAME, i
          bad = b == 61 or b == 34 or b == 39 or b == 60
        end
        i = i + 1
      elseif state == NAME then
        if WS[b] or b == 61 or b == 62 or b == 47 then
          name, ns = sub(buf, ns, i - 1), nil
          if b == 61 then
            state = BEFORE_VALUE
          elseif WS[b] then
            state = AFTER_NAME
          else
            if not bad then
              attrs = add(attrs, name, "")
            end
            if b == 62 then
              break
            end
            state = SLASH
          end
        elseif b == 34 or b == 39 or b == 60 then
          bad = true
        end
        i = i + 1
      elseif state == AFTER_NAME then
        if b == 61 then
          state = BEFORE_VALUE
        elseif not WS[b] then
          if not bad then
            attrs = add(attrs, name, "")
          end
          if b == 62 then
            break
          elseif b == 47 then
            state = SLASH
          else
            state, ns = NAME, i
            bad = b == 34 or b == 39 or b == 60
          end
        end
        i = i + 1
      elseif state == BEFORE_VALUE then
        if b == 34 or b == 39 then
          state, quote, vs = QUOTED, b == 34 and '"' or "'", i + 1
        elseif b == 62 then
          if not bad then
            attrs = add(attrs, name, "")
          end
          break
        elseif not WS[b] then
          state, vs = UNQUOTED, i
        end
        i = i + 1
      elseif state == UNQUOTED then
        if WS[b] or b == 62 then
          if not bad then
            attrs = add(attrs, name, sub(buf, vs, i - 1))
          end
          if b == 62 then
            break
          end
          state, vs = BEFORE_NAME, nil
        end
        i = i + 1
      else -- SLASH
        if b == 62 then
          pos = i + 1
          return attrs, true
        end
        -- Read the byte again as the start of a name.
        state = BEFORE_NAME
      end
    end
    pos = i + 1
    return attrs, false
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
      want(9)
      if sub(buf, pos, pos + 3) == "<!--" then
        local c1, c2 = byte(buf, pos + 4, pos + 5)
        if c1 == 62 then -- "<!-->"
          pos = pos + 5
        elseif c1 == 45 and c2 == 62 then -- "<!--->"
          pos = pos + 6
        else
          skip_to, pos = "-->", pos + 4
        end
      elseif sub(buf, pos + 2, pos + 8) == "[CDATA[" then
        skip_to, pos = "]]>", pos + 9
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
        -- "</>" is dropped. "</ x>" is a bogus comment.
        skip_to, pos = ">", pos + 2
        return nil
      end
      pos = pos + 1
      return "text", "<"
    end
    local from = pos + rel
    if nogt and nogt - base >= from then
      from = nogt - base + 1
    end
    local gt = find(buf, ">", from, true)
    while not gt do
      nogt = base + #buf
      if #buf - pos + 1 > M.MAX_TAG then
        pos = pos + 1
        return "text", "<"
      end
      tick()
      if not fill() then
        pos = pos + 1
        return "text", "<"
      end
      gt = find(buf, ">", nogt - base + 1, true)
    end
    if gt - pos > M.MAX_TAG then
      pos = pos + 1
      return "text", "<"
    end
    local start = pos + rel
    local _, e = find(buf, "^[^%s/>]+", start)
    local name = lower(sub(buf, start, e))
    if closing then
      pos = gt + 1
      return "end", name
    end
    local attrs, self_closing
    local nb = byte(buf, e + 1)
    if nb == 62 then
      pos, self_closing = e + 2, false
    elseif nb == 47 and byte(buf, e + 2) == 62 then
      pos, self_closing = e + 3, true
    else
      attrs, self_closing = attributes(e + 1, gt)
    end
    local r = RAW[name]
    if r ~= nil then
      raw, rcdata = name, r
    end
    return "start", name, attrs, self_closing
  end

  return function()
    while true do
      tick()
      if skip_to then
        skip()
      elseif raw then
        local kind, s = raw_step()
        if kind then
          return kind, s
        end
      else
        if pos > #buf and not fill() then
          if pend ~= "" then
            return "text", finish(#buf)
          end
          return nil
        end
        local lt = find(buf, "<", pos, true)
        if not lt then
          if eof then
            return "text", finish(#buf)
          end
          -- A UTF-8 sequence or entity cut by the chunk end waits for the
          -- next chunk.
          local s = take(#buf)
          fill()
          if s ~= "" then
            return "text", s
          end
        elseif lt > pos or pend ~= "" then
          return "text", finish(lt - 1)
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
