-- Tests for lib/html/layout.lua against spec/layout.md and the line format
-- in spec/pipeline.md. Each row is an HTML string that goes through the
-- tokenizer and the layout, at several chunk sizes. A row comment names
-- the spec rule when the table header does not.

local t = require("test")
local layout = require("html.layout")
local tokenizer = require("html.tokenizer")
local unicode = require("unicode")

local T = {}

local WHOLE = 1 << 30
local SIZES = { 1, 7, WHOLE }

-- Style bytes (spec/pipeline.md "Line format").
local N, H, E, L, P = "\1", "\2", "\3", "\4", "\5"

local WIDTH = 40
local HR = N .. string.rep("\xE2\x94\x80", WIDTH)
local WIDE1, WIDE2, WIDE3 = "\xE4\xB8\xAD", "\xE6\x96\x87", "\xE5\xAD\x97"
local NBSP = "\xC2\xA0"

local function reader(s, size)
  local i = 1
  return function()
    if i > #s then
      return nil
    end
    local chunk = s:sub(i, i + size - 1)
    i = i + size
    return chunk
  end
end

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("a")
  f:close()
  return s
end

-- Renders html at width in chunks of size bytes. Returns the lines and the
-- layout.
local function render(html, width, size)
  local lay = layout.new(width)
  local next_token = tokenizer.new(reader(html, size or WHOLE), lay.count)
  while true do
    local kind, value, attrs, self_closing = next_token()
    if not kind then
      break
    end
    lay.push(kind, value, attrs, self_closing)
  end
  return lay.finish(), lay
end

-- A row input is an HTML string, or { html, width = n }.
local function input_of(input)
  if type(input) == "table" then
    return input[1], input.width
  end
  return input, WIDTH
end

local function styled(input, size)
  local html, width = input_of(input)
  return (render(html, width, size))
end

local function plain_lines(lines)
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = line:gsub("[\1-\5]", "")
  end
  return out
end

local function plain(input, size)
  return plain_lines(styled(input, size))
end

local function set(list)
  local s = {}
  for _, k in ipairs(list) do
    s[k] = true
  end
  return s
end

-- "Element handling": plain lines.
local LAYOUT_BLOCKS = {
  { "br gives one line break", "a<br>b", { "a", "b" } },
  { "two br give one empty line", "a<br><br>b", { "a", "", "b" } },
  { "br at the start gives no blank line", "<br>x", { "x" } },
  { "two br at the start give no blank line", "<br><br>x", { "x" } },
  { "br pair after text keeps the empty line", "x<br><br>y",
    { "x", "", "y" } },
  { "hr fills the width", { "a<hr>b", width = 5 },
    { "a", string.rep("\xE2\x94\x80", 5), "b" } },
  { "hr inside emphasis", { "<b>a<hr>b</b>", width = 3 },
    { "a", string.rep("\xE2\x94\x80", 3), "b" } },
  { "input breaks and has no content", "a<input>b", { "a", "b" } },
  { "no blank line at start or end", "<h2>T</h2>", { "T" } },
  { "img with alt", "a <img alt=x> b", { "a [img: x] b" } },
  { "img alt collapses and trims white space", "a <img alt=' a\n cat '> b",
    { "a [img: a cat] b" } },
  { "img without alt", "a <img>", { "a [img]" } },
  { "img with empty alt", "a <img alt=''>", { "a [img]" } },
  { "img with other attributes", "a <img src=x>", { "a [img]" } },
  -- "Lists"
  { "li prefix", "<ul><li>a</li><li> b </ul>", { "- a", "- b" } },
  { "nested lists have no indent",
    "<ul><li>a<ol><li>b</li></ol></li><li>c</li></ul>",
    { "- a", "- b", "- c" } },
}
for _, name in ipairs({ "p", "div", "section", "article", "main", "header",
    "footer", "nav", "aside", "blockquote", "dt", "dd", "table", "tr", "td",
    "th", "ul", "ol", "dl", "form", "button", "select", "option",
    "textarea" }) do
  LAYOUT_BLOCKS[#LAYOUT_BLOCKS + 1] = { "block break: " .. name,
    "a<" .. name .. ">b</" .. name .. ">c", { "a", "b", "c" } }
