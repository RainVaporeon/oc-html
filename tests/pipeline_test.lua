-- End-to-end tests for bin/html.lua with real files: arguments, file errors,
-- the case files, file writes, "~" and the module cache. Each table row is
-- one scenario. tests/entry_test.lua covers the viewer mode and the URL
-- paths, tests/corpus_test.lua the case files in every mode.

local t = require("test")
local computer = require("computer")

local T = {}

local html = t.load_bin("html")({})

-- The expected-output comparison from tasks/archive/mvp-plan.md: removes "\r",
-- trailing spaces and tabs, and blank lines at the end.
local function normalize(s)
  local lines = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line:gsub("\r", ""):gsub("[ \t]+$", "")
  end
  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
  end
  return table.concat(lines, "\n")
end

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("a")
  f:close()
  return s
end

-- Runs main and returns the exit code, stdout lines and stderr lines. There
-- is no GPU, so the program prints (the maximum --width is 160).
local function call(args, extra)
  local out, err = {}, {}
  local deps = {
    out = function(line) out[#out + 1] = line end,
    err = function(line) err[#err + 1] = line end,
    width = 40,
    open = io.open,
    traceback = function(msg) return msg .. "\nstack traceback: (fake)" end,
    clock = os.clock,
  }
  for k, v in pairs(extra or {}) do
    deps[k] = v
  end
  args.n = #args
  local code = html.main(args, deps)
  return code, out, err
end

-- Arguments (spec/cli.md "Usage") ---------------------------------------------

local WIDTH_ERROR = "html: --width needs a whole number from 2 to 160"
  .. " (see html --help)"

t.cases(T, "cli_arguments", {
  { "--help", { "--help" }, { code = 0, out = { html.USAGE }, err = {} } },
  { "no arguments", {}, { code = 0, out = { html.USAGE }, err = {} } },
  { "unknown option", { "--nope" },
    { code = 2, out = {}, err = { "html: unknown option: --nope"
      .. " (see html --help)" } } },
  { "--stats is not an option", { "--stats", "a.html" },
    { code = 2, out = {}, err = { "html: unknown option: --stats"
      .. " (see html --help)" } } },
  { "--stats-out is not an option", { "--stats-out", "s.txt", "a.html" },
    { code = 2, out = {}, err = { "html: unknown option: --stats-out"
      .. " (see html --help)" } } },
  { "two files", { "a", "b" },
    { code = 2, out = {}, err = { "html: too many arguments"
      .. " (see html --help)" } } },
  { "--width with text", { "--width", "x", "a.html" },
    { code = 2, out = {}, err = { WIDTH_ERROR } } },
  { "--width without a value", { "a.html", "--width" },
    { code = 2, out = {}, err = { WIDTH_ERROR } } },
  { "--width 0", { "--width", "0", "a.html" },
    { code = 2, out = {}, err = { WIDTH_ERROR } } },
  { "--width above the no-screen maximum", { "--width", "161", "a.html" },
    { code = 2, out = {}, err = { WIDTH_ERROR } } },
  { "--width far above the maximum",
    { "--width", "9223372036854775807", "a.html" },
    { code = 2, out = {}, err = { WIDTH_ERROR } } },
}, function(args)
  local code, out, err = call(args)
  return { code = code, out = out, err = err }
end)

t.cases(T, "usage_text", {
  { "--print", "--print", true },
  { "--width", "--width", true },
  { "--no-rescale", "--no-rescale", true },
  { "--help", "--help", true },
  { "http:// form", "http://", true },
  { "https:// form", "https://", true },
  { "--stats was removed", "--stats", false },
  { "--stats-out was removed", "--stats-out", false },
}, function(word)
  return html.USAGE:find(word, 1, true) ~= nil
end)

-- File errors with the real io.open (spec/cli.md "Local files") ----------------

t.cases(T, "file_errors", {
  { "missing file: the only message is file not found",
    { args = { "tests/cases/missing.html" } },
    { code = 1, out = {}, err = { "html: file not found: "
      .. "tests/cases/missing.html" } } },
  { "directory",
    { args = { "tests/cases" }, deps = { is_dir = function() return true end } },
    { code = 1, out = {}, err = { "html: not a file: tests/cases" } } },
  { "low memory stops with the controlled message",
    { args = { "tests/cases/basic.html" }, free = 100 * 1024 },
    { code = 1, out = {}, err = { "html: page too large for available memory "
      .. "(rendered N lines before stopping)" } } },
}, function(input)
  if input.free then
    computer.test.set_free(input.free)
  end
  local args = { "--print", table.unpack(input.args) }
  local code, out, err = call(args, input.deps)
  computer.test.reset()
  for i, line in ipairs(err) do
    err[i] = line:gsub("%d+", "N")
  end
  return { code = code, out = out, err = err }
end)

-- The case files through the real io.open ---------------------------------------
-- --width 41 gives the layout width 40 that the case files use.

local case_rows = {}
for _, name in ipairs(t.list_cases()) do
  case_rows[#case_rows + 1] = { name, name,
    { code = 0, err = {}, text = normalize(read_file("tests/cases/" .. name
      .. ".txt")) } }
end

t.cases(T, "case_files_match_expected_text", case_rows, function(name)
  local code, out, err = call({ "--width", "41", "tests/cases/" .. name
    .. ".html" })
  return { code = code, err = err, text = normalize(table.concat(out, "\n")) }
end)

-- File writes (spec/errors.md "File writes") ------------------------------------
-- plan[step] is "fail" (nil and a reason) or "raise". Returns the result and
-- the calls made.

local function writer(plan, calls)
  local f = {}
  for _, name in ipairs({ "write", "flush", "close" }) do
    f[name] = function(self)
      calls[#calls + 1] = name
      if plan[name] == "fail" then
        return nil, "not enough space"
      end
      if plan[name] == "raise" then
        error(name .. " boom", 0)
      end
      -- OpenOS close returns no values on success.
      if name == "close" then
        return
      end
      return self
    end
  end
  return f
end

local ALL = { "write", "flush", "close" }

t.cases(T, "write_text", {
  { "success; close returns no values", {},
    { ok = true, calls = ALL } },
  { "write fails", { write = "fail" },
    { why = "not enough space", calls = { "write", "close" } } },
  { "flush fails", { flush = "fail" },
    { why = "not enough space", calls = ALL } },
  { "close fails with a reason", { close = "fail" },
    { why = "not enough space", calls = ALL } },
  { "write raises", { write = "raise" },
    { why = "write boom", calls = { "write", "close" } } },
  { "flush raises", { flush = "raise" },
    { why = "flush boom", calls = ALL } },
  { "close raises", { close = "raise" },
    { why = "close boom", calls = ALL } },
  { "open fails", { open = "fail" },
    { why = "no such dir", calls = {} } },
}, function(plan)
  local calls = {}
  local ok, why = html.write_text(function()
    if plan.open then
      return nil, "no such dir"
    end
    return writer(plan, calls)
  end, "/tmp/x", "text")
  return { ok = ok, why = why, calls = calls }
end)

-- "~" (spec/cli.md "Home directory") --------------------------------------------

t.cases(T, "expand_home", {
  { "bare ~", { "~", "/home" }, "/home" },
  { "~/ and home", { "~/a.html", "/home" }, "/home/a.html" },
  { "home with a trailing slash", { "~/a.html", "/home/" }, "/home/a.html" },
  { "no home: /home", { "~/a.html", nil }, "/home/a.html" },
  { "empty home: /home", { "~/a.html", "" }, "/home/a.html" },
  { "another home", { "~/x", "/usr/me" }, "/usr/me/x" },
  { "not leading", { "a/~/b", "/home" }, "a/~/b" },
  { "no user form", { "~user/a", "/home" }, "~user/a" },
  { "absolute path", { "/abs.html", "/home" }, "/abs.html" },
}, function(input)
  return html.expand_home(input[1], input[2])
end)

function T.file_expands_home_before_resolve()
  local resolved, opened = {}, nil
  call({ "--print", "~/page.html" }, {
    home = "/home/me",
    resolve = function(p) resolved[#resolved + 1] = p return p end,
    open = function(p, mode)
      opened = p
      return io.open("tests/cases/basic.html", mode)
    end,
  })
  t.eq(opened, "/home/me/page.html")
  t.eq(resolved, { "/home/me/page.html" })
end

-- Module cache (spec/pipeline.md "Module loading") ------------------------------

-- A fake package.loaded with html modules and other modules.
local function fake_loaded()
  return {
    ["html.guard"] = {}, ["html.layout"] = {}, ["html."] = true,
    html = {}, ["htmlx.a"] = {}, computer = {}, [1] = "html.x",
  }
end

local KEPT = { "1", "computer", "html", "htmlx.a" }

local function loaded_names(loaded)
  local names = {}
  for k in pairs(loaded) do
    names[#names + 1] = tostring(k)
  end
  table.sort(names)
  return names
end

local function gpu()
  return {
    getScreen = function() return "screen" end,
    maxResolution = function() return 60, 20 end,
    getResolution = function() return 40, 10 end,
  }
end

-- Runs run_program for one scenario: args, view, exists, and get_deps_error
-- (the error that get_deps raises).
local function program(input)
  local loaded = fake_loaded()
  local ok, code = pcall(html.run_program, input.args, function()
    if input.get_deps_error then
      error(input.get_deps_error, 0)
    end
    loaded["html.guard"] = {}
    return {
      out = function() end, err = function() end, width = 50,
      open = function(_, mode) return io.open("tests/cases/basic.html", mode) end,
      traceback = function(msg) return msg end, clock = os.clock,
      gpu = gpu(),
      view = input.view or function() return "quit" end,
      exists = input.exists,
      on_interrupt = function() return function() end end,
    }
  end, loaded)
  return { ok = ok, code = code, left = loaded_names(loaded) }
end

t.cases(T, "module_cache_cleared_on_every_path", {
  { "normal exit", { args = { "page.html" } },
    { ok = true, code = 0, left = KEPT } },
  { "--help", { args = { "--help" } }, { ok = true, code = 0, left = KEPT } },
  { "Ctrl+C in the viewer", { args = { "page.html" },
    view = function() return "interrupted" end },
    { ok = true, code = 130, left = KEPT } },
  { "unexpected error", { args = { "page.html" },
    view = function() error("boom") end },
    { ok = true, code = 1, left = KEPT } },
  { "missing file", { args = { "nope.html" },
    exists = function() return false end },
    { ok = true, code = 1, left = KEPT } },
  { "usage error", { args = { "--bad" } },
    { ok = true, code = 2, left = KEPT } },
  { "an error raised out of get_deps is raised again",
    { args = { "x.html" }, get_deps_error = "interrupted" },
    { ok = false, code = "interrupted", left = KEPT } },
}, program)

function T.clear_modules_removes_only_html_modules()
  local loaded = fake_loaded()
  t.eq(html.clear_modules(loaded), 3)
  t.eq(loaded_names(loaded), KEPT)
  t.eq(html.clear_modules(nil), 0)
end

function T.chunk_clears_package_loaded_before_require()
  local loaded = fake_loaded()
  rawset(_G, "package", { loaded = loaded })
  local ok, M = pcall(t.load_bin("html"), {})
  rawset(_G, "package", nil)
  t.ok(ok, M)
  t.eq(type(M.main), "function")
  t.eq(loaded_names(loaded), KEPT)
end

return T
