-- probe: measures an OpenComputers machine and writes one fact per line.
-- Usage: probe [--quick] [--label NAME] [--out PATH]
-- The code avoids Lua 5.3-only syntax so it also runs (and reports) on Lua 5.2.

local component = require("component")
local computer = require("computer")
local fs = require("filesystem")
local shell = require("shell")
local term = require("term")

local USAGE = "Usage: probe [--quick] [--label NAME] [--out PATH]\n" ..
  "  --quick       only the env, lua, text and gpu sections\n" ..
  "  --label NAME  label for the output (default: default)\n" ..
  "  --out PATH    output file (default: /home/probe-<label>.txt)"

-- OpenOS kills a program after about 5 s without a yield. Stay far below it.
local YIELD_INTERVAL = 0.25
-- Each timed item stays below the 0.5 s no-yield rule.
local BENCH_LIMIT = 0.4
-- Growth tests stop above this reserve so the machine never runs out of memory.
local MEMORY_RESERVE = 96 * 1024
local MAX_LINE = 200
-- Hard cap on the output file. The target is about 20 KB.
local MAX_OUTPUT = 30 * 1024
local MAX_COMPONENTS = 24
local SHORT_ADDRESS = 8

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
  -- Iteration caps for timed loops, used when no clock advances inside a slice.
  max_passes = 4,
  max_calls = 2000,
}

-- Clocks ------------------------------------------------------------------

local function wall()
  return computer.uptime()
end

local cpu_fn = computer.uptime
local clock_name = "uptime"
if type(os.clock) == "function" and pcall(os.clock) then
  cpu_fn = os.clock
  clock_name = "os.clock"
end

local function cpu()
  return cpu_fn()
end

local last_cpu, last_wall = cpu(), wall()

local function yield_now()
  os.sleep(0)
  last_cpu, last_wall = cpu(), wall()
end

local function tick()
  if cpu() - last_cpu > YIELD_INTERVAL or wall() - last_wall > YIELD_INTERVAL then
    yield_now()
  end
end

-- Returns true when a clock advances inside one busy loop.
local function clock_advances(fn)
  local start = fn()
  for _ = 1, 50000 do
    if fn() ~= start then
      return true
    end
  end
  return false
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

local function hex(v)
  return string.format("0x%06X", math.floor(v))
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

