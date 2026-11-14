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

-- A saved failure replays only when the same seed gives the same document.
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

-- The UTF-8 oracle: the index of the first bad byte, or nil.
t.cases(T, "utf8_error", {
  { "ASCII, CJK and emoji", "abc \228\184\173\230\150\135 \240\159\152\128",
    nil },
  { "empty", "", nil },
  { "lone continuation byte", "a\128", 2 },
  { "overlong", "\192\175", 1 },
  { "surrogate", "\237\160\128", 1 },
  { "above U+10FFFF", "\244\144\128\128", 1 },
  { "truncated sequence", "x\228\184", 2 },
  { "highest code point", "\244\143\191\191", nil },
  { "byte 0xFF", "a\255", 2 },
}, function(s)
  return fuzz.utf8_error(s)
end)

-- The line oracle: true when check_lines rejects the lines.
t.cases(T, "check_lines", {
  { "valid lines", { { "\1abc", "", "\2\228\184\173\230\150\135\3x" }, 5 },
    false },
  { "no style byte", { { "abc" }, 10 }, true },
  { "tab", { { "\1a\tb" }, 10 }, true },
  { "zero byte", { { "\1a\0b" }, 10 }, true },
  { "too wide", { { "\1abcdef" }, 5 }, true },
  { "invalid UTF-8", { { "\1\237\160\128" }, 5 }, true },
  { "not a table", { "text", 5 }, true },
}, function(input)
  return fuzz.check_lines(input[1], input[2]) ~= nil
end)

-- The fuzz contract: a fixed seed over the saved cases and the fuzz corpus
-- gives no failure. A share of the documents goes through the fake card with
-- random chunks, gaps, headers and errors.
function T.short_run_has_no_failures()
  local corpus = { "tests/fuzz-corpus/mixed.html",
    "tests/fuzz-corpus/broken.html" }
  for _, name in ipairs(t.list_cases()) do
    corpus[#corpus + 1] = "tests/cases/" .. name .. ".html"
  end
  local failures = {}
  local summary = fuzz.run({
    n = 60,
    seed = 20261114,
    corpus = corpus,
    large = "tests/pages/large.html",
    on_failure = function(f)
      failures[#failures + 1] = f.index .. " (" .. f.generator .. "): "
        .. f.message:sub(1, 300)
    end,
  })
  t.eq(summary.documents, 60)
  t.ok(summary.card > 0, "some documents go through the card")
  t.eq(failures, {})
end

return T