end
for k = 1, 6 do
  local h = "h" .. k
  LAYOUT_BLOCKS[#LAYOUT_BLOCKS + 1] = { "heading block: " .. h,
    "a<" .. h .. ">T</" .. h .. ">b", { "a", "", "T", "", "b" } }
end
t.cases(T, "layout_blocks", LAYOUT_BLOCKS, plain, { sizes = SIZES })

-- "Element handling" styles, "Styles nest", line format.
local LAYOUT_STYLE = {
  { "lines start with a style byte", "<p>a</p>", { N .. "a" } },
  { "heading style", "a<h1>T</h1>b", { N .. "a", "", H .. "T", "", N .. "b" } },
  { "link with href", "a <a href=/x>b</a> c", { N .. "a " .. L .. "b " .. N .. "c" } },
  { "link without href is plain", "a <a name=x>b</a> c", { N .. "a b c" } },
  { "code is inline text", "a <code>f()</code> b", { N .. "a f() b" } },
  { "unknown tags are inline", "a<foo>b</foo><span>c</span>d", { N .. "abcd" } },
  { "innermost style wins, outer returns",
    "<a href=x>a<b>b</b>c</a>d", { L .. "a" .. E .. "b" .. L .. "c" .. N .. "d" } },
  { "emphasis inside a heading", "<h2>a<em>b</em>c</h2>",
    { H .. "a" .. E .. "b" .. H .. "c" } },
  -- "Wrapping": a style continues on the next line.
  { "style continues after a wrap", { "a <b>bbb ccc ddd</b> e", width = 7 },
    { N .. "a " .. E .. "bbb", E .. "ccc ddd", N .. "e" } },
  { "style continues in a split word",
    { "<a href=x>abcdefghij</a>", width = 4 },
    { L .. "abcd", L .. "efgh", L .. "ij" } },
  -- "Width": style bytes never count.
  { "style bytes do not count toward width",
    { "a<b>b</b>c<i>d</i>e", width = 5 },
    { N .. "a" .. E .. "b" .. N .. "c" .. E .. "d" .. N .. "e" } },
  { "case file styles.html", read_file("tests/cases/styles.html"),
    { H .. "Top " .. E .. "mid " .. H .. "end", "",
      N .. "plain " .. E .. "bold " .. L .. "link " .. E .. "back " .. N
        .. "plain",
      P .. "a " .. E .. "b", P .. "c" } },
}
for _, name in ipairs({ "b", "strong", "i", "em", "u", "mark" }) do
  LAYOUT_STYLE[#LAYOUT_STYLE + 1] = { "emphasis: " .. name,
    "a <" .. name .. ">b</" .. name .. "> c",
    { N .. "a " .. E .. "b " .. N .. "c" } }
end
t.cases(T, "layout_style", LAYOUT_STYLE, styled, { sizes = SIZES })

-- "Width" and "Wrapping": plain lines.
local LAYOUT_WRAP = {
  { "wraps at word boundaries",
    { "aaa bbb ccc ddd eeeeeeeeee f", width = 10 },
    { "aaa bbb", "ccc ddd", "eeeeeeeeee", "f" } },
  { "word wider than the width is split", { "abcdefghij", width = 4 },
    { "abcd", "efgh", "ij" } },
  { "wide characters count two",
    { "ab " .. WIDE1 .. WIDE2 .. " x", width = 6 },
    { "ab", WIDE1 .. WIDE2 .. " x" } },
  { "wide word is split at the width",
    { WIDE1 .. WIDE2 .. WIDE3, width = 3 }, { WIDE1, WIDE2, WIDE3 } },
  { "wide character never straddles the width",
    { "abcd" .. WIDE1, width = 5 }, { "abcd", WIDE1 } },
  { "word with a style change wraps as one word",
    { "abc de<b>fg</b>", width = 6 }, { "abc", "defg" } },
  { "word over inline tags wraps as one word",
    { "abc d<span>e</span>f<b>g</b>", width = 6 }, { "abc", "defg" } },
  -- "Images"
  { "img alt wraps like text", { "<img alt='one two three'>", width = 10 },
    { "[img: one", "two three]" } },
  -- "Lists"
  { "wrapped li line has no prefix", { "<li>aaa bbb ccc", width = 8 },
    { "- aaa", "bbb ccc" } },
  -- "White space": U+00A0 is not a wrap point.
  { "nbsp is not a wrap point", { "ab&nbsp;cd", width = 4 },
    { "ab" .. NBSP .. "c", "d" } },
}
t.cases(T, "layout_wrap", LAYOUT_WRAP, plain, { sizes = SIZES })

