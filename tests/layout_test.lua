-- Tests for lib/html/layout.lua: element table, open-element stack,
-- whitespace, pre and wrap.

local t = require("test")
local layout = require("html.layout")
local unicode = require("unicode")

local T = {}

-- Runs a list of tokens. A string item is text. A table item is a tag:
-- { "start", name, attrs, self_closing } or { "end", name }.
local function new_run(width, items)
  local lay = layout.new(width)
  for _, item in ipairs(items) do
    if type(item) == "string" then
      lay.push("text", item)
    else
      lay.push(item[1], item[2], item[3], item[4])
    end
  end
  return lay.finish(), lay
end

local function run(width, items)
  return (new_run(width, items))
end

-- Lines without style bytes.
local function plain(lines)
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = line:gsub("[\1-\5]", "")
  end
  return out
end

local function S(name, attrs) return { "start", name, attrs } end
local function E(name) return { "end", name } end

function T.lines_start_with_a_style_byte()
  t.eq(run(40, { S("p"), "a", E("p") }), { "\1a" })
end

function T.block_tags_end_the_line()
  t.eq(plain(run(40, { "x", S("p"), "a", E("p"), S("div"), "b", E("div"),
    "c" })), { "x", "a", "b", "c" })
end

function T.br_breaks_and_repeats()
  t.eq(plain(run(40, { "a", S("br"), S("br"), "b" })), { "a", "", "b" })
end

function T.heading_has_blank_lines_and_style()
  t.eq(run(40, { "a", S("h1"), "T", E("h1"), "b" }),
    { "\1a", "", "\2T", "", "\1b" })
end

function T.no_blank_line_at_start_or_end()
  t.eq(plain(run(40, { S("h2"), "T", E("h2") })), { "T" })
end

function T.li_prefix()
  t.eq(plain(run(40, { S("ul"), S("li"), "a", E("li"), S("li"), " b ",
    E("ul") })), { "- a", "- b" })
end

function T.hr_fills_the_width()
  t.eq(plain(run(5, { "a", S("hr"), "b" })), { "a", "─────", "b" })
end

function T.whitespace_collapses()
  t.eq(plain(run(40, { "  a \n\t b  ", "  c", "\n" })), { "a b c" })
end

function T.word_spans_tokens_and_inline_tags()
  t.eq(plain(run(40, { "hel", "lo ", S("b"), "wo", E("b"), "rld" })),
    { "hello world" })
end

function T.script_and_style_dropped()
  t.eq(plain(run(40, { "a ", S("script"), "x", E("script"), S("style"),
    "y", E("style"), "b" })), { "a b" })
end

function T.unclosed_head_ends_at_body()
  t.eq(plain(run(40, { S("head"), S("title"), "T", S("body"), "x" })),
    { "x" })
end

function T.stray_end_of_dropped_tag_ignored()
  t.eq(plain(run(40, { E("script"), "a", { "start", "svg", nil, true }, "b" })), { "ab" })
end

function T.wraps_at_word_boundaries()
  t.eq(plain(run(10, { "aaa bbb ccc ddd eeeeeeeeee f" })),
    { "aaa bbb", "ccc ddd", "eeeeeeeeee", "f" })
end

function T.long_word_is_split()
  t.eq(plain(run(4, { "abcdefghij" })), { "abcd", "efgh", "ij" })
end

function T.wide_characters_count_two()
  local lines = plain(run(6, { "ab \xE4\xB8\xAD\xE6\x96\x87 x" }))
  t.eq(lines, { "ab", "\xE4\xB8\xAD\xE6\x96\x87 x" })
  for _, line in ipairs(lines) do
    t.ok(unicode.wlen(line) <= 6, line)
  end
end

function T.long_wide_word_never_exceeds_width()
  local lines = plain(run(3, { "\xE4\xB8\xAD\xE6\x96\x87\xE5\xAD\x97" }))
  t.eq(lines, { "\xE4\xB8\xAD", "\xE6\x96\x87", "\xE5\xAD\x97" })
end

