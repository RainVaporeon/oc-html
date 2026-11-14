-- End-to-end tests for bin/html.lua: file to plain text.

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

-- Runs main in print mode and returns the exit code, stdout lines and
-- stderr lines. tests/entry_test.lua covers the viewer mode.
local function main(args, extra)
  table.insert(args, 1, "--print")
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

function T.basic_case_matches_expected_text()
  local code, out, err = main({ "tests/cases/basic.html" })
  t.eq(code, 0)
  t.eq(err, {})
  t.eq(normalize(table.concat(out, "\n")),
    normalize(read_file("tests/cases/basic.txt")))
end

function T.basic_case_same_at_small_chunks()
  local doc = read_file("tests/cases/basic.html")
  local function render(size)
    local i = 1
    return html.render(function()
      if i > #doc then
        return nil
      end
      local chunk = doc:sub(i, i + size - 1)
      i = i + size
      return chunk
    end, 40)
  end
  local expected = render(4096)
  for size = 1, 8 do
    t.eq(render(size), expected, "chunk size " .. size)
  end
end

function T.width_option()
  local code, out = main({ "--width", "20", "tests/cases/basic.html" })
  t.eq(code, 0)
  for _, line in ipairs(out) do
    t.ok(require("unicode").wlen(line) <= 20, line)
  end
end

function T.help_and_no_arguments_show_usage()
  local code, out = main({ "--help" })
  t.eq(code, 0)
  t.eq(out, { html.USAGE })
  code, out = main({})
  t.eq(code, 0)
  t.eq(out, { html.USAGE })
end

