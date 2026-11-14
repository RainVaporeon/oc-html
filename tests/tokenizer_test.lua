-- Tests for lib/html/tokenizer.lua: SPEC.md parsing rules at every chunk
-- size.

local t = require("test")
local tokenizer = require("html.tokenizer")

local T = {}

local SIZES = { 1, 2, 7, 4096 }

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

-- "name=value" pairs in name order, or "" when attrs is nil.
local function attr_string(attrs)
  if attrs == nil then
    return ""
  end
  local names = {}
  for name in pairs(attrs) do
    names[#names + 1] = name
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
  local next_token = tokenizer.new(reader(s, size or 4096))
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

-- Joins the tokens, so a failure shows them.
local function show(list)
  return table.concat(list, " | ")
end

-- Checks doc against expected with one chunk and at every chunk size.
local function check(doc, expected)
  t.eq(show(tokens(doc, #doc + 1)), show(expected), "single chunk")
  for _, size in ipairs(SIZES) do
    t.eq(show(tokens(doc, size)), show(expected), "chunk size " .. size)
  end
end

-- Runs fn with a smaller MAX_TAG.
local function with_max_tag(n, fn)
  local saved = tokenizer.MAX_TAG
  tokenizer.MAX_TAG = n
  local ok, err = pcall(fn)
  tokenizer.MAX_TAG = saved
  t.ok(ok, tostring(err))
end

-- Tags and text

function T.tags_and_text()
  check("<p>Hello <b>World</b></p>", {
    "start:p", "text:Hello ", "start:b", "text:World", "end:b", "end:p",
  })
end

function T.names_are_lowercase()
  check("<DIV>x</Div>", { "start:div", "text:x", "end:div" })
end

function T.self_closing_flag()
  check("a<br/>b<br />c<br><img src=x />", {
    "text:a", "start:br/", "text:b", "start:br/", "text:c", "start:br",
    "start:img[src=x]/",
  })
end

function T.slash_in_unquoted_value_is_not_self_closing()
  check("<a href=/x/>y", { "start:a[href=/x/]", "text:y" })
end

function T.text_is_cleaned_and_decoded()
  check("a&amp;b\r\n&lt;\1", { "text:a&b\n<" })
end

-- Comments, doctype, CDATA, bogus comments

function T.comment_skipped()
  check("a<!-- <p>no</p> -- x -->b", { "text:ab" })
end

function T.comment_short_forms()
  check("a<!-->b<!--->c<!---->d<!-- x --->e", { "text:abcde" })
end

function T.unclosed_comment_dropped()
  check("a<!-- b <p>c</p>", { "text:a" })
  check("a<!--", { "text:a" })
  check("a<!-", { "text:a" })
end

function T.doctype_skipped()
  check('<!DOCTYPE html PUBLIC "-//W3C//DTD">a', { "text:a" })
end

function T.bogus_comments_skipped()
  check("a<! x >b<?xml y?>c<!>d", { "text:abcd" })
end

function T.cdata_is_text()
  check("a<![CDATA[<b>&amp;</b>]]>c", { "text:a<b>&amp;</b>c" })
  check("<![CDATA[a]]b]>]]>c", { "text:a]]b]>c" })
  check("<![CDATA[\xC3\xA9\1]]>", { "text:\xC3\xA9" })
end

function T.unclosed_cdata_is_text()
  check("<![CDATA[x<y]", { "text:x<y]" })
end

-- Attributes

function T.attribute_value_forms()
  check([[<a href="x y" title='t' id=z hidden>]],
    { "start:a[hidden=,href=x y,id=z,title=t]" })
end

function T.attribute_spaces_around_equals()
  check([[<a x = "v" y= w z =u>]], { "start:a[x=v,y=w,z=u]" })
end

function T.attribute_empty_values()
  check([[<a x="" y=>b<c z=''>]],
    { "start:a[x=,y=]", "text:b", "start:c[z=]" })
end

function T.gt_in_quoted_value_does_not_end_tag()
  check([[<a title="a>b" x='>'>c]], { "start:a[title=a>b,x=>]", "text:c" })
end

function T.duplicate_attribute_keeps_first()
  check("<a x=1 X=2 x='3'>", { "start:a[x=1]" })
end

function T.attribute_names_are_lowercase()
  check("<A HREF=x Data-Id=y>", { "start:a[data-id=y,href=x]" })
end

function T.attribute_values_are_cleaned_and_decoded()
  check('<a t="&amp;&lt;\1\r&#x263A;" u=a&amp;b>',
    { "start:a[t=&<\xE2\x98\xBA,u=a&b]" })
end

function T.broken_attributes_dropped()
  check([[<a "q"=1 =e x<y=2 ok=3 'z>]], { "start:a[ok=3]" })
end

function T.no_attributes_gives_nil()
  for _, doc in ipairs({ "<p>", "<p >", "<p/>", "<p />", "<p\n>" }) do
    for _, size in ipairs(SIZES) do
      local next_token = tokenizer.new(reader(doc, size))
      local kind, _, attrs = next_token()
      t.eq(kind, "start", doc)
      t.eq(attrs, nil, doc)
    end
  end
end

function T.end_tag_attributes_ignored()
  check([[</a x=">" y>b]], { "end:a", "text:b" })
end

-- Recovery decision: a broken quoted value ends the tag at the first ">"
-- in the value. Its attribute is dropped. Earlier attributes are kept.
function T.unclosed_quote_at_end_of_input()
  check([[<a id=k href="x>y]], { "start:a[id=k]", "text:y" })
  check([[<a href="xy]], {})
end

function T.quoted_value_with_end_tag_is_broken()
  check([[<a id=k href="no-close>broken</a> <b x="y>z">w</b>]], {
    "start:a[id=k]", "text:broken", "end:a", "text: ",
    "start:b[x=y>z]", "text:w", "end:b",
  })
end

function T.unclosed_quote_past_max_tag()
  with_max_tag(16, function()
    check('<a t="x>y' .. string.rep("z", 40),
      { "start:a", "text:y" .. string.rep("z", 40) })
    check('<a t=">' .. string.rep("z", 40) .. '">w',
      { "start:a", "text:" .. string.rep("z", 40) .. '">w' })
  end)
end

function T.closed_quote_far_away_within_max_tag()
  check('<a t="' .. string.rep("z", 100) .. '>">w',
    { "start:a[t=" .. string.rep("z", 100) .. ">]", "text:w" })
end

-- Raw text and RCDATA

function T.script_content_skipped()
  check("<script>if (a<b) x('</p>');</SCRIPT >y",
    { "start:script", "end:script", "text:y" })
end

function T.raw_end_needs_space_slash_or_gt()
  check("<style>a</styles>b</style-x>c</style\n>d",
    { "start:style", "end:style", "text:d" })
  check("<script>a</script/>b", { "start:script", "end:script", "text:b" })
end

-- Regression: an unclosed script at the end of input looped forever.
function T.unclosed_script_ends_with_input()
  check("a<script>x < y", { "text:a", "start:script" })
  check("a<script>x</scr", { "text:a", "start:script" })
end

function T.rcdata_content_is_text()
  check("<title>a<b>&amp;</p></title>c",
    { "start:title", "text:a<b>&</p>", "end:title", "text:c" })
  check("<TEXTAREA x=1>\xC3\xA9 <!-- n --></TextArea >",
    { "start:textarea[x=1]", "text:\xC3\xA9 <!-- n -->", "end:textarea" })
end

function T.unclosed_rcdata_is_text()
  check("<title>a<b", { "start:title", "text:a<b" })
  check("<title>a</ti", { "start:title", "text:a</ti" })
  check("<title>a&amp", { "start:title", "text:a&" })
end

-- Unknown and malformed tags

function T.lt_before_non_letter_is_text()
  check("a < b <3 c<", { "text:a < b <3 c<" })
  check("<\0>", { "text:<>" })
end

function T.empty_end_tag_dropped()
  check("a</>b", { "text:ab" })
end

function T.end_tag_with_space_is_bogus_comment()
  check("a</ foo>b</3>c", { "text:abc" })
end

function T.unclosed_tag_at_end_is_dropped()
  check("x<a href", { "text:x" })
  check("x</a", { "text:x" })
end

function T.long_unclosed_tag_becomes_text()
  with_max_tag(16, function()
    check("<a " .. string.rep("b", 40), { "text:<a " .. string.rep("b", 40) })
  end)
end

-- Many "<" with no ">" stay linear and become text. The tags in the last
-- MAX_TAG bytes are cut by the end of input and dropped.
function T.many_unclosed_tags_become_text()
  local doc = string.rep("<a ", 2000)
  with_max_tag(64, function()
    check(doc, { "text:" .. doc:sub(1, #doc - 63) })
  end)
end

-- A ">" more than MAX_TAG bytes after "<" never ends the tag, at any chunk
-- size.
function T.far_gt_does_not_end_tag()
  with_max_tag(16, function()
    check("<a " .. string.rep("b", 40) .. ">c",
      { "text:<a " .. string.rep("b", 40) .. ">c" })
  end)
end

-- Bounded buffering: a text run streams before the input ends.
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

-- The SPEC rule: tokens split at any chunk edge give the same result.
function T.same_tokens_at_chunk_sizes_1_to_8()
  local doc = '<!DOCTYPE html><html><head><title>T &amp; U</title></head>'
    .. '<body><h1 class="big">Caf\xC3\xA9 &amp; \xE4\xB8\xAD\xE6\x96\x87</h1>'
    .. '<!-- c --><p>A&nbsp;b &#x263A; &mdash;<br/>end</p>'
    .. "<a href='/x?a=1&amp;b=2' title=\"a>b\">l</a><![CDATA[x]]>"
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
  "<![CDATA[", "<![CDATA", "<title>", "<textarea></textarea", "<a x=",
  "<a x='", '<a x="y', "<a =", "<a/ /", "</a x='>",
}

function T.broken_input_does_not_raise()
  for _, doc in ipairs(BROKEN) do
    for _, size in ipairs(SIZES) do
      local ok, err = pcall(tokens, doc, size, 10 * #doc + 10)
      t.ok(ok, "input " .. doc .. " size " .. size .. ": " .. tostring(err))
    end
  end
end

-- Fixed-seed generator: tag soup and random bytes. Every case ends without
-- an error and gives the same tokens at every chunk size.
function T.generated_broken_input()
  local alphabet = { "<", ">", "/", "!", "-", "a", "p", "script", " ", "&",
    ";", "#", "x", '"', "'", "\xE4\xB8\xAD", "\xC3", "=", "?", "\n",
    "<!--", "-->", "<![CDATA[", "]]>", "title", "</", "<a href=", "&amp;",
    "<style>", "</script>", "\t", "TEXTAREA", "[" }
  local seed = 12345
  local function rand(n)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % n + 1
  end
  for case = 1, 500 do
    local parts = {}
    if case % 5 == 0 then
      for k = 1, rand(60) do
        parts[k] = string.char(rand(256) - 1)
      end
    else
      for k = 1, rand(40) do
        parts[k] = alphabet[rand(#alphabet)]
      end
    end
    local doc = table.concat(parts)
    local limit = 10 * #doc + 10
    local ok, expected = pcall(tokens, doc, #doc + 1, limit)
    t.ok(ok, "case " .. case .. ": " .. tostring(expected))
    local size = SIZES[rand(#SIZES)]
    local ok2, got = pcall(tokens, doc, size, limit)
    t.ok(ok2, "case " .. case .. " size " .. size .. ": " .. tostring(got))
    if ok and ok2 then
      t.eq(show(got), show(expected), "case " .. case .. " size " .. size
        .. " input " .. doc)
    end
  end
end


-- A byte that clean removes inside an entity: the text is
-- decode(clean(run)) at every chunk size, as SPEC.md says. Found by the
-- fuzzer.
local REMOVED_IN_ENTITY = {
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
}

-- Joined text of all tokens, or the tokens when one is not text.
local function joined_text(list)
  if #list == 0 then
    return ""
  end
  if #list == 1 and list[1]:sub(1, 5) == "text:" then
    return list[1]:sub(6)
  end
  return show(list)
end

local function check_text(doc, expected, prefix, suffix)
  local single = tokens(doc, #doc + 1)
  local want = {}
  if prefix then
    want[#want + 1] = prefix
  end
  if expected ~= "" then
    want[#want + 1] = "text:" .. expected
  end
  if suffix then
    want[#want + 1] = suffix
  end
  t.eq(show(single), show(want), "single chunk")
  for size = 1, 16 do
    t.eq(show(tokens(doc, size)), show(single), "chunk size " .. size)
  end
end

function T.removed_byte_in_entity_matches_single_chunk()
  for _, case in ipairs(REMOVED_IN_ENTITY) do
    local s, expected = case[1], case[2]
    check_text(s, expected)
    t.eq(joined_text(tokens(s, 1)), expected)
    check_text("<p>" .. s .. "</p>", expected, "start:p", "end:p")
  end
end

function T.removed_byte_in_entity_in_rcdata()
  for _, case in ipairs(REMOVED_IN_ENTITY) do
    for _, name in ipairs({ "title", "textarea" }) do
      check_text("<" .. name .. ">" .. case[1] .. "</" .. name .. ">",
        case[2], "start:" .. name, "end:" .. name)
      -- Unclosed: the content ends with the input.
      check_text("<" .. name .. ">" .. case[1], case[2], "start:" .. name)
    end
  end
end

-- CDATA is cleaned, not decoded. A removed character cut by a chunk edge
-- is removed whole.
function T.cdata_cleans_across_chunks()
  check_text("<![CDATA[a\xE2\x80\x8Bb&copy\x04c\xC2\xADd]]>", "ab&copycd")
  check_text("<![CDATA[\xE4\xB8\xAD\xE2\x80", "\xE4\xB8\xAD?")
end

-- Every fuzz failure file that the env can read gives the same tokens at
-- every chunk size. The env cannot list a directory, so the names are
-- probed: <seed>-<index>.html for the seeds of the recorded runs.
function T.fuzz_failure_files_match_single_chunk()
  local count = 0
  for _, seed in ipairs({ 1, 11, 2026, 987654321 }) do
    for index = 1, 1000 do
      local path = "tests/fuzz-failures/" .. seed .. "-" .. index .. ".html"
      local f = io.open(path, "rb")
      if f then
        local doc = f:read("a")
        f:close()
        count = count + 1
        local expected = show(tokens(doc, #doc + 1))
        for _, size in ipairs({ 1, 2, 3, 5, 8, 13, 16 }) do
          t.eq(show(tokens(doc, size)), expected, path .. " size " .. size)
        end
      end
    end
  end
  print("fuzz failure files checked: " .. count)
end

return T
