-- memprobe: in-game memory experiments for oc-html (Task 3c).
-- Usage: memprobe --step 1|2 [--out PATH]
-- Step 1 stores a marker module in package.loaded and exits. Step 2 runs
-- right after it, without a reboot. It checks the marker (H1), then tries
-- allocations that are larger than freeMemory() after garbage was made (H2).
-- The report has one "section.key=value" line per fact.
-- Loaded with a table as the first argument, the chunk returns its module
-- table M without running. The tests use this.

local M = {}

M.VERSION = 1
M.DEFAULT_OUT = "/home/memprobe.txt"
M.MARKER = "memprobe.marker"

M.USAGE = [[
Usage: memprobe --step 1|2 [--out PATH]
  --step 1    store a marker module in package.loaded, then exit
  --step 2    check the marker and run the memory test (run it right after
              step 1, without a reboot)
  --out PATH  report file (default: /home/memprobe.txt)]]

-- About 600 KB of garbage in 1 KB strings. Strings longer than 40 bytes are
-- not interned, so each piece is a separate object.
local GARBAGE_BYTES = 600 * 1024
local GARBAGE_PIECE = 1024
-- Each try asks for freeMemory() plus this many bytes.
local EXTRA = { 64 * 1024, 256 * 1024 }
local AFTER_YIELDS = 20
-- OpenOS kills a program after 5 s without a yield. A part that runs
-- longer than this without a yield is skipped.
local NO_YIELD_LIMIT = 1
local MAX_VALUE = 200

-- Returns an options table, or nil and an error message.
function M.parse_args(argv)
  local opts = { out = M.DEFAULT_OUT }
  local i, count = 1, argv.n or #argv
  while i <= count do
    local a = tostring(argv[i])
    if a == "--help" or a == "-h" then
      opts.help = true
    elseif a == "--step" then
      i = i + 1
      local s = argv[i]
      if s ~= "1" and s ~= "2" then
        return nil, "memprobe: --step needs 1 or 2"
      end
      opts.step = tonumber(s)
    elseif a == "--out" then
      i = i + 1
      local p = argv[i]
      if type(p) ~= "string" or p == "" then
        return nil, "memprobe: --out needs a file path"
      end
      opts.out = p
    else
      return nil, "memprobe: unknown argument: " .. a
    end
    i = i + 1
  end
  if not opts.help and not opts.step then
    return nil, "memprobe: --step 1 or --step 2 is needed"
  end
  return opts
end

-- One line of text, at most MAX_VALUE bytes.
local function value_text(v)
  if math.type(v) == "float" and v == math.floor(v) and v < 2 ^ 53
      and v > -2 ^ 53 then
    v = math.tointeger(v)
  end
  local s = tostring(v):gsub("[\r\n].*$", "")
  if #s > MAX_VALUE then
    s = s:sub(1, MAX_VALUE)
  end
  return s
end

