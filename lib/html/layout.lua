-- Turns tokens into wrapped lines. There is no DOM tree.
-- A line is one string. A non-empty line starts with a style byte (see
-- M.NORMAL and the others). A style lasts until the next style byte.
-- An empty line is "".

local guard = require("html.guard")
local unicode = require("unicode")

local M = {}

local byte, find, sub, rep = string.byte, string.find, string.sub,
  string.rep
local concat = table.concat

M.NORMAL = "\1"
M.HEADING = "\2"
M.EMPHASIS = "\3"
M.LINK = "\4"
M.PRE = "\5"

local function set(...)
  local s = {}
  for _, k in ipairs({ ... }) do
    s[k] = true
  end
  return s
end

-- Dropped with all content. head is here until title goes to the status
-- line.
local DROP = set("script", "style", "template", "svg", "math", "iframe",
  "object", "noscript", "head")

local BLOCK = set("p", "div", "section", "article", "main", "header",
  "footer", "nav", "aside", "blockquote", "pre", "li", "table", "tr", "td",
  "th", "ul", "ol", "dl", "form", "input", "button", "select", "textarea")

local HEADING = set("h1", "h2", "h3", "h4", "h5", "h6")

local SPACE = "[ \t\n]"
local NOT_SPACE = "[^ \t\n]"

-- Returns a layout object for lines of at most width columns:
--   push(kind, value, attrs, self_closing)   one token from the tokenizer
--   count()                                  number of finished lines
--   finish()                                 ends the input, returns lines
-- lines holds the finished lines while push runs.
function M.new(width)
  if width < 1 then
    width = 1
  end
  local lines, n = {}, 0
  -- Pieces of the current line.
  local parts, np, cur_w = {}, 0, 0
  local line_style = M.NORMAL
  -- Pieces of a word that is not placed yet. A word can span text tokens.
  local word, nw = {}, 0
  -- True when white space came after the last placed word.
  local space = false
  -- True when the current line has a word. A prefix such as "- " is not a
  -- word, so white space after it is not kept.
  local has_word = false
  local drop, dropping = {}, 0
  local style = M.NORMAL

  local function emit(line)
    n = n + 1
    lines[n] = line
    guard.tick(n)
  end

  local function end_line()
    if np > 0 then
      emit(line_style .. concat(parts, "", 1, np))
    else
      emit("")
    end
    np, cur_w = 0, 0
    has_word = false
  end

  local function place(s, w)
    if np == 0 then
      line_style = style
    end
    np = np + 1
    parts[np] = s
    cur_w = cur_w + w
  end

  -- Places a word wider than the line, split at characters.
  local function place_long(s)
    local i, len, from, w = 1, #s, 1, 0
    while i <= len do
      guard.tick(n)
      local b = byte(s, i)
      local size = b < 0x80 and 1 or b >= 0xF0 and 4 or b >= 0xE0 and 3 or 2
      local cw = unicode.wlen(sub(s, i, i + size - 1))
      if cur_w + w + cw > width and cur_w + w > 0 then
        if i > from then
          place(sub(s, from, i - 1), w)
        end
        end_line()
        from, w = i, 0
      end
      w = w + cw
      i = i + size
    end
    if from <= len then
      place(sub(s, from), w)
    end
  end

  local function commit()
    if nw == 0 then
      return
    end
    local s = nw == 1 and word[1] or concat(word, "", 1, nw)
    nw = 0
    local w = unicode.wlen(s)
    local gap = (space and has_word) and 1 or 0
    space = false
    if cur_w + gap + w <= width then
      if gap == 1 then
        place(" ", 1)
      end
      place(s, w)
    else
      if np > 0 then
        end_line()
      end
      if w <= width then
        place(s, w)
      else
        place_long(s)
      end
    end
    has_word = true
  end

  local function add_text(s)
    local i, len = 1, #s
    while i <= len do
      guard.tick(n)
      local ws = find(s, SPACE, i)
      if not ws then
        nw = nw + 1
        word[nw] = i == 1 and s or sub(s, i)
        return
      end
      if ws > i then
        nw = nw + 1
        word[nw] = sub(s, i, ws - 1)
      end
      commit()
      space = has_word
      local nxt = find(s, NOT_SPACE, ws + 1)
      if not nxt then
        return
      end
      i = nxt
    end
  end

  -- Ends the current line if it has content.
  local function block()
    commit()
    space = false
    if np > 0 then
      end_line()
    end
  end

  -- Adds one blank line, never two in a row and never at the start.
  local function blank()
    if n > 0 and lines[n] ~= "" then
      emit("")
    end
  end

  local function start_tag(name, self_closing)
    if DROP[name] then
      if not self_closing then
        drop[name] = (drop[name] or 0) + 1
        dropping = dropping + 1
      end
    elseif name == "body" then
      -- An unclosed head ends at body.
      dropping = dropping - (drop.head or 0)
      drop.head = 0
    elseif dropping > 0 then
      return
    elseif HEADING[name] then
      block()
      blank()
      style = M.HEADING
    elseif name == "br" then
      commit()
      space = false
      end_line()
    elseif name == "hr" then
      block()
      emit(M.NORMAL .. rep("─", width))
    elseif name == "li" then
      block()
      place("- ", 2)
    elseif BLOCK[name] then
      block()
    end
  end

  local function end_tag(name)
    if DROP[name] then
      local open = drop[name] or 0
      if open > 0 then
        drop[name] = open - 1
        dropping = dropping - 1
      end
    elseif dropping > 0 then
      return
    elseif HEADING[name] then
      block()
      style = M.NORMAL
      blank()
    elseif BLOCK[name] then
      block()
    end
  end

  local self = { lines = lines }

  function self.push(kind, value, _, self_closing)
    if kind == "text" then
      if dropping == 0 then
        add_text(value)
      end
    elseif kind == "start" then
      start_tag(value, self_closing)
    elseif kind == "end" then
      end_tag(value)
    end
  end

  function self.count()
    return n
  end

  function self.finish()
    block()
    while n > 0 and lines[n] == "" do
      lines[n] = nil
      n = n - 1
    end
    return lines
  end

  return self
end

return M