-- "Preformatted text": lines with style bytes.
local LAYOUT_PRE = {
  { "pre keeps white space", "a<pre>\n  x  y\n\n z</pre>b",
    { N .. "a", P .. "  x  y", "", P .. " z", N .. "b" } },
  { "pre drops one newline after the start tag", "a<pre>\n\nx</pre>",
    { N .. "a", "", P .. "x" } },
  { "pre keeps a first newline after another tag", "a<pre><b></b>\nx</pre>",
    { N .. "a", "", P .. "x" } },
  { "pre tabs go to 8-column stops",
    "<pre>\tx\nab\tc\n1234567\t8\n12345678\t9</pre>",
    { P .. "        x", P .. "ab      c", P .. "1234567 8",
      P .. "12345678        9" } },
  { "pre tab stops at the line end", { "<pre>abcdefghi\tx</pre>", width = 10 },
    { P .. "abcdefghi ", P .. "x" } },
  { "no tab reaches a line", { "a\tb<pre>\tc\td</pre>e\t", width = 30 },
    { N .. "a b", P .. "        c       d", N .. "e" } },
  { "pre wraps hard at the width", { "<pre>ab cdef gh\nxy</pre>", width = 4 },
    { P .. "ab c", P .. "def ", P .. "gh", P .. "xy" } },
  { "pre wraps wide characters",
    { "<pre>a" .. WIDE1 .. WIDE2 .. WIDE3 .. "</pre>", width = 5 },
    { P .. "a" .. WIDE1 .. WIDE2, P .. WIDE3 } },
  { "br inside pre", "<pre>a<br>b</pre>", { P .. "a", P .. "b" } },
  { "emphasis inside pre keeps white space",
    "<pre>a  <b>b  b</b>  c</pre>", { P .. "a  " .. E .. "b  b" .. P .. "  c" } },
}
t.cases(T, "layout_pre", LAYOUT_PRE, styled, { sizes = SIZES })

-- "White space": lines with style bytes.
local LAYOUT_WS = {
  { "white space collapses", "  a \n\t b    c\n", { N .. "a b c" } },
  { "a word spans text tokens and inline tags", "hel<b>lo</b> wo<i>r</i>ld",
    { N .. "hel" .. E .. "lo " .. N .. "wo" .. E .. "r" .. N .. "ld" } },
  { "a block has no leading or trailing space",
    "<p>  a  </p><p> <b> b </b> </p>", { N .. "a", E .. "b" } },
  { "a space at a style change is kept once", "a <b> b </b> c",
    { N .. "a " .. E .. "b " .. N .. "c" } },
  { "nbsp does not collapse", "a&nbsp;&nbsp; b",
    { N .. "a" .. NBSP .. NBSP .. " b" } },
  { "nbsp at a block start is kept", "<p>&nbsp;a&nbsp;</p>",
    { N .. NBSP .. "a" .. NBSP } },
}
t.cases(T, "layout_ws", LAYOUT_WS, styled, { sizes = SIZES })

