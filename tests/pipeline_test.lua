-- End-to-end tests for bin/html.lua: file to plain text.

local t = require("test")
local computer = require("computer")

local T = {}

local html = t.load_bin("html")({})

-- The expected-output comparison from tasks/plan.md: removes "\r",
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

-- Runs main and returns the exit code, stdout lines and stderr lines.
local function main(args, extra)
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
    log = function(text) logged = text end,
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
    "free_after", "delta", "lowest_free", "peak_used" })
  t.eq(err[1], "stats: file=" .. #read_file("tests/cases/basic.html")
    .. " bytes")
  t.eq(err[2], "stats: width=40")
  t.eq(err[3], "stats: lines=" .. #out)
  t.ok(err[9]:find("^stats: lowest_free=%d+ bytes$"), err[9])
  t.ok(err[10]:find("^stats: peak_used=%-?%d+ bytes %([%d.%-]+ per line%)$"),
    err[10])
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
  computer.freeMemory = function()
    reads = reads + 1
    if reads > 4 then
      return 100 * 1024
    end
    return real_free()
  end
  local ok, code, out, err = pcall(main, { "--stats-out", "s.txt",
    "tests/cases/basic.html" }, {
      write_file = function(_, text) written = text return true end,
    })
  computer.freeMemory = real_free
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

return T
