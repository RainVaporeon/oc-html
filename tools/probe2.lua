-- probe2: measures the open in-game assumptions of oc-html in one run. It
-- also runs the installed renderer (/home/bin/html.lua) on wiki.html and
-- large.html from the script folder. It writes one fact per line to one file.
-- Usage: probe2 [--dir <path>] [--out <path>] [--no-interactive] [--skip-render]

local component = require("component")
local computer = require("computer")
local event = require("event")
local fs = require("filesystem")
local shell = require("shell")
local term = require("term")

local unicode_ok, unicode = pcall(require, "unicode")
local keyboard_ok, keyboard = pcall(require, "keyboard")

local USAGE = "Usage: probe2 [--dir <path>] [--out <path>] [--no-interactive] [--skip-render]\n" ..
  "  --dir PATH         folder with wiki.html and large.html (default: the script folder)\n" ..
  "  --out PATH         output file (default: <dir>/probe2.txt)\n" ..
  "  --no-interactive   skip the key input section\n" ..
  "  --skip-render      skip the html render section"

-- OpenOS kills a program after about 5 s without a yield. Stay far below it.
local YIELD_INTERVAL = 0.25
-- Each timed item stays below the 0.5 s no-yield rule.
local BENCH_LIMIT = 0.4
local MAX_LINE = 200
local MAX_OUTPUT = 60 * 1024
-- A longer value is split into numbered parts of this size.
local LONG_PART = 150
local SHORT_ADDRESS = 8
-- The kernel runs a full GC on every 10th resume, so 11 yields include one.
local SETTLE_YIELDS = 11
-- A rise above the previous reading by more than this is a GC (as in guard v2).
local GC_RISE_MIN = 16384
local GC_RISE_PART = 0.05
local KEY_TIMEOUT = 15
local HTML_PROGRAM = "/home/bin/html.lua"
local HTML_LIB = "/home/lib/html"
local HTML_ERROR_LOG = "/tmp/html-error.log"
local TMP = "/tmp/probe2-"
local STATS_TMP = TMP .. "stats.txt"
local PAGES = { "wiki", "large" }

local state = {
  errors = 0,
  out = nil,
  out_bytes = 0,
  pending = {},
  suppressed = 0,
  temp_files = {},
  gpu = nil,
  saved = nil,
  opts = nil,
  device_info = nil,
  cwd = nil,
  -- Set by the "interrupted" listener (plain Ctrl+C). tick() turns it into
  -- an error, except while the input section waits for Ctrl+C.
  interrupt_pending = false,
  expect_interrupt = false,
  interrupt_events = 0,
  -- Keeps benchmark results alive so no loop is optimized away.
  sink = 0,
}

-- Script folder -----------------------------------------------------------

local function script_anchor() end

-- OpenOS loads a program with the chunk name "=<path>"; plain Lua uses "@<path>".
-- getinfo takes a function of this chunk, so the pcall level does not matter.
local function find_script_dir()
  if type(debug) == "table" and type(debug.getinfo) == "function" then
    local ok, info = pcall(debug.getinfo, script_anchor, "S")
    local src = ok and type(info) == "table" and info.source
    if type(src) == "string" then
      local c = src:sub(1, 1)
      local path = src:sub(2)
      if (c == "@" or c == "=") and path:sub(1, 1) == "/" then
        local dir = path:match("^(.*)/[^/]*$")
        if dir then
          return dir == "" and "/" or dir, "debug.getinfo"
        end
      end
    end
  end
  local ok, process = pcall(require, "process")
  if ok and type(process) == "table" and type(process.info) == "function" then
    local ok2, info = pcall(process.info)
    local path = ok2 and type(info) == "table" and info.path
    if type(path) == "string" and path:sub(1, 1) == "/" then
      local dir = path:match("^(.*)/[^/]*$")
      if dir then
        return dir == "" and "/" or dir, "process.info"
      end
    end
  end
  return shell.getWorkingDirectory(), "cwd"
end

local SCRIPT_DIR, SCRIPT_DIR_METHOD = find_script_dir()

local function join(dir, name)
  if dir:sub(-1) == "/" then
    return dir .. name
  end
  return dir .. "/" .. name
end

-- Clocks ------------------------------------------------------------------

local function wall()
  return computer.uptime()
end

local function cpu()
  return os.clock()
end

local last_cpu, last_wall = cpu(), wall()

local function check_interrupt()
  if state.interrupt_pending and not state.expect_interrupt then
    state.interrupt_pending = false
    error("interrupted", 0)
  end
end

local function yield_now()
  os.sleep(0)
  last_cpu, last_wall = cpu(), wall()
  check_interrupt()
end

local function tick()
  if cpu() - last_cpu > YIELD_INTERVAL or wall() - last_wall > YIELD_INTERVAL then
    yield_now()
  end
end

-- Formatting --------------------------------------------------------------

local function escape(s)
  s = string.gsub(s, "\\", "\\x5C")
  s = string.gsub(s, "[\0-\31\127-\255]", function(c)
    return string.format("\\x%02X", string.byte(c))
  end)
  return s
end

local function fmt(v)
  local t = type(v)
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      return tostring(v)
    end
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
      return string.format("%d", v)
    end
    return string.format("%.3f", v)
  elseif t == "string" then
    return escape(v)
  end
  return escape(tostring(v))
end

local function ms(seconds)
  return string.format("%.3f", seconds * 1000)
end

local function rate(count, seconds)
  if not seconds or seconds <= 0 then
    return "n/a"
  end
  return string.format("%.1f", count / seconds)
end

local function short(addr)
  if type(addr) ~= "string" then
    return tostring(addr)
  end
  return addr:sub(1, SHORT_ADDRESS)
end

local function err_text(err)
  if type(err) == "table" then
    if err.reason ~= nil then
      return tostring(err.reason)
    end
    return "table error"
  end
  return tostring(err)
end

local function is_interrupt(err)
  return type(err) == "string" and err:find("interrupted", 1, true) ~= nil
end

