-- Regression tests from review findings. Each test fails while its defect is
-- present. Names are f<N>_<name>, N is the finding number.

local t = require("test")

local T = {}

local html = t.load_bin("html")({})
local tokenizer = require("html.tokenizer")
local computer = require("computer")

local function chunk_reader(s)
  local pos = 1
  return function()
    if pos > #s then
      return nil
    end
    local c = s:sub(pos, pos + 4095)
    pos = pos + 4096
    return c
  end
end

-- f1, f2, f3: inputs that once took quadratic time or too much memory. Each
-- row must finish (the time bound is far above the linear time) and give the
-- right text. The title keeps at most 256 bytes (spec/layout.md "Title").

local function repeated(piece, count)
  return string.rep(piece, count)
end

local function x_lines(width, count)
  local lines = {}
  for i = 1, count do
    lines[i] = string.rep("x", width)
  end
  return lines
end

local TIME_LIMIT = 20

t.cases(T, "pathological_inputs_finish_with_the_right_text", {
  { "f1a: 150000 broken quotes", repeated("<a x='>", 150000),
    { lines = {}, title = "" } },
  { "f1b: 64 tags with 2600 broken quotes each",
    repeated("<a" .. string.rep(" x='>'", 2600) .. ">", 64),
    { lines = {}, title = "" } },
  { "f2: a word of 20000 pieces is split at the width",
    repeated("<i>x</i>", 20000), { lines = x_lines(80, 250), title = "" } },
  { "f3: a huge title is cut at 256 bytes",
    "<title>" .. string.rep("a ", 140000) .. "</title>",
    { lines = {}, title = string.rep("a ", 128) } },
}, function(input)
  local started = os.clock()
  local lines, title = html.render(chunk_reader(input), 80)
  if os.clock() - started > TIME_LIMIT then
    error("took over " .. TIME_LIMIT .. " s of CPU time")
  end
  local plain = {}
  for i, line in ipairs(lines) do
    plain[i] = (line:gsub("[\1-\5]", ""))
  end
  return { lines = plain, title = title or "" }
end)

-- f6: the print output loop has no memory check (spec/cli.md "Print output
-- loop"). The free memory drops under the reserve when the first line is
-- written. Every line is still written and the exit code is 0.
function T.f6_print_mode_does_not_stop_on_memory()
  local count = 0
  local errs = {}
  local code = html.main({ "--print", "page.html", n = 2 }, {
    out = function()
      count = count + 1
      computer.test.set_free(100 * 1024)
    end,
    err = function(line) errs[#errs + 1] = line end,
    width = 50,
    open = function()
      local text = string.rep("<p>word word word word word</p>\n", 1000)
      local pos = 1
      return {
        read = function(_, n)
          if pos > #text then
            return nil
          end
          local c = text:sub(pos, pos + n - 1)
          pos = pos + n
          return c
        end,
        seek = function() return #text end,
        close = function() end,
      }
    end,
    traceback = function(m) return m end,
    clock = os.clock,
  })
  t.eq(errs, {})
  t.eq(code, 0)
  t.eq(count, 1000)
end

-- f7: a failing module load gives one controlled line, exit code 1
-- (spec/errors.md "Controlled and unexpected errors"). raised is what
-- require raises, or nil for game_deps in the sandbox, which has no OpenOS
-- modules.
t.cases(T, "f7_loader_failures_give_one_controlled_line", {
  { "game_deps in the sandbox", { game_deps = true },
    { raw = false, code = 1 } },
  { "a table raised", { raised = { code = 1 } },
    { raw = false, code = 1, lines = 1, prefix = "html: ", one_line = true } },
  { "a table with a failing tostring", { raised = setmetatable({}, {
    __tostring = function() error("boom", 0) end }) },
    { raw = false, code = 1, lines = 1, prefix = "html: ", one_line = true } },
  { "out of memory", { raised = "not enough memory" },
    { raw = false, code = 1, lines = 1, prefix = "html: ", one_line = true,
      has_reason = true } },
}, function(input)
  local err = {}
  local get_deps = html.game_deps
  local fresh = t.load_bin("html")({})
  local real_require = require
  if input.raised ~= nil then
    _G.require = function() error(input.raised, 0) end
    get_deps = function()
      return { err = function(l) err[#err + 1] = l end, out = print,
        home = "/home" }
    end
  end
  local ok, code = pcall(fresh.run_program, { "page.html" }, get_deps, {})
  _G.require = real_require
  if not ok then
    return { raw = true, code = code }
  end
  if input.game_deps then
    return { raw = false, code = code }
  end
  local first = err[1] or ""
  return {
    raw = false,
    code = code,
    lines = #err,
    prefix = first:sub(1, 6),
    one_line = not first:find("\n"),
    has_reason = input.raised == "not enough memory"
      and first:find("not enough memory", 1, true) ~= nil or nil,
  }
end)

-- f11a: empty reads end normally (spec/fetch.md "Stream into the pipeline":
-- an empty chunk is not the end and does not loop).
function T.f11a_empty_reads_end_normally()
  local calls, empties = 0, 0
  local function read()
    calls = calls + 1
    if calls > 10000 then
      error("reader called over 10000 times")
    end
    if empties < 100 then
      empties = empties + 1
      return ""
    end
    return nil
  end
  local next_token = tokenizer.new(read)
  while next_token() do
    t.ok(false, "no token expected")
  end
  t.eq(calls, 101)
end

return T
