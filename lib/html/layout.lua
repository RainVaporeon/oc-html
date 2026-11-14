-- Turns tokens into wrapped lines. There is no DOM tree, only a bounded
-- stack of open elements.
-- A line is one string. A non-empty line starts with a style byte (see
-- M.NORMAL and the others). A style lasts until the next style byte. Style
-- bytes never count toward the width. An empty line is "".

local guard = require("html.guard")
local unicode = require("unicode")

local M = {}

local byte, find, sub, rep, gsub = string.byte, string.find, string.sub,
  string.rep, string.gsub
local concat = table.concat
local tick = guard.tick

M.NORMAL = "\1"
M.HEADING = "\2"
M.EMPHASIS = "\3"
M.LINK = "\4"
M.PRE = "\5"

-- Open elements above this depth are not kept (see push_open).
M.MAX_DEPTH = 256

-- The title buffer takes at most this many bytes of raw text.
local TITLE_BUF = 1024
-- The first title text is kept up to this many bytes.
local TITLE_MAX = 256

local function set(...)
  local s = {}
  for _, k in ipairs({ ... }) do
    s[k] = true
  end
  return s
end

-- Dropped with all content. The text of title goes to title().
local DROP = set("script", "style", "template", "svg", "math", "iframe",
  "object", "noscript", "head", "title")

local BLOCK = set("p", "div", "section", "article", "main", "header",
  "footer", "nav", "aside", "blockquote", "table", "tr", "td", "th", "ul",
  "ol", "dl", "dt", "dd", "form", "input", "button", "select", "option",
  "textarea", "pre", "li")

local HEADING = set("h1", "h2", "h3", "h4", "h5", "h6")

local EMPHASIS = set("b", "strong", "i", "em", "u", "mark")

-- Elements without content. They never go on the stack.
local VOID = set("area", "base", "br", "col", "embed", "hr", "img", "input",
  "keygen", "link", "meta", "param", "source", "track", "wbr")

-- A start tag of one of these closes an open p (the HTML standard list).
local CLOSES_P = set("address", "article", "aside", "blockquote", "center",
  "details", "dialog", "dir", "div", "dl", "dd", "dt", "fieldset",
  "figcaption", "figure", "footer", "form", "header", "hgroup", "hr", "li",
  "listing", "main", "menu", "nav", "ol", "p", "plaintext", "pre", "search",
  "section", "summary", "table", "ul", "xmp", "h1", "h2", "h3", "h4", "h5",
  "h6")

-- Implied ends: a start tag closes an open element of the listed names. The
-- search stops at an element in stops.
local P_SET = set("p")
local P_STOPS = {}
for k in pairs(BLOCK) do
  P_STOPS[k] = true
end
for k in pairs(HEADING) do
  P_STOPS[k] = true
end
local IMPLIED = {
  li = { set("li"), set("ul", "ol", "menu") },
  dt = { set("dt", "dd"), set("dl") },
  dd = { set("dt", "dd"), set("dl") },
  tr = { set("tr", "td", "th"), set("table") },
  td = { set("td", "th"), set("tr", "table") },
  th = { set("td", "th"), set("tr", "table") },
  option = { set("option"), set("select") },
}

local SPACE = "[ \t\n]"
local NOT_SPACE = "[^ \t\n]"
local NON_ASCII = "[\128-\255]"
local PRE_BREAK = "[\t\n]"