function T.no_line_exceeds_width()
  local words = {}
  for k = 1, 200 do
    words[k] = string.rep("w", k % 13 + 1)
  end
  for width = 1, 20 do
    for _, line in ipairs(plain(run(width, { table.concat(words, " ") }))) do
      t.ok(unicode.wlen(line) <= width, "width " .. width .. ": " .. line)
    end
  end
end

-- Element table rows.

function T.every_dropped_element_hides_its_content()
  for _, name in ipairs({ "script", "style", "template", "svg", "math",
      "iframe", "object", "noscript", "head", "title" }) do
    t.eq(plain(run(40, { "a ", S(name), "x", S("p"), "y", E("p"), E(name),
      "b" })), { "a b" }, name)
  end
end

function T.dropped_element_ends_at_parent_end()
  t.eq(plain(run(40, { S("div"), S("svg"), "x", E("div"), "b" })), { "b" })
end

function T.nested_same_dropped_element()
  t.eq(plain(run(40, { S("svg"), S("svg"), "x", E("svg"), "y", E("svg"),
    "b" })), { "b" })
end

function T.title_in_head_is_stored_not_shown()
  local lines, lay = new_run(40, { S("head"), S("title"), "  My \n page ",
    E("title"), E("head"), S("body"), "x" })
  t.eq(plain(lines), { "x" })
  t.eq(lay.title(), "My page")
end

function T.title_without_head_and_first_title_wins()
  local _, lay = new_run(40, { S("title"), "One", E("title"), S("title"),
    "Two", E("title"), "x" })
  t.eq(lay.title(), "One")
end

function T.title_is_nil_when_missing_or_empty()
  local _, lay = new_run(40, { "x" })
  t.eq(lay.title(), nil)
  _, lay = new_run(40, { S("title"), "  ", E("title") })
  t.eq(lay.title(), nil)
end

function T.svg_title_is_not_the_document_title()
  local _, lay = new_run(40, { S("svg"), S("title"), "icon", E("title"),
    E("svg") })
  t.eq(lay.title(), nil)
end

