-- Tests for lib/html/tokenizer.lua (Task 3 scope: tags and text).

local t = require("test")
local tokenizer = require("html.tokenizer")

local T = {}

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

-- Returns the tokens as strings. Adjacent text tokens are joined, because
-- chunk edges may split text.
local function tokens(s, size)
  local next_token = tokenizer.new(reader(s, size or 4096))
  local out, text = {}, nil
  while true do
    local kind, value, _, self_closing = next_token()
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
      local item = kind .. ":" .. value
      if self_closing then
        item = item .. "/"
      end
      out[#out + 1] = item
    end
  end
end

function T.tags_and_text()
  t.eq(tokens("<p>Hello <b>World</b></p>"), {
    "start:p", "text:Hello ", "start:b", "text:World", "end:b", "end:p",
  })
end

function T.names_are_lowercase()
  t.eq(tokens("<DIV>x</Div>"), { "start:div", "text:x", "end:div" })
end

function T.self_closing_flag()
  t.eq(tokens("a<br/>b<br />c<br>"), {
    "text:a", "start:br/", "text:b", "start:br/", "text:c", "start:br",
  })
end

function T.attributes_do_not_end_the_name()
  t.eq(tokens('<a href="x">y</a>'), { "start:a", "text:y", "end:a" })
end

function T.text_is_cleaned_and_decoded()
  t.eq(tokens("a&amp;b\r\n&lt;\1"), { "text:a&b\n<" })
end

function T.comment_and_doctype_skipped()
  t.eq(tokens("<!DOCTYPE html><!-- <p>no</p> -->x<?xml y?>z"),
    { "text:xz" })
end

function T.lone_lt_is_text()
  t.eq(tokens("a < b <3 c<"), { "text:a < b <3 c<" })
end

function T.script_content_skipped()
  t.eq(tokens("<script>if (a<b) x('</p>');</SCRIPT >y"),
    { "start:script", "end:script", "text:y" })
end

function T.script_end_needs_full_name()
  t.eq(tokens("<style>a</styles>b</style>c"),
    { "start:style", "end:style", "text:c" })
end

-- Regression: an unclosed script at the end of input looped forever.
function T.unclosed_script_ends_with_input()
  for size = 1, 4 do
    t.eq(tokens("a<script>x < y", size), { "text:a", "start:script" })
  end
end

function T.unclosed_tag_at_end_is_dropped()
  t.eq(tokens("x<a href"), { "text:x" })
end

-- The SPEC rule: tokens split at any chunk edge give the same result.
function T.same_tokens_at_chunk_sizes_1_to_8()
  local doc = '<!DOCTYPE html><html><head><title>T</title></head><body>'
    .. '<h1 class="big">Caf\xC3\xA9 &amp; \xE4\xB8\xAD\xE6\x96\x87</h1>'
    .. '<!-- c --><p>A&nbsp;b &#x263A; &mdash;<br/>end</p>'
    .. '<script>if (a</b) {}</script><p>tail &copy</p></body></html>'
  local expected = tokens(doc, 4096)
  t.ok(#expected > 10)
  for size = 1, 8 do
    t.eq(tokens(doc, size), expected, "chunk size " .. size)
  end
end

local BROKEN = {
  "", "<", "</", "<!", "<!-", "<!--", "<!-- x", "<?", "</>", "<>", "<<<>>>",
  "<a", "<a href='>", "</a", "<script>", "<script>x</scr", "<style",
  "&", "&#", "&#x", "&#99999999999;", "&amp", "\xFF<\xFE>\xC3",
  "<p>\xE4\xB8", "<!DOCTYPE", "<\0>", "</\0>", "<a/", "<p/><",
}

function T.broken_input_does_not_raise()
  for _, doc in ipairs(BROKEN) do
    for size = 1, 4 do
      local ok, err = pcall(tokens, doc, size)
      t.ok(ok, "input " .. doc .. " size " .. size .. ": " .. tostring(err))
    end
  end
end

function T.random_soup_does_not_raise()
  local alphabet = { "<", ">", "/", "!", "-", "a", "p", "script", " ", "&",
    ";", "#", "x", '"', "'", "\xE4\xB8\xAD", "\xC3", "=", "?", "\n" }
  local seed = 12345
  local function rand(n)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % n + 1
  end
  for _ = 1, 200 do
    local parts = {}
    for k = 1, rand(40) do
      parts[k] = alphabet[rand(#alphabet)]
    end
    local doc = table.concat(parts)
    local size = rand(8)
    local ok, err = pcall(tokens, doc, size)
    t.ok(ok, "input " .. doc .. " size " .. size .. ": " .. tostring(err))
  end
end

function T.long_unclosed_tag_becomes_text()
  local saved = tokenizer.MAX_TAG
  tokenizer.MAX_TAG = 16
  local ok, result = pcall(tokens, "<a " .. string.rep("b", 40), 4)
  tokenizer.MAX_TAG = saved
  t.ok(ok, tostring(result))
  t.eq(result, { "text:<a " .. string.rep("b", 40) })
end

return T