local function make_record(prefix)
  local function record(key, value)
    emit(prefix .. "." .. key .. "=" .. fmt(value))
  end

  -- An interrupt (Ctrl+C) is passed up so the user can stop the probe.
  local function fail(key, err)
    if is_interrupt(err) then
      error(err, 0)
    end
    state.errors = state.errors + 1
    emit(prefix .. "." .. key .. "=ERR " .. escape(err_text(err)))
  end

  local function try(key, fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then
      record(key, v)
    else
      fail(key, v)
    end
    return ok, v
  end

  return record, try, fail
end

local function record_list(record, key, items)
  record(key .. ".count", #items)
  local chunk, len, part = {}, 0, 0
  local function push()
    part = part + 1
    record(key .. "." .. part, table.concat(chunk, ","))
    chunk, len = {}, 0
  end
  for _, item in ipairs(items) do
    if len + #item + 1 > 150 and #chunk > 0 then
      push()
    end
    chunk[#chunk + 1] = item
    len = len + #item + 1
  end
  if #chunk > 0 then
    push()
  end
end

-- Shared helpers ----------------------------------------------------------

local function device_info()
  if state.device_info == nil then
    local ok, info = pcall(computer.getDeviceInfo)
    if ok and type(info) == "table" then
      state.device_info = info
    else
      state.device_info = false
    end
  end
  return state.device_info or {}
end

local INFO_FIELDS = { "class", "description", "product", "capacity", "width", "clock" }

local function record_info(record, key, info)
  if type(info) ~= "table" then
    record(key .. ".info", "none")
    return
  end
  for _, field in ipairs(INFO_FIELDS) do
    if info[field] ~= nil then
      record(key .. "." .. field, info[field])
    end
  end
end

local function method_set(addr)
  local ok, methods = pcall(component.methods, addr)
  if ok and type(methods) == "table" then
    return methods
  end
  return {}
end

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = tostring(k)
  end
  table.sort(keys)
  return keys
end

-- Runs op(i) until BENCH_LIMIT passes on either clock. Returns calls, wall s, cpu s.
local function bench(op)
  yield_now()
  local c0, w0 = cpu(), wall()
  local n = 0
  repeat
    op(n)
    n = n + 1
  until cpu() - c0 >= BENCH_LIMIT or wall() - w0 >= BENCH_LIMIT or n >= state.max_calls
  local dc, dw = cpu() - c0, wall() - w0
  yield_now()
  return n, dw, dc
end

local function record_bench(record, key, n, dw, dc)
  record(key .. ".calls", n)
  record(key .. ".wall_ms", ms(dw))
  record(key .. ".cpu_ms", ms(dc))
  record(key .. ".per_s", rate(n, dw > 0 and dw or dc))
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

-- Screen ------------------------------------------------------------------

local function save_screen()
  local gpu = state.gpu
  if not gpu then
    return
  end
  local saved = { palette = {} }
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
  for i = 0, 15 do
    local ok_p, color = pcall(gpu.getPaletteColor, i)
    if ok_p then
      saved.palette[i] = color
    end
  end
  state.saved = saved
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
    if saved.fg then
      pcall(gpu.setForeground, saved.fg, saved.fg_pal)
    end
    if saved.bg then
      pcall(gpu.setBackground, saved.bg, saved.bg_pal)
    end
  end
  pcall(term.clear)
end

-- Test data ---------------------------------------------------------------

local WORDS = {
  "the", "page", "link", "html", "viewer", "render", "server", "table", "open",
  "computer", "screen", "memory", "energy", "quarry", "reactor", "turbine",
  "cable", "network", "item", "fluid", "steam", "boiler", "circuit", "wire",
  "machine", "assembler", "chest", "drawer", "robot", "drone", "a", "of",
}

local part_buf = {}

-- Builds one part of about 24 characters. Returns the part and the next seed.
local function make_part(seed)
  local n, len = 0, 0
  while len < 24 do
    seed = (seed * 75 + 74) % 65537
    n = n + 1
    part_buf[n] = WORDS[seed % #WORDS + 1]
    len = len + #part_buf[n] + 1
  end
  return table.concat(part_buf, " ", 1, n), seed
end

-- Three parts of one line. The line number keeps each line unique.
local function gen_parts(i)
  local seed = (i * 7919) % 65537
  local a, b, c
  a, seed = make_part(seed)
  b, seed = make_part(seed)
  c = make_part(seed)
  return i .. " " .. a, b, c
end

local function make_html(size)
  local parts, len, i = {}, 0, 0
  while len < size do
    i = i + 1
    parts[i] = string.format(
      '<p class="x">Some <a href="/wiki/Page_%d">linked text</a> and  more\twords here.</p>\n', i)
    len = len + #parts[i]
    tick()
  end
  return table.concat(parts):sub(1, size)
end

-- Section: env ------------------------------------------------------------

local function section_env(record, try, fail)
  record("lua_version", _VERSION)
  record("os_version", _G._OSVERSION)
  try("architecture", computer.getArchitecture)
  try("architectures", function()
    return table.concat(computer.getArchitectures(), ",")
  end)
  record("total_memory", computer.totalMemory())
  record("free_memory", computer.freeMemory())
  try("energy", computer.energy)
  try("max_energy", computer.maxEnergy)
  record("uptime_ms", ms(computer.uptime()))
  try("boot_address", function() return short(computer.getBootAddress()) end)
  try("tmp_address", function() return short(computer.tmpAddress()) end)

  local info = device_info()
  if state.device_info == false then
    fail("device_info", "computer.getDeviceInfo failed")
  end

  local list = {}
  for addr, ctype in component.list() do
    list[#list + 1] = { addr = addr, ctype = ctype }
  end
  table.sort(list, function(x, y)
    if x.ctype ~= y.ctype then
      return x.ctype < y.ctype
    end
    return x.addr < y.addr
  end)
  record("components", #list)

  local known, listed_type = {}, {}
  for i, c in ipairs(list) do
    known[c.addr] = true
    if i <= MAX_COMPONENTS then
      local key = "comp." .. i
      record(key .. ".type", c.ctype)
      record(key .. ".addr", short(c.addr))
      record_info(record, key, info[c.addr])
      -- Method lists repeat for components of the same type. List each type once.
      if not listed_type[c.ctype] then
        listed_type[c.ctype] = true
        local ok, methods = pcall(component.methods, c.addr)
        if ok then
          record_list(record, key .. ".methods", sorted_keys(methods))
        else
          fail(key .. ".methods", methods)
        end
      end
    end
    tick()
  end
  if #list > MAX_COMPONENTS then
    record("components_not_listed", #list - MAX_COMPONENTS)
  end

  -- Devices that are not components, such as the CPU and the memory sticks.
  local others = {}
  for addr, d in pairs(info) do
    if not known[addr] then
      others[#others + 1] = { addr = addr, info = d }
    end
  end
  table.sort(others, function(x, y)
    local cx, cy = tostring(x.info.class), tostring(y.info.class)
    if cx ~= cy then
      return cx < cy
    end
    return x.addr < y.addr
  end)
  record("devices", #others)
  for i, d in ipairs(others) do
    if i > MAX_COMPONENTS then
      break
    end
    record("dev." .. i .. ".addr", short(d.addr))
    record_info(record, "dev." .. i, d.info)
  end
end

-- Section: lua ------------------------------------------------------------

local LUA_NAMES = {
  "utf8", "string.pack", "string.unpack", "string.dump", "table.move", "table.pack",
  "table.unpack", "math.type", "math.tointeger", "math.ult", "collectgarbage",
  "debug", "debug.traceback", "debug.getinfo", "debug.sethook", "load",
  "loadstring", "setfenv", "coroutine", "coroutine.isyieldable", "os.clock",
  "os.time", "os.date", "bit32",
}

local function lookup(name)
  local v = _G
  for part in name:gmatch("[^%.]+") do
    if type(v) ~= "table" then
      return nil
    end
    v = v[part]
  end
  return v
end

local function section_lua(record, try, fail)
  record("version", _VERSION)
  for _, name in ipairs(LUA_NAMES) do
    record("has." .. name, type(lookup(name)))
  end
  if type(debug) == "table" then
    record_list(record, "debug_functions", sorted_keys(debug))
  end

  try("int_div", function()
    local v = assert(load("return 7 // 2"))()
    return tostring(v) .. " " .. tostring(math.type and math.type(v))
  end)
  try("bitwise", function()
    local f = assert(load("return 5 & 3, 5 | 3, 5 ~ 3, ~0, 1 << 4, 256 >> 4"))
    return table.concat({ f() }, ",")
  end)
  try("goto", function()
    return assert(load("local n = 0 ::top:: n = n + 1 if n < 3 then goto top end return n"))()
  end)
  try("math_type", function()
    return math.type(1) .. "," .. math.type(1.0) .. "," .. tostring(math.type("1"))
  end)
  try("maxinteger", function() return tostring(math.maxinteger) end)
  try("integer_bytes", function() return #string.pack("j", 0) end)
  try("float_tostring", function()
    return tostring(3.0) .. " " .. tostring(1 / 0) .. " " .. tostring(2 ^ 53)
  end)
  try("utf8_charpattern", function() return utf8.charpattern end)
  try("load_env", function()
    return assert(load("return x", "=probe", "t", { x = 42 }))()
  end)
  try("load_env_isolated", function()
    return assert(load("return print", "=probe", "t", {}))() == nil
  end)
  try("load_binary_refused", function()
    local f = load(string.dump(function() end), "=probe", "t")
    return f == nil
  end)
  try("collectgarbage_count", function() return collectgarbage("count") end)
  try("os_clock", os.clock)
  try("os_time", os.time)
  try("os_date", function() return os.date("%Y-%m-%d %H:%M:%S") end)
  try("coroutine_isyieldable", function() return coroutine.isyieldable() end)

  try("error_table_pcall", function()
    local _, e = pcall(error, { reason = "x" })
    return type(e) .. ":" .. tostring(type(e) == "table" and e.reason)
  end)
  try("error_table_xpcall", function()
    local _, e = xpcall(function() error({ reason = "x" }) end, function(m) return m end)
    return type(e) .. ":" .. tostring(type(e) == "table" and e.reason)
  end)
  try("error_table_xpcall_traceback", function()
    local _, e = xpcall(function() error({ reason = "x" }) end, debug.traceback)
    return type(e) .. ":" .. tostring(type(e) == "table" and e.reason)
  end)
  try("traceback_in_xpcall", function()
    local _, tb = xpcall(function() error("boom") end, debug.traceback)
    return type(tb) == "string" and tb:find("stack traceback", 1, true) ~= nil
  end)
  try("traceback_first_line", function()
    local _, tb = xpcall(function() error("boom") end, debug.traceback)
    return (tostring(tb):match("^[^\n]*"))
  end)
  try("error_level0", function()
    local _, e = pcall(error, "msg", 0)
    return e
  end)
  try("error_level1", function()
    local _, e = pcall(function() error("msg") end)
    return e
  end)
  try("yield_in_pcall", function()
    local co = coroutine.create(function()
      return pcall(function()
        return coroutine.yield(1) + 1
      end)
    end)
    local _, first = coroutine.resume(co)
    local _, ok, v = coroutine.resume(co, 41)
    return tostring(first) .. "," .. tostring(ok) .. "," .. tostring(v)
  end)
  try("sleep_in_pcall", function()
    local ok, e = pcall(os.sleep, 0)
    if not ok and is_interrupt(e) then
      error(e, 0)
    end
    return ok
  end)
end

-- Section: memory ---------------------------------------------------------

local has_gc = type(collectgarbage) == "function" and (pcall(collectgarbage, "count"))

-- Without collectgarbage, yields give the Lua GC time, and the highest
-- reading has the least garbage in it.
local function settle_free()
  if has_gc then
    collectgarbage("collect")
    collectgarbage("collect")
    local free = computer.freeMemory()
    yield_now()
    return free
  end
  local best = 0
  for _ = 1, 5 do
    yield_now()
    local free = computer.freeMemory()
    if free > best then
      best = free
    end
  end
  return best
end

-- freeMemory() also counts garbage. Settle and check again before a stop,
-- at most MAX_RECHECKS times per test because each settle costs time.
local MAX_RECHECKS = 20

local function has_room(need, checks)
  if computer.freeMemory() >= need then
    return true
  end
  if checks.n >= MAX_RECHECKS then
    return false
  end
  checks.n = checks.n + 1
  return settle_free() >= need
end

local function measure_items(record, key, n, item_bytes, make)
  local base = settle_free()
  local holder = {}
  for i = 1, n do
    holder[i] = false
  end
  local before = settle_free()
  local count, low, checks = 0, false, { n = 0 }
  for i = 1, n do
    if not has_room(MEMORY_RESERVE + item_bytes, checks) then
      low = true
      break
    end
    holder[i] = make(i)
    count = i
    tick()
  end
  local after = settle_free()
  holder = nil
  local released = settle_free()
  record(key .. ".count", count)
  if count > 0 then
    record(key .. ".bytes_per_item", (before - after) / count)
  end
  record(key .. ".release_delta", released - base)
  if low then
    record(key .. ".stopped_low_memory", true)
  end
end

local LINE_FORMATS = {
  {
    name = "plain",
    slots = 1,
    new = function() return {} end,
    add = function(store, i, a, b, c)
      store[i] = a .. " " .. b .. " " .. c
    end,
  },
  {
    name = "runs",
    slots = 1,
    new = function() return {} end,
    add = function(store, i, a, b, c)
      store[i] = { { a, 1 }, { b, 2 }, { c, 3 } }
    end,
  },
  {
    name = "inline",
    slots = 1,
    new = function() return {} end,
    add = function(store, i, a, b, c)
      store[i] = "\1" .. a .. "\2 " .. b .. "\3 " .. c
    end,
  },
  {
    name = "flat",
    slots = 6,
    new = function() return { runs = {}, starts = {}, n = 0 } end,
    add = function(store, i, a, b, c)
      local runs, n = store.runs, store.n
      store.starts[i] = n + 1
      runs[n + 1], runs[n + 2] = a, 1
      runs[n + 3], runs[n + 4] = b, 2
      runs[n + 5], runs[n + 6] = c, 3
      store.n = n + 6
    end,
  },
}

local function measure_lines(record, key, n, format)
  local before = settle_free()
  local store = format.new()
  local count, low, cap, checks = 0, false, 4, { n = 0 }
  for i = 1, n do
    local need = MEMORY_RESERVE
    -- A table rehash allocates the doubled array (16 bytes per slot) while the old one is alive.
    if format.slots * i > cap then
      need = need + 32 * cap
    end
    if not has_room(need, checks) then
      low = true
      break
    end
    while format.slots * i > cap do
      cap = cap * 2
    end
    format.add(store, i, gen_parts(i))
    count = i
    tick()
  end
  local after = settle_free()
  store = nil
  local released = settle_free()
  record(key .. ".count", count)
  if count > 0 then
    record(key .. ".bytes_per_line", (before - after) / count)
  end
  record(key .. ".release_delta", released - before)
  record(key .. ".rechecks", checks.n)
  if low then
    record(key .. ".stopped_low_memory", true)
    record(key .. ".free_at_stop", after)
  end
end

local function section_memory(record, try, fail)
  record("method", has_gc and "collectgarbage" or "yield_max_of_5")
  local readings, low, high = {}, math.huge, 0
  for k = 1, 5 do
    readings[k] = settle_free()
    low = math.min(low, readings[k])
    high = math.max(high, readings[k])
  end
  record("noise.readings", table.concat(readings, ","))
  record("noise.spread", high - low)
  record("total", computer.totalMemory())
  record("free", high)

  local function run(fn, key, ...)
    local ok, err = pcall(fn, record, key, ...)
    if not ok then
      fail(key, err)
    end
  end

  run(measure_items, "empty_table", 1000, 0, function() return {} end)
  run(measure_items, "table4", 1000, 0, function() return { 1, 2, 3, 4 } end)
  local string_tests = { { "str80", 80, 200 }, { "str1k", 1024, 64 }, { "str64k", 65536, 4 } }
  for _, t in ipairs(string_tests) do
    run(function(_, key, size, n)
      if computer.freeMemory() < MEMORY_RESERVE + 3 * size then
        record(key .. ".skipped", "low memory")
        return
      end
      local base = string.rep("x", size - 8)
      measure_items(record, key, n, 2 * size, function(i)
        return base .. string.format("%08d", i)
      end)
    end, t[1], t[2], t[3])
  end

  local total, sample = 0, 100
  for i = 1, sample do
    local a, b, c = gen_parts(i)
    total = total + #a + #b + #c + 2
  end
  record("lines.avg_chars", total / sample)
  for _, format in ipairs(LINE_FORMATS) do
    for _, n in ipairs({ 1000, 10000 }) do
      run(measure_lines, "lines." .. format.name .. "." .. n, n, format)
    end
  end
end

-- Section: timing ---------------------------------------------------------

-- Smallest non-zero step of a clock inside one busy loop.
local function resolution(fn)
  local min_step, prev, changes = math.huge, fn(), 0
  local c0, w0 = cpu(), wall()
  for k = 1, 100000 do
    local v = fn()
    if v ~= prev then
      local d = v - prev
      if d > 0 and d < min_step then
        min_step = d
      end
      changes = changes + 1
      prev = v
    end
    if k % 1000 == 0 and (cpu() - c0 > 0.2 or wall() - w0 > 0.2) then
      break
    end
  end
  return min_step, changes
end

-- Runs pass(over) until BENCH_LIMIT. Each pass returns the bytes it processed.
local function run_rate(record, key, pass)
  yield_now()
  local c0, w0 = cpu(), wall()
  local function over()
    return cpu() - c0 >= BENCH_LIMIT or wall() - w0 >= BENCH_LIMIT
  end
  local bytes, passes = 0, 0
  repeat
    bytes = bytes + pass(over)
    passes = passes + 1
  until over() or passes >= state.max_passes
  local dc, dw = cpu() - c0, wall() - w0
  yield_now()
  record(key .. ".passes", passes)
  record(key .. ".cpu_ms", ms(dc))
  record(key .. ".wall_ms", ms(dw))
  record(key .. ".kb_per_s", rate(bytes / 1024, dc > 0 and dc or dw))
end

local function section_timing(record, try, fail)
  record("clock_source", clock_name)
  yield_now()
  local step, changes = resolution(computer.uptime)
  record("uptime.busy_min_step_ms", step < math.huge and ms(step) or "none")
  record("uptime.busy_changes", changes)
  yield_now()
  if clock_name == "os.clock" then
    step, changes = resolution(os.clock)
    record("os_clock.min_step_ms", step < math.huge and ms(step) or "none")
    record("os_clock.changes", changes)
  end

  local ok, err = pcall(function()
    yield_now()
    local w0, c0 = wall(), cpu()
    local prev, min_step = w0, math.huge
    for _ = 1, 20 do
      os.sleep(0)
      local now = wall()
      if now - prev > 0 and now - prev < min_step then
        min_step = now - prev
      end
      prev = now
    end
    record("sleep0.avg_wall_ms", ms((wall() - w0) / 20))
    record("sleep0.avg_cpu_ms", ms((cpu() - c0) / 20))
    record("uptime.yield_min_step_ms", min_step < math.huge and ms(min_step) or "none")
    last_cpu, last_wall = cpu(), wall()
  end)
  if not ok then
    fail("sleep0", err)
  end

  ok, err = pcall(function()
    local w0, c0 = wall(), cpu()
    local signals = 0
    for _ = 1, 20 do
      if computer.pullSignal(0) ~= nil then
        signals = signals + 1
      end
    end
    record("pull_signal0.avg_wall_ms", ms((wall() - w0) / 20))
    record("pull_signal0.avg_cpu_ms", ms((cpu() - c0) / 20))
    record("pull_signal0.signals_seen", signals)
    last_cpu, last_wall = cpu(), wall()
  end)
  if not ok then
    fail("pull_signal0", err)
  end

  local html = make_html(65536)
  record("html_bytes", #html)
  local find, byte = string.find, string.byte

  local tests = {
    { "find_lt", function(over)
      local i, n, count = 1, #html, 0
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
    { "byte_loop", function(over)
      local i, n = 1, #html
      while i <= n do
        local stop = math.min(n, i + 4095)
        for k = i, stop do
          local _ = byte(html, k)
        end
        i = stop + 1
        if over() then
          break
        end
      end
      return i - 1
    end },
    { "gmatch_words", function(over)
      local count, last = 0, 0
      for pos in html:gmatch("()%S+") do
        count = count + 1
        last = pos
        if count % 256 == 0 and over() then
          return last
        end
      end
      return #html
    end },
    { "gsub_space", function()
      local _ = html:gsub("%s+", " ")
      return #html
    end },
  }
  for _, t in ipairs(tests) do
    ok, err = pcall(run_rate, record, t[1], t[2])
    if not ok then
      fail(t[1], err)
    end
  end

  ok, err = pcall(function()
    local parts, bytes = {}, 0
    for i = 1, 1000 do
      parts[i] = html:sub(i * 64 - 63, i * 64)
      bytes = bytes + #parts[i]
    end
    run_rate(record, "concat_1000", function()
      local _ = table.concat(parts)
      return bytes
    end)
  end)
  if not ok then
    fail("concat_1000", err)
  end
  html = nil

  local unit = "abc \xE4\xB8\xAD\xE6\x96\x87 text \xE2\x94\x80 "
  local units = {}
  for i = 1, math.floor(4096 / #unit) do
    units[i] = unit
  end
  local mixed = table.concat(units)
  record("mixed_bytes", #mixed)
  local unicode_ok, unicode = pcall(require, "unicode")
  ok, err = pcall(function()
    if not unicode_ok then
      error("no unicode library")
    end
    run_rate(record, "unicode_wlen", function()
      unicode.wlen(mixed)
      return #mixed
    end)
  end)
  if not ok then
    fail("unicode_wlen", err)
  end
  ok, err = pcall(function()
    run_rate(record, "utf8_len", function()
      utf8.len(mixed)
      return #mixed
    end)
  end)
  if not ok then
    fail("utf8_len", err)
  end
end

-- Section: file -----------------------------------------------------------

local READ_SIZES = { 256, 1024, 2048, 4096, 8192, math.huge }

local function size_name(size)
  if size == math.huge then
    return "huge"
  end
  return tostring(size)
end

local function write_test_file(record, key, path, size)
  state.temp_files[#state.temp_files + 1] = path
  local chunk = make_html(4096)
  local f = assert(io.open(path, "wb"))
  yield_now()
  local c0, w0 = cpu(), wall()
  local written = 0
  while written < size do
    local n = math.min(4096, size - written)
    f:write(n == 4096 and chunk or chunk:sub(1, n))
    written = written + n
    tick()
  end
  f:close()
  local dc, dw = cpu() - c0, wall() - w0
  record(key .. ".size", written)
  record(key .. ".write_wall_ms", ms(dw))
  record(key .. ".write_kb_per_s", rate(written / 1024, dw > 0 and dw or dc))
end

local function read_test(record, key, reader)
  yield_now()
  local c0, w0 = cpu(), wall()
  local calls, bytes, first = 0, 0, nil
  repeat
    local data = reader()
    if not data then
      break
    end
    calls = calls + 1
    bytes = bytes + #data
    first = first or #data
  until cpu() - c0 >= BENCH_LIMIT or wall() - w0 >= BENCH_LIMIT or calls >= state.max_calls
  local dc, dw = cpu() - c0, wall() - w0
  record(key .. ".first", first)
  record(key .. ".calls", calls)
  record(key .. ".kb_per_s", rate(bytes / 1024, dw > 0 and dw or dc))
end

local function read_tests(record, fail, key, path)
  for _, size in ipairs(READ_SIZES) do
    local name = key .. ".io." .. size_name(size)
    local f
    local ok, err = pcall(function()
      f = assert(io.open(path, "rb"))
      read_test(record, name, function() return f:read(size) end)
    end)
    if f then
      pcall(f.close, f)
    end
    if not ok then
      fail(name, err)
    end
  end
  for _, size in ipairs(READ_SIZES) do
    local name = key .. ".raw." .. size_name(size)
    local proxy, handle
    local ok, err = pcall(function()
      local mount
      proxy, mount = fs.get(path)
      if mount:sub(-1) ~= "/" then
        mount = mount .. "/"
      end
      if mount:sub(1, 1) ~= "/" then
        mount = "/" .. mount
      end
      local rel = path
      if path:sub(1, #mount) == mount then
        rel = path:sub(#mount + 1)
      end
      handle = assert(proxy.open(rel, "r"))
      read_test(record, name, function() return proxy.read(handle, size) end)
    end)
    if proxy and handle then
      pcall(proxy.close, handle)
    end
    if not ok then
      fail(name, err)
    end
  end
end

local function drive_space(record, key, addr)
  local proxy = component.proxy(addr)
  local total, used = proxy.spaceTotal(), proxy.spaceUsed()
  record(key .. ".addr", short(addr))
  record(key .. ".total", total)
  record(key .. ".free", total - used)
  return total - used
end

local function section_file(record, try, fail)
  local label = state.opts.label
  local ok, tmp_free = pcall(drive_space, record, "tmp", computer.tmpAddress())
  if not ok then
    fail("tmp", tmp_free)
    tmp_free = nil
  end
  local boot_free
  ok, boot_free = pcall(drive_space, record, "boot", computer.getBootAddress())
  if not ok then
    fail("boot", boot_free)
    boot_free = nil
  end

  local targets = {}
  if tmp_free then
    -- The tmpfs is often only 64 KB, so the file uses what fits.
    local size = math.min(65536, math.floor((tmp_free - 4096) / 1024) * 1024)
    if size >= 4096 then
      targets[#targets + 1] = { "tmp", "/tmp/probe-" .. label .. ".bin", size }
    else
      record("tmp.skipped", "not enough space")
    end
  end
  if boot_free and boot_free > 2 * 65536 then
    -- The boot drive file sits next to the output file and is removed after the test.
    targets[#targets + 1] = { "disk", state.opts.out .. ".tmp", 65536 }
  else
    record("disk.skipped", "not enough space or no boot drive")
  end

  for _, t in ipairs(targets) do
    local key, path, size = t[1], t[2], t[3]
    local ok_w, err = pcall(function()
      local proxy = fs.get(path)
      record(key .. ".file_drive", short(proxy and proxy.address))
      write_test_file(record, key, path, size)
      read_tests(record, fail, key, path)
    end)
    if not ok_w then
      fail(key, err)
    end
    local ok_r, rerr = pcall(remove_temp, path)
    if not ok_r then
      fail(key .. ".remove", rerr)
    end
    record(key .. ".removed", not fs.exists(path))
  end

  local crlf = "a\r\nb\nc\r"
  local path = "/tmp/probe-" .. label .. ".crlf"
  state.temp_files[#state.temp_files + 1] = path
  ok = pcall(function()
    local f = assert(io.open(path, "wb"))
    f:write(crlf)
    f:close()
  end)
  if ok then
    try("textmode.read", function()
      local f = assert(io.open(path, "r"))
      local data = f:read("*a")
      f:close()
      return data
    end)
    try("textmode.read_changed", function()
      local f = assert(io.open(path, "r"))
      local data = f:read("*a")
      f:close()
      return data ~= crlf
    end)
    try("textmode.lines", function()
      local f = assert(io.open(path, "r"))
      local out = {}
      for line in f:lines() do
        out[#out + 1] = line
      end
      f:close()
      return table.concat(out, "|")
    end)
    try("textmode.write", function()
      local f = assert(io.open(path, "w"))
      f:write(crlf)
      f:close()
      f = assert(io.open(path, "rb"))
      local data = f:read("*a")
      f:close()
      return data
    end)
  else
    fail("textmode", "cannot write " .. path)
  end
  local ok_r, rerr = pcall(remove_temp, path)
  if not ok_r then
    fail("textmode.remove", rerr)
  end
end

-- Section: text -----------------------------------------------------------

local TEXT_CASES = {
  { "ascii", "abc" },
  { "e_acute", "\xC3\xA9" },
  { "box", "\xE2\x94\x80" },
  { "zh", "\xE4\xB8\xAD\xE6\x96\x87" },
  { "ja", "\xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E\xE3\x83\x86\xE3\x82\xAD\xE3\x82\xB9\xE3\x83\x88" },
  { "emoji", "\xF0\x9F\x98\x80" },
  { "combining", "e\xCC\x81" },
  { "lone_cont", "\x80" },
  { "truncated", "\xE4\xB8" },
  { "overlong", "\xC0\xAF" },
  { "surrogate", "\xED\xA0\x80" },
  { "zwsp", "\xE2\x80\x8B" },
}

local function section_text(record, try, fail)
  local unicode_ok, unicode = pcall(require, "unicode")
  record("has_unicode", unicode_ok)
  record("has_utf8", type(utf8) == "table")
  for _, case in ipairs(TEXT_CASES) do
    local name, s = case[1], case[2]
    record(name .. ".bytes", s)
    try(name .. ".len", function() return unicode.len(s) end)
    try(name .. ".wlen", function() return unicode.wlen(s) end)
    try(name .. ".char_width", function() return unicode.charWidth(unicode.sub(s, 1, 1)) end)
    try(name .. ".is_wide", function() return unicode.isWide(unicode.sub(s, 1, 1)) end)
    try(name .. ".utf8_len", function()
      local n, pos = utf8.len(s)
      if n == nil then
        return "nil@" .. tostring(pos)
      end
      return n
    end)
    try(name .. ".sub12", function() return unicode.sub(s, 1, 2) end)
    tick()
  end
  for _, cp in ipairs({ 0x41, 0x2500, 0x1F600, 0x110000 }) do
    try(string.format("char.%X", cp), function() return unicode.char(cp) end)
  end
  try("wtrunc_zh_3", function() return unicode.wtrunc("\xE4\xB8\xAD\xE6\x96\x87abc", 3) end)
end

-- Section: gpu ------------------------------------------------------------

local function section_gpu(record, try, fail)
  local gpu = state.gpu
  if not gpu then
    record("present", false)
    return
  end
  local screen_addr = gpu.getScreen()
  if not screen_addr then
    record("present", true)
    record("screen", "none")
    return
  end
  record("present", true)
  record("addr", short(gpu.address))
  record("screen.addr", short(screen_addr))
  local info = device_info()
  record_info(record, "info", info[gpu.address])
  record_info(record, "screen.info", info[screen_addr])

  try("max_resolution", function()
    local w, h = gpu.maxResolution()
    return w .. "x" .. h
  end)
  try("resolution", function()
    local w, h = gpu.getResolution()
    return w .. "x" .. h
  end)
  try("max_depth", gpu.maxDepth)
  try("depth", gpu.getDepth)
  local methods = method_set(gpu.address)
  if methods.getViewport then
    try("viewport", function()
      local w, h = gpu.getViewport()
      return w .. "x" .. h
    end)
  end
  local ok_depth, depth = pcall(gpu.getDepth)
  if ok_depth and depth == 1 then
    -- A depth-1 screen has no palette. Reading it only raises errors.
    record("palette", "none at depth 1")
  else
    for i = 0, 15 do
      try("palette." .. i, function() return hex(gpu.getPaletteColor(i)) end)
    end
  end

  local screen = component.proxy(screen_addr)
  local screen_methods = method_set(screen_addr)
  if screen_methods.isPrecise then
    try("screen.precise", screen.isPrecise)
  end
  if screen_methods.getAspectRatio then
    try("screen.aspect", function()
      local w, h = screen.getAspectRatio()
      return w .. "x" .. h
    end)
  end
  if screen_methods.getKeyboards then
    try("screen.keyboards", function() return #screen.getKeyboards() end)
  end

  for _, name in ipairs({ "allocateBuffer", "freeBuffer", "setActiveBuffer", "bitblt",
      "freeMemory", "totalMemory", "getViewport" }) do
    record("has." .. name, methods[name] ~= nil)
  end
  if methods.totalMemory then
    try("vram_total", gpu.totalMemory)
  end
  if methods.freeMemory then
    try("vram_free", gpu.freeMemory)
  end

  local w, h = gpu.getResolution()
  local s160 = string.rep("x", 160)
  local saved = state.saved or {}
  local function reset_colors()
    if saved.fg then
      pcall(gpu.setForeground, saved.fg, saved.fg_pal)
    end
    if saved.bg then
      pcall(gpu.setBackground, saved.bg, saved.bg_pal)
    end
  end

  local rates = {
    { "set1", function(n) gpu.set(n % w + 1, n % 8 + 1, "#") end },
    { "set160", function(n) gpu.set(1, n % 10 + 1, s160) end },
    { "fill160", function(n) gpu.fill(1, n % 10 + 1, 160, 1, " ") end },
    { "copy160x10", function() gpu.copy(1, 1, 160, 10, 0, 1) end },
    { "fg_changed", function(n) gpu.setForeground(n % 2 == 0 and 0xFFFFFF or 0x000000) end },
    { "fg_same", function() gpu.setForeground(0xFFFFFF) end },
  }
  for _, r in ipairs(rates) do
    local ok, err = pcall(function()
      record_bench(record, r[1], bench(r[2]))
    end)
    reset_colors()
    if not ok then
      fail(r[1], err)
    end
  end

  pcall(gpu.fill, 1, 1, w, h, " ")
  try("wide.set", function()
    gpu.fill(1, 1, 6, 1, " ")
    return gpu.set(1, 1, "\xE4\xB8\xAD")
  end)
  for col = 1, 2 do
    try("wide.get" .. col, function()
      local ch, fg, bg = gpu.get(col, 1)
      return string.format("char=%s fg=%s bg=%s", ch, hex(fg), hex(bg))
    end)
  end

  local ok, err = pcall(function()
    local lines = {}
    for i = 1, 50 do
      lines[i] = string.format("%03d ", i) .. string.rep(string.char(97 + i % 26), math.max(0, w - 4))
    end
    for r = 1, 3 do
      yield_now()
      local c0, w0 = cpu(), wall()
      for i = 1, 50 do
        gpu.set(1, (i - 1) % h + 1, lines[i])
      end
      record("redraw50." .. r .. ".wall_ms", ms(wall() - w0))
      record("redraw50." .. r .. ".cpu_ms", ms(cpu() - c0))
    end
    yield_now()
    local c0, w0 = cpu(), wall()
    gpu.fill(1, 1, w, h, " ")
    record("clear.wall_ms", ms(wall() - w0))
    record("clear.cpu_ms", ms(cpu() - c0))
  end)
  if not ok then
    fail("redraw50", err)
  end

  if methods.allocateBuffer then
    ok, err = pcall(function()
      local idx = gpu.allocateBuffer(w, h)
      record("buffer.index", idx)
      if type(idx) ~= "number" or idx <= 0 then
        return
      end
      if methods.freeMemory then
        record("buffer.vram_free_after_alloc", gpu.freeMemory())
      end
      local ok2, err2 = pcall(function()
        gpu.setActiveBuffer(idx)
        record_bench(record, "buffer.set160", bench(function(n) gpu.set(1, n % 10 + 1, s160) end))
        gpu.setActiveBuffer(0)
        for r = 1, 3 do
          yield_now()
          local c0, w0 = cpu(), wall()
          gpu.bitblt(0, 1, 1, w, h, idx, 1, 1)
          record("buffer.bitblt." .. r .. ".wall_ms", ms(wall() - w0))
          record("buffer.bitblt." .. r .. ".cpu_ms", ms(cpu() - c0))
        end
      end)
      pcall(gpu.setActiveBuffer, 0)
      pcall(gpu.freeBuffer, idx)
      if not ok2 then
        error(err2, 0)
      end
    end)
    if not ok then
      fail("buffer", err)
    end
  end
end

-- Section: keyboard -------------------------------------------------------

local function section_keyboard(record, try, fail)
  local keyboard = require("keyboard")
  for _, name in ipairs({ "up", "down", "pageUp", "pageDown", "home", "end", "q", "enter", "c", "lcontrol" }) do
    try("keys." .. name, function() return keyboard.keys[name] end)
  end
end

-- Section: extras ---------------------------------------------------------

local DATA_METHODS = {
  "crc32", "md5", "sha256", "encode64", "decode64", "deflate", "inflate", "getLimit",
  "encrypt", "decrypt", "random", "generateKeyPair", "ecdsa", "ecdh", "deserializeKey",
}

local function section_extras(record, try, fail)
  local info = device_info()
  local inet = component.list("internet")()
  record("internet.present", inet ~= nil)
  if inet then
    local proxy = component.proxy(inet)
    local methods = method_set(inet)
    record("internet.addr", short(inet))
    record_info(record, "internet", info[inet])
    try("internet.http_enabled", proxy.isHttpEnabled)
    try("internet.tcp_enabled", proxy.isTcpEnabled)
    record("internet.has_request", methods.request ~= nil)
    record("internet.has_connect", methods.connect ~= nil)
  end

  local data = component.list("data")()
  record("data.present", data ~= nil)
  if data then
    local proxy = component.proxy(data)
    local methods = method_set(data)
    record("data.addr", short(data))
    record_info(record, "data", info[data])
    for _, name in ipairs(DATA_METHODS) do
      record("data.has." .. name, methods[name] ~= nil)
    end
    local tier = 1
    if methods.encrypt then
      tier = 2
    end
    if methods.generateKeyPair then
      tier = 3
    end
    record("data.tier_from_methods", tier)
    if methods.getLimit then
      try("data.limit", proxy.getLimit)
    end
  end
end

-- Main --------------------------------------------------------------------

local SECTIONS = {
  { name = "env", quick = true, run = section_env },
  { name = "lua", quick = true, run = section_lua },
  { name = "memory", quick = false, run = section_memory },
  { name = "timing", quick = false, run = section_timing },
  { name = "file", quick = false, run = section_file },
  { name = "text", quick = true, run = section_text },
  { name = "gpu", quick = true, run = section_gpu },
  { name = "keyboard", quick = false, run = section_keyboard },
  { name = "extras", quick = false, run = section_extras },
}

local function parse_args(argv)
  local opts = { quick = false, label = "default" }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--quick" then
      opts.quick = true
    elseif a == "--help" or a == "-h" then
      opts.help = true
    elseif a == "--label" or a == "--out" then
      if not argv[i + 1] then
        return nil, a .. " needs a value"
      end
      opts[a:sub(3)] = argv[i + 1]
      i = i + 1
    elseif a:sub(1, 8) == "--label=" then
      opts.label = a:sub(9)
    elseif a:sub(1, 6) == "--out=" then
      opts.out = a:sub(7)
    else
      return nil, "unknown argument: " .. a
    end
    i = i + 1
  end
  opts.label = (opts.label:gsub("[^%w_%-]", "_")):sub(1, 32)
  if opts.label == "" then
    opts.label = "default"
  end
  opts.out = shell.resolve(opts.out or ("/home/probe-" .. opts.label .. ".txt"))
  return opts
end

local function run_sections(opts)
  local selected = {}
  for _, s in ipairs(SECTIONS) do
    if s.quick or not opts.quick then
      selected[#selected + 1] = s
    end
  end
  for i, s in ipairs(selected) do
    print(string.format("probe: [%d/%d] %s", i, #selected, s.name))
    local record, try, fail = make_record(s.name)
    local ok, err = pcall(s.run, record, try, fail)
    if s.name == "gpu" then
      restore_screen()
    end
    if not ok then
      fail("section", err)
    end
    flush()
    yield_now()
  end
end

local function main(...)
  local opts, perr = parse_args({ ... })
  if not opts then
    io.stderr:write("probe: " .. perr .. "\n" .. USAGE .. "\n")
    return 1
  end
  if opts.help then
    print(USAGE)
    return 0
  end
  state.opts = opts

  local out, oerr = io.open(opts.out, "w")
  if not out then
    io.stderr:write("probe: cannot open " .. opts.out .. ": " .. tostring(oerr) .. "\n")
    return 1
  end
  state.out = out
  local start = wall()

  if clock_advances(cpu_fn) or clock_advances(computer.uptime) then
    state.max_passes = 500
    state.max_calls = 50000
  end

  emit("#probe v1 label=" .. opts.label, true)
  local record = make_record("probe")
  record("quick", opts.quick)
  record("clock_source", clock_name)
  record("clock_advances", state.max_calls > 2000)
  flush()

  if component.isAvailable("gpu") then
    state.gpu = component.gpu
  end
  save_screen()

  local ok, err = xpcall(run_sections, function(e) return e end, opts)
  restore_screen()
  cleanup_temps()
  if not ok then
    if is_interrupt(err) then
      emit("probe.interrupted=true", true)
    else
      state.errors = state.errors + 1
      emit("probe.fatal=ERR " .. escape(err_text(err)), true)
    end
  end
  emit("probe.output_bytes=" .. state.out_bytes, true)
  emit("probe.suppressed_lines=" .. state.suppressed, true)
  emit("probe.errors=" .. state.errors, true)
  emit("probe.duration_ms=" .. ms(wall() - start), true)
  pcall(flush)
  pcall(out.close, out)

  print("probe: output " .. opts.out)
  print("probe: size " .. tostring(fs.size(opts.out)) .. " bytes")
  print("probe: errors " .. state.errors)
  return 0
end

return main(...)