function T.long_title_is_cut_at_a_character_boundary()
  local _, lay = new_run(40, { S("title"), string.rep("\xE4\xB8\xAD", 200),
    E("title") })
  local title = lay.title()
  t.ok(#title <= 256, #title)
  t.eq(#title % 3, 0)
end

function T.long_leading_whitespace_in_title_keeps_the_text()
  local html = t.load_bin("html")({})
  local input = "<title>" .. string.rep(" ", 5000) .. "Real</title>"
  for _, size in ipairs({ 1, 7, 4096 }) do
    local pos = 1
    local _, title = html.render(function()
      if pos > #input then
        return nil
      end
      local c = input:sub(pos, pos + size - 1)
      pos = pos + size
      return c
    end, 40)
    t.eq(title, "Real", "read size " .. size)
  end
end

function T.unclosed_title_in_head_ends_at_body()
  local lines, lay = new_run(40, { S("head"), S("title"), "T", S("body"),
    "x" })
  t.eq(plain(lines), { "x" })
  t.eq(lay.title(), "T")
end

function T.every_heading_level()
  for k = 1, 6 do
    t.eq(run(40, { "a", S("h" .. k), "T", E("h" .. k), "b" }),
      { "\1a", "", "\2T", "", "\1b" }, "h" .. k)
  end
end

function T.every_block_element_breaks()
  for _, name in ipairs({ "p", "div", "section", "article", "main",
      "header", "footer", "nav", "aside", "blockquote", "table", "tr", "td",
      "th", "ul", "ol", "dl", "form", "button", "select", "textarea" }) do
    t.eq(plain(run(40, { "a", S(name), "b", E(name), "c" })),
      { "a", "b", "c" }, name)
  end
end

function T.input_breaks_and_has_no_content()
  t.eq(plain(run(40, { "a", S("input"), "b" })), { "a", "b" })
end

function T.br_inside_pre()
  t.eq(plain(run(40, { S("pre"), "a", S("br"), "b", E("pre") })),
    { "a", "b" })
end

function T.hr_is_normal_style_and_breaks()
  t.eq(run(3, { S("b"), "a", S("hr"), "b", E("b") }),
    { "\3a", "\1───", "\3b" })
end

function T.every_emphasis_element()
  for _, name in ipairs({ "b", "strong", "i", "em", "u", "mark" }) do
    t.eq(run(40, { "a ", S(name), "b", E(name), " c" }), { "\1a \3b \1c" },
      name)
  end
end

function T.link_with_href()
  t.eq(run(40, { "a ", S("a", { href = "/x" }), "b", E("a"), " c" }),
    { "\1a \4b \1c" })
end

function T.link_without_href_is_plain()
  t.eq(run(40, { "a ", S("a", { name = "x" }), "b", E("a"), " c" }),
    { "\1a b c" })
end

function T.pre_keeps_whitespace_with_pre_style()
  t.eq(run(40, { "a", S("pre"), "\n  x  y\n\n z", E("pre"), "b" }),
    { "\1a", "\5  x  y", "", "\5 z", "\1b" })
end

function T.code_is_inline()
  t.eq(run(40, { "a ", S("code"), "f()", E("code"), " b" }),
    { "\1a f() b" })
end

function T.img_alt_text()
  t.eq(plain(run(40, { "a ", S("img", { alt = " a\n cat " }), " b" })),
    { "a [img: a cat] b" })
  t.eq(plain(run(40, { "a ", S("img"), S("img", { alt = "" }),
    S("img", { src = "x" }) })), { "a [img][img][img]" })
end

function T.img_alt_wraps_like_text()
  t.eq(plain(run(10, { S("img", { alt = "one two three" }) })),
    { "[img: one", "two three]" })
end

function T.unknown_tags_are_inline()
  t.eq(run(40, { "a", S("foo"), "b", E("foo"), S("span"), "c", E("span"),
    "d" }), { "\1abcd" })
end

-- Lists.

function T.nested_lists_have_no_indent()
  t.eq(plain(run(40, { S("ul"), S("li"), "a", S("ol"), S("li"), "b",
    E("li"), E("ol"), E("li"), S("li"), "c", E("li"), E("ul") })),
    { "- a", "- b", "- c" })
end

function T.unclosed_li_closes_at_next_li()
  t.eq(run(40, { S("ul"), S("li"), S("b"), "a", S("li"), "b", E("ul") }),
    { "\1- \3a", "\1- b" })
end

function T.li_continuation_has_no_prefix()
  t.eq(plain(run(8, { S("li"), "aaa bbb ccc" })), { "- aaa", "bbb ccc" })
end

-- The open-element stack.

function T.unclosed_inline_closes_at_parent_end()
  t.eq(run(40, { S("p"), "a ", S("b"), "b", E("p"), "c" }),
    { "\1a \3b", "\1c" })
end

function T.unclosed_heading_closes_at_document_end()
  t.eq(run(40, { "a", S("h1"), "T" }), { "\1a", "", "\2T" })
end

function T.stray_end_tags_are_ignored()
  t.eq(run(40, { E("b"), E("p"), "a", E("div"), " ", E("a"), "b" }),
    { "\1a b" })
end

function T.stray_end_does_not_close_an_outer_style()
  t.eq(run(40, { S("b"), "a", E("i"), "b", E("b"), "c" }), { "\3ab\1c" })
end

function T.misnested_tags_close_inner_ones()
  t.eq(run(40, { S("i"), S("b"), "a", E("i"), "b", E("b"), "c" }),
    { "\3a\1bc" })
end

function T.innermost_style_wins_and_outer_returns()
  t.eq(run(40, { S("a", { href = "x" }), "a", S("b"), "b", E("b"), "c",
    E("a"), "d" }), { "\4a\3b\4c\1d" })
  t.eq(run(40, { S("h2"), "a", S("em"), "b", E("em"), "c", E("h2") }),
    { "\2a\3b\2c" })
end

function T.emphasis_inside_pre_keeps_whitespace()
  t.eq(run(40, { S("pre"), "a  ", S("b"), "b  b", E("b"), "  c", E("pre") }),
    { "\5a  \3b  b\5  c" })
end

function T.p_closes_an_open_p()
  t.eq(run(40, { S("p"), S("b"), "a", S("p"), "b" }), { "\3a", "\1b" })
end

function T.depth_is_bounded()
  local items = {}
  for _ = 1, 1000 do
    items[#items + 1] = S("span")
  end
  items[#items + 1] = S("b")
  items[#items + 1] = "a"
  items[#items + 1] = E("b")
  items[#items + 1] = "b"
  for _ = 1, 1000 do
    items[#items + 1] = E("span")
  end
  items[#items + 1] = "c"
  -- b is past the bound, so its style does not apply.
  t.eq(run(40, items), { "\1abc" })
end

function T.dropped_element_at_depth_bound_still_hides()
  local items = {}
  for _ = 1, layout.MAX_DEPTH do
    items[#items + 1] = S("div")
  end
  items[#items + 1] = "a"
  items[#items + 1] = S("script")
  items[#items + 1] = "x"
  items[#items + 1] = E("script")
  items[#items + 1] = "b"
  t.eq(plain(run(40, items)), { "a", "b" })
end

function T.deep_nesting_inside_dropped_element()
  local items = {}
  items[1] = S("svg")
  for _ = 1, 1000 do
    items[#items + 1] = S("g")
  end
  items[#items + 1] = "x"
  items[#items + 1] = E("svg")
  items[#items + 1] = "b"
  t.eq(plain(run(40, items)), { "b" })
end

-- Whitespace, pre and wrap.

function T.no_leading_or_trailing_space()
  t.eq(run(40, { S("p"), "  a  ", E("p"), S("p"), " ", S("b"), " b ",
    E("b"), " ", E("p") }), { "\1a", "\3b" })
end

function T.space_at_a_style_change_is_kept_once()
  t.eq(run(40, { "a ", S("b"), " b ", E("b"), " c" }), { "\1a \3b \1c" })
end

function T.pre_skips_one_leading_newline()
  t.eq(plain(run(40, { S("pre"), "\n\nx", E("pre") })), { "", "x" })
end

function T.pre_expands_tabs_to_8_column_stops()
  t.eq(plain(run(40, { S("pre"), "\tx\nab\tc\n1234567\t8\n12345678\t9",
    E("pre") })), {
      "        x",
      "ab      c",
      "1234567 8",
      "12345678        9",
    })
end

function T.pre_tab_never_passes_the_width()
  local lines = plain(run(10, { S("pre"), "abcdefghi\tx", E("pre") }))
  t.eq(lines, { "abcdefghi ", "x" })
end

function T.pre_wraps_hard_at_the_width()
  t.eq(run(4, { S("pre"), "ab cdef gh\nxy", E("pre") }),
    { "\5ab c", "\5def ", "\5gh", "\5xy" })
end

function T.pre_wraps_wide_characters()
  local lines = plain(run(5, { S("pre"),
    "a\xE4\xB8\xAD\xE6\x96\x87\xE5\xAD\x97", E("pre") }))
  t.eq(lines, { "a\xE4\xB8\xAD\xE6\x96\x87", "\xE5\xAD\x97" })
end

function T.tabs_never_reach_a_line()
  local lines = run(30, { "a\tb", S("pre"), "\tc\td", E("pre"), "e\t" })
  for _, line in ipairs(lines) do
    t.ok(not line:find("\t"), line)
  end
end

function T.wide_character_never_straddles_the_width()
  local lines = plain(run(5, { "abcd\xE4\xB8\xAD" }))
  t.eq(lines, { "abcd", "\xE4\xB8\xAD" })
end

function T.style_continues_after_a_wrap()
  t.eq(run(7, { "a ", S("b"), "bbb ccc ddd", E("b"), " e" }),
    { "\1a \3bbb", "\3ccc ddd", "\1e" })
end

function T.style_continues_in_a_split_word()
  t.eq(run(4, { S("a", { href = "x" }), "abcdefghij", E("a") }),
    { "\4abcd", "\4efgh", "\4ij" })
end

function T.word_with_style_change_wraps_as_one_word()
  t.eq(run(6, { "abc ", "de", S("b"), "fg", E("b") }),
    { "\1abc", "\1de\3fg" })
end

function T.style_bytes_do_not_count_toward_width()
  t.eq(run(5, { "a", S("b"), "b", E("b"), "c", S("i"), "d", E("i"), "e" }),
    { "\1a\3b\1c\3d\1e" })
end

-- A style byte is never followed by another style byte or the line end.
local function no_empty_runs(lines)
  for _, line in ipairs(lines) do
    t.ok(not line:find("[\1-\5][\1-\5]") and not line:find("[\1-\5]$"),
      line)
    if line ~= "" then
      t.ok(line:find("^[\1-\5]"), line)
    end
  end
end

function T.no_empty_style_runs()
  no_empty_runs(run(6, { S("b"), S("i"), E("i"), " ", E("b"), "a ",
    S("a", { href = "x" }), " ", E("a"), S("em"), "", "bcdefghijk", E("em"),
    S("u"), " ", E("u"), S("li"), S("b"), "x", S("h1"), S("b"), E("b"), "y",
    S("pre"), S("b"), "\n", E("b"), "\t", S("i"), "zz", E("pre") }))
end

function T.styles_and_width_hold_for_many_widths()
  local items = {}
  local tags = { "b", "a", "i", "code", "span" }
  for k = 1, 120 do
    local tag = tags[k % #tags + 1]
    items[#items + 1] = S(tag, tag == "a" and { href = "x" } or nil)
    items[#items + 1] = string.rep("w", k % 11 + 1) .. " \xE4\xB8\xAD"
    items[#items + 1] = E(tag)
    items[#items + 1] = k % 7 == 0 and " " or ""
  end
  for width = 2, 25 do
    local lines = run(width, items)
    no_empty_runs(lines)
    for _, line in ipairs(plain(lines)) do
      t.ok(unicode.wlen(line) <= width, "width " .. width .. ": " .. line)
    end
  end
end

-- Expected-output cases in tests/cases. The comparison removes "\r",
-- trailing spaces and tabs, and blank lines at the end (tasks/archive/mvp-plan.md).

local tokenizer = require("html.tokenizer")

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("a")
  f:close()
  return s
end

-- Renders a file at width 40. Returns the lines and the layout.
local function render(path)
  local doc = read_file(path)
  local lay = layout.new(40)
  local done = false
  local next_token = tokenizer.new(function()
    if done then
      return nil
    end
    done = true
    return doc
  end, lay.count)
  while true do
    local kind, value, attrs, self_closing = next_token()
    if not kind then
      break
    end
    lay.push(kind, value, attrs, self_closing)
  end
  return lay.finish(), lay
end

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

function T.diff_names_the_first_differing_line()
  t.eq(line_diff("a\nb", "a\nb"), nil)
  t.eq(line_diff("a\nb\nc", "a\nx\nc"),
    "first difference at line 2\n  expected: b\n  actual:   x")
  t.eq(line_diff("a", "a\nb"),
    "first difference at line 2\n  expected: (no line)\n  actual:   b")
  t.eq(line_diff("a\tb\1", "a b"),
    "first difference at line 1\n  expected: a\\x09b\\x01\n  actual:   a b")
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
      local lines = render("tests/cases/" .. name .. ".html")
      local diff = line_diff(normalize(expected),
        normalize(table.concat(plain(lines), "\n")))
      if diff then
        failures[#failures + 1] = "case " .. name .. ": " .. diff
      end
    end
  end
  t.ok(#failures == 0, "\n" .. table.concat(failures, "\n"))
end

function T.case_titles()
  local _, lay = render("tests/cases/elements.html")
  t.eq(lay.title(), "Element table")
  _, lay = render("tests/cases/broken.html")
  t.eq(lay.title(), "Broken")
  _, lay = render("tests/cases/title.html")
  t.eq(lay.title(), "Tom & Jerry")
end

function T.case_style_bytes()
  local lines, lay = render("tests/cases/styles.html")
  t.eq(lay.title(), "Styles")
  t.eq(lines, {
    "\2Top \3mid \2end",
    "",
    "\1plain \3bold \4link \3back \1plain",
    "\5a \3b",
    "\5c",
  })
end

return T