local function new_report()
  local report = { lines = {} }
  function report.add(key, value)
    report.lines[#report.lines + 1] = key .. "=" .. value_text(value)
  end
  return report
end

-- Calls fn in pcall. Returns its first result, or nil and records the error
-- under key. Ctrl+C ("interrupted") still stops the run.
local function try(report, key, fn, ...)
  local ok, v = pcall(fn, ...)
  if ok then
    return v
  end
  if v == "interrupted" then
    error(v, 0)
  end
  report.add(key, "ERR " .. value_text(v))
  return nil
end

-- Records the result of fn under key, or the error.
local function record(report, key, fn, ...)
  local v = try(report, key, fn, ...)
  if v ~= nil then
    report.add(key, v)
  end
  return v
end

local function count_html_modules(loaded)
  local n = 0
  for name in pairs(loaded) do
    if type(name) == "string" and name:sub(1, 5) == "html." then
      n = n + 1
    end
  end
  return n
end

local function step1(report, deps)
  local loaded = deps.loaded
  report.add("h1.step1.loaded_type", type(loaded))
  record(report, "h1.step1.free", deps.free)
  record(report, "h1.step1.uptime", deps.uptime)
  if type(loaded) ~= "table" then
    report.add("h1.step1.marker_set", false)
    return
  end
  report.add("h1.step1.loaded_id", tostring(loaded))
  report.add("h1.step1.html_modules", count_html_modules(loaded))
  local token = string.format("%08x", deps.random(0, 0x7fffffff))
  loaded[M.MARKER] = { token = token }
  report.add("h1.step1.token", token)
  report.add("h1.step1.marker_set", true)
end

-- Returns the step 1 lines and the step 1 values of an earlier report.
local function read_step1(deps, path)
  local text = deps.read_file(path)
  local lines, values = {}, {}
  if type(text) ~= "string" then
    return lines, values
  end
  for line in text:gmatch("[^\n]+") do
    local key, value = line:match("^(h1%.step1%.[%w_]+)=(.*)$")
    if key then
      lines[#lines + 1] = line
      values[key] = value
    end
  end
  return lines, values
end

local function step2_h1(report, deps, values)
  local loaded = deps.loaded
  report.add("h1.step2.step1_found", values["h1.step1.token"] ~= nil)
  report.add("h1.step2.loaded_type", type(loaded))
  if type(loaded) ~= "table" then
    report.add("h1.result", "unknown")
    return
  end
  local id = tostring(loaded)
  report.add("h1.step2.loaded_id", id)
  if values["h1.step1.loaded_id"] then
    report.add("h1.step2.same_loaded_table", values["h1.step1.loaded_id"] == id)
  end
  report.add("h1.step2.html_modules", count_html_modules(loaded))
  local marker = loaded[M.MARKER]
  report.add("h1.step2.marker_present", marker ~= nil)
  if type(marker) == "table" and values["h1.step1.token"] then
    report.add("h1.step2.token_match", marker.token == values["h1.step1.token"])
  end
  loaded[M.MARKER] = nil
  report.add("h1.step2.marker_removed", loaded[M.MARKER] == nil)
  report.add("h1.result", marker ~= nil and "kept" or "not_kept")
end

-- Makes about GARBAGE_BYTES of strings, reads freeMemory() while they are
-- held and after the table is dropped. No yield here: a yield can let the
-- kernel collect the garbage.
local function make_garbage(deps)
  local r = { count = false, holding = false, dropped = false }
  local pieces = {}
  for i = 1, GARBAGE_BYTES // GARBAGE_PIECE do
    pieces[i] = deps.make_string(GARBAGE_PIECE)
  end
  r.count = #pieces
  r.holding = deps.free()
  pieces = nil
  r.dropped = deps.free()
  return r
end

-- Tries to allocate one string of size bytes. The result table exists
-- before the allocation, so the reads while the string is held allocate
-- nothing new.
local function try_alloc(deps, size)
  local r = { ok = false, err = false, len = false, holding = false,
    dropped = false }
  local ok, err = pcall(function()
    local s = deps.make_string(size)
    r.len = #s
    r.holding = deps.free()
    s = nil
  end)
  r.ok = ok
  if not ok then
    r.err = err
  end
  r.dropped = deps.free()
  return r
end

local function step2_h2(report, deps)
  report.add("h2.method", "string.rep")
  report.add("h2.garbage_bytes", GARBAGE_BYTES)
  record(report, "h2.free_start", deps.free)
  for n, extra in ipairs(EXTRA) do
    local key = "h2.try" .. n
    try(report, key .. ".yield", deps.sleep)
    local t0 = deps.clock()
    local g = try(report, key .. ".garbage", make_garbage, deps)
    if g then
      report.add(key .. ".garbage_pieces", g.count)
      report.add(key .. ".garbage_free_holding", g.holding)
      report.add(key .. ".garbage_free_dropped", g.dropped)
    end
    local free = try(report, key .. ".free_before", deps.free)
    if deps.clock() - t0 > NO_YIELD_LIMIT then
      report.add(key .. ".skipped", "no-yield time over " .. NO_YIELD_LIMIT
        .. " s")
    elseif free then
      local size = free + extra
      report.add(key .. ".extra", extra)
      report.add(key .. ".free_before", free)
      report.add(key .. ".size", size)
      local r = try(report, key .. ".alloc", try_alloc, deps, size)
      if r then
        report.add(key .. ".ok", r.ok)
        if r.ok then
          report.add(key .. ".len", r.len)
          report.add(key .. ".free_holding", r.holding)
        else
          report.add(key .. ".error", r.err)
        end
        report.add(key .. ".free_dropped", r.dropped)
      end
      report.add(key .. ".cpu_s", string.format("%.3f", deps.clock() - t0))
    end
  end
  local readings = {}
  for i = 1, AFTER_YIELDS do
    try(report, "h2.after_yields.yield", deps.sleep)
    readings[i] = value_text(try(report, "h2.after_yields.free", deps.free))
  end
  report.add("h2.after_yields", table.concat(readings, ","))
end

local function step2(report, deps, prior)
  record(report, "h1.step2.free", deps.free)
  step2_h1(report, deps, prior)
  try(report, "h2.yield", deps.sleep)
  step2_h2(report, deps)
end

local function write_report(deps, path, lines)
  local text = table.concat(lines, "\n") .. "\n"
  local ok, done, why = pcall(deps.write_file, path, text)
  if ok and done then
    return true
  end
  if not ok then
    why = done
  end
  return false, value_text(why or "unknown reason")
end

-- argv: the program arguments (a table, n is optional).
-- deps: the machine links:
--   out(line), err(line)   print to stdout and stderr
--   free(), total()        computer.freeMemory, computer.totalMemory
--   uptime(), clock()      computer.uptime, os.clock
--   sleep()                os.sleep(0), a yield
--   random(lo, hi)         math.random
--   loaded                 package.loaded, or nil
--   make_string(n)         a new string of n bytes
--   read_file(path)        the content, or nil
--   write_file(path, text) true, or nil and a reason
--   version                _VERSION
-- Returns the exit code.
function M.main(argv, deps)
  local opts, msg = M.parse_args(argv)
  if not opts then
    deps.err(msg .. " (see memprobe --help)")
    return 2
  end
  if opts.help then
    deps.out(M.USAGE)
    return 0
  end
  local report = new_report()
  -- Step 2 keeps the step 1 lines of the report file.
  local prior, values = {}, {}
  if opts.step == 2 then
    local read_ok, p, v = pcall(read_step1, deps, opts.out)
    if read_ok then
      prior, values = p, v
    else
      report.add("h1.step1.read", "ERR " .. value_text(p))
    end
  end
  local ok, e = pcall(function()
    report.add("memprobe.version", M.VERSION)
    report.add("memprobe.step", opts.step)
    report.add("env.lua_version", deps.version)
    record(report, "env.total_memory", deps.total)
    if opts.step == 1 then
      step1(report, deps)
    else
      step2(report, deps, values)
    end
  end)
  if not ok then
    report.add("memprobe.error", e)
  end
  local lines = {}
  for _, line in ipairs(prior) do
    lines[#lines + 1] = line
  end
  for _, line in ipairs(report.lines) do
    lines[#lines + 1] = line
  end
  local written, why = write_report(deps, opts.out, lines)
  if not written then
    for _, line in ipairs(lines) do
      deps.out(line)
    end
    deps.err("memprobe: cannot write " .. opts.out .. " (" .. why .. ")")
    return 1
  end
  deps.out("memprobe: step " .. opts.step .. " done, " .. #lines
    .. " lines in " .. opts.out)
  if opts.step == 1 then
    deps.out("Next: run 'memprobe --step 2" .. (opts.out ~= M.DEFAULT_OUT
      and " --out " .. opts.out or "") .. "' now. Do not reboot first.")
  else
    deps.out("Next: run html with --stats-out as in docs/ingame/task3c.md.")
  end
  return ok and 0 or 1
end

-- The links to OpenOS. Loaded only when the chunk runs as a program.
function M.game_deps()
  local computer = require("computer")
  return {
    out = function(line) io.write(line, "\n") end,
    err = function(line) io.stderr:write(line, "\n") end,
    free = computer.freeMemory,
    total = computer.totalMemory,
    uptime = computer.uptime,
    clock = os.clock,
    sleep = function() os.sleep(0) return true end,
    random = math.random,
    loaded = type(package) == "table" and package.loaded or nil,
    make_string = function(n) return string.rep("x", n) end,
    read_file = function(path)
      local f = io.open(path, "rb")
      if not f then
        return nil
      end
      local s = f:read("*a")
      f:close()
      return s
    end,
    write_file = function(path, text)
      local f, why = io.open(path, "wb")
      if not f then
        return nil, why
      end
      local done, werr = f:write(text)
      f:close()
      if not done then
        return nil, werr
      end
      return true
    end,
    version = _VERSION,
  }
end

local argv = table.pack(...)
if type(argv[1]) == "table" then
  return M
end
local ok, code = pcall(function()
  return M.main(argv, M.game_deps())
end)
if not ok then
  io.stderr:write("memprobe: unexpected error: "
    .. tostring(code):match("^[^\n]*") .. "\n")
  return 1
end
return code
