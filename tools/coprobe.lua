-- coprobe: checks whether the page loader can run inside a coroutine that
-- the viewer loop resumes (the loader yields, the viewer loop owns
-- event.pull). It answers the questions Q1 to Q6 of docs/ingame/coprobe.md.
-- Usage: coprobe [--out PATH]
-- The report has one "coprobe.<key>=<value>" line per fact. It is written
-- after every question, so Ctrl+C keeps what was measured.

local component = require("component")
local computer = require("computer")
local event = require("event")

local DEFAULT_OUT = "/home/coprobe.txt"
local MAX_RESUMES = 400
local PASS_WAIT = 0.05
local KEY_SECONDS = 5
local GARBAGE_BLOCKS = 200
local BLOCK_SIZE = 1024
local MAIN_PASSES = 11
local NET_TIMEOUT = 10
local MAX_VALUE = 120

local out = DEFAULT_OUT
local i = 1
while i <= select("#", ...) do
  local a = select(i, ...)
  if a == "--out" then
    i = i + 1
    out = select(i, ...) or out
  end
  i = i + 1
end

local lines, started, interrupted = {}, false, false

local function put(key, value)
  value = tostring(value):gsub("[%c]", " ")
  if #value > MAX_VALUE then
    value = value:sub(1, MAX_VALUE) .. "..."
  end
  lines[#lines + 1] = "coprobe." .. key .. "=" .. value
end

-- A silent close() counts as success.
local function flush()
  if #lines == 0 then
    return
  end
  local f, why = io.open(out, started and "ab" or "wb")
  if not f then
    io.stderr:write("coprobe: cannot write " .. out .. " (" .. tostring(why) .. ")\n")
    return
  end
  f:write(table.concat(lines, "\n") .. "\n")
  f:close()
  started = true
  lines = {}
end

-- Resumes fn as a coroutine until it ends. The main side calls
-- event.pull between the resumes, as the viewer loop does.
-- Returns ok, error text, resume count and the coroutine.
local function run(fn)
  local co = coroutine.create(fn)
  local n = 0
  while coroutine.status(co) == "suspended" and n < MAX_RESUMES do
    n = n + 1
    local ok, err = coroutine.resume(co)
    if not ok then
      return false, err, n, co
    end
    event.pull(PASS_WAIT)
  end
  return coroutine.status(co) == "dead", "not finished", n, co
end

local function result(key, ok, err, n, co)
  put(key .. ".ok", ok)
  put(key .. ".error", ok and "none" or err)
  put(key .. ".resumes", n)
  put(key .. ".final_status", coroutine.status(co))
end

local function q1()
  local gpu = component.gpu
  local ok, err, n, co = run(function()
    local ch, fg, bg = gpu.get(1, 1)
    gpu.set(1, 1, ch)
    coroutine.yield()
    gpu.set(1, 1, ch)
  end)
  result("q1.gpu", ok, err, n, co)
  if not component.isAvailable("internet") then
    put("q1.net", "no internet card")
    return
  end
  local card = component.internet
  local state = {}
  ok, err, n, co = run(function()
    local h = assert(card.request("http://example.com/"))
    local limit = computer.uptime() + NET_TIMEOUT
    while not h.finishConnect() and computer.uptime() < limit do
      coroutine.yield()
    end
    state.read = #(h.read(1024) or "")
    h.close()
  end)
  result("q1.net", ok, err, n, co)
  put("q1.net.bytes", state.read or "none")
end

local function q2()
  local state = {}
  local ok, err, n, co = run(function()
    state.inside = coroutine.status(coroutine.running())
    local t0 = computer.uptime()
    os.sleep(0.2)
    state.sleep_ms = (computer.uptime() - t0) * 1000
    local t1 = computer.uptime()
    event.pull(0.1)
    state.pull_ms = (computer.uptime() - t1) * 1000
  end)
  result("q2", ok, err, n, co)
  put("q2.status_inside", state.inside)
  put("q2.sleep_ms", state.sleep_ms or "none")
  put("q2.pull_ms", state.pull_ms or "none")
end

-- Q3 and Q6: the user presses keys while a coroutine is suspended.
local function q3()
  local main_keys, listener_keys, passes, ping = 0, 0, 0, 0
  local function on_key() listener_keys = listener_keys + 1 end
  local function on_ping() ping = ping + 1 end
  event.listen("key_down", on_key)
  event.listen("coprobe_ping", on_ping)
  local ok, err = pcall(function()
    local co = coroutine.create(function()
      while true do
        passes = passes + 1
        coroutine.yield()
      end
    end)
    computer.pushSignal("coprobe_ping")
    print("Press keys for " .. KEY_SECONDS .. " seconds")
    local stop = computer.uptime() + KEY_SECONDS
    while computer.uptime() < stop do
      coroutine.resume(co)
      local name = event.pull(PASS_WAIT)
      if name == "key_down" then
        main_keys = main_keys + 1
      end
    end
    put("q3.status_after", coroutine.status(co))
  end)
  event.ignore("key_down", on_key)
  event.ignore("coprobe_ping", on_ping)
  put("q3.main_key_down", main_keys)
  put("q6.listener_key_down", listener_keys)
  put("q6.listener_ping", ping)
  put("q3.passes", passes)
  if not ok then
    error(err, 0)
  end
end

local function q4()
  local state = {}
  local co = coroutine.create(function()
    local garbage = {}
    for k = 1, GARBAGE_BLOCKS do
      garbage[k] = string.rep("x", BLOCK_SIZE)
    end
    state.allocated = computer.freeMemory()
    garbage = nil
    state.dropped = computer.freeMemory()
    for _ = 1, MAIN_PASSES do
      coroutine.yield()
    end
  end)
  state.before = computer.freeMemory()
  state.min = state.before
  while coroutine.status(co) == "suspended" do
    local ok, err = coroutine.resume(co)
    if not ok then
      error(err, 0)
    end
    event.pull(0)
    state.min = math.min(state.min, computer.freeMemory())
  end
  state.after = computer.freeMemory()
  put("q4.free_before", state.before)
  put("q4.free_allocated", state.allocated or "none")
  put("q4.free_dropped", state.dropped or "none")
  put("q4.free_after_passes", state.after)
  put("q4.free_min", state.min)
  put("q4.gc_seen", state.dropped ~= nil and state.after > state.dropped)
end

local function q5()
  local ok, err, n, co = run(function() error("coprobe boom") end)
  result("q5", ok, err, n, co)
  put("q5.message_has_boom", tostring(err):find("coprobe boom", 1, true) ~= nil)
end

local function ask(name, fn)
  if interrupted then
    return
  end
  local ok, err = pcall(fn)
  if not ok then
    if tostring(err):find("interrupted", 1, true) then
      interrupted = true
      put("interrupted_at", name)
    else
      put(name .. ".raise", err)
    end
  end
  flush()
end

put("version", 1)
put("lua", _VERSION)
put("total_memory", computer.totalMemory())
ask("q1", q1)
ask("q2", q2)
ask("q3", q3)
ask("q4", q4)
ask("q5", q5)
put("interrupted", interrupted)
flush()
print("coprobe: report " .. out)
print("coprobe: copy " .. out .. " to ./datacollection/")