-- "The open-element stack": lines with style bytes.
local LAYOUT_STACK = {
  { "unclosed heading closes at the document end", "a<h1>T",
    { N .. "a", "", H .. "T" } },
  { "stray end tags are ignored", "</b></p>a</div> </a>b", { N .. "a b" } },
  { "stray end tag does not close an outer style", "<b>a</i>b</b>c",
    { E .. "ab" .. N .. "c" } },
  -- "Inline styles continue after a misnested inline end tag."
  { "misnested end tag keeps the inner style", "<i><b>a</i>b</b>c",
    { E .. "ab" .. N .. "c" } },
  { "misnested end tag keeps an inner link", "<b><a href=x>a</b>b</a>c",
    { L .. "ab" .. N .. "c" } },
  { "after a misnested end tag the inner element takes the outer style",
    "<a href=x><span>a</a>b</span>c", { L .. "a" .. N .. "bc" } },
  { "misnested end tag around a block", "<b>a<p>b</b>c</p>d",
    { E .. "a", E .. "b" .. N .. "c", N .. "d" } },
  -- "When a block or heading element closes, the inline elements still open
  -- inside it close with it."
  { "block end closes open inline elements", "<p>a <b>b</p>c",
    { N .. "a " .. E .. "b", N .. "c" } },
  { "heading end closes open inline elements", "<h1><b>a</h1>b",
    { E .. "a", "", N .. "b" } },
  -- Implied ends.
  { "li closes li", "<ul><li><b>a<li>b</ul>",
    { N .. "- " .. E .. "a", N .. "- b" } },
  { "li search stops at ul", "<li><b>a<ul><li>b",
    { N .. "- " .. E .. "a", E .. "- b" } },
  { "li search stops at ol", "<li><b>a<ol><li>b",
    { N .. "- " .. E .. "a", E .. "- b" } },
  { "li search stops at menu", "<li><b>a<menu><li>b",
    { N .. "- " .. E .. "a", E .. "- b" } },
  { "dd closes dt", "<dl><dt><b>a<dd>b</dl>", { E .. "a", N .. "b" } },
  { "dt closes dd", "<dl><dd><b>a<dt>b</dl>", { E .. "a", N .. "b" } },
  { "dd search stops at dl", "<dd><b>a<dl><dd>b", { E .. "a", E .. "b" } },
  { "tr closes td", "<table><tr><td><b>a<tr>b</table>", { E .. "a", N .. "b" } },
  { "tr closes tr", "<table><tr><b>a<tr>b</table>", { E .. "a", N .. "b" } },
  { "tr search stops at table", "<tr><b>a<table><tr>b", { E .. "a", E .. "b" } },
  { "td closes td", "<tr><td><b>a<td>b", { E .. "a", N .. "b" } },
  { "th closes td", "<tr><td><b>a<th>b", { E .. "a", N .. "b" } },
  { "td closes th", "<tr><th><b>a<td>b", { E .. "a", N .. "b" } },
  { "td search stops at table", "<td><b>a<table><td>b", { E .. "a", E .. "b" } },
  { "option closes option", "<select><option><b>a<option>b</select>",
    { E .. "a", N .. "b" } },
  { "option search stops at select", "<option><b>a<select><option>b",
    { E .. "a", E .. "b" } },
  { "body closes head", "<head>x<body>y", { N .. "y" } },
}
-- "The start tag of one of these elements closes an open p". A closed p
-- closes the b inside it, so "b" is normal.
for _, name in ipairs({ "address", "article", "aside", "blockquote",
    "center", "details", "dialog", "dir", "div", "dl", "dd", "dt", "fieldset",
    "figcaption", "figure", "footer", "form", "header", "hgroup", "hr", "li",
    "listing", "main", "menu", "nav", "ol", "p", "plaintext", "pre", "search",
    "section", "summary", "table", "ul", "xmp", "h1", "h2", "h3", "h4", "h5",
    "h6" }) do
  local expected = { E .. "a", N .. "b" }
  if name:match("^h%d$") then
    expected = { E .. "a", "", H .. "b" }
  elseif name == "li" then
    expected = { E .. "a", N .. "- b" }
  elseif name == "pre" then
    expected = { E .. "a", P .. "b" }
  elseif name == "hr" then
    expected = { E .. "a", HR, N .. "b" }
  end
  LAYOUT_STACK[#LAYOUT_STACK + 1] = { name .. " closes p",
    "<p><b>a<" .. name .. ">b", expected }