function T.bad_arguments_give_one_line()
  for _, args in ipairs({ { "--nope" }, { "a", "b" }, { "--width", "x" },
      { "--width" } }) do
    local code, out, err = main(args)
    t.eq(code, 2)
    t.eq(out, {})
    t.eq(#err, 1)
    t.ok(err[1]:find("^html: "), err[1])
  end
end

function T.missing_file_gives_one_line()
  local code, out, err = main({ "tests/cases/missing.html" })
  t.eq(code, 1)
  t.eq(out, {})
  t.eq(err, { "html: cannot open file: tests/cases/missing.html" })
end

function T.directory_gives_one_line()
  local code, _, err = main({ "tests/cases" },
    { is_dir = function() return true end })
  t.eq(code, 1)
  t.eq(err, { "html: not a file: tests/cases" })
end

function T.low_memory_gives_controlled_message()
  computer.test.set_free(100 * 1024)
  local code, out, err = main({ "tests/cases/basic.html" })
  t.eq(code, 1)
  t.eq(out, {})
  t.eq(#err, 1)
  t.ok(err[1]:find("^html: page too large for available memory"), err[1])
end

function T.unexpected_error_gives_one_line_and_log()
  local logged
  local fake_file = {
    read = function() error("boom") end,
    seek = function() return 10 end,
    close = function() end,
  }
  local code, out, err = main({ "x.html" }, {
    open = function() return fake_file end,
    log = function(text) logged = text return true end,
  })
  t.eq(code, 1)
  t.eq(out, {})
  t.eq(#err, 1)
  t.ok(err[1]:find("^html: unexpected error: .*boom"), err[1])
  t.ok(not err[1]:find("\n"), "one line")
  t.ok(logged:find("stack traceback"), "traceback logged")
end

function T.stats_output()
  local code, out, err = main({ "--stats", "tests/cases/basic.html" },
    { uptime = function() return 0 end })
  t.eq(code, 0)
  t.ok(#out > 0)
  local keys = {}
  for _, line in ipairs(err) do
    local key = line:match("^stats: ([%w_]+)=")
    t.ok(key, line)
    keys[#keys + 1] = key
  end
  t.eq(keys, { "file", "width", "lines", "cpu", "wall", "free_before",
    "free_after", "delta", "lowest_free", "peak_used", "settles", "trace" })
  t.eq(err[1], "stats: file=" .. #read_file("tests/cases/basic.html")
    .. " bytes")
  t.eq(err[2], "stats: width=40")
  t.eq(err[3], "stats: lines=" .. #out)
  t.ok(err[9]:find("^stats: lowest_free=%d+ bytes$"), err[9])
  t.ok(err[10]:find("^stats: peak_used=%-?%d+ bytes %([%d.%-]+ per line%)$"),
    err[10])
  t.ok(err[11]:find("^stats: settles=%d+ gc_seen=%d+ settle_yields=%d+$"),
    err[11])
  t.ok(err[12]:find("^stats: trace=%d+:%d+[sS]?[,%dsS:]*$"), err[12])
  t.ok(#err[12] < 1000, "trace line length " .. #err[12])
end

-- Returns the value of one stats key as a number.
local function stat(err, key)
  for _, line in ipairs(err) do
    local v = line:match("^stats: " .. key .. "=(%-?%d+)")
    if v then
      return tonumber(v)
    end
  end
end

function T.stats_peak_used_from_lowest_reading()
  -- The shim gives a fixed free value, so a jitter reading every 5th call
  -- is the lowest reading during the render.
  computer.test.set_jitter(50000, 5)
  local code, _, err = main({ "--stats", "tests/cases/basic.html" })
  t.eq(code, 0)
  local before, lowest = stat(err, "free_before"), stat(err, "lowest_free")
  t.eq(before, 1800000)
  t.eq(lowest, 1750000)
  t.eq(stat(err, "peak_used"), before - lowest)
end

function T.stats_width_never_empty()
  local code, _, err = main({ "--stats", "tests/cases/basic.html" },
    { width = false })
  t.eq(code, 0)
  t.eq(err[2], "stats: width=80")
end

function T.stats_out_writes_same_lines()
  local written = {}
  local code, out, err = main({ "--stats-out", "s.txt",
    "tests/cases/basic.html" }, {
      write_file = function(path, text)
        written[#written + 1] = { path, text }
        return true
      end,
    })
  t.eq(code, 0)
  t.ok(#out > 0, "page printed")
  t.eq(#written, 1)
  t.eq(written[1][1], "s.txt")
  t.eq(written[1][2], table.concat(err, "\n") .. "\n")
  t.ok(err[1]:find("^stats: file="), err[1])
end

function T.stats_out_uses_resolved_path()
  local got
  main({ "--stats-out", "s.txt", "tests/cases/basic.html" }, {
    resolve = function(p) return p == "s.txt" and "/home/s.txt" or p end,
    write_file = function(path) got = path return true end,
  })
  t.eq(got, "/home/s.txt")
end

function T.stats_out_write_failure_gives_one_line()
  for _, writer in ipairs({
    function() return nil, "disk full" end,
    function() error("boom\nsecond line") end,
    false,
  }) do
    local code, out, err = main({ "--stats-out", "s.txt",
      "tests/cases/basic.html" }, { write_file = writer })
    t.eq(code, 1)
    t.ok(#out > 0, "page still printed")
    local errors = {}
    for _, line in ipairs(err) do
      if line:find("^html: ") then
        errors[#errors + 1] = line
      else
        t.ok(line:find("^stats: "), line)
      end
    end
    t.eq(#errors, 1)
    t.ok(errors[1]:find("^html: cannot write stats file: s%.txt %(.+%)$"),
      errors[1])
    t.eq(err[#err], errors[1], "error after the stats lines")
  end
end

function T.unexpected_error_log_failure_gives_one_line()
  local fake_file = {
    read = function() error("boom") end,
    seek = function() return 10 end,
    close = function() end,
  }
  for _, log in ipairs({
    function() return nil, "not enough space" end,
    function() error("log boom\nsecond line") end,
  }) do
    local code, out, err = main({ "x.html" }, {
      open = function() return fake_file end,
      log = log,
    })
    t.eq(code, 1)
    t.eq(out, {})
    t.eq(#err, 1)
    t.ok(err[1]:find("^html: unexpected error: .*boom %(cannot write "
      .. "/tmp/html%-error%.log: .+%)$"), err[1])
  end
end

-- A fake file. fail names the call that fails: "write", "flush" or "close".
local function fake_writer(fail, calls)
  local f = {}
  local function step(name)
    return function(self)
      calls[#calls + 1] = name
      if name == fail then
        return nil, "not enough space"
      end
      -- OpenOS close returns no values on success.
      if name == "close" then
        return
      end
      return self
    end
  end
  f.write, f.flush, f.close = step("write"), step("flush"), step("close")
  return f
end

function T.write_text_checks_write_flush_and_close()
  for _, fail in ipairs({ "write", "flush", "close" }) do
    local calls = {}
    local done, why = html.write_text(function()
      return fake_writer(fail, calls)
    end, "/tmp/x", "text")
    t.eq(done, nil, fail)
    t.eq(why, "not enough space", fail)
    t.eq(calls[#calls], "close", "always closed after " .. fail)
  end
  local calls = {}
  t.eq(html.write_text(function() return fake_writer(nil, calls) end,
    "/tmp/x", "text"), true)
  t.eq(calls, { "write", "flush", "close" })
  t.eq({ html.write_text(function() return nil, "no such dir" end,
    "/x/y", "") }, { nil, "no such dir" })
end

function T.stats_out_flush_failure_gives_one_line()
  local code, _, err = main({ "--stats-out", "/tmp/s.txt",
    "tests/cases/basic.html" }, {
      write_file = function(path, text)
        return html.write_text(function()
          return fake_writer("flush", {})
        end, path, text)
      end,
    })
  t.eq(code, 1)
  t.eq(err[#err], "html: cannot write stats file: /tmp/s.txt "
    .. "(not enough space)")
end

function T.expand_home_rules()
  t.eq(html.expand_home("~", "/home"), "/home")
  t.eq(html.expand_home("~/a.html", "/home"), "/home/a.html")
  t.eq(html.expand_home("~/a.html", "/home/"), "/home/a.html")
  t.eq(html.expand_home("~/a.html", nil), "/home/a.html", "default home")
  t.eq(html.expand_home("~/a.html", ""), "/home/a.html", "empty home")
  t.eq(html.expand_home("~/x", "/usr/me"), "/usr/me/x")
  t.eq(html.expand_home("a/~/b", "/home"), "a/~/b", "not leading")
  t.eq(html.expand_home("~user/a", "/home"), "~user/a", "no user form")
  t.eq(html.expand_home("/abs.html", "/home"), "/abs.html")
end

function T.file_and_stats_out_expand_home_before_resolve()
  local resolved, opened, got = {}, nil, nil
  main({ "--stats-out", "~/s.txt", "~/page.html" }, {
    home = "/home/me",
    resolve = function(p) resolved[#resolved + 1] = p return p end,
    open = function(p, mode)
      opened = p
      return io.open("tests/cases/basic.html", mode)
    end,
    write_file = function(path) got = path return true end,
  })
  t.eq(opened, "/home/me/page.html")
  t.eq(got, "/home/me/s.txt")
  t.eq(resolved, { "/home/me/page.html", "/home/me/s.txt" })
end

function T.stats_out_needs_a_path()
  local code, _, err = main({ "tests/cases/basic.html", "--stats-out" })
  t.eq(code, 2)
  t.eq(err[1]:sub(1, 36), "html: --stats-out needs a file path ")
end

function T.stats_after_controlled_stop()
  local written
  -- Free memory drops below the reserve during the render.
  local reads = 0
  local real_free = computer.freeMemory
  rawset(computer, "freeMemory", function()
    reads = reads + 1
    if reads > 4 then
      return 100 * 1024
    end
    return real_free()
  end)
  local ok, code, out, err = pcall(main, { "--stats-out", "s.txt",
    "tests/cases/basic.html" }, {
      write_file = function(_, text) written = text return true end,
    })
  rawset(computer, "freeMemory", real_free)
  t.ok(ok, code)
  t.eq(code, 1)
  t.eq(out, {})
  t.ok(err[1]:find("^html: page too large for available memory"), err[1])
  t.eq(stat(err, "free_before"), 1800000)
  t.eq(stat(err, "lowest_free"), 100 * 1024)
  t.eq(stat(err, "peak_used"), 1800000 - 100 * 1024)
  t.eq(err[#err], "stats: stopped=" .. err[1])
  t.ok(written and written:find("stats: stopped=html: page too large", 1,
    true), "file has the stop reason")
end

function T.stats_after_stop_trace_ends_with_stop_reading()
  local reads = 0
  local real_free = computer.freeMemory
  rawset(computer, "freeMemory", function()
    reads = reads + 1
    if reads > 4 then
      return 100 * 1024
    end
    return real_free()
  end)
  local ok, code, _, err = pcall(main, { "--stats", "tests/cases/basic.html" })
  rawset(computer, "freeMemory", real_free)
  t.ok(ok, code)
  local trace
  for _, line in ipairs(err) do
    trace = trace or line:match("^stats: trace=(.*)$")
  end
  t.ok(trace and trace:find(":" .. 100 * 1024 .. "s$"), tostring(trace))
end

-- The 0.0.2a crash: a guard module from 0.0.1a has no lowest_free.
function T.stats_with_old_guard_module_print_na()
  local guard = require("html.guard")
  local saved_lowest, saved_trace = guard.lowest_free, guard.trace_text
  guard.lowest_free, guard.trace_text = nil, nil
  local ok, code, out, err = pcall(main, { "--stats", "tests/cases/basic.html" })
  guard.lowest_free, guard.trace_text = saved_lowest, saved_trace
  t.ok(ok, code)
  t.eq(code, 0)
  t.ok(#out > 0)
  t.eq(stat(err, "lowest_free"), stat(err, "free_after"),
    "falls back to free_after")
  t.ok(err[#err] == "stats: trace=n/a", err[#err])
end

function T.stats_with_failing_guard_function_print_na()
  local guard = require("html.guard")
  local saved = guard.trace_text
  rawset(guard, "trace_text", function() error("broken") end)
  local ok, code, _, err = pcall(main, { "--stats", "tests/cases/basic.html" })
  guard.trace_text = saved
  t.ok(ok, code)
  t.eq(code, 0)
  t.eq(err[#err], "stats: trace=n/a")
end

function T.stats_lines_print_na_for_missing_values()
  local lines = html.stats_lines({ lines = 5, wall = "x", free_before = 1000,
    free_after = false }, nil, nil)
  t.eq(lines, {
    "stats: file=n/a",
    "stats: width=n/a",
    "stats: lines=5",
    "stats: cpu=n/a",
    "stats: wall=n/a",
    "stats: free_before=1000 bytes",
    "stats: free_after=n/a",
    "stats: delta=n/a",
    "stats: lowest_free=1000 bytes",
    "stats: peak_used=0 bytes (0.0 per line)",
    "stats: settles=n/a gc_seen=n/a settle_yields=n/a",
    "stats: trace=n/a",
  })
  local stopped = html.stats_lines({ free_before = "x", stopped = "html: x" },
    "y", "")
  t.eq(stopped, {
    "stats: file=n/a",
    "stats: width=n/a",
    "stats: free_before=n/a",
    "stats: lowest_free=n/a",
    "stats: peak_used=n/a",
    "stats: settles=n/a gc_seen=n/a settle_yields=n/a",
    "stats: trace=n/a",
    "stats: stopped=html: x",
  })
end

function T.stats_lines_with_trace()
  local lines = html.stats_lines({ size = 10, width = 40, free_before = 900 },
    800, "1:850,2:800")
  t.eq(lines[#lines], "stats: trace=1:850,2:800")
  t.eq(stat(lines, "peak_used"), 100)
end

function T.stats_lines_with_settle_counts()
  local lines = html.stats_lines({ free_before = 900 }, 800, "",
    { settles = 3, gc_seen = 2, settle_yields = 25 })
  t.eq(lines[#lines - 1], "stats: settles=3 gc_seen=2 settle_yields=25")
end

function T.stats_output_counts_settles_after_render()
  local code, _, err = main({ "--stats", "tests/cases/basic.html" })
  t.eq(code, 0)
  -- The free_after settle counts. The free_before settle is before reset.
  t.eq(stat(err, "settles"), 1)
end

-- A fake package.loaded with html modules and other modules.
local function fake_loaded()
  return {
    ["html.guard"] = {}, ["html.layout"] = {}, ["html."] = true,
    html = {}, ["htmlx.a"] = {}, computer = {}, [1] = "html.x",
  }
end

local function loaded_names(loaded)
  local names = {}
  for k in pairs(loaded) do
    names[#names + 1] = tostring(k)
  end
  table.sort(names)
  return names
end

function T.clear_modules_removes_only_html_modules()
  local loaded = fake_loaded()
  t.eq(html.clear_modules(loaded), 3)
  t.eq(loaded_names(loaded), { "1", "computer", "html", "htmlx.a" })
  t.eq(html.clear_modules(nil), 0)
end

function T.chunk_clears_package_loaded_before_require()
  local loaded = fake_loaded()
  rawset(_G, "package", { loaded = loaded })
  local ok, M = pcall(t.load_bin("html"), {})
  rawset(_G, "package", nil)
  t.ok(ok, M)
  t.eq(type(M.main), "function")
  t.eq(loaded_names(loaded), { "1", "computer", "html", "htmlx.a" })
end

function T.run_program_clears_modules_after_main()
  local loaded = fake_loaded()
  local out = {}
  local code = html.run_program({ "--help", n = 1 }, function()
    loaded["html.guard"] = {}
    return { out = function(line) out[#out + 1] = line end,
      err = function() end }
  end, loaded)
  t.eq(code, 0)
  t.eq(out[1]:sub(1, 6), "Usage:")
  t.eq(loaded_names(loaded), { "1", "computer", "html", "htmlx.a" })
end

function T.run_program_clears_modules_and_raises_on_error()
  local loaded = fake_loaded()
  local ok, err = pcall(html.run_program, { "x.html", n = 1 }, function()
    error("interrupted", 0)
  end, loaded)
  t.eq(ok, false)
  t.eq(err, "interrupted")
  t.eq(loaded_names(loaded), { "1", "computer", "html", "htmlx.a" })
end

return T