-- Returns a layout object for lines of at most width columns:
--   push(kind, value, attrs, self_closing)   one token from the tokenizer
--   count()                                  number of finished lines
--   finish()                                 ends the input, returns lines
--   title()                                  the document title, or nil
-- lines holds the finished lines while push runs.
function M.new(width)
  if width < 1 then
    width = 1
  end
  local lines, n = {}, 0
  -- Pieces of the current line, its width and the style of its last piece.
  local parts, np, cur_w = {}, 0, 0
  local lstyle = M.NORMAL
  -- Pieces of a word that is not placed yet, with their styles and widths.
  -- A word can span text tokens and inline tags.
  local word, wst, wwd, nw, ww = {}, {}, {}, 0, 0
  -- True when white space came after the last placed word.
  local space = false
  -- True when the pending word continues a word that was placed early
  -- because it was wider than the width.
  local cont = false
  -- True when the current line has a word. A prefix such as "- " is not a
  -- word, so white space after it is not kept.
  local has_word = false
  -- The open elements: name, style inside, pre flag inside, and the style
  -- the element sets itself (false when it takes the style of its parent).
  local sname, sstyle, spre, sown, sd = {}, {}, {}, {}, 0
  local style, in_pre = M.NORMAL, false
  -- Stack index of the outermost dropped element, or 0.
  local drop_at = 0
  -- Stack index of the open title element, or 0, and its text.
  local title_at, title_buf, title_len, title_text = 0, {}, 0, nil
  local title_bytes = 0
  -- True right after a pre start tag: one newline there is skipped.
  local pre_first = false
  local hr_line

  local function emit(line)
    n = n + 1
    lines[n] = line
    tick(n)
  end

  local function end_line()
    if np > 0 then
      emit(concat(parts, "", 1, np))
    else
      emit("")
    end
    np, cur_w = 0, 0
    has_word = false
  end

  -- Adds s (not empty) of w columns in style st to the current line.
  local function place(s, st, w)
    if np == 0 then
      parts[1], parts[2] = st, s
      np, lstyle = 2, st
    else
      if st ~= lstyle then
        np = np + 1
        parts[np] = st
        lstyle = st
      end
      np = np + 1
      parts[np] = s
    end
    cur_w = cur_w + w
  end

  -- Places s (not empty) at character boundaries. It fills the current line
  -- and goes on in new lines. A wide character never straddles the width.
  local function split(s, st)
    local len = #s
    if not find(s, NON_ASCII) then
      local i = 1
      while i <= len do
        local room = width - cur_w
        if room <= 0 then
          end_line()
          room = width
        end
        local j = i + room - 1
        if j > len then
          j = len
        end
        place(sub(s, i, j), st, j - i + 1)
        i = j + 1
      end
      return
    end
    local wlen = unicode.wlen
    local i, from, w = 1, 1, 0
    while i <= len do
      local b = byte(s, i)
      local size = b < 0x80 and 1 or b >= 0xF0 and 4 or b >= 0xE0 and 3
        or 2
      local cw = b < 0x80 and 1 or wlen(sub(s, i, i + size - 1))
      if cur_w + w + cw > width and cur_w + w > 0 then
        if i > from then
          place(sub(s, from, i - 1), st, w)
        end
        end_line()
        from, w = i, 0
      end
      w = w + cw
      i = i + size
    end
    if from <= len then
      place(sub(s, from), st, w)
    end
  end

  -- Places the pending word, with one space before it when white space
  -- came before it. With partial, the word goes on in later pieces.
  local function commit(partial)
    if nw == 0 then
      cont = cont and partial or false
      return
    end
    local gap = (space and has_word and not cont) and 1 or 0
    space = false
    if cur_w + gap + ww > width and has_word and not cont then
      end_line()
      gap = 0
    end
    if cur_w + gap + ww <= width then
      if gap == 1 then
        place(" ", lstyle, 1)
      end
      for i = 1, nw do
        place(word[i], wst[i], wwd[i])
      end
    else
      for i = 1, nw do
        if cur_w + wwd[i] <= width then
          place(word[i], wst[i], wwd[i])
        else
          split(word[i], wst[i])
        end
      end
    end
    nw, ww = 0, 0
    has_word = true
    cont = partial or false
  end

  local function add_piece(s, ascii)
    local w = ascii and #s or unicode.wlen(s)
    nw = nw + 1
    word[nw], wst[nw], wwd[nw] = s, style, w
    ww = ww + w
    -- A word wider than the width is split now, so it stays small.
    if ww > width then
      commit(true)
    end
  end

  -- Text outside pre: white space collapses, words wrap.
  local function add_text(s)
    local ascii = not find(s, NON_ASCII)
    local i, len = 1, #s
    while i <= len do
      local ws = find(s, SPACE, i)
      if not ws then
        add_piece(i == 1 and s or sub(s, i), ascii)
        return
      end
      if ws > i then
        add_piece(sub(s, i, ws - 1), ascii)
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

  -- Text inside pre: spaces and newlines stay, a tab goes to the next
  -- 8-column stop, long lines wrap hard at the width.
  local function pre_text(s)
    if pre_first then
      pre_first = false
      if byte(s, 1) == 10 then
        s = sub(s, 2)
      end
    end
    local i, len = 1, #s
    while i <= len do
      local j = find(s, PRE_BREAK, i)
      local stop = j and j - 1 or len
      if stop >= i then
        split(sub(s, i, stop), style)
      end
      if not j then
        return
      end
      if byte(s, j) == 10 then
        end_line()
      else
        if cur_w >= width then
          end_line()
        end
        local sp = 8 - cur_w % 8
        if cur_w + sp > width then
          sp = width - cur_w
        end
        place(rep(" ", sp), style, sp)
      end
      i = j + 1
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

  -- Adds text to the title buffer. Stops at TITLE_BUF bytes and cuts the
  -- piece that crosses the limit at a character boundary. Leading white
  -- space is dropped and does not count toward the limit.
  local function add_title(value)
    if title_at == 0 or title_bytes >= TITLE_BUF then
      return
    end
    -- Small chunks give many small pieces. Join them to keep the list short.
    if title_len >= 64 then
      title_buf[1] = concat(title_buf, "", 1, title_len)
      for k = 2, title_len do
        title_buf[k] = nil
      end
      title_len = 1
    end
    if title_bytes == 0 then
      value = gsub(value, "^[ \t\n\r\f]+", "")
      if value == "" then
        return
      end
    end
    local room = TITLE_BUF - title_bytes
    if #value > room then
      local cut = room
      while cut > 0 do
        local b = byte(value, cut + 1)
        if b < 0x80 or b >= 0xC0 then
          break
        end
        cut = cut - 1
      end
      value = sub(value, 1, cut)
    end
    title_bytes = title_bytes + #value
    title_len = title_len + 1
    title_buf[title_len] = value
  end

  local function end_title()
    local s = concat(title_buf, "", 1, title_len)
    s = gsub(gsub(s, "[ \t\n]+", " "), "^ ", "")
    s = gsub(s, " $", "")
    if #s > TITLE_MAX then
      local cut = TITLE_MAX
      -- Cut at a character boundary.
      while cut > 0 do
        local b = byte(s, cut + 1)
        if b < 0x80 or b >= 0xC0 then
          break
        end
        cut = cut - 1
      end
      s = sub(s, 1, cut)
    end
    if s ~= "" then
      title_text = s
    end
    title_buf, title_len, title_bytes = nil, 0, 0
  end

  -- Closes the innermost open element and applies its end rule.
  local function close_top()
    local name = sname[sd]
    sname[sd], sstyle[sd], spre[sd], sown[sd] = nil, nil, nil, nil
    sd = sd - 1
    if sd > 0 then
      style, in_pre = sstyle[sd], spre[sd]
    else
      style, in_pre = M.NORMAL, false
    end
    if title_at > sd then
      title_at = 0
      end_title()
    end
    if drop_at > 0 then
      if drop_at > sd then
        drop_at = 0
      end
      return
    end
    if HEADING[name] then
      block()
      blank()
    elseif BLOCK[name] then
      block()
    end
  end

  -- Closes open elements down to and including index i.
  local function close_to(i)
    while sd >= i do
      close_top()
    end
  end

  -- Closes the innermost open element named in names, unless an element
  -- in stops comes first.
  local function close_open(names, stops)
    for i = sd, 1, -1 do
      local name = sname[i]
      if names[name] then
        close_to(i)
        return
      elseif stops[name] then
        return
      end
    end
  end

  -- Opens an element. At the depth bound, the new element is not kept:
  -- its start rule still applies, but its style, pre and drop rules do not.
  -- A dropped element is the exception outside a dropped part: it closes
  -- the innermost element to make room, so its content stays hidden.
  local function push_open(name, st, pre, own)
    if sd >= M.MAX_DEPTH then
      if drop_at > 0 or not DROP[name] then
        return false
      end
      close_top()
    end
    sd = sd + 1
    sname[sd], sstyle[sd], spre[sd], sown[sd] = name, st, pre, own or false
    style, in_pre = st, pre
    return true
  end

  -- Removes the inline element at index i (below the top) from the stack.
  -- The elements above it stay open and take their styles again from their
  -- new parents, as browsers do for a misnested inline end tag.
  local function remove_at(i)
    for k = i, sd - 1 do
      sname[k], sown[k] = sname[k + 1], sown[k + 1]
    end
    sname[sd], sstyle[sd], spre[sd], sown[sd] = nil, nil, nil, nil
    sd = sd - 1
    for k = i, sd do
      local pst, ppre = M.NORMAL, false
      if k > 1 then
        pst, ppre = sstyle[k - 1], spre[k - 1]
      end
      sstyle[k] = sown[k] or pst
      spre[k] = ppre or sname[k] == "pre"
    end
    style, in_pre = sstyle[sd], spre[sd]
  end

  local function start_tag(name, attrs, self_closing)
    pre_first = false
    local void = VOID[name] or self_closing
    if name == "body" then
      -- An unclosed head ends at body.
      for i = sd, 1, -1 do
        if sname[i] == "head" then
          close_to(i)
          break
        end
      end
    end
    if drop_at > 0 then
      -- A title in head is the document title. A title in svg is not.
      if not void and push_open(name, style, in_pre) and name == "title"
          and sname[drop_at] == "head" and title_buf and title_at == 0 then
        title_at = sd
      end
      return
    end
    if CLOSES_P[name] then
      close_open(P_SET, P_STOPS)
    end
    local imp = IMPLIED[name]
    if imp then
      close_open(imp[1], imp[2])
    end
    if DROP[name] then
      if not void and push_open(name, style, in_pre) then
        drop_at = sd
        if name == "title" and title_buf then
          title_at = sd
        end
      end
      return
    end
    local own, pre = false, in_pre
    if HEADING[name] then
      block()
      blank()
      own = M.HEADING
    elseif EMPHASIS[name] then
      own = M.EMPHASIS
    elseif name == "a" then
      if attrs and attrs.href then
        own = M.LINK
      end
    elseif name == "br" then
      commit()
      space = false
      end_line()
    elseif name == "hr" then
      block()
      hr_line = hr_line or M.NORMAL .. rep("─", width)
      emit(hr_line)
    elseif name == "img" then
      local alt = attrs and attrs.alt
      if alt then
        alt = gsub(gsub(gsub(alt, "[ \t\n]+", " "), "^ ", ""), " $", "")
      end
      local s = (alt and alt ~= "") and "[img: " .. alt .. "]" or "[img]"
      if in_pre then
        pre_text(s)
      else
        add_text(s)
      end
    elseif name == "li" then
      block()
      if width > 2 then
        place("- ", style, 2)
      end
    elseif name == "pre" then
      block()
      own, pre = M.PRE, true
    elseif BLOCK[name] then
      block()
    end
    if not void then
      push_open(name, own or style, pre, own)
      if name == "pre" then
        pre_first = true
      end
    end
  end

  -- An end tag closes the innermost open element of its name. An inline
  -- element closes alone, so the elements open inside it stay open. A block,
  -- heading or dropped element, and any element around a dropped part,
  -- closes the elements inside it too.
  local function end_tag(name)
    pre_first = false
    for i = sd, 1, -1 do
      if sname[i] == name then
        if i < sd and drop_at == 0 and not (BLOCK[name] or HEADING[name]
            or DROP[name]) then
          remove_at(i)
        else
          close_to(i)
        end
        return
      end
    end
  end

  local self = { lines = lines }

  function self.push(kind, value, attrs, self_closing)
    if kind == "text" then
      if value == "" then
        return
      end
      if drop_at > 0 then
        add_title(value)
      elseif in_pre then
        pre_text(value)
      else
        add_text(value)
      end
      tick(n)
    elseif kind == "start" then
      start_tag(value, attrs, self_closing)
    elseif kind == "end" then
      end_tag(value)
    end
  end

  function self.count()
    return n
  end

  function self.title()
    return title_text
  end

  function self.finish()
    close_to(1)
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
