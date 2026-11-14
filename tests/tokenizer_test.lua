-- Tests for lib/html/tokenizer.lua: spec/tokenizer.md rules at every chunk
-- size. Each row names its input and the tokens that spec rule gives.

local t = require("test")
local tokenizer = require("html.tokenizer")

local T = {}

-- spec/tokenizer.md "Broken markup". The tests use the spec value, not the
-- module field.
local MAX_TAG = 16384

local WHOLE = 1 << 30
local SIZES = { 1, 2, 3, 7, 4096, WHOLE }
local SIZES_1_TO_16 = { WHOLE }
for size = 1, 16 do
  SIZES_1_TO_16[#SIZES_1_TO_16 + 1] = size
end

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

-- "[name=value,...]" in name order, or "" when the tag has no attributes.
local function attr_string(attrs)
  local names = {}
  for name in pairs(attrs or {}) do
    names[#names + 1] = name
  end
  if #names == 0 then
    return ""
  end
  table.sort(names)
  local parts = {}
  for k, name in ipairs(names) do
    parts[k] = name .. "=" .. attrs[name]
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

-- Returns the tokens as strings. Adjacent text tokens are joined, because
-- chunk edges may split text. limit stops a run that does not end.
local function tokens(s, size, limit)
  local next_token = tokenizer.new(reader(s, size))
  local out, text = {}, nil
  local count = 0
  while true do
    count = count + 1
    if limit and count > limit then
      error("no end after " .. limit .. " tokens")
    end
    local kind, value, attrs, self_closing = next_token()
    if kind == "text" then
      text = (text or "") .. value
    else
      if text and text ~= "" then
        out[#out + 1] = "text:" .. text
      end
      text = nil
      if not kind then
        return out
      end
      local item = kind .. ":" .. value .. attr_string(attrs)
      if self_closing then
        item = item .. "/"
      end
      out[#out + 1] = item
    end
  end
end

local B = string.rep("b", MAX_TAG + 16)
local Z = string.rep("z", MAX_TAG + 16)

local TOKENS = {
  -- "Tokens"
  { "tags and text", "<p>Hello <b>World</b></p>",
    { "start:p", "text:Hello ", "start:b", "text:World", "end:b", "end:p" } },
  { "names are lowercase", "<DIV>x</Div>",
    { "start:div", "text:x", "end:div" } },
  { "self-closing flag", "a<br/>b<br />c<br><img src=x />",
    { "text:a", "start:br/", "text:b", "start:br/", "text:c", "start:br",
      "start:img[src=x]/" } },
  { "slash in unquoted value", "<a href=/x/>y",
    { "start:a[href=/x/]", "text:y" } },
  { "no attributes", "<p>", { "start:p" } },
  { "no attributes, space", "<p >", { "start:p" } },
  { "no attributes, newline", "<p\n>", { "start:p" } },
  { "no attributes, self-closing", "<p/>", { "start:p/" } },
  { "no attributes, space self-closing", "<p />", { "start:p/" } },
  { "text is cleaned and decoded", "a&amp;b\r\n&lt;\1", { "text:a&b\n<" } },
  { "chunk edges do not change tokens",
    '<!DOCTYPE html><html><head><title>T &amp; U</title></head>'
      .. '<body><h1 class="big">Caf\xC3\xA9 &amp; \xE4\xB8\xAD\xE6\x96\x87'
      .. '</h1><!-- c --><p>A&nbsp;b &#x263A; &mdash;<br/>end</p>'
      .. "<a href='/x?a=1&amp;b=2' title=\"a>b\">l</a><![CDATA[x]]>"
      .. '<script>if (a</b) {}</script><p>tail &copy</p></body></html>',
    { "start:html", "start:head", "start:title", "text:T & U", "end:title",
      "end:head", "start:body", "start:h1[class=big]",
      "text:Caf\xC3\xA9 & \xE4\xB8\xAD\xE6\x96\x87", "end:h1", "start:p",
      "text:A\xC2\xA0b \xE2\x98\xBA \xE2\x80\x94", "start:br/", "text:end",
      "end:p", "start:a[href=/x?a=1&b=2,title=a>b]", "text:l", "end:a",
      "start:script", "end:script", "start:p", "text:tail \xC2\xA9", "end:p",
      "end:body", "end:html" },
    sizes = { 1, 2, 3, 4, 5, 6, 7, 8, WHOLE } },

  -- "Skipped markup"
  { "comment", "a<!-- <p>no</p> -- x -->b", { "text:ab" } },
  { "comment short forms", "a<!-->b<!--->c<!---->d<!-- x --->e",
    { "text:abcde" } },
  { "unclosed comment", "a<!-- b <p>c</p>", { "text:a" } },
  { "unclosed comment, opener only", "a<!--", { "text:a" } },
  { "unclosed bogus comment, <!-", "a<!-", { "text:a" } },
  { "unclosed bogus comment, <?", "a<?xml", { "text:a" } },
  { "unclosed bogus comment, </ space", "a</ foo", { "text:a" } },
  { "doctype", '<!DOCTYPE html PUBLIC "-//W3C//DTD">a', { "text:a" } },
  { "bogus comments", "a<! x >b<?xml y?>c<!>d", { "text:abcd" } },
  { "bogus end tags", "a</ foo>b</3>c", { "text:abc" } },
  { "empty end tag", "a</>b", { "text:ab" } },
  { "cdata", "a<![CDATA[<b>&amp;</b>]]>c", { "text:ac" } },
  { "cdata with ]]", "<![CDATA[a]]b]>]]>c", { "text:c" } },
  { "cdata with bytes clean removes", "<![CDATA[\xC3\xA9\1]]>", {} },
  { "cdata at every chunk size", "<![CDATA[a\xE2\x80\x8Bb&copy\x04c]]>d",
    { "text:d" }, sizes = SIZES_1_TO_16 },
  { "unclosed cdata", "a<![CDATA[x<y]", { "text:a" } },
  { "unclosed cdata only", "<![CDATA[x<y]", {} },
  { "unclosed cdata, cut UTF-8", "<![CDATA[\xE4\xB8\xAD\xE2\x80", {},
    sizes = SIZES_1_TO_16 },

  -- "Broken markup"
  { "< before non-letter", "a < b <3 c<", { "text:a < b <3 c<" } },
  { "< before zero byte", "<\0>", { "text:<>" } },
  { "unclosed start tag at end", "x<a href", { "text:x<a href" } },
  { "unclosed end tag at end", "x</a", { "text:x</a" } },
  { "</ at end", "a</", { "text:a</" } },
  { "two unclosed tags at end", "x<a <b", { "text:x<a <b" } },
  { "unclosed quoted value at end", '<a href="xy', { 'text:<a href="xy' } },
  { "unclosed tags under MAX_TAG", string.rep("<a ", 2000),
    { "text:" .. string.rep("<a ", 2000) } },
  { "unclosed tags past MAX_TAG", string.rep("<a ", 6000),
    { "text:" .. string.rep("<a ", 6000) } },
  { "> past MAX_TAG", "<a " .. B .. ">c", { "text:<a " .. B .. ">c" } },
  { "> within MAX_TAG", "<a " .. string.rep("b", 16000) .. ">c",
    { "start:a[" .. string.rep("b", 16000) .. "=]", "text:c" } },

  -- "Attributes"
  { "value forms", [[<a href="x y" title='t' id=z hidden>]],
    { "start:a[hidden=,href=x y,id=z,title=t]" } },
  { "spaces around =", [[<a x = "v" y= w z =u>]], { "start:a[x=v,y=w,z=u]" } },
  { "empty values", [[<a x="" y=>b<c z=''>]],
    { "start:a[x=,y=]", "text:b", "start:c[z=]" } },
  { "> in quoted value", [[<a title="a>b" x='>'>c]],
    { "start:a[title=a>b,x=>]", "text:c" } },
  { "closing quote 100 bytes away",
    '<a t="' .. string.rep("z", 100) .. '>">w',
    { "start:a[t=" .. string.rep("z", 100) .. ">]", "text:w" } },
  { "duplicate keeps first", "<a x=1 X=2 x='3'>", { "start:a[x=1]" } },
  { "names are lowercase", "<A HREF=x Data-Id=y>",
    { "start:a[data-id=y,href=x]" } },
  { "values are cleaned and decoded", '<a t="&amp;&lt;\1\r&#x263A;" u=a&amp;b>',
    { "start:a[t=&<\xE2\x98\xBA,u=a&b]" } },
  { "broken names dropped", [[<a "q"=1 =e x<y=2 ok=3 'z>]],
    { "start:a[ok=3]" } },
  { "end tag attributes ignored", "</a x y=1>b", { "end:a", "text:b" } },
  { "end tag ends at first >", [[</a x=">" y>b]],
    { "end:a", 'text:" y>b' } },

  -- "Broken quoted value"
  { "unclosed quote ends at first >", [[<a id=k href="x>y]],
    { "start:a[id=k]", "text:y" } },
  { "quoted value with > then </",
    [[<a id=k href="no-close>broken</a> <b x="y>z">w</b>]],
    { "start:a[id=k]", "text:broken", "end:a", "text: ", "start:b[x=y>z]",
      "text:w", "end:b" } },
  { "quote not closed within MAX_TAG", '<a t="x>y' .. Z,
    { "start:a", "text:y" .. Z } },
  { "quote closed past MAX_TAG", '<a t=">' .. Z .. '">w',
    { "start:a", "text:" .. Z .. '">w' } },
  { "first > of broken value past MAX_TAG", '<a x=">" t="' .. Z .. ">w",
    { "start:a", 'text:" t="' .. Z .. ">w" } },

  -- "Raw text and RCDATA"
  { "script content skipped", "<script>if (a<b) x('</p>');</SCRIPT >y",
    { "start:script", "end:script", "text:y" } },
  { "raw end needs space, newline or >",
    "<style>a</styles>b</style-x>c</style\n>d",
    { "start:style", "end:style", "text:d" } },
  { "raw end with /", "<script>a</script/>b",
    { "start:script", "end:script", "text:b" } },
  -- Regression: an unclosed script at the end of input looped forever.
  { "unclosed script", "a<script>x < y", { "text:a", "start:script" } },
  { "unclosed script, cut end tag", "a<script>x</scr",
    { "text:a", "start:script" } },
  { "title content is text", "<title>a<b>&amp;</p></title>c",
    { "start:title", "text:a<b>&</p>", "end:title", "text:c" } },
  { "textarea content is text",
    "<TEXTAREA x=1>\xC3\xA9 <!-- n --></TextArea >",
    { "start:textarea[x=1]", "text:\xC3\xA9 <!-- n -->", "end:textarea" } },
  { "unclosed title", "<title>a<b", { "start:title", "text:a<b" } },
  { "unclosed title, cut end tag", "<title>a</ti",
    { "start:title", "text:a</ti" } },
  { "unclosed title, cut entity", "<title>a&amp",
    { "start:title", "text:a&" } },
}

t.cases(T, "tokens", TOKENS, function(input, size)
  return tokens(input, size)
end, { sizes = SIZES })

-- spec/tokenizer.md "Never raise an error on bad markup", and the tokens do
-- not depend on the chunk edges.
local BROKEN = {
  "", "<", "</", "<!", "<!-", "<!--", "<!-- x", "<?", "</>", "<>", "<<<>>>",
  "<a", "<a href='>", "</a", "<script>", "<script>x</scr", "<style",
  "&", "&#", "&#x", "&#99999999999;", "&amp", "\xFF<\xFE>\xC3",
  "<p>\xE4\xB8", "<!DOCTYPE", "<\0>", "</\0>", "<a/", "<p/><",
  "<![CDATA[", "<![CDATA", "<title>", "<textarea></textarea", "<a x=",
  "<a x='", '<a x="y', "<a =", "<a/ /", "</a x='>",
}

local NO_RAISE = {}
for k, doc in ipairs(BROKEN) do
  NO_RAISE[k] = { doc, doc, "same tokens" }
end

t.cases(T, "no_raise", NO_RAISE, function(input, size)
  local limit = 10 * #input + 10
  local whole = tokens(input, WHOLE, limit)
  local got = tokens(input, size, limit)
  if table.concat(got, "|") ~= table.concat(whole, "|") then
    return "chunked " .. table.concat(got, " | ") .. ", whole "
      .. table.concat(whole, " | ")
  end
  return "same tokens"
end, { sizes = SIZES })

-- spec/text.md: text is decode(clean(run)) at every chunk size, also with a
-- byte that clean removes inside an entity (found by the fuzzer). Each row
-- runs as plain text, in p, and in closed and unclosed title and textarea.
local CLEAN_DECODE_BASE = {
  { "&copy\x04a", "&copya" },
  { "&lt\x04a", "&lta" },
  { "&lt\x16a", "&lta" },
  { "&gt\x03a", "&gta" },
  { "&amp\x16a", "&ampa" },
  { "&#\x119", "\t" },
  { "&#1\x14;", "" },
  { "&#\x1C5", "" },
  { "&#x\x04a", "\n" },
  { "&#\xE2\x80\x8B1", "" },
  { "x &eacute; \xE4\xB8\xAD&#x1F600;y &amp z\xF0\x9F\x98\x80&copy;",
    "x \xC3\xA9 \xE4\xB8\xAD\xF0\x9F\x98\x80y & z\xF0\x9F\x98\x80\xC2\xA9" },
  { "&copy\x04a &lt\x16b &#\x119 &#x\x04a &#\xE2\x80\x8B1 \xE4\xB8"
      .. "\xAD&#1\x14; \xC2\xAD&amp\xEF\xBB\xBF;x\xF0\x9F\x98\x80&",
    "&copya &ltb \t \n  \xE4\xB8\xAD &x\xF0\x9F\x98\x80&" },
}

local WRAPPERS = {
  { "", "" }, { "<p>", "</p>" }, { "<title>", "</title>" },
  { "<textarea>", "</textarea>" }, { "<title>" }, { "<textarea>" },
}

local CLEAN_DECODE = {}
for _, base in ipairs(CLEAN_DECODE_BASE) do
  for _, w in ipairs(WRAPPERS) do
    local open, close = w[1], w[2]
    local expected = {}
    if open ~= "" then
      expected[#expected + 1] = "start:" .. open:sub(2, -2)
    end
    if base[2] ~= "" then
      expected[#expected + 1] = "text:" .. base[2]
    end
    if close and close ~= "" then
      expected[#expected + 1] = "end:" .. close:sub(3, -2)
    end
    local input = open .. base[1] .. (close or "")
    CLEAN_DECODE[#CLEAN_DECODE + 1] = { input, input, expected }
  end
end

t.cases(T, "clean_decode", CLEAN_DECODE, function(input, size)
  return tokens(input, size)
end, { sizes = SIZES_1_TO_16 })

-- spec/tokenizer.md "Tokens" and "MAX_TAG ... bounds the buffer": a text
-- run streams before the input ends.
function T.text_run_streams()
  local reads = 0
  local next_token = tokenizer.new(function()
    reads = reads + 1
    if reads > 100 then
      return nil
    end
    return string.rep("a", 4096)
  end)
  local kind = next_token()
  t.eq(kind, "text")
  t.ok(reads <= 2, "reads " .. reads)
end

return T
