-- netprobe: measures the internet card facts N1 to N15 that the remote fetch
-- code assumes (docs/netprobe-plan.md). It uses component.internet directly.
-- Usage: netprobe [--out PATH] [--base URL] [--echo URL] [--skip-large]
--                 [--leak] [URL ...]
-- The report has one "net.<group>.<name>=<value>" line per fact. It is
-- written after every step, so a stop (Ctrl+C, a crash) keeps what was
-- measured. A body is never kept: the probe counts bytes and keeps small
-- samples only.
-- Loaded with a table as the first argument, the chunk returns its module
-- table M without running. The tests use this.

local M = {}

M.VERSION = 1
M.DEFAULT_OUT = "/home/netprobe.txt"
-- A public echo service with /status, /redirect-to, /redirect, /delay,
-- /headers and /user-agent endpoints. It must answer on http and https.
M.DEFAULT_ECHO = "https://httpbingo.org"
-- The raw URL of the repository files (tests/pages/large.html is fetched
-- from here). The user can change it with --base.
M.DEFAULT_BASE = "https://raw.githubusercontent.com/RainVaporeon/oc-html/main"
M.SMALL_HTTP = "http://example.com/"
M.SMALL_HTTPS = "https://example.com/"
-- The origins of tests/real/*.html (tests/real/SOURCES.md), for N15.
M.REAL_PAGES = {
  { "wiki", "https://wiki.gtnewhorizons.com/wiki/Main_Page" },
  { "wikipedia", "https://en.wikipedia.org/wiki/Lua_(programming_language)" },
  { "manual", "https://www.lua.org/manual/5.3/manual.html" },
}

M.USAGE = [[
Usage: netprobe [--out PATH] [--base URL] [--echo URL] [--skip-large] [--leak] [URL ...]
  --out PATH     report file (default: /home/netprobe.txt)
  --base URL     raw URL of the repository files (large page and 404 test)
  --echo URL     echo service with /status, /redirect-to, /delay, /headers
                 (default: https://httpbingo.org)
  --skip-large   skip the large page section
  --leak         at the end of the limit test, drop open handles without
                 close() and leave them open (run the probe again, or reboot,
                 to see whether the slots stay used)
  URL ...        http(s) pages to measure in place of the default small pages
Copy the report to ./datacollection/ in the repository.]]

-- OpenOS kills a program after about 5 s without a yield. Stay far below it.
local YIELD_INTERVAL = 0.25
local CONNECT_TIMEOUT = 20
local RESPONSE_TIMEOUT = 20
local IDLE_TIMEOUT = 15
local STEP_TIMEOUT = 60
local LARGE_TIMEOUT = 300
-- How long response() is polled before the first read (N3).
local N3_WAIT = 3
local SAMPLE = 256
local CAPTURE = 2048
local READ_CAP = 256 * 1024
local SMALL_CAP = 64 * 1024
local LARGE_CAP = 8 * 1024 * 1024
-- The no-yield read loop (N5) stops at this much CPU time or these calls.
local SPIN_CPU = 0.2
local SPIN_CALLS = 200
local SPIN_DATA = 30
local MEM_CHUNKS = 16
local HOLD_SECONDS = 1
local SETTLE_YIELDS = 11
local GC_RISE_MIN = 16384
local LIMIT_MAX = 64
local MAX_HOPS = 5
local MAX_LINE = 200
local MAX_OUTPUT = 200 * 1024
local LONG_PART = 150
local MAX_VALUE = 120
local BUCKETS = { 16, 256, 1024, 2048, 4096, 8192, 16384, 32768, 65536 }
local INTERESTING = { "content-length", "content-type", "content-encoding",
  "transfer-encoding", "location", "server", "connection" }

-- Arguments ---------------------------------------------------------------

local function is_url(s)
  return type(s) == "string" and (s:match("^http://[^/%s]+")
    or s:match("^https://[^/%s]+")) ~= nil
end

-- Returns an options table, or nil and an error message.
function M.parse_args(argv)
  local opts = { out = M.DEFAULT_OUT, base = M.DEFAULT_BASE,
    echo = M.DEFAULT_ECHO, urls = {} }
  local i, count = 1, argv.n or #argv
  while i <= count do
    local a = tostring(argv[i])
    if a == "--help" or a == "-h" then
      opts.help = true
    elseif a == "--skip-large" then
      opts.skip_large = true
    elseif a == "--leak" then
      opts.leak = true
    elseif a == "--out" or a == "--base" or a == "--echo" then
      i = i + 1
      local v = argv[i]
      if type(v) ~= "string" or v == "" then
        return nil, "netprobe: " .. a .. " needs a value"
      end
      if a ~= "--out" and not is_url(v) then
        return nil, "netprobe: " .. a .. " needs an http or https URL: " .. v
      end
      opts[a:sub(3)] = v
    elseif a:sub(1, 1) == "-" then
      return nil, "netprobe: unknown argument: " .. a
    elseif is_url(a) then
      opts.urls[#opts.urls + 1] = a
    else
      return nil, "netprobe: not an http or https URL: " .. a
    end
    i = i + 1
  end
  opts.base = opts.base:gsub("/+$", "")
  opts.echo = opts.echo:gsub("/+$", "")
  return opts
end

-- Text helpers ------------------------------------------------------------

local function escape(s)
  s = string.gsub(s, "\\", "\\x5C")
  s = string.gsub(s, "[\0-\31\127-\255]", function(c)
    return string.format("\\x%02X", string.byte(c))
  end)
  return s
end

local function fmt(v)
  if type(v) == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      return tostring(v)
    end
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
      return string.format("%d", v)
    end
    return string.format("%.3f", v)
  end
  return escape(tostring(v))
end

local function ms(seconds)
  return string.format("%.3f", seconds * 1000)
end

local function cut(s, n)
  s = tostring(s)
  if #s > n then
    return s:sub(1, n) .. "..."
  end
  return s
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
  return type(err) == "string"
    and (err == "interrupted" or err:find("[:%s]interrupted$") ~= nil)
end

local function urlencode(s)
  return (s:gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

-- The part of a URL after the scheme and before the first "/".
local function host_of(url)
  return url:match("^https?://([^/]+)") or url
end

-- Absolute URL of a redirect target, or nil for forms the probe skips.
local function resolve(url, location)
  if location:match("^https?://") then
    return location
  end
  if location:sub(1, 1) == "/" and location:sub(2, 2) ~= "/" then
    return url:match("^https?://[^/]+") .. location
  end
  return nil
end

-- The test URLs derived from the options.
function M.targets(opts)
  local echo = opts.echo
  local host = echo:match("^https?://(.*)$")
  local plain, secure = "http://" .. host, "https://" .. host
  local pages
  if #opts.urls > 0 then
    pages = {}
    for i, u in ipairs(opts.urls) do
      pages[i] = { "url" .. i, u }
    end
  else
    pages = { { "http", M.SMALL_HTTP }, { "https", M.SMALL_HTTPS },
      { "base", opts.base .. "/AGENTS.md" } }
  end
  local bare = host:match("^[^/]+"):gsub(":%d+$", "")
  return {
    pages = pages, plain = plain, secure = secure, echo = echo,
    large = opts.base .. "/tests/pages/large.html",
    base404 = opts.base .. "/no-such-file-netprobe",
    refused = "http://" .. bare .. ":1/",
    silent = "http://example.com:81/",
  }
end

-- State and output --------------------------------------------------------

local function now(P) return P.deps.uptime() end

local function cpu(P) return P.deps.clock() end

local function check_interrupt(P)
  if P.deps.interrupted and P.deps.interrupted() then
    error("interrupted", 0)
  end
end

-- A yield: the kernel can run other work, and Ctrl+C can arrive.
local function yield_now(P)
  P.deps.sleep()
  P.last = now(P)
  check_interrupt(P)
end

local function tick(P)
  if now(P) - P.last > YIELD_INTERVAL then
    yield_now(P)
  end
end

local function emit(P, line, force)
  if #line > MAX_LINE then
    line = line:sub(1, MAX_LINE - 3) .. "..."
  end
  if not force and P.bytes + #line + 1 > MAX_OUTPUT then
    P.suppressed = P.suppressed + 1
    return
  end
  P.bytes = P.bytes + #line + 1
  P.count = P.count + 1
  P.lines[#P.lines + 1] = line
end

-- Writes the lines of the last step to the report (the first write creates
-- the file, later writes append). The lines stay pending when the write
-- fails. Returns true, or false and a reason.
local function write_report(P)
  if #P.lines == 0 then
    return true
  end
  local text = table.concat(P.lines, "\n") .. "\n"
  local ok, done, why = pcall(P.deps.write_file, P.opts.out, text, P.started)
  if ok and done then
    P.started = true
    P.lines = {}
    return true
  end
  if not ok then
    why = done
  end
  return false, cut(why or "unknown reason", MAX_VALUE)
end

-- The recorder of one group. Keys are "<name>.<field>".
local function recorder(P, group)
  local R = {}
  local prefix = "net." .. group .. "."

  function R.set(key, value)
    emit(P, prefix .. key .. "=" .. fmt(value))
  end

  -- Splits a long value into key.1, key.2, ... and key.parts.
  function R.long(key, value)
    local s = fmt(value)
    if #s <= LONG_PART then
      emit(P, prefix .. key .. "=" .. s)
      return
    end
    local part = 0
    for i = 1, #s, LONG_PART do
      part = part + 1
      emit(P, prefix .. key .. "." .. part .. "=" .. s:sub(i, i + LONG_PART - 1))
    end
    emit(P, prefix .. key .. ".parts=" .. part)
  end

  -- A failure is a value. An interrupt is passed up.
  function R.fail(key, err)
    if is_interrupt(err) then
      error(err, 0)
    end
    P.errors = P.errors + 1
    emit(P, prefix .. key .. ".error=" .. cut(fmt(err_text(err)), MAX_VALUE))
  end

  return R
end

-- Memory ------------------------------------------------------------------

-- Yields until a GC is seen (a rise in free memory), at most SETTLE_YIELDS
-- times. Returns the reading after the GC, or the highest reading.
local function settle(P)
  local free = P.deps.free
  local prev = free()
  local best = prev
  for _ = 1, SETTLE_YIELDS do
    yield_now(P)
    local f = free()
    if f - prev > math.max(GC_RISE_MIN, prev * 0.05) then
      return f
    end
    best = math.max(best, f)
    prev = f
  end
  return best
end

-- Header summary -----------------------------------------------------------

local function record_headers(R, k, headers)
  R.set(k .. "type", type(headers))
  if type(headers) ~= "table" then
    return
  end
  local names, found, n, dup = {}, {}, 0, 0
  for name, value in pairs(headers) do
    n = n + 1
    local kind = type(value)
    if kind == "table" then
      kind = "list" .. #value
    end
    if #names < 40 then
      names[#names + 1] = cut(name, 40) .. ":" .. kind
    end
    local lower = type(name) == "string" and name:lower()
    if lower then
      if found[lower] then
        dup = dup + 1
      else
        found[lower] = { name, value }
      end
    end
  end
  table.sort(names)
  R.set(k .. "count", n)
  R.set(k .. "case_duplicates", dup)
  R.long(k .. "names", table.concat(names, ","))
  for _, want in ipairs(INTERESTING) do
    local e = found[want]
    if e then
      local key = k .. want:gsub("%-", "_")
      local value = e[2]
      R.set(key .. ".name", e[1])
      R.set(key .. ".type", type(value))
      if type(value) == "table" then
        R.set(key .. ".count", #value)
        R.set(key .. ".value", cut(value[1], MAX_VALUE))
      else
        R.set(key .. ".value", cut(value, MAX_VALUE))
      end
    end
  end
end

-- The names and value types of the fields of a handle or the card.
local function describe_fields(t)
  local out = {}
  local ok = pcall(function()
    for k, v in pairs(t) do
      out[#out + 1] = tostring(k) .. ":" .. type(v)
    end
  end)
  table.sort(out)
  return ok and table.concat(out, ",") or "unreadable"
end

-- One request ---------------------------------------------------------------

-- Opens url and records every fact of the exchange under "<name>.".
-- o: max_bytes (read until this many bytes; 0 reads only when the status
-- line needs a read), read_size (the read argument, nil for read()),
-- sample (body bytes kept), headers (request headers), api (describe the
-- handle), spin (the no-yield read loop), memory (free memory facts),
-- hold (wait before the first read), connect_timeout, response_timeout,
-- timeout (whole request). Returns { code, location } of the response.
-- The handle is closed on every path.
local function measure(P, R, name, url, o)
  o = o or {}
  local d = P.deps
  local k = name .. "."
  local info = {}
  P.where = P.section .. "." .. name
  P.deps.out("netprobe:   " .. name .. " " .. cut(url, 60))
  yield_now(P)

  local h
  local function body()
    local card = P.card
    local t0 = now(P)
    local deadline = t0 + (o.timeout or STEP_TIMEOUT)
    R.set(k .. "url", url)
    if o.memory then
      R.set(k .. "mem.before", settle(P))
    end
    local c0 = cpu(P)
    local ok, handle, reason
    if o.headers then
      ok, handle, reason = pcall(card.request, url, nil, o.headers)
    else
      ok, handle, reason = pcall(card.request, url)
    end
    R.set(k .. "request.ms", ms(now(P) - t0))
    R.set(k .. "request.cpu_ms", ms(cpu(P) - c0))
    if not ok then
      if is_interrupt(handle) then
        error(handle, 0)
      end
      R.set(k .. "request.result", "raise")
      R.set(k .. "request.raise", cut(err_text(handle), MAX_VALUE))
      return
    end
    if not handle then
      R.set(k .. "request.result", "nil")
      R.set(k .. "request.error", cut(err_text(reason), MAX_VALUE))
      return
    end
    h = handle
    R.set(k .. "request.result", "handle")
    R.set(k .. "request.handle_type", type(h))
    if o.api then
      R.long(k .. "handle.fields", describe_fields(h))
      local mt_ok, mt = pcall(getmetatable, h)
      R.set(k .. "handle.metatable", mt_ok and type(mt) or "error")
      if mt_ok and type(mt) == "table" and type(mt.__index) == "table" then
        R.long(k .. "handle.index_fields", describe_fields(mt.__index))
      end
      for _, m in ipairs({ "finishConnect", "response", "read", "close" }) do
        R.set(k .. "handle.has." .. m, type(h[m]))
      end
    end

    -- N3: response() before finishConnect.
    local early = table.pack(pcall(h.response))
    if not early[1] and is_interrupt(early[2]) then
      error(early[2], 0)
    end
    R.set(k .. "n3.before_connect", early[1] and (early[2] ~= nil and "value"
      or "nil") or "ERR " .. cut(err_text(early[2]), MAX_VALUE))

    -- Connect (N2).
    local polls, c_start = 0, now(P)
    local limit = c_start + (o.connect_timeout or CONNECT_TIMEOUT)
    local connected = false
    while true do
      local cok, done, why = pcall(h.finishConnect)
      if not cok then
        if is_interrupt(done) then
          error(done, 0)
        end
        R.set(k .. "connect.result", "raise")
        R.set(k .. "connect.raise", cut(err_text(done), MAX_VALUE))
        break
      end
      if done == nil then
        R.set(k .. "connect.result", "error")
        R.set(k .. "connect.error", cut(err_text(why), MAX_VALUE))
        break
      end
      if done then
        connected = true
        R.set(k .. "connect.result", "ok")
        break
      end
      polls = polls + 1
      if now(P) > limit or now(P) > deadline then
        R.set(k .. "connect.result", "timeout")
        break
      end
      yield_now(P)
    end
    R.set(k .. "connect.polls", polls)
    R.set(k .. "connect.ms", ms(now(P) - c_start))
    R.set(k .. "connect.total_ms", ms(now(P) - t0))
    if not connected then
      return
    end
    if o.memory then
      R.set(k .. "mem.connected", d.free())
    end

    -- Read bookkeeping.
    local st = { bytes = 0, chunks = 0, empties = 0, reads = 0, run = 0,
      max_run = 0, min = nil, max = 0, wall = 0, cpu = 0, max_wall = 0,
      max_cpu = 0, first = nil, sizes = {}, buckets = {}, full = 0,
      sample = {}, sample_n = 0, free_min = nil, done = false }
    local want = o.sample or 0
    local size = o.read_size

    local function read_once()
      local a, ca = now(P), cpu(P)
      local rok, r1, r2
      if size then
        rok, r1, r2 = pcall(h.read, size)
      else
        rok, r1, r2 = pcall(h.read)
      end
      local dw, dc = now(P) - a, cpu(P) - ca
      st.reads = st.reads + 1
      st.wall, st.cpu = st.wall + dw, st.cpu + dc
      st.max_wall, st.max_cpu = math.max(st.max_wall, dw), math.max(st.max_cpu, dc)
      if not rok then
        if is_interrupt(r1) then
          error(r1, 0)
        end
        st.done, st.stop, st.reason = true, "raise", err_text(r1)
        return nil
      end
      if r1 == nil then
        st.done = true
        st.stop = r2 ~= nil and "error" or "eof"
        st.reason = r2 ~= nil and err_text(r2) or nil
        return nil
      end
      if type(r1) ~= "string" then
        st.done, st.stop, st.reason = true, "odd", "read gave " .. type(r1)
        return nil
      end
      if r1 == "" then
        st.empties = st.empties + 1
        st.run = st.run + 1
        st.max_run = math.max(st.max_run, st.run)
        return ""
      end
      st.run = 0
      local n = #r1
      st.first = st.first or now(P)
      st.bytes, st.chunks = st.bytes + n, st.chunks + 1
      st.min = st.min and math.min(st.min, n) or n
      st.max = math.max(st.max, n)
      if size and n == size then
        st.full = st.full + 1
      end
      if #st.sizes < 12 then
        st.sizes[#st.sizes + 1] = n
      end
      local label = "gt" .. BUCKETS[#BUCKETS]
      for _, b in ipairs(BUCKETS) do
        if n <= b then
          label = "le" .. b
          break
        end
      end
      st.buckets[label] = (st.buckets[label] or 0) + 1
      if st.sample_n < want then
        local part = r1:sub(1, want - st.sample_n)
        st.sample[#st.sample + 1] = part
        st.sample_n = st.sample_n + #part
      end
      if o.memory then
        local f = d.free()
        st.free_min = st.free_min and math.min(st.free_min, f) or f
      end
      return r1
    end

    -- Status line (N3): poll response() before any read.
    local code, message, headers
    local r_start = now(P)
    local polls_resp = 0
    local function poll_response(stop_at)
      while true do
        local rok, c, m, hd = pcall(h.response)
        if not rok then
          if is_interrupt(c) then
            error(c, 0)
          end
          R.set(k .. "response.raise", cut(err_text(c), MAX_VALUE))
          return false, true
        end
        if c ~= nil then
          code, message, headers = c, m, hd
          return true
        end
        polls_resp = polls_resp + 1
        if now(P) > stop_at or now(P) > deadline then
          return false
        end
        yield_now(P)
      end
    end
    local got, failed = poll_response(r_start + N3_WAIT)
    local before_read = got
    R.set(k .. "n3.before_read", got)
    R.set(k .. "n3.polls_before_read", polls_resp)
    if not got and not failed then
      -- The status line may come only after a read.
      local r = read_once()
      R.set(k .. "n3.first_read", r == nil and (st.stop or "nil") or #r)
      got, failed = poll_response(now(P) + N3_WAIT)
      R.set(k .. "n3.after_read", got)
      if not got and not failed then
        got = poll_response(r_start + (o.response_timeout or RESPONSE_TIMEOUT))
      end
    end
    R.set(k .. "response.polls", polls_resp)
    R.set(k .. "response.ms", ms(now(P) - r_start))
    R.set(k .. "response.total_ms", ms(now(P) - t0))
    if not got then
      R.set(k .. "response.result", failed and "raise" or "timeout")
      return
    end
    R.set(k .. "response.result", "ok")
    R.set(k .. "status.code", code)
    R.set(k .. "status.code_type", type(code))
    R.set(k .. "status.message", cut(message, MAX_VALUE))
    record_headers(R, k .. "headers.", headers)
    info.code = code
    if type(headers) == "table" then
      for hn, hv in pairs(headers) do
        if type(hn) == "string" and hn:lower() == "location" then
          info.location = type(hv) == "table" and hv[1] or hv
        end
      end
    end
    if o.memory then
      R.set(k .. "mem.response", d.free())
    end
    if o.hold and before_read then
      local until_t = now(P) + HOLD_SECONDS
      while now(P) < until_t do
        yield_now(P)
      end
      R.set(k .. "mem.after_hold", d.free())
    end

    -- Body (N4, N5, N6).
    local max_bytes = o.max_bytes or 0
    if o.spin and max_bytes > 0 and not st.done then
      local sc, sw = cpu(P), now(P)
      local calls, data, empt = 0, 0, 0
      while calls < SPIN_CALLS and data < SPIN_DATA and not st.done
          and cpu(P) - sc < SPIN_CPU and st.bytes < max_bytes do
        local r = read_once()
        calls = calls + 1
        if r == "" then
          empt = empt + 1
        elseif r then
          data = data + 1
        end
      end
      R.set(k .. "spin.calls", calls)
      R.set(k .. "spin.data", data)
      R.set(k .. "spin.empty", empt)
      R.set(k .. "spin.cpu_ms", ms(cpu(P) - sc))
      R.set(k .. "spin.wall_ms", ms(now(P) - sw))
      yield_now(P)
    end
    local idle = now(P)
    local mem16 = false
    while max_bytes > 0 and not st.done do
      if st.bytes >= max_bytes then
        st.done, st.stop = true, "cap"
      elseif now(P) > deadline then
        st.done, st.stop = true, "timeout_total"
      elseif now(P) - idle > IDLE_TIMEOUT then
        st.done, st.stop = true, "timeout_idle"
      else
        local r = read_once()
        if r == "" then
          yield_now(P)
        elseif r then
          idle = now(P)
          tick(P)
          if o.memory and not mem16 and st.chunks >= MEM_CHUNKS then
            mem16 = true
            R.set(k .. "mem.after_chunks", settle(P))
            R.set(k .. "mem.chunks", st.chunks)
            idle = now(P)
          end
        end
      end
    end
    if st.stop or st.reads > 0 then
      local t_end = now(P)
      R.set(k .. "read.end", st.stop or "none")
      if st.reason then
        R.set(k .. "read.reason", cut(st.reason, MAX_VALUE))
      end
      R.set(k .. "read.bytes", st.bytes)
      R.set(k .. "read.chunks", st.chunks)
      R.set(k .. "read.calls", st.reads)
      R.set(k .. "read.empty", st.empties)
      R.set(k .. "read.max_empty_run", st.max_run)
      R.set(k .. "read.request_size", size or "none")
      if st.chunks > 0 then
        R.set(k .. "read.min", st.min)
        R.set(k .. "read.max", st.max)
        R.set(k .. "read.avg", st.bytes / st.chunks)
        R.set(k .. "read.full_chunks", st.full)
        R.set(k .. "read.first_sizes", table.concat(st.sizes, ","))
        local keys = {}
        for label, n in pairs(st.buckets) do
          keys[#keys + 1] = label .. "=" .. n
        end
        table.sort(keys)
        R.long(k .. "read.buckets", table.concat(keys, ","))
        R.set(k .. "read.ttfb_ms", ms(st.first - t0))
        R.set(k .. "read.body_ms", ms(t_end - st.first))
        if t_end > st.first then
          R.set(k .. "read.kb_per_s", st.bytes / 1024 / (t_end - st.first))
        end
      end
      R.set(k .. "read.total_ms", ms(t_end - t0))
      R.set(k .. "read.call_wall_ms", ms(st.wall))
      R.set(k .. "read.call_cpu_ms", ms(st.cpu))
      R.set(k .. "read.call_max_wall_ms", ms(st.max_wall))
      R.set(k .. "read.call_max_cpu_ms", ms(st.max_cpu))
      if st.sample_n > 0 then
        R.long(k .. "body.sample", table.concat(st.sample))
      end
      if o.memory and st.free_min then
        R.set(k .. "mem.min", st.free_min)
      end
    end
  end

  local ok, err = pcall(body)
  if h then
    local c0 = now(P)
    local cok, cerr = pcall(h.close)
    if cok then
      R.set(k .. "close.ok", true)
      R.set(k .. "close.ms", ms(now(P) - c0))
    elseif is_interrupt(cerr) then
      ok, err = false, ok and cerr or err
    else
      R.set(k .. "close.error", cut(err_text(cerr), MAX_VALUE))
    end
  end
  if not ok then
    R.fail(name, err)
  elseif o.memory then
    R.set(k .. "mem.after_close", settle(P))
  end
  return info
end

-- Runs a step. A failure is a value, an interrupt is passed up.
local function step(P, R, name, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    R.fail(name, err)
  end
  return ok
end

-- Sections ------------------------------------------------------------------

-- N1: the card, the handle and the header table.
local function section_api(P, R, T)
  local card = P.card
  R.set("card.type", type(card))
  R.long("card.fields", describe_fields(card))
  if P.deps.methods then
    local ok, m = pcall(P.deps.methods, card)
    if ok and type(m) == "table" then
      local list = {}
      for mn, direct in pairs(m) do
        list[#list + 1] = tostring(mn) .. ":" .. tostring(direct)
      end
      table.sort(list)
      R.long("card.component_methods", table.concat(list, ","))
    else
      R.set("card.component_methods", "ERR " .. cut(err_text(m), MAX_VALUE))
    end
  end
  for _, m in ipairs({ "isHttpEnabled", "isTcpEnabled" }) do
    if type(card[m]) == "function" then
      local ok, v = pcall(card[m])
      R.set("card." .. m, ok and tostring(v) or "ERR " .. cut(err_text(v), MAX_VALUE))
    else
      R.set("card." .. m, "missing")
    end
  end
  measure(P, R, "get", T.pages[1][2], { api = true, max_bytes = 0 })
end

-- N2 and N3: connect and status line timing on each page, twice.
local function section_connect(P, R, T)
  for _, page in ipairs(T.pages) do
    for try = 1, 2 do
      step(P, R, page[1] .. "_" .. try, measure, P, R, page[1] .. "_" .. try,
        page[2], { max_bytes = 0 })
    end
  end
end

-- N4, N5 and N6: chunk sizes, call times and memory.
local function section_read(P, R, T)
  for _, page in ipairs(T.pages) do
    step(P, R, page[1], measure, P, R, page[1], page[2], { max_bytes = SMALL_CAP,
      sample = SAMPLE, spin = true })
  end
  local runs = { { "large_default", nil }, { "large_4096", 4096 },
    { "large_65536", 65536 } }
  for _, run in ipairs(runs) do
    step(P, R, run[1], measure, P, R, run[1], T.large, { max_bytes = READ_CAP,
      read_size = run[2], memory = true, hold = true, spin = run[2] == nil,
      timeout = STEP_TIMEOUT })
  end
end

-- N7: the whole large page.
local function section_large(P, R, T)
  if P.opts.skip_large then
    R.set("skipped", "--skip-large")
    return
  end
  step(P, R, "page", measure, P, R, "page", T.large, { max_bytes = LARGE_CAP,
    read_size = 4096, memory = true, timeout = LARGE_TIMEOUT })
end

-- N9: redirects. A 3xx answer is followed by hand for up to MAX_HOPS hops.
local function section_redirect(P, R, T)
  local function to(scheme_base, target)
    return scheme_base .. "/redirect-to?url=" .. urlencode(target)
  end
  local cases = {
    { "http_to_http", to(T.plain, T.plain .. "/get") },
    { "http_to_https", to(T.plain, T.secure .. "/get") },
    { "https_to_http", to(T.secure, T.plain .. "/get") },
    { "chain3", T.plain .. "/redirect/3" },
  }
  for _, c in ipairs(cases) do
    step(P, R, c[1], function()
      local url = c[2]
      for hop = 0, MAX_HOPS do
        local name = hop == 0 and c[1] or (c[1] .. "_hop" .. hop)
        local info = measure(P, R, name, url, { max_bytes = 1024, sample = SAMPLE })
        local code = info and info.code
        if type(code) ~= "number" or code < 300 or code > 399
            or not info.location then
          R.set(c[1] .. ".hops", hop)
          return
        end
        url = resolve(url, tostring(info.location))
        if not url then
          R.set(c[1] .. ".hops", hop)
          R.set(c[1] .. ".stopped", "location not followed: "
            .. cut(info.location, MAX_VALUE))
          return
        end
      end
      R.set(c[1] .. ".hops", MAX_HOPS + 1)
      R.set(c[1] .. ".stopped", "hop limit")
    end)
  end
end

-- N10: error statuses and their bodies.
local function section_status(P, R, T)
  local cases = {
    { "base404", T.base404 },
    { "echo404", T.echo .. "/status/404" },
    { "echo500", T.echo .. "/status/500" },
  }
  for _, c in ipairs(cases) do
    step(P, R, c[1], measure, P, R, c[1], c[2], { max_bytes = 1024,
      sample = SAMPLE })
  end
end

-- N11 and N12: unreachable and blocked addresses.
local function section_fail(P, R, T)
  local cases = {
    { "unknown_host", "http://netprobe-no-such-host.invalid/", {} },
    { "refused", T.refused, { connect_timeout = CONNECT_TIMEOUT } },
    { "silent", T.silent, { connect_timeout = CONNECT_TIMEOUT } },
    { "tls", "https://expired.badssl.com/", {} },
    { "delay10", T.echo .. "/delay/10", { max_bytes = 1024, sample = SAMPLE,
      response_timeout = RESPONSE_TIMEOUT } },
    { "blocked_localhost", "http://localhost/", { connect_timeout = 8 } },
    { "blocked_loopback", "http://127.0.0.1/", { connect_timeout = 8 } },
    { "blocked_private_192", "http://192.168.0.1/", { connect_timeout = 8 } },
    { "blocked_private_10", "http://10.0.0.1/", { connect_timeout = 8 } },
  }
  for _, c in ipairs(cases) do
    c[3].timeout = STEP_TIMEOUT
    step(P, R, c[1], measure, P, R, c[1], c[2], c[3])
  end
end

-- N14 and N15: request headers as the server sees them, and the headers of
-- the origins of the real pages.
local function section_headers(P, R, T)
  step(P, R, "echo_default", measure, P, R, "echo_default", T.echo .. "/headers",
    { max_bytes = CAPTURE, sample = CAPTURE })
  step(P, R, "echo_agent", measure, P, R, "echo_agent", T.echo .. "/user-agent",
    { max_bytes = CAPTURE, sample = CAPTURE })
  step(P, R, "echo_custom", measure, P, R, "echo_custom", T.echo .. "/headers", {
    max_bytes = CAPTURE, sample = CAPTURE,
    headers = { ["User-Agent"] = "netprobe/1", ["X-Netprobe"] = "custom",
      ["Accept-Encoding"] = "identity" } })
  for _, page in ipairs(M.REAL_PAGES) do
    step(P, R, "real_" .. page[1], measure, P, R, "real_" .. page[1], page[2],
      { max_bytes = 1024 })
  end
end

-- N13: the connection limit. It runs last, because a leak can leave slots
-- open. Every handle is closed, except with --leak.
local function section_limit(P, R, T)
  local card = P.card
  local url = T.pages[1][2]
  P.where = "limit"
  local function open_until_fail(max)
    local handles = {}
    local why
    for _ = 1, max do
      local ok, h, reason = pcall(card.request, url)
      if not ok then
        if is_interrupt(h) then
          error(h, 0)
        end
        why = "raise: " .. cut(err_text(h), MAX_VALUE)
        break
      end
      if not h then
        why = "nil: " .. cut(err_text(reason), MAX_VALUE)
        break
      end
      handles[#handles + 1] = h
      tick(P)
    end
    return handles, why
  end
  local function close_all(handles)
    for i = #handles, 1, -1 do
      local ok, e = pcall(handles[i].close)
      if not ok and is_interrupt(e) then
        error(e, 0)
      end
      handles[i] = nil
    end
  end
  local held = {}
  local ok, err = pcall(function()
    local why
    held, why = open_until_fail(LIMIT_MAX)
    R.set("opened", #held)
    R.set("opened_stop", why or ("cap " .. LIMIT_MAX))
    if why and #held > 0 then
      -- Does close() free a slot?
      local ok1, e1 = pcall(held[#held].close)
      R.set("close_one", ok1 and "ok" or cut(err_text(e1), MAX_VALUE))
      held[#held] = nil
      local ok2, h2, why2 = pcall(card.request, url)
      if ok2 and h2 then
        held[#held + 1] = h2
        R.set("reopen_after_close", true)
      else
        R.set("reopen_after_close", false)
        R.set("reopen_error", cut(err_text(ok2 and why2 or h2), MAX_VALUE))
      end
      -- Is a second close() safe?
      local first = held[1]
      local c1 = pcall(first.close)
      local c2, e2 = pcall(first.close)
      R.set("double_close", c1 and c2 and "ok" or "ERR " .. cut(err_text(e2),
        MAX_VALUE))
      table.remove(held, 1)
      local ok3, h3 = pcall(card.request, url)
      if ok3 and h3 then
        held[#held + 1] = h3
      end
    end
  end)
  close_all(held)
  held = nil
  if not ok then
    R.fail("opened", err)
  end
  if P.opts.leak then
    -- Open to the limit, drop the handles without close() and collect.
    local lost, why = open_until_fail(LIMIT_MAX)
    local n = #lost
    lost = nil
    for _ = 1, 3 do
      pcall(collectgarbage)
      yield_now(P)
    end
    local again, why2 = open_until_fail(LIMIT_MAX)
    R.set("leak.dropped", n)
    R.set("leak.dropped_stop", why or "cap")
    R.set("leak.after_gc_opened", #again)
    R.set("leak.after_gc_stop", why2 or "cap")
    R.set("leaked", #again)
    R.set("leak.note", "handles left open on purpose; run the probe again and compare limit.opened")
    again = nil
  else
    R.set("leak.skipped", "run with --leak, then run the probe again")
  end
end

local SECTIONS = {
  { "api", section_api },
  { "connect", section_connect },
  { "read", section_read },
  { "large", section_large },
  { "redirect", section_redirect },
  { "status", section_status },
  { "fail", section_fail },
  { "headers", section_headers },
  { "limit", section_limit },
}

-- Main ----------------------------------------------------------------------

local function run_sections(P, T)
  for i, s in ipairs(SECTIONS) do
    P.section = s[1]
    P.deps.out(string.format("netprobe: [%d/%d] %s", i, #SECTIONS, s[1]))
    local R = recorder(P, s[1])
    local ok, err = pcall(s[2], P, R, T)
    if not ok then
      R.fail("section", err)
    end
    local wrote, why = write_report(P)
    if not wrote and not P.warned then
      P.warned = true
      io.stderr:write("netprobe: cannot write " .. P.opts.out .. " (" .. why .. ")\n")
    end
    yield_now(P)
  end
end

-- argv: the program arguments (a table, n is optional).
-- deps: the machine links:
--   out(line), err(line)   print to stdout and stderr
--   card                   the internet card proxy, or nil
--   methods(card)          component.methods of the card, or nil
--   uptime(), clock()      computer.uptime (wall), os.clock (CPU)
--   sleep()                os.sleep(0), a yield
--   free(), total()        computer.freeMemory, computer.totalMemory
--   interrupted()          true after Ctrl+C was seen (optional)
--   setup(), teardown()    install and remove the Ctrl+C listener (optional)
--   write_file(path, text, append)
--                          true, or nil and a reason; append is false for
--                          the first write (create or truncate the file)
--   version                _VERSION
-- Returns the exit code: 0, 1 (no card or no file), 2 (usage), 130 (Ctrl+C).
function M.main(argv, deps)
  local opts, msg = M.parse_args(argv)
  if not opts then
    deps.err(msg .. " (see netprobe --help)")
    return 2
  end
  if opts.help then
    deps.out(M.USAGE)
    return 0
  end
  if not deps.card then
    deps.err("netprobe: no internet card found")
    return 1
  end
  local P = { deps = deps, opts = opts, card = deps.card, lines = {},
    bytes = 0, count = 0, suppressed = 0, errors = 0, section = "start", where = "start",
    last = deps.uptime() }
  P.out = deps.out
  local T = M.targets(opts)
  local start = deps.uptime()

  emit(P, "#netprobe v" .. M.VERSION, true)
  local H = recorder(P, "probe")
  H.set("args", table.concat(argv, " ", 1, argv.n or #argv))
  H.set("base", opts.base)
  H.set("echo", opts.echo)
  H.set("skip_large", opts.skip_large == true)
  H.set("leak", opts.leak == true)
  H.set("lua_version", deps.version)
  H.set("clock", "uptime wall time (50 ms steps), os.clock CPU time")
  H.set("total_memory", deps.total())
  H.set("free_memory", deps.free())
  local first, why = write_report(P)
  if not first then
    deps.err("netprobe: cannot write " .. opts.out .. " (" .. why .. ")")
    return 1
  end

  if deps.setup then
    pcall(deps.setup)
  end
  local ok, err = pcall(run_sections, P, T)
  if deps.teardown then
    pcall(deps.teardown)
  end
  local code = 0
  if not ok then
    if is_interrupt(err) then
      emit(P, "net.probe.interrupted=true", true)
      emit(P, "net.probe.interrupted_at=" .. escape(P.where), true)
      code = 130
    else
      P.errors = P.errors + 1
      emit(P, "net.probe.fatal=" .. cut(escape(err_text(err)), MAX_VALUE), true)
      code = 1
    end
  end
  emit(P, "net.probe.output_bytes=" .. P.bytes, true)
  emit(P, "net.probe.suppressed_lines=" .. P.suppressed, true)
  emit(P, "net.probe.errors=" .. P.errors, true)
  emit(P, "net.probe.duration_ms=" .. ms(deps.uptime() - start), true)
  local wrote, wwhy = write_report(P)
  if not wrote then
    for _, line in ipairs(P.lines) do
      deps.out(line)
    end
    deps.err("netprobe: cannot write " .. opts.out .. " (" .. wwhy .. ")")
    return 1
  end
  deps.out("netprobe: " .. P.count .. " lines, " .. P.errors .. " errors")
  deps.out("netprobe: report " .. opts.out)
  deps.out("netprobe: copy " .. opts.out .. " to ./datacollection/ in the repository")
  return code
end

-- The links to OpenOS. Loaded only when the chunk runs as a program.
function M.game_deps()
  local component = require("component")
  local computer = require("computer")
  local card = component.isAvailable("internet") and component.internet or nil
  local flag = false
  local function on_interrupt() flag = true end
  local event_ok, event = pcall(require, "event")
  return {
    out = function(line) io.write(line, "\n") end,
    err = function(line) io.stderr:write(line, "\n") end,
    card = card,
    methods = function(c) return component.methods(c.address) end,
    uptime = computer.uptime,
    clock = os.clock,
    sleep = function() os.sleep(0) end,
    free = computer.freeMemory,
    total = computer.totalMemory,
    interrupted = function() return flag end,
    setup = function()
      if event_ok then
        event.listen("interrupted", on_interrupt)
      end
    end,
    teardown = function()
      if event_ok then
        event.ignore("interrupted", on_interrupt)
      end
    end,
    write_file = function(path, text)
      local f, why = io.open(path, append and "ab" or "wb")
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
  io.stderr:write("netprobe: unexpected error: "
    .. tostring(code):match("^[^\n]*") .. "\n")
  return 1
end
return code