-- Values first..n of a table.pack result as "a,b,c".
local function values_text(packed, first)
  local parts = {}
  for i = first or 1, packed.n do
    parts[#parts + 1] = tostring(packed[i])
  end
  return table.concat(parts, ",")
end

local function hex_bytes(s)
  return (s:gsub(".", function(c)
    return string.format("%02X", string.byte(c))
  end))
end

-- Output ------------------------------------------------------------------

local UUID = "(" .. string.rep("%x", 8) .. ")%-" .. string.rep("%x", 4) .. "%-" ..
  string.rep("%x", 4) .. "%-" .. string.rep("%x", 4) .. "%-" .. string.rep("%x", 12)

local function emit(line, force)
  -- Error messages can contain full component addresses. Keep only 8 characters.
  line = line:gsub(UUID, "%1")
  if #line > MAX_LINE then
    line = line:sub(1, MAX_LINE - 3) .. "..."
  end
  if not force and state.out_bytes + #line + 1 > MAX_OUTPUT then
    state.suppressed = state.suppressed + 1
    return
  end
  state.out_bytes = state.out_bytes + #line + 1
  state.pending[#state.pending + 1] = line
end

local function flush()
  if state.out and #state.pending > 0 then
    state.out:write(table.concat(state.pending, "\n"), "\n")
    if state.out.flush then
      pcall(state.out.flush, state.out)
    end
  end
  state.pending = {}
end

-- Returns the recorder of one section: set, long, try and fail.
local function make_recorder(prefix)
  local R = {}

  function R.set(key, value)
    emit(prefix .. "." .. key .. "=" .. fmt(value))
  end

  -- Splits a long value into key.1, key.2, ... and key.parts.
  function R.long(key, value)
    local s = fmt(value)
    if #s <= LONG_PART then
      emit(prefix .. "." .. key .. "=" .. s)
      return
    end
    local part = 0
    for i = 1, #s, LONG_PART do
      part = part + 1
      emit(prefix .. "." .. key .. "." .. part .. "=" .. s:sub(i, i + LONG_PART - 1))
    end
    emit(prefix .. "." .. key .. ".parts=" .. part)
  end

  -- An interrupt (Ctrl+C) is passed up so the report is written at once.
  function R.fail(key, err)
    if is_interrupt(err) then
      error(err, 0)
    end
    state.errors = state.errors + 1
    emit(prefix .. "." .. key .. "=ERR " .. escape(err_text(err)))
  end

  function R.try(key, fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then
      R.set(key, v)
    else
      R.fail(key, v)
    end
    return ok, v
  end

  return R
end

-- Files -------------------------------------------------------------------

local function temp(path)
  state.temp_files[#state.temp_files + 1] = path
  return path
end

local function remove_temp(path)
  if fs.exists(path) then
    fs.remove(path)
  end
  for i = #state.temp_files, 1, -1 do
    if state.temp_files[i] == path then
      table.remove(state.temp_files, i)
    end
  end
end

local function cleanup_temps()
  for i = #state.temp_files, 1, -1 do
    pcall(fs.remove, state.temp_files[i])
    state.temp_files[i] = nil
  end
end

local function read_file(path, max)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read(max or "*a")
  f:close()
  return data
end

local function write_file(path, text)
  local f, why = io.open(path, "wb")
  if not f then
    error("cannot open " .. path .. ": " .. tostring(why), 0)
  end
  f:write(text)
  f:close()
end

-- Machine helpers ---------------------------------------------------------

local function device_info()
  if state.device_info == nil then
    local ok, info = pcall(computer.getDeviceInfo)
    state.device_info = ok and type(info) == "table" and info or false
  end
  return state.device_info or {}
end

local INFO_FIELDS = { "class", "description", "product", "capacity", "width", "clock" }

local function record_info(R, key, info)
  if type(info) ~= "table" then
    R.set(key .. ".info", "none")
    return
  end
  for _, field in ipairs(INFO_FIELDS) do
    if info[field] ~= nil then
      R.set(key .. "." .. field, info[field])
    end
  end
end

-- Yields until a GC is seen, at most SETTLE_YIELDS times. Returns the
-- reading after the GC (or the highest reading), whether a GC was seen, and
-- the number of yields.
local function settle()
  local prev = computer.freeMemory()
  local best, gc, n = prev, false, 0
  for _ = 1, SETTLE_YIELDS do
    yield_now()
    n = n + 1
    local free = computer.freeMemory()
    if free - prev > math.max(GC_RISE_MIN, prev * GC_RISE_PART) then
      best, gc = free, true
      break
    end
    if free > best then
      best = free
    end
    prev = free
  end
  return best, gc, n
end

-- Runs op(n) until BENCH_LIMIT passes on either clock, or max calls.
-- Returns calls, wall s, cpu s.
local function bench(op, max)
  yield_now()
  local c0, w0 = cpu(), wall()
  local n = 0
  repeat
    op(n)
    n = n + 1
  until cpu() - c0 >= BENCH_LIMIT or wall() - w0 >= BENCH_LIMIT or n >= max
  local dc, dw = cpu() - c0, wall() - w0
  yield_now()
  return n, dw, dc
end

local function record_bench(R, key, n, dw, dc)
  R.set(key .. ".calls", n)
  R.set(key .. ".wall_ms", ms(dw))
  R.set(key .. ".cpu_ms", ms(dc))
  R.set(key .. ".per_s", rate(n, dw > 0 and dw or dc))
end

-- Screen ------------------------------------------------------------------

local function save_screen()
  local saved = { palette = {} }
  local ok_c, cx, cy = pcall(term.getCursor)
  if ok_c then
    saved.cx, saved.cy = cx, cy
  end
  if term.getCursorBlink then
    local ok_b, blink = pcall(term.getCursorBlink)
    if ok_b then
      saved.blink = blink
    end
  end
  local gpu = state.gpu
  if gpu then
    local ok, w, h = pcall(gpu.getResolution)
    if ok then
      saved.w, saved.h = w, h
    end
    local ok_fg, fg, fg_pal = pcall(gpu.getForeground)
    if ok_fg then
      saved.fg, saved.fg_pal = fg, fg_pal
    end
    local ok_bg, bg, bg_pal = pcall(gpu.getBackground)
    if ok_bg then
      saved.bg, saved.bg_pal = bg, bg_pal
    end
    local ok_d, depth = pcall(gpu.getDepth)
    if not ok_d or depth ~= 1 then
      for i = 0, 15 do
        local ok_p, color = pcall(gpu.getPaletteColor, i)
        if ok_p then
          saved.palette[i] = color
        end
      end
    end
  end
  state.saved = saved
end

local function restore_colors()
  local gpu, saved = state.gpu, state.saved
  if not gpu or not saved then
    return
  end
  if saved.fg then
    pcall(gpu.setForeground, saved.fg, saved.fg_pal)
  end
  if saved.bg then
    pcall(gpu.setBackground, saved.bg, saved.bg_pal)
  end
end

local function restore_screen()
  local gpu, saved = state.gpu, state.saved
  if gpu and saved then
    if gpu.setActiveBuffer then
      pcall(gpu.setActiveBuffer, 0)
    end
    if saved.w then
      local ok, w, h = pcall(gpu.getResolution)
      if not ok or w ~= saved.w or h ~= saved.h then
        pcall(gpu.setResolution, saved.w, saved.h)
      end
    end
    for i = 0, 15 do
      if saved.palette[i] then
        local ok, color = pcall(gpu.getPaletteColor, i)
        if ok and color ~= saved.palette[i] then
          pcall(gpu.setPaletteColor, i, saved.palette[i])
        end
      end
    end
    restore_colors()
  end
  pcall(term.clear)
  pcall(term.setCursor, 1, 1)
  if saved and saved.blink ~= nil and term.setCursorBlink then
    pcall(term.setCursorBlink, saved.blink)
  end
end

-- Section: env ------------------------------------------------------------

local function page_path(page)
  return join(state.opts.dir, page .. ".html")
end

local function tier_from_width(w)
  if w >= 160 then
    return 3
  elseif w >= 80 then
    return 2
  end
  return 1
end

local function section_env(R)
  R.set("lua_version", _VERSION)
  R.set("os_version", _G._OSVERSION)
  R.try("architecture", computer.getArchitecture)
  R.set("total_memory", computer.totalMemory())
  R.set("free_memory", computer.freeMemory())
  R.set("uptime_ms", ms(wall()))

  local info = device_info()
  local mem = {}
  for _, d in pairs(info) do
    if type(d) == "table" and d.class == "memory" then
      mem[#mem + 1] = tostring(d.capacity or d.description)
    end
  end
  table.sort(mem)
  R.set("memory_devices", table.concat(mem, ","))

  local gpu = state.gpu
  R.set("gpu.present", gpu ~= nil)
  if gpu then
    R.set("gpu.addr", short(gpu.address))
    record_info(R, "gpu", info[gpu.address])
    R.try("gpu.max_resolution", function()
      local w, h = gpu.maxResolution()
      return w .. "x" .. h
    end)
    R.try("gpu.tier_from_max_resolution", function()
      return tier_from_width((gpu.maxResolution()))
    end)
    R.try("gpu.max_depth", gpu.maxDepth)
    R.try("gpu.depth", gpu.getDepth)
    R.try("gpu.resolution", function()
      local w, h = gpu.getResolution()
      return w .. "x" .. h
    end)
    local ok, scr = pcall(gpu.getScreen)
    if ok and scr then
      R.set("screen.addr", short(scr))
      record_info(R, "screen", info[scr])
    else
      R.set("screen", "none")
    end
  end
  R.set("data_card", component.isAvailable("data"))
  R.set("internet_card", component.isAvailable("internet"))

  R.set("dir", state.opts.dir)
  R.set("dir_method", state.opts.dir_method)
  R.set("out", state.opts.out)
  R.set("cwd", shell.getWorkingDirectory())
  for _, page in ipairs(PAGES) do
    local p = page_path(page)
    local exists = fs.exists(p)
    R.set("page." .. page .. ".exists", exists)
    if exists then
      R.set("page." .. page .. ".size", fs.size(p))
    end
  end
  R.set("html.exists", fs.exists(HTML_PROGRAM))
  if fs.exists(HTML_PROGRAM) then
    R.set("html.size", fs.size(HTML_PROGRAM))
  end
  R.try("html.lib", function()
    local names = {}
    for name in fs.list(HTML_LIB) do
      names[#names + 1] = name .. ":" .. tostring(fs.size(join(HTML_LIB, name)))
    end
    table.sort(names)
    return table.concat(names, ",")
  end)
end

-- Section: render ---------------------------------------------------------

local function noop() end

-- Loads the installed html program as a module. Returns M, or nil and why.
local function load_html()
  local chunk, lerr = loadfile(HTML_PROGRAM)
  if not chunk then
    return nil, "loadfile: " .. tostring(lerr)
  end
  local ok, M = pcall(chunk, {})
  if not ok then
    if is_interrupt(M) then
      error(M, 0)
    end
    return nil, "load: " .. err_text(M)
  end
  if type(M) ~= "table" or type(M.main) ~= "function" or type(M.game_deps) ~= "function" then
    return nil, "no module table with main and game_deps"
  end
  return M
end

local function copy_stats(R, page)
  local text = read_file(STATS_TMP, 32768)
  if not text then
    R.set(page .. ".run.stats_file", "missing")
    return
  end
  local n = 0
  for line in text:gmatch("[^\n]+") do
    local k, v = line:match("^stats: ([%w_]+)=(.*)$")
    if k then
      n = n + 1
      R.long(page .. "." .. k, v)
    end
    tick()
  end
  R.set(page .. ".run.stats_lines", n)
end

-- Runs html through its module API. Returns the method, pcall ok, the
-- result and the captured stderr lines, or nil and why the API did not fit.
local function run_api(argv)
  local M, why = load_html()
  if not M then
    return nil, why
  end
  local dok, deps = pcall(M.game_deps)
  if not dok or type(deps) ~= "table" then
    if type(M.clear_modules) == "function" then
      pcall(M.clear_modules, package.loaded)
    end
    return nil, "game_deps: " .. err_text(deps)
  end
  local errs = {}
  deps.out = noop
  deps.err = function(line)
    errs[#errs + 1] = tostring(line)
  end
  local ok, result = pcall(M.main, argv, deps)
  local cleared = "n/a"
  if type(M.clear_modules) == "function" then
    local cok, count = pcall(M.clear_modules, package.loaded)
    cleared = cok and count or ("ERR " .. err_text(count))
  end
  return { ok = ok, result = result, errs = errs, cleared = cleared }
end

local function render_page(R, page)
  local path = page_path(page)
  if not fs.exists(path) then
    R.set(page .. ".run.skipped", "missing " .. path)
    return
  end
  local free, gc, yields = settle()
  R.set(page .. ".run.settle_free", free)
  R.set(page .. ".run.settle_gc", gc)
  R.set(page .. ".run.settle_yields", yields)
  local log_before = fs.exists(HTML_ERROR_LOG)
  temp(STATS_TMP)
  if fs.exists(STATS_TMP) then
    fs.remove(STATS_TMP)
  end
  local argv = { "--stats", "--stats-out", STATS_TMP, path, n = 4 }

  local w0, c0 = wall(), cpu()
  local res, why = run_api(argv)
  if res then
    R.set(page .. ".run.method", "api")
    if res.ok then
      R.set(page .. ".run.exit", res.result)
    else
      if is_interrupt(res.result) then
        error(res.result, 0)
      end
      R.set(page .. ".run.exit", "error")
      R.set(page .. ".run.error", err_text(res.result):match("^[^\n]*"))
    end
    R.set(page .. ".run.cleared_modules", res.cleared)
    local n = 0
    for _, line in ipairs(res.errs) do
      if line:sub(1, 7) ~= "stats: " then
        n = n + 1
        if n <= 5 then
          R.set(page .. ".run.stderr." .. n, line)
        end
      end
    end
    R.set(page .. ".run.stderr_other_lines", n)
    R.set(page .. ".run.stderr_lines", #res.errs)
  else
    R.set(page .. ".run.method", "shell")
    R.set(page .. ".run.api_unusable", why)
    local cmd = HTML_PROGRAM .. " --stats --stats-out " .. STATS_TMP .. " " .. path .. " > /dev/null"
    R.set(page .. ".run.command", cmd)
    local packed = table.pack(pcall(shell.execute, cmd))
    if not packed[1] and is_interrupt(packed[2]) then
      error(packed[2], 0)
    end
    R.set(page .. ".run.exit", values_text(packed))
  end
  local dw, dc = wall() - w0, cpu() - c0
  last_cpu, last_wall = cpu(), wall()
  R.set(page .. ".run.wall_ms", ms(dw))
  R.set(page .. ".run.cpu_ms", ms(dc))

  if not log_before and fs.exists(HTML_ERROR_LOG) then
    R.long(page .. ".run.error_log", read_file(HTML_ERROR_LOG, 600) or "")
    fs.remove(HTML_ERROR_LOG)
  end
  copy_stats(R, page)
  remove_temp(STATS_TMP)
  free, gc, yields = settle()
  R.set(page .. ".run.after_free", free)
  R.set(page .. ".run.after_gc", gc)
  R.set(page .. ".run.html_modules_left", (function()
    local n = 0
    for name in pairs(package.loaded) do
      if type(name) == "string" and name:sub(1, 5) == "html." then
        n = n + 1
      end
    end
    return n
  end)())
end

local function section_render(R)
  if state.opts.skip_render then
    R.set("skipped", "--skip-render")
    return
  end
  R.set("program", HTML_PROGRAM)
  R.set("program_exists", fs.exists(HTML_PROGRAM))
  for _, page in ipairs(PAGES) do
    print("probe2:   render " .. page .. ".html")
    local ok, err = pcall(render_page, R, page)
    pcall(remove_temp, STATS_TMP)
    if not ok then
      R.fail(page .. ".run", err)
    end
    flush()
    yield_now()
  end
end

-- Section: mem ------------------------------------------------------------

-- Makes about pieces KB of garbage. The table and strings die on return.
local function make_garbage(tag, pieces)
  local g = {}
  for k = 1, pieces do
    g[k] = string.rep("g", 1000) .. tag .. ":" .. k
  end
  return #g
end

local function gc_every_10th(R)
  local jumps, rises = {}, {}
  local c0, w0 = cpu(), wall()
  for y = 1, 40 do
    make_garbage(y, 16)
    local before = computer.freeMemory()
    yield_now()
    local after = computer.freeMemory()
    if after - before > math.max(GC_RISE_MIN, before * GC_RISE_PART) then
      jumps[#jumps + 1] = y
      rises[#rises + 1] = after - before
    end
  end
  R.set("gc10.yields", 40)
  R.set("gc10.garbage_per_yield", "16 x 1 KB strings")
  R.set("gc10.wall_ms", ms(wall() - w0))
  R.set("gc10.cpu_ms", ms(cpu() - c0))
  R.set("gc10.jumps", table.concat(jumps, ","))
  R.set("gc10.rises", table.concat(rises, ","))
  local gaps, all10 = {}, #jumps >= 2
  for i = 2, #jumps do
    gaps[#gaps + 1] = jumps[i] - jumps[i - 1]
    if gaps[#gaps] ~= 10 then
      all10 = false
    end
  end
  R.set("gc10.intervals", table.concat(gaps, ","))
  R.set("gc10.every_10th", all10)
end

local function table_doubling(R, rep)
  local key = "doubling." .. rep
  local t = {}
  for i = 1, 8192 do
    t[i] = i
  end
  local f1, g1 = settle()
  t[8193] = 8193
  local f2, g2 = settle()
  R.set(key .. ".free_8192", f1)
  R.set(key .. ".free_8193", f2)
  R.set(key .. ".gc_seen", tostring(g1) .. "," .. tostring(g2))
  R.set(key .. ".cost", f1 - f2)
  return #t
end

-- 152 letters with k style bytes (\1 to \5) spread inside.
local function styled_base(k)
  local text = string.rep("abcdefgh", 19)
  if k == 0 then
    return text
  end
  local parts, step, pos = {}, 152 // (k + 1), 1
  for j = 1, k do
    parts[#parts + 1] = text:sub(pos, pos + step - 1)
    parts[#parts + 1] = string.char(1 + (j - 1) % 5)
    pos = pos + step
  end
  parts[#parts + 1] = text:sub(pos)
  return table.concat(parts)
end

local function string_cost(R, k)
  local key = "str160.style" .. k
  local base = styled_base(k)
  local holder = {}
  for i = 1, 1000 do
    holder[i] = false
  end
  local before = settle()
  for i = 1, 1000 do
    holder[i] = base .. string.format("%08d", i)
    if i % 100 == 0 then
      tick()
    end
  end
  local after = settle()
  R.set(key .. ".bytes", #base + 8)
  R.set(key .. ".free_before", before)
  R.set(key .. ".free_after", after)
  R.set(key .. ".per_string", (before - after) / 1000)
  return #holder
end

local function section_mem(R)
  R.set("unit", "freeMemory (real bytes / ramScale)")
  R.set("total", computer.totalMemory())
  R.set("settle", "up to 11 yields, stop at a rise over max(16384, 5%)")
  local ok, err = pcall(gc_every_10th, R)
  if not ok then
    R.fail("gc10", err)
  end
  R.set("doubling.expected_real", 8192 * 16)
  for rep = 1, 2 do
    ok, err = pcall(table_doubling, R, rep)
    if not ok then
      R.fail("doubling." .. rep, err)
    end
  end
  for _, k in ipairs({ 0, 3, 10 }) do
    ok, err = pcall(string_cost, R, k)
    if not ok then
      R.fail("str160.style" .. k, err)
    end
  end
  R.set("free_end", (settle()))
end

-- Section: fs -------------------------------------------------------------

local function rename_test(R, key, fn)
  local a, b = temp(TMP .. "ren-a.txt"), temp(TMP .. "ren-b.txt")
  write_file(a, "A")
  write_file(b, "B")
  local packed = table.pack(pcall(fn, a, b))
  local a_exists, b_content = fs.exists(a), read_file(b)
  R.set(key .. ".pcall", packed[1])
  R.set(key .. ".ret", values_text(packed, 2))
  R.set(key .. ".a_exists", a_exists)
  R.set(key .. ".b_content", tostring(b_content))
  local result = "other"
  if not packed[1] then
    result = "error"
  elseif not a_exists and b_content == "A" then
    result = "replaced"
  elseif a_exists and b_content == "B" then
    result = "failed"
  end
  R.set(key .. ".result", result)
  remove_temp(a)
  remove_temp(b)
end

local function free_space(proxy)
  return proxy.spaceTotal() - proxy.spaceUsed()
end

local function fill_tmp(R)
  local proxy = fs.get("/tmp")
  R.try("fill.space_before", free_space, proxy)
  local path = temp(TMP .. "fill.bin")
  local f, oerr = io.open(path, "wb")
  if not f then
    R.set("fill.open", "ERR " .. tostring(oerr))
    return
  end
  local block = string.rep("f", 4096)
  local written, stop, why, first = 0, "cap 80 KB", nil, nil
  while written < 80 * 1024 do
    local ok, done, reason, rets = pcall(function()
      local w1, e1 = f:write(block)
      if w1 == nil and e1 ~= nil then
        return false, "write: " .. tostring(e1)
      end
      local w2, e2 = f:flush()
      if w2 == nil and e2 ~= nil then
        return false, "flush: " .. tostring(e2)
      end
      return true, nil, type(w1) .. "," .. type(w2)
    end)
    if not ok then
      stop, why = "error", err_text(done)
      break
    end
    if not done then
      stop, why = "failed", reason
      break
    end
    first = first or rets
    written = written + 4096
    tick()
  end
  local close = table.pack(pcall(f.close, f))
  R.set("fill.step", 4096)
  R.set("fill.bytes_written", written)
  R.set("fill.stop", stop)
  R.set("fill.error", tostring(why))
  R.set("fill.write_flush_ret_types", tostring(first))
  R.set("fill.close", values_text(close))
  R.try("fill.file_size", fs.size, path)
  R.try("fill.space_full", free_space, proxy)
  remove_temp(path)
  R.set("fill.removed", not fs.exists(path))
  R.try("fill.space_after", free_space, proxy)
end

local function section_fs(R)
  local ok, err = pcall(rename_test, R, "rename_fs", fs.rename)
  if not ok then
    R.fail("rename_fs", err)
  end
  ok, err = pcall(rename_test, R, "rename_os", os.rename)
  if not ok then
    R.fail("rename_os", err)
  end
  ok, err = pcall(fill_tmp, R)
  if not ok then
    R.fail("fill", err)
  end
  R.set("cwd", shell.getWorkingDirectory())
  R.try("resolve.relative", shell.resolve, "probe2-rel")
  R.try("resolve.home", shell.resolve, "~")
  R.try("resolve.parent", shell.resolve, "..")
  R.try("resolve.dot", shell.resolve, "./probe2-rel")
  for _, p in ipairs({ { "root", "/" }, { "tmp", "/tmp" } }) do
    local key, path = p[1], p[2]
    local okg, proxy, mount = pcall(fs.get, path)
    if okg and proxy then
      R.set("get." .. key .. ".mount", tostring(mount))
      R.set("get." .. key .. ".addr", short(proxy.address))
      R.try("get." .. key .. ".space_total", proxy.spaceTotal)
      R.try("get." .. key .. ".space_used", proxy.spaceUsed)
      R.try("get." .. key .. ".read_only", proxy.isReadOnly)
    else
      R.fail("get." .. key, okg and "no proxy" or proxy)
    end
  end
end

-- Section: shell ----------------------------------------------------------

local SHELL_TESTS = {
  { "gt", { "echo p2gt > %s" } },
  { "gtgt", { "echo p2one > %s", "echo p2two >> %s" } },
  { "err2", { "cat /tmp/probe2-missing 2> %s" } },
  { "err2to1", { "cat /tmp/probe2-missing > %s 2>&1" } },
  { "pipe", { "echo p2pipe | cat > %s" } },
}

local function list_tmp()
  local names = {}
  local ok, iter = pcall(fs.list, "/tmp")
  if ok and iter then
    for name in iter do
      names[name] = true
    end
  end
  return names
end

-- Returns the first screen row (1 to rows) that shows text, or false.
local function screen_row_with(text, rows)
  local gpu = state.gpu
  if not gpu then
    return "no gpu"
  end
  local w, h = gpu.getResolution()
  local width = math.min(#text + 16, w)
  for y = 1, math.min(rows, h) do
    local chars = {}
    for x = 1, width do
      chars[x] = (gpu.get(x, y))
    end
    if table.concat(chars):find(text, 1, true) then
      return y
    end
  end
  return false
end

local function shell_redirects(R)
  for _, t in ipairs(SHELL_TESTS) do
    local name, cmds = t[1], t[2]
    local file = temp(TMP .. "sh-" .. name .. ".txt")
    if fs.exists(file) then
      fs.remove(file)
    end
    for i, c in ipairs(cmds) do
      local cmd = c:format(file)
      local packed = table.pack(pcall(shell.execute, cmd))
      if not packed[1] and is_interrupt(packed[2]) then
        error(packed[2], 0)
      end
      R.set(name .. ".cmd." .. i, cmd)
      R.set(name .. ".ret." .. i, values_text(packed))
    end
    local exists = fs.exists(file)
    R.set(name .. ".file_exists", exists)
    if exists then
      R.set(name .. ".content", read_file(file, 150) or "")
    end
    remove_temp(file)
    tick()
  end
end

local function shell_stderr(R)
  local script = temp(TMP .. "err.lua")
  local out = temp(TMP .. "sh-so.txt")
  write_file(script, 'io.stdout:write("P2OUT\\n") io.stderr:write("P2ERRMARK\\n")\n')
  pcall(term.clear)
  local packed = table.pack(pcall(shell.execute, script .. " > " .. out))
  if not packed[1] and is_interrupt(packed[2]) then
    error(packed[2], 0)
  end
  R.set("stderr.ret", values_text(packed))
  R.set("stderr.file", tostring(read_file(out, 150)))
  R.set("stderr.on_screen_row", screen_row_with("P2ERRMARK", 6))
  remove_temp(script)
  remove_temp(out)
end

local function section_shell(R)
  R.set("io_stderr", type(io.stderr))
  R.set("io_stderr_is_stdout", io.stderr == io.stdout)
  state.cwd = shell.getWorkingDirectory()
  local before = list_tmp()
  -- A redirect that the shell does not know can create a file named like
  -- "2" or "&1" in the working folder. /tmp keeps it away from user files.
  local okcd = pcall(shell.setWorkingDirectory, "/tmp")
  R.set("cwd_set_tmp", okcd)
  local ok, err = pcall(shell_redirects, R)
  if not ok then
    R.fail("redirects", err)
  end
  ok, err = pcall(shell_stderr, R)
  if not ok then
    R.fail("stderr", err)
  end
  pcall(shell.setWorkingDirectory, state.cwd)
  state.cwd = nil
  local stray = {}
  for name in pairs(list_tmp()) do
    if not before[name] then
      stray[#stray + 1] = name
      if #name <= 3 or name:sub(1, 7) == "probe2-" then
        pcall(fs.remove, join("/tmp", name))
      end
    end
  end
  table.sort(stray)
  R.set("stray_tmp_files", table.concat(stray, ","))
  R.try("term.viewport", function()
    return values_text(table.pack(term.getViewport()))
  end)
  R.try("term.available", term.isAvailable)
  R.try("term.cursor", function()
    return values_text(table.pack(term.getCursor()))
  end)
end

-- Section: gpu ------------------------------------------------------------

local function resolution_test(R, gpu)
  local w0, h0 = gpu.getResolution()
  local mw, mh = gpu.maxResolution()
  local tw, th = mw, mh
  if w0 == mw and h0 == mh then
    tw, th = math.max(1, mw // 2), math.max(1, mh // 2)
  end
  R.set("res.start", w0 .. "x" .. h0)
  R.set("res.target", tw .. "x" .. th)
  yield_now()
  local c0, t0 = cpu(), wall()
  local set = table.pack(pcall(gpu.setResolution, tw, th))
  R.set("res.set_wall_ms", ms(wall() - t0))
  R.set("res.set_cpu_ms", ms(cpu() - c0))
  R.set("res.set_ret", values_text(set))
  local w1, h1 = gpu.getResolution()
  R.set("res.after", w1 .. "x" .. h1)
  R.set("res.after_matches", w1 == tw and h1 == th)
  c0, t0 = cpu(), wall()
  local back = table.pack(pcall(gpu.setResolution, w0, h0))
  R.set("res.back_wall_ms", ms(wall() - t0))
  R.set("res.back_cpu_ms", ms(cpu() - c0))
  R.set("res.back_ret", values_text(back))
  local w2, h2 = gpu.getResolution()
  R.set("res.restored", w2 .. "x" .. h2)
  R.set("res.restored_ok", w2 == w0 and h2 == h0)
  yield_now()
end

local function pattern_char(row, col)
  return string.char(97 + (row * 7 + col) % 26)
end

local function copy_test(R, gpu)
  local w, h = gpu.getResolution()
  local cw, ch = math.min(160, w), math.min(48, h - 1)
  if ch < 2 then
    R.set("copy.skipped", "screen too small")
    return
  end
  for r = 1, ch + 1 do
    local t = {}
    for c = 1, cw do
      t[c] = pattern_char(r, c)
    end
    gpu.set(1, r, table.concat(t))
  end
  yield_now()
  local c0, t0 = cpu(), wall()
  gpu.copy(1, 2, cw, ch, 0, -1)
  local dw, dc = wall() - t0, cpu() - c0
  R.set("copy.size", cw .. "x" .. ch)
  R.set("copy.wall_ms", ms(dw))
  R.set("copy.cpu_ms", ms(dc))
  local cells = { { 1, 1 }, { cw, 1 }, { math.min(10, cw), math.min(10, ch) }, { 1, ch }, { cw, ch } }
  local bad = 0
  for i, p in ipairs(cells) do
    local x, y = p[1], p[2]
    local got = gpu.get(x, y)
    local want = pattern_char(y + 1, x)
    if got ~= want then
      bad = bad + 1
    end
    R.set("copy.cell." .. i, x .. "," .. y .. " got=" .. tostring(got) .. " want=" .. want)
  end
  local last = gpu.get(1, ch + 1)
  R.set("copy.last_row_kept", last == pattern_char(ch + 1, 1))
  R.set("copy.correct", bad == 0)
  record_bench(R, "copy.repeat", bench(function()
    gpu.copy(1, 2, cw, ch, 0, -1)
  end, 200))
end

local function color_test(R, name, setter, a, b)
  local r1 = table.pack(pcall(setter, a))
  local r2 = table.pack(pcall(setter, a))
  local r3 = table.pack(pcall(setter, b))
  R.set(name .. ".first_ret", values_text(r1))
  R.set(name .. ".same_ret", values_text(r2))
  R.set(name .. ".changed_ret", values_text(r3))
  R.set(name .. ".returns_old", r2[2] == a and r3[2] == a)
  record_bench(R, name .. ".same", bench(function()
    setter(a)
  end, 2000))
  restore_colors()
end

local function term_after_gpu(R, gpu)
  local w, h = gpu.getResolution()
  gpu.fill(1, 1, w, h, " ")
  gpu.set(math.max(1, w - 10), math.max(1, h - 1), "probe2-gpu")
  R.set("term.cursor_before", values_text(table.pack(term.getCursor())))
  term.clear()
  term.write("x")
  R.set("term.cursor_after_write", values_text(table.pack(term.getCursor())))
  R.set("term.cell_1_1", (gpu.get(1, 1)))
end

local function section_gpu(R)
  local gpu = state.gpu
  if not gpu then
    R.set("present", false)
    return
  end
  local tests = {
    { "res", resolution_test },
    { "copy", copy_test },
    { "term", term_after_gpu },
  }
  for _, t in ipairs(tests) do
    local ok, err = pcall(t[2], R, gpu)
    restore_colors()
    if not ok then
      R.fail(t[1], err)
    end
    yield_now()
  end
  local ok, err = pcall(color_test, R, "fg", gpu.setForeground, 0xFFFFFF, 0x00FF00)
  if not ok then
    R.fail("fg", err)
  end
  ok, err = pcall(color_test, R, "bg", gpu.setBackground, 0x000000, 0x0000FF)
  if not ok then
    R.fail("bg", err)
  end
end

-- Section: text -----------------------------------------------------------

local TEXT_CASES = {
  { "hangul", "\xED\x95\x9C\xEA\xB5\xAD\xEC\x96\xB4" },
  { "arabic", "\xD8\xB9\xD8\xB1\xD8\xA8\xD9\x8A" },
  { "box", "\xE2\x94\x8C\xE2\x94\x80\xE2\x94\x90" },
  { "greek", "\xCE\xB1\xCE\xB2\xCE\xB3" },
  { "combining", "e\xCC\x81" },
  { "vs16", "\xE2\x98\xBA\xEF\xB8\x8F" },
  { "fullwidth", "\xEF\xBC\xA1" },
  { "tab", "a\tb" },
  { "cjk2", "\xE4\xB8\xAD\xE6\x96\x87" },
}
local TEXT_SCAN = 12

local function text_case(R, gpu, name, s)
  R.set(name .. ".hex", hex_bytes(s))
  if unicode_ok then
    R.try(name .. ".len", unicode.len, s)
    R.try(name .. ".wlen", unicode.wlen, s)
  end
  local w = gpu.getResolution()
  gpu.fill(1, 1, w, 1, " ")
  R.set(name .. ".set_ret", tostring(gpu.set(1, 1, s)))
  local cells, last = {}, 0
  for x = 1, math.min(TEXT_SCAN, w) do
    local ch = gpu.get(x, 1)
    cells[x] = tostring(ch)
    if ch ~= " " then
      last = x
    end
  end
  local used = last
  if last > 0 and unicode_ok then
    local ok, wide = pcall(unicode.isWide, cells[last])
    if ok and wide then
      used = last + 1
    end
  end
  R.set(name .. ".cells", table.concat(cells, "|"))
  R.set(name .. ".columns", used)
end

local function section_text(R)
  local gpu = state.gpu
  R.set("has_unicode", unicode_ok)
  if not gpu then
    R.set("gpu", "none")
    return
  end
  R.set("scan_columns", TEXT_SCAN)
  for _, c in ipairs(TEXT_CASES) do
    local ok, err = pcall(text_case, R, gpu, c[1], c[2])
    if not ok then
      R.fail(c[1], err)
    end
    tick()
  end
end

-- Section: speed ----------------------------------------------------------

local WORDS = {
  "the", "page", "link", "html", "viewer", "render", "server", "table", "open",
  "computer", "screen", "memory", "energy", "quarry", "reactor", "turbine",
}

local function make_html(size)
  local parts, len, i = {}, 0, 0
  while len < size do
    i = i + 1
    parts[i] = string.format(
      '<p class="x">Some %s <a href="/wiki/Page_%d">linked %s</a> and  more\twords here.</p>\n',
      WORDS[i % #WORDS + 1], i, WORDS[(i * 7) % #WORDS + 1])
    len = len + #parts[i]
    tick()
  end
  return table.concat(parts):sub(1, size)
end

-- Runs pass(over) until BENCH_LIMIT. Each pass returns the amount it did.
local function run_rate(R, key, unit, pass)
  yield_now()
  local c0, w0 = cpu(), wall()
  local function over()
    return cpu() - c0 >= BENCH_LIMIT or wall() - w0 >= BENCH_LIMIT
  end
  local amount, passes = 0, 0
  repeat
    amount = amount + pass(over)
    passes = passes + 1
  until over() or passes >= 1000
  local dc, dw = cpu() - c0, wall() - w0
  yield_now()
  R.set(key .. ".passes", passes)
  R.set(key .. ".cpu_ms", ms(dc))
  R.set(key .. ".wall_ms", ms(dw))
  if unit == "kb" then
    amount = amount / 1024
  end
  R.set(key .. "." .. unit .. "_per_s", rate(amount, dc > 0 and dc or dw))
end

local function speed_tests(html)
  local find, byte, sub = string.find, string.byte, string.sub
  local n = #html
  local function byte_pass(width)
    return function(over)
      local i, sum = 1, 0
      while i <= n do
        local stop = math.min(n, i + 4095)
        while i <= stop do
          local b = byte(html, i, i + width - 1)
          sum = sum + b
          i = i + width
        end
        if over() then
          break
        end
      end
      state.sink = state.sink + sum
      return math.min(i - 1, n)
    end
  end
  local parts = {}
  for i = 1, 1000 do
    local k = (i - 1) * 80 % (n - 80) + 1
    parts[i] = sub(html, k, k + 79)
  end
  return {
    { "find_lt", "kb", function(over)
      local i, count = 1, 0
      while true do
        local j = find(html, "<", i, true)
        if not j then
          return n
        end
        i = j + 1
        count = count + 1
        if count % 256 == 0 and over() then
          return i - 1
        end
      end
    end },
    { "byte_1", "kb", byte_pass(1) },
    { "byte_16", "kb", byte_pass(16) },
    { "byte_64", "kb", byte_pass(64) },
    { "sub_80", "kb", function(over)
      local i, sum = 1, 0
      while i + 79 <= n do
        sum = sum + #sub(html, i, i + 79)
        i = i + 80
        if i % 8000 == 1 and over() then
          break
        end
      end
      state.sink = state.sink + sum
      return sum
    end },
    { "concat_1000x80", "kb", function()
      return #table.concat(parts)
    end },
    { "table_insert_1000", "ops", function()
      local t = {}
      for i = 1, 1000 do
        table.insert(t, i)
      end
      return #t
    end },
    { "index_append_1000", "ops", function()
      local t = {}
      for i = 1, 1000 do
        t[#t + 1] = i
      end
      return #t
    end },
  }
end

local function section_speed(R)
  local html = make_html(65536)
  R.set("html_bytes", #html)
  R.set("limit_ms", ms(BENCH_LIMIT))
  for _, t in ipairs(speed_tests(html)) do
    local ok, err = pcall(run_rate, R, t[1], t[2], t[3])
    if not ok then
      R.fail(t[1], err)
    end
  end
  R.set("sink", state.sink % 1000)
end

-- Section: input ----------------------------------------------------------

local KEY_STEPS = {
  { "up", "Up", 200 },
  { "down", "Down", 208 },
  { "pgup", "PgUp", 201 },
  { "pgdn", "PgDn", 209 },
  { "home", "Home", 199 },
  { "end", "End", 207 },
  { "q", "q", 16 },
  { "enter", "Enter", 28 },
}
local TOTAL_STEPS = #KEY_STEPS + 2

-- Drops queued events, such as key_up events of the last step.
local function drain()
  for _ = 1, 20 do
    local ok, name = pcall(event.pull, 0)
    if not ok then
      if is_interrupt(name) then
        error(name, 0)
      end
      return
    end
    if name == nil then
      return
    end
  end
end

-- Calls event.pull with a timeout. Returns pcall ok and the packed event.
local function pull(timeout, name)
  local packed
  if name then
    packed = table.pack(pcall(event.pull, math.max(0, timeout), name))
  else
    packed = table.pack(pcall(event.pull, math.max(0, timeout)))
  end
  last_cpu, last_wall = cpu(), wall()
  if not packed[1] and is_interrupt(packed[2]) and not state.expect_interrupt then
    error(packed[2], 0)
  end
  return packed
end

local function prompt(step, text)
  print(string.format("probe2: input [%d/%d] %s", step, TOTAL_STEPS, text))
end

local function key_step(R, step, s)
  local key, label, code = s[1], s[2], s[3]
  drain()
  prompt(step, "press " .. label .. " (" .. KEY_TIMEOUT .. " s)")
  local t0 = wall()
  local e = pull(KEY_TIMEOUT, "key_down")
  if not e[1] then
    R.fail(key, e[2])
    return
  end
  if e[2] == nil then
    R.set(key, "timeout")
    return
  end
  R.set(key .. ".event", e[2])
  R.set(key .. ".char", e[4])
  R.set(key .. ".code", e[5])
  R.set(key .. ".ms", ms(wall() - t0))
  R.set(key .. ".match", e[5] == code)
end

local function hold_step(R, step)
  drain()
  prompt(step, "hold Down for 2 s, then release (" .. KEY_TIMEOUT .. " s)")
  local deadline = wall() + KEY_TIMEOUT
  local first
  while wall() < deadline do
    local e = pull(deadline - wall(), "key_down")
    if not e[1] then
      R.fail("hold", e[2])
      return
    end
    if e[2] == nil then
      break
    end
    if e[5] == 208 then
      first = wall()
      break
    end
  end
  if not first then
    R.set("hold", "timeout")
    return
  end
  local times, released = { first }, false
  local stop = first + 4
  while wall() < stop do
    local e = pull(stop - wall())
    if not e[1] then
      R.fail("hold", e[2])
      return
    end
    if e[2] == nil then
      break
    end
    if e[2] == "key_down" and e[5] == 208 then
      times[#times + 1] = wall()
    elseif e[2] == "key_up" and e[5] == 208 then
      released = true
      break
    end
  end
  local gaps, lo, hi, sum = {}, math.huge, 0, 0
  for i = 2, #times do
    local g = times[i] - times[i - 1]
    gaps[#gaps + 1] = g
    lo, hi, sum = math.min(lo, g), math.max(hi, g), sum + g
  end
  R.set("hold.key_down_count", #times)
  R.set("hold.held_ms", ms(times[#times] - first))
  R.set("hold.released", released)
  if #gaps > 0 then
    R.set("hold.interval_min_ms", ms(lo))
    R.set("hold.interval_avg_ms", ms(sum / #gaps))
    R.set("hold.interval_max_ms", ms(hi))
  end
end

local function ctrl_c_step(R, step)
  drain()
  state.expect_interrupt = true
  prompt(step, "press Ctrl+C once (not Ctrl+Alt+C) (" .. KEY_TIMEOUT .. " s)")
  local t0 = wall()
  local deadline = t0 + KEY_TIMEOUT
  local seen, arrival, got_c = {}, nil, false
  while wall() < deadline and #seen < 8 do
    local e = pull(deadline - wall())
    if not e[1] then
      seen[#seen + 1] = "error:" .. err_text(e[2])
      arrival = "error from event.pull: " .. err_text(e[2])
      break
    end
    if e[2] == nil then
      break
    end
    local name = tostring(e[2])
    if name == "key_down" or name == "key_up" then
      local ctrl = keyboard_ok and keyboard.isControlDown and keyboard.isControlDown()
      seen[#seen + 1] = string.format("%s:%s:%s:ctrl=%s:%sms", name, tostring(e[4]),
        tostring(e[5]), tostring(ctrl), ms(wall() - t0))
      if name == "key_down" and (e[5] == 46 or e[4] == 3) and not got_c then
        got_c = true
        -- The interrupted event, if any, follows the key event.
        deadline = math.min(deadline, wall() + 1.5)
      end
    elseif name == "interrupted" then
      seen[#seen + 1] = "interrupted:" .. ms(wall() - t0) .. "ms"
      arrival = "interrupted event"
      break
    else
      seen[#seen + 1] = name
    end
  end
  state.expect_interrupt = false
  state.interrupt_pending = false
  if not arrival then
    arrival = got_c and "key_down with ctrl only" or "timeout"
  end
  R.set("ctrl_c.arrival", arrival)
  R.long("ctrl_c.events", table.concat(seen, ","))
  R.set("ctrl_c.listener_events", state.interrupt_events)
end

local function section_input(R)
  R.set("ctrl_alt_c", "not tested (kills the program)")
  if state.opts.no_interactive then
    R.set("skipped", "--no-interactive")
    return
  end
  R.set("keyboard_lib", keyboard_ok)
  R.set("keyboard_component", component.isAvailable("keyboard"))
  pcall(term.clear)
  print("probe2: key test. Press each key when asked. A step waits " .. KEY_TIMEOUT .. " s.")
  for i, s in ipairs(KEY_STEPS) do
    local ok, err = pcall(key_step, R, i, s)
    if not ok then
      R.fail(s[1], err)
    end
  end
  local ok, err = pcall(hold_step, R, #KEY_STEPS + 1)
  if not ok then
    R.fail("hold", err)
  end
  ok, err = pcall(ctrl_c_step, R, #KEY_STEPS + 2)
  state.expect_interrupt = false
  state.interrupt_pending = false
  if not ok then
    R.fail("ctrl_c", err)
  end
  drain()
end

-- Main --------------------------------------------------------------------

local SECTIONS = {
  { "env", section_env },
  { "render", section_render },
  { "mem", section_mem },
  { "fs", section_fs },
  { "shell", section_shell, true },
  { "gpu", section_gpu, true },
  { "text", section_text, true },
  { "speed", section_speed },
  { "input", section_input, true },
}

local function parse_args(argv)
  local opts = {}
  local i = 1
  while i <= argv.n do
    local a = tostring(argv[i])
    if a == "--help" or a == "-h" then
      opts.help = true
    elseif a == "--no-interactive" then
      opts.no_interactive = true
    elseif a == "--skip-render" then
      opts.skip_render = true
    elseif a == "--dir" or a == "--out" then
      local v = argv[i + 1]
      if type(v) ~= "string" or v == "" then
        return nil, a .. " needs a value"
      end
      opts[a:sub(3)] = v
      i = i + 1
    else
      return nil, "unknown argument: " .. a
    end
    i = i + 1
  end
  if opts.dir then
    opts.dir, opts.dir_method = shell.resolve(opts.dir), "--dir"
  else
    opts.dir, opts.dir_method = SCRIPT_DIR, SCRIPT_DIR_METHOD
  end
  opts.out = shell.resolve(opts.out or join(opts.dir, "probe2.txt"))
  return opts
end

local function run_sections()
  for i, s in ipairs(SECTIONS) do
    print(string.format("probe2: [%d/%d] %s", i, #SECTIONS, s[1]))
    local R = make_recorder(s[1])
    local ok, err = pcall(s[2], R)
    if s[3] then
      restore_screen()
    end
    if not ok then
      R.fail("section", err)
    end
    flush()
    yield_now()
  end
end

local function on_interrupt()
  state.interrupt_events = state.interrupt_events + 1
  if not state.expect_interrupt then
    state.interrupt_pending = true
  end
end

local function main(...)
  local opts, perr = parse_args(table.pack(...))
  if not opts then
    io.stderr:write("probe2: " .. perr .. "\n" .. USAGE .. "\n")
    return 2
  end
  if opts.help then
    print(USAGE)
    return 0
  end
  state.opts = opts

  local out, oerr = io.open(opts.out, "w")
  if not out then
    io.stderr:write("probe2: cannot open " .. opts.out .. ": " .. tostring(oerr) .. "\n")
    return 1
  end
  state.out = out
  local start = wall()

  emit("#probe2 v1", true)
  local P = make_recorder("probe")
  P.set("args", table.concat({ ... }, " "))
  P.set("no_interactive", opts.no_interactive == true)
  P.set("skip_render", opts.skip_render == true)
  flush()

  if component.isAvailable("gpu") then
    state.gpu = component.gpu
  end
  save_screen()
  local listening = pcall(event.listen, "interrupted", on_interrupt)

  local ok, err = xpcall(run_sections, function(e) return e end)
  restore_screen()
  cleanup_temps()
  if state.cwd then
    pcall(shell.setWorkingDirectory, state.cwd)
  end
  if listening then
    pcall(event.ignore, "interrupted", on_interrupt)
  end
  if not ok then
    if is_interrupt(err) then
      emit("probe.interrupted=true", true)
    else
      state.errors = state.errors + 1
      emit("probe.fatal=ERR " .. escape(err_text(err)), true)
    end
  end
  emit("probe.interrupt_listener=" .. tostring(listening), true)
  emit("probe.output_bytes=" .. state.out_bytes, true)
  emit("probe.suppressed_lines=" .. state.suppressed, true)
  emit("probe.errors=" .. state.errors, true)
  emit("probe.duration_ms=" .. ms(wall() - start), true)
  pcall(flush)
  pcall(out.close, out)

  print("probe2: output " .. opts.out)
  print("probe2: size " .. tostring(fs.size(opts.out)) .. " bytes")
  print("probe2: errors " .. state.errors)
  return 0
end

return main(...)
