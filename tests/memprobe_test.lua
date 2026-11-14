-- Tests for tools/memprobe.lua with fake machine links.

local t = require("test")

local T = {}

local probe = t.load_tool("memprobe")({})

-- A fake machine. opts: free (bytes), limit (largest string that can be
-- made), loaded, files, fail_write, fail_free.
local function fake(opts)
  opts = opts or {}
  local m = {
    out = {}, err = {}, files = opts.files or {}, sleeps = 0, sizes = {},
    clock = 0,
  }
  m.deps = {
    out = function(line) m.out[#m.out + 1] = line end,
    err = function(line) m.err[#m.err + 1] = line end,
    free = function()
      if opts.fail_free then
        error("no free memory reading")
      end
      return opts.free or 1680000
    end,
    total = function() return 2097152 end,
    uptime = function() return 12.5 end,
    clock = function()
      m.clock = m.clock + 0.001
      return m.clock
    end,
    sleep = function()
      m.sleeps = m.sleeps + 1
      return true
    end,
    random = function() return 0x1234abcd end,
    loaded = opts.loaded,
    make_string = function(n)
      m.sizes[#m.sizes + 1] = n
      if n > (opts.limit or math.huge) then
        error("not enough memory", 0)
      end
      return string.rep("x", math.min(n, 64))
    end,
    read_file = function(path) return m.files[path] end,
    write_file = function(path, text)
      if opts.fail_write then
        return nil, "disk full"
      end
      m.files[path] = text
      return true
    end,
    version = "Lua 5.3",
  }
  return m
end

local function run(m, ...)
  local argv = table.pack(...)
  return probe.main(argv, m.deps)
end

-- The report file as a key-to-value table, and the list of keys in order.
local function parse(text)
  local values, keys = {}, {}
  for line in text:gmatch("[^\n]+") do
    local k, v = line:match("^([%w_.]+)=(.*)$")
    t.ok(k, "line has the section.key=value form: " .. line)
    values[k] = v
    keys[#keys + 1] = k
  end
  return values, keys
end

function T.needs_a_step()
  local m = fake()
  t.eq(run(m), 2)
  t.ok(m.err[1]:find("^memprobe: %-%-step 1 or %-%-step 2 is needed"), m.err[1])
  t.eq(run(fake(), "--step", "3"), 2)
  t.eq(run(fake(), "--step", "1", "--out"), 2)
  t.eq(run(fake(), "--bad"), 2)
end

function T.help()
  local m = fake()
  t.eq(run(m, "--help"), 0)
  t.ok(m.out[1]:find("^Usage: memprobe"), m.out[1])
end

function T.step1_then_step2_finds_the_marker()
  local loaded = { ["html.guard"] = {} }
  local m = fake({ loaded = loaded })
  t.eq(run(m, "--step", "1"), 0)
  t.ok(loaded[probe.MARKER], "marker stored")
  local v1 = parse(m.files[probe.DEFAULT_OUT])
  t.eq(v1["memprobe.step"], "1")
  t.eq(v1["h1.step1.token"], "1234abcd")
  t.eq(v1["h1.step1.marker_set"], "true")
  t.eq(v1["h1.step1.html_modules"], "1")
  t.ok(m.out[#m.out]:find("memprobe %-%-step 2"), m.out[#m.out])
  t.ok(m.out[#m.out]:find("Do not reboot"), m.out[#m.out])

  t.eq(run(m, "--step", "2"), 0)
  local v2, keys = parse(m.files[probe.DEFAULT_OUT])
  t.eq(keys[1]:sub(1, 9), "h1.step1.", "step 1 lines kept first")
  t.eq(v2["h1.step1.token"], "1234abcd")
  t.eq(v2["memprobe.step"], "2")
  t.eq(v2["h1.step2.step1_found"], "true")
  t.eq(v2["h1.step2.marker_present"], "true")
  t.eq(v2["h1.step2.token_match"], "true")
  t.eq(v2["h1.step2.same_loaded_table"], "true")
  t.eq(v2["h1.step2.marker_removed"], "true")
  t.eq(v2["h1.result"], "kept")
  t.eq(loaded[probe.MARKER], nil, "marker removed")
end

function T.step2_after_reboot_reports_not_kept()
  local m = fake({ loaded = {} })
  t.eq(run(m, "--step", "1"), 0)
  m.deps.loaded = {}
  t.eq(run(m, "--step", "2"), 0)
  local v = parse(m.files[probe.DEFAULT_OUT])
  t.eq(v["h1.step2.marker_present"], "false")
  t.eq(v["h1.step2.same_loaded_table"], "false")
  t.eq(v["h1.result"], "not_kept")
end

function T.step2_without_step1_file()
  local m = fake({ loaded = {} })
  t.eq(run(m, "--step", "2", "--out", "/home/x.txt"), 0)
  local v = parse(m.files["/home/x.txt"])
  t.eq(v["h1.step2.step1_found"], "false")
  t.eq(v["h1.result"], "not_kept")
end

function T.step2_without_package_loaded()
  local m = fake()
  t.eq(run(m, "--step", "2"), 0)
  t.eq(parse(m.files[probe.DEFAULT_OUT])["h1.result"], "unknown")
end

function T.h2_tries_two_sizes_above_free_memory()
  local m = fake({ loaded = {}, free = 1000000 })
  t.eq(run(m, "--step", "2"), 0)
  local v = parse(m.files[probe.DEFAULT_OUT])
  t.eq(v["h2.try1.size"], tostring(1000000 + 64 * 1024))
  t.eq(v["h2.try2.size"], tostring(1000000 + 256 * 1024))
  t.eq(v["h2.try1.ok"], "true")
  t.eq(v["h2.try1.len"], "64")
  t.eq(v["h2.try1.free_holding"], "1000000")
  t.eq(v["h2.try1.free_dropped"], "1000000")
  t.eq(v["h2.try1.garbage_pieces"], "600")
  t.eq(v["h2.try1.garbage_free_holding"], "1000000")
  t.eq(v["h2.try2.garbage_free_dropped"], "1000000")
  t.ok(v["h2.try1.cpu_s"]:find("^%d+%.%d%d%d$"), v["h2.try1.cpu_s"])
  -- 600 garbage pieces of 1 KB before each try.
  local pieces = 0
  for _, n in ipairs(m.sizes) do
    if n == 1024 then
      pieces = pieces + 1
    end
  end
  t.eq(pieces, 2 * 600)
end

function T.h2_records_a_failed_allocation()
  local m = fake({ loaded = {}, free = 1000000, limit = 1100000 })
  t.eq(run(m, "--step", "2"), 0)
  local v = parse(m.files[probe.DEFAULT_OUT])
  t.eq(v["h2.try1.ok"], "true")
  t.eq(v["h2.try2.ok"], "false")
  t.eq(v["h2.try2.error"], "not enough memory")
  t.eq(v["h2.try2.free_holding"], nil)
  t.eq(v["h2.try2.free_dropped"], "1000000")
end

function T.h2_reads_free_memory_over_20_yields()
  local m = fake({ loaded = {} })
  t.eq(run(m, "--step", "2"), 0)
  local v = parse(m.files[probe.DEFAULT_OUT])
  local n = 0
  for x in v["h2.after_yields"]:gmatch("[^,]+") do
    t.eq(x, "1680000")
    n = n + 1
  end
  t.eq(n, 20)
  t.ok(m.sleeps >= 20 + 2, "yields between the steps: " .. m.sleeps)
end

function T.errors_are_recorded_not_raised()
  local m = fake({ loaded = {}, fail_free = true })
  t.eq(run(m, "--step", "2"), 0)
  local v = parse(m.files[probe.DEFAULT_OUT])
  t.ok(v["h2.free_start"]:find("^ERR "), v["h2.free_start"])
  t.ok(v["h2.try1.free_before"]:find("^ERR "), v["h2.try1.free_before"])
  t.eq(v["h1.result"], "not_kept", "H1 still ran")
end

function T.interrupt_stops_the_run_and_writes_the_report()
  local m = fake({ loaded = {} })
  m.deps.sleep = function() error("interrupted", 0) end
  t.eq(run(m, "--step", "2"), 1)
  local v = parse(m.files[probe.DEFAULT_OUT])
  t.eq(v["memprobe.error"], "interrupted")
  t.eq(v["h1.result"], "not_kept")
end

function T.values_are_one_short_line()
  local m = fake({ loaded = {}, limit = 0 })
  m.deps.make_string = function()
    error("first line\nsecond line " .. string.rep("y", 500), 0)
  end
  t.eq(run(m, "--step", "2"), 0)
  local text = m.files[probe.DEFAULT_OUT]
  t.ok(not text:find("second line", 1, true), "only the first line kept")
  for line in text:gmatch("[^\n]+") do
    t.ok(#line < 260, "line length " .. #line)
  end
end

function T.write_failure_prints_the_report()
  local m = fake({ loaded = {}, fail_write = true })
  t.eq(run(m, "--step", "1"), 1)
  t.ok(m.out[1]:find("^memprobe%.version=1$"), m.out[1])
  t.eq(m.err[1], "memprobe: cannot write /home/memprobe.txt (disk full)")
end

return T