end
-- "No other start tag closes a p": the b stays open, so "b" is emphasis.
local INLINE = set({ "a", "span" })
for _, name in ipairs({ "tr", "td", "th", "input", "button", "select",
    "textarea", "option", "a", "span", "br" }) do
  local expected = INLINE[name] and { E .. "ab" } or { E .. "a", E .. "b" }
  LAYOUT_STACK[#LAYOUT_STACK + 1] = { name .. " does not close p",
    "<p><b>a<" .. name .. ">b", expected }
end
t.cases(T, "layout_stack", LAYOUT_STACK, styled, { sizes = SIZES })

-- Dropped elements ("Element handling"): plain lines.
local LAYOUT_DROP = {
  { "title text is not shown", "a <title>x</title>b", { "a b" } },
  { "dropped element ends when its parent closes", "<div><svg>x</div>b",
    { "b" } },
  { "dropped element ends when an inline parent closes", "<b><svg>x</b>y",
    { "y" } },
  { "nested same dropped element needs its own end tag",
    "<svg><svg>x</svg>y</svg>b", { "b" } },
  { "stray end tag of a dropped element is ignored", "</script>a<svg/>b",
    { "ab" } },
}
for _, name in ipairs({ "script", "style", "template", "svg", "math",
    "iframe", "object", "noscript", "head" }) do
  LAYOUT_DROP[#LAYOUT_DROP + 1] = { "dropped: " .. name,
    "a <" .. name .. ">x<p>y</p></" .. name .. ">b", { "a b" } }
end
t.cases(T, "layout_drop", LAYOUT_DROP, plain, { sizes = SIZES })

-- "Depth bound": the stack holds at most 256 open elements.
local rep = string.rep
local LAYOUT_DEPTH = {
  { "style at depth 256 applies", rep("<span>", 255) .. "<b>a</b>b",
    { E .. "a" .. N .. "b" } },
  { "style past depth 256 is lost",
    rep("<span>", 1000) .. "<b>a</b>b" .. rep("</span>", 1000) .. "c",
    { N .. "abc" } },
  { "dropped element past the bound still hides its content",
    rep("<div>", 256) .. "a<script>x</script>b", { N .. "a", N .. "b" } },
  { "deep nesting inside a dropped element is hidden",
    "<svg>" .. rep("<g>", 1000) .. "x</svg>b", { N .. "b" } },
}
t.cases(T, "layout_depth", LAYOUT_DEPTH, styled, { sizes = SIZES })

-- "Title".
local function title(input, size)
  local _, lay = render(input, WIDTH, size)
  return lay.title()
end

local TITLE = {
  { "title in head", "<head><title>  My \n page </title></head><body>x",
    "My page" },
  { "title in body", "<body><title>T</title>x", "T" },
  { "first title wins", "<title>One</title><title>Two</title>x", "One" },
  { "no title", "x", nil },
  { "empty title is no title", "<title>  </title>", nil },
  { "the first title is the title even when empty",
    "<title> </title><title>B</title>", nil },
  { "unclosed title ends at the end of input", "<title>T", "T" },
  { "svg title is not the document title", "<svg><title>icon</title></svg>",
    nil },
  { "title in another dropped element is not the document title",
    "<object><title>x</title></object>", nil },
  { "title keeps 256 bytes", "<title>" .. rep("a", 300) .. "</title>",
    rep("a", 256) },
  { "long title is cut at a character boundary",
    "<title>" .. rep(WIDE1, 200) .. "</title>", rep(WIDE1, 85) },
  { "title text past 1024 raw bytes is not read",
    "<title>a" .. rep(" ", 2000) .. "b</title>", "a" },
  { "leading white space does not count toward the raw limit",
    "<title>" .. rep(" ", 5000) .. "Real</title>", "Real",
    sizes = { 1, 7, 4096, WHOLE } },
  { "title from many small chunks", "<title>" .. rep("abcdefghij", 20)
    .. "</title>", rep("abcdefghij", 20) },
  { "case file elements.html", read_file("tests/cases/elements.html"),
    "Element table" },
  { "case file broken.html", read_file("tests/cases/broken.html"), "Broken" },
  { "case file title.html", read_file("tests/cases/title.html"),
    "Tom & Jerry" },
}
t.cases(T, "title", TITLE, title, { sizes = SIZES })

