-- Tests for lib/html/layout.lua (Task 3 scope: blocks, whitespace, wrap).

local t = require("test")
local layout = require("html.layout")
local unicode = require("unicode")

local T = {}

-- Runs a list of tokens. A string item is text. A table item is a tag:
-- { "start", name } or { "end", name }.
local function run(width, items)
  local lay = layout.new(width)
  for _, item in ipairs(items) do
    if type(item) == "string" then
      lay.push("text", item)
    else
      lay.push(item[1], item[2], nil, item[3])
    end
  end
  return lay.finish()
end

-- Lines without style bytes.
local function plain(lines)
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = line:gsub("[\1-\5]", "")
  end
  return out
end

local function S(name) return { "start", name } end
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
  t.eq(plain(run(40, { E("script"), "a", { "start", "svg", true }, "b" })), { "ab" })
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

return T
