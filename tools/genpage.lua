-- genpage: writes a deterministic test page of about 1 MB to stdout.
-- Run in the container, from the project root:
--   lua5.3 tools/genpage.lua > tests/pages/large.html
-- The page mixes headings, paragraphs, lists, links, entities, a pre block,
-- CJK text and a few broken tags. The same seed gives the same bytes.

local SEED = 20261114
local TARGET = 1000000

-- A 31-bit linear congruential generator. math.random differs between C
-- libraries, so the page would differ between machines.
local state = SEED
local function rand(n)
  state = (state * 1103515245 + 12345) & 0x7fffffff
  return (state >> 8) % n + 1
end

local function pick(list)
  return list[rand(#list)]
end

local WORDS = {
  "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing",
  "elit", "sed", "do", "eiusmod", "tempor", "incididunt", "labore", "magna",
  "aliqua", "computer", "screen", "memory", "graphics", "card", "redstone",
  "robot", "drone", "network", "cable", "relay", "server", "rack", "disk",
  "floppy", "tier", "component", "signal", "energy", "capacitor", "the",
  "a", "of", "and", "to", "in", "is", "for", "with", "on", "as", "by",
  "internationalization", "electromagnetic", "x",
}

local ENTITIES = {
  "&amp;", "&lt;", "&gt;", "&quot;", "&apos;", "&nbsp;", "&copy;", "&reg;",
  "&mdash;", "&ndash;", "&hellip;", "&eacute;", "&#169;", "&#x4E2D;",
  "&#8212;", "&#150;", "&unknown;", "&amp", "&#0;", "&#xD800;",
}

local CJK = {
  "中文文本", "日本語のテキスト", "한국어 문장", "汉字和假名", "テスト",
  "全角：，。", "混合 mixed 文字",
}

local BROKEN = {
  "<b>unclosed bold ",
  "</div>",
  "</span></p>",
  "<a href=\"no-close>broken attribute</a>",
  "a < b and c > d",
  "<p<p>",
  "<i><b>crossed</i></b>",
  "<img src=x alt=\"broken image\">",
  "<!-- open comment -- still text? -->",
  "<br/><br>",
}

local out, size = {}, 0
local function emit(s)
  out[#out + 1] = s
  size = size + #s
end

local function words(n)
  local w = {}
  for i = 1, n do
    w[i] = pick(WORDS)
  end
  return table.concat(w, " ")
end

local function inline_piece()
  local r = rand(20)
  if r <= 10 then
    return words(rand(8))
  elseif r <= 12 then
    return "<b>" .. words(rand(3)) .. "</b>"
  elseif r <= 13 then
    return "<em>" .. words(rand(3)) .. "</em>"
  elseif r <= 15 then
    return "<a href=\"/wiki/page" .. rand(9999) .. "\">" .. words(rand(4))
      .. "</a>"
  elseif r <= 17 then
    return pick(ENTITIES)
  elseif r <= 19 then
    return pick(CJK)
  else
    return "<code>" .. words(1) .. "()</code>"
  end
end

local function paragraph()
  local p = {}
  for i = 1, 4 + rand(12) do
    p[i] = inline_piece()
  end
  emit("<p>" .. table.concat(p, " ") .. "</p>\n")
end

local function list()
  local tag = rand(2) == 1 and "ul" or "ol"
  emit("<" .. tag .. ">\n")
  for _ = 1, 2 + rand(6) do
    emit("<li>" .. inline_piece() .. " " .. inline_piece() .. "</li>\n")
  end
  emit("</" .. tag .. ">\n")
end

local function pre_block()
  emit("<pre>\n")
  for i = 1, 5 + rand(10) do
    emit(string.rep(" ", rand(8) - 1) .. "line " .. i .. ": "
      .. words(rand(6)) .. " &lt;tag&gt;\n")
  end
  emit("</pre>\n")
end

local function dropped()
  if rand(2) == 1 then
    emit("<script>var s = '<p>not shown</p>'; if (a < b) {}</script>\n")
  else
    emit("<style>p { color: red; } /* <b> */</style>\n")
  end
end

emit("<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n"
  .. "<title>Large generated test page</title>\n</head>\n<body>\n")
local section = 0
while size < TARGET do
  section = section + 1
  local level = rand(3)
  emit("<h" .. level .. ">Section " .. section .. ": " .. words(rand(5))
    .. "</h" .. level .. ">\n")
  for _ = 1, 1 + rand(5) do
    local r = rand(20)
    if r <= 12 then
      paragraph()
    elseif r <= 15 then
      list()
    elseif r <= 16 then
      pre_block()
    elseif r <= 17 then
      dropped()
    elseif r <= 18 then
      emit("<hr>\n")
    else
      emit(pick(BROKEN) .. "\n")
    end
  end
end
emit("</body>\n</html>\n")

io.write(table.concat(out))