-- Line format (spec/pipeline.md) and width, over many widths: no line is
-- wider than the width, every non-empty line starts with a style byte, and
-- a style byte is never followed by another style byte or the line end.
function T.line_format_and_width_hold_for_many_widths()
  local words = {}
  for k = 1, 200 do
    words[k] = rep("w", k % 13 + 1)
  end
  local mix = {}
  local tags = { "b", "a", "i", "code", "span" }
  for k = 1, 120 do
    local tag = tags[k % #tags + 1]
    mix[#mix + 1] = "<" .. tag .. (tag == "a" and " href=x>" or ">")
      .. rep("w", k % 11 + 1) .. " " .. WIDE1 .. "</" .. tag .. ">"
      .. (k % 7 == 0 and " " or "")
  end
  -- { doc, smallest width }. A wide character needs 2 columns.
  local docs = {
    { table.concat(words, " "), 1 },
    { table.concat(mix), 2 },
    { "<b><i></i> </b>a <a href=x> </a><em>bcdefghijk</em><u> </u><li><b>x"
      .. "<h1><b></b>y<pre><b>\n</b>\t<i>zz</pre>", 1 },
  }
  for d, item in ipairs(docs) do
    local doc = item[1]
    for width = item[2], 25 do
      local where = "doc " .. d .. " width " .. width
      for _, line in ipairs(render(doc, width)) do
        local text = line:gsub("[\1-\5]", "")
        t.ok(unicode.wlen(text) <= width, where .. ": " .. line)
        t.ok(not line:find("[\1-\5][\1-\5]") and not line:find("[\1-\5]$"),
          where .. ": " .. line)
        t.ok(line == "" or line:find("^[\1-\5]"), where .. ": " .. line)
      end
    end
  end
end

-- Expected-output cases in tests/cases. The comparison removes "\r",
-- trailing spaces and tabs, and blank lines at the end.

local function normalize(s)
  local out = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line:gsub("\r", ""):gsub("[ \t]+$", "")
  end
  while #out > 0 and out[#out] == "" do
    out[#out] = nil
  end
  return table.concat(out, "\n")
end

local function escape(s)
  return (s:gsub("[^\32-\126]", function(c)
    if c:byte() >= 128 then
      return c
    end
    return string.format("\\x%02X", c:byte())
  end))
end

local function split_lines(s)
  local out = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  return out
end

-- Returns nil when equal, else a text with the first differing line.
local function line_diff(expected, actual)
  if expected == actual then
    return nil
  end
  local e, a = split_lines(expected), split_lines(actual)
  for i = 1, math.max(#e, #a) do
    if e[i] ~= a[i] then
      return string.format("first difference at line %d\n  expected: %s\n"
        .. "  actual:   %s", i, e[i] and escape(e[i]) or "(no line)",
        a[i] and escape(a[i]) or "(no line)")
    end
  end
end

function T.cases_match_expected_text()
  local failures = {}
  -- A case needs tests/cases/<name>.html and tests/cases/<name>.txt.
  for _, name in ipairs(t.list_cases()) do
    local f = io.open("tests/cases/" .. name .. ".txt", "rb")
    if not f then
      failures[#failures + 1] = "case " .. name .. ": missing tests/cases/"
        .. name .. ".txt"
    else
      local expected = f:read("a")
      f:close()
      local lines = render(read_file("tests/cases/" .. name .. ".html"),
        WIDTH)
      local diff = line_diff(normalize(expected),
        normalize(table.concat(plain_lines(lines), "\n")))
      if diff then
        failures[#failures + 1] = "case " .. name .. ": " .. diff
      end
    end
  end
  t.ok(#failures == 0, "\n" .. table.concat(failures, "\n"))
end

return T
