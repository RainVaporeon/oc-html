-- A short fuzz run with a fixed seed, so the normal suite catches
-- regressions. tests/fuzz.lua runs the long runs.

local t = require("test")

local T = {}

local function load_fuzz()
  local f = assert(io.open("tests/fuzz.lua", "rb"))
  local src = f:read("a")
  f:close()
  return assert(load(src, "@tests/fuzz.lua"))({})
end

local fuzz = load_fuzz()

function T.same_seed_gives_same_documents()
  local sources = { files = { { "x", "<p>a &amp; b</p>" } } }
  for index = 1, 10 do
    local a, ia = fuzz.document(7, index, sources)
    local b, ib = fuzz.document(7, index, sources)
    t.eq(a, b, "document " .. index)
    t.eq(ia, ib, "choices " .. index)
  end
  t.ok(fuzz.document(7, 1, sources) ~= fuzz.document(8, 1, sources),
    "another seed gives another document")
end

function T.utf8_check()
  t.eq(fuzz.utf8_error("abc 中文 😀"), nil)
  t.eq(fuzz.utf8_error("a\128"), 2, "lone continuation")
  t.eq(fuzz.utf8_error("\192\175"), 1, "overlong")
  t.eq(fuzz.utf8_error("\237\160\128"), 1, "surrogate")
  t.eq(fuzz.utf8_error("\244\144\128\128"), 1, "above U+10FFFF")
  t.eq(fuzz.utf8_error("x\228\184"), 2, "truncated")
end

function T.line_oracles()
  t.eq(fuzz.check_lines({ "\1abc", "", "\2中文\3x" }, 5), nil)
  t.ok(fuzz.check_lines({ "abc" }, 10), "no style byte")
  t.ok(fuzz.check_lines({ "\1a\tb" }, 10), "tab")
  t.ok(fuzz.check_lines({ "\1a\0b" }, 10), "zero byte")
  t.ok(fuzz.check_lines({ "\1abcdef" }, 5), "too wide")
  t.ok(fuzz.check_lines({ "\1\237\160\128" }, 5), "invalid UTF-8")
end

function T.short_run_has_no_failures()
  local failures = {}
  local summary = fuzz.run({
    n = 30,
    seed = 20261114,
    corpus = { "tests/cases/basic.html", "tests/fuzz-corpus/mixed.html",
      "tests/fuzz-corpus/broken.html" },
    large = "tests/pages/large.html",
    on_failure = function(f)
      failures[#failures + 1] = f.index .. " (" .. f.generator .. "): "
        .. f.message:sub(1, 300)
    end,
  })
  t.eq(summary.documents, 30)
  t.eq(failures, {})
end

return T
