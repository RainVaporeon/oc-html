-- Tests that confirm or reject review findings. Each test fails while the
-- defect is present. Test names are f<N>_<name>, N is the finding number.

local t = require("test")

local T = {}

-- Counting wrappers go in before any module loads, because the modules keep
-- string.find and string.gsub in locals.
local count = { on = false, find = 0, gsub_max = 0 }
local real_find, real_gsub = string.find, string.gsub

local function counting_find(s, pattern, init, plain)
  if count.on and type(s) == "string" then
    local k = real_find(s, pattern, init, plain)
    local from = init or 1
    if from < 0 then
      from = #s + from + 1
    end
    count.find = count.find + math.max(0, (k or #s) - from + 1)
    return real_find(s, pattern, init, plain)
  end
  return real_find(s, pattern, init, plain)
end

local function counting_gsub(s, ...)
  if count.on and type(s) == "string" and #s > count.gsub_max then
    count.gsub_max = #s
  end
  return real_gsub(s, ...)
end

-- rawset keeps the language server from reporting a second set of the field.
rawset(string, "find", counting_find)
rawset(string, "gsub", counting_gsub)

local html = t.load_bin("html")({})
local guard = require("html.guard")
local tokenizer = require("html.tokenizer")
local layout = require("html.layout")
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

local function drain(read)
  local nt = tokenizer.new(read)
  local n = 0
  while nt() do
    n = n + 1
    if n > 5000000 then
      error("too many tokens")
    end
  end
  return n
end

local function scan_total(input)
  count.find = 0
  count.on = true
  local ok, err = pcall(drain, chunk_reader(input))
  count.on = false
  if not ok then
    error(err, 0)
  end
  return count.find
end

function T.f1_broken_quote_scan_is_linear_a()
  local input = string.rep("<a x='>", 150000)
  local total = scan_total(input)
  t.ok(total < 10 * #input, "scanned " .. total .. " bytes for input of "
    .. #input)
end

function T.f1_broken_quote_scan_is_linear_b()
  local one = "<a" .. string.rep(" x='>'", 2600) .. ">"
  local input = string.rep(one, 64)
  local total = scan_total(input)
  t.ok(total < 10 * #input, "scanned " .. total .. " bytes for input of "
    .. #input)
end

function T.f2_long_word_is_committed()
  local lay = layout.new(80)
  for _ = 1, 20000 do
    lay.push("start", "i")
    lay.push("text", "x")
    lay.push("end", "i")
  end
  t.ok(#lay.lines >= 1, "no line before finish, word still pending")
end

function T.f3_title_gsub_subject_is_small()
  local input = "<title>" .. string.rep("a ", 140000) .. "</title>"
  count.gsub_max = 0
  count.on = true
  local ok, err = pcall(html.render, chunk_reader(input), 80)
  count.on = false
  if not ok then
    error(err, 0)
  end
  t.ok(count.gsub_max <= 8192, "largest gsub subject is " .. count.gsub_max
    .. " bytes")
end

-- Entry helpers, as in tests/entry_test.lua.
local PAGE = "<html><head><title>My Page</title></head><body>"
  .. "<h1>Head</h1><p>Some text.</p></body></html>"

local function fake_file(text, reader)
  local state = { closed = false }
  local pos = 1
  local f = {}
  function f.read(_, n)
    if reader then
      return reader(n)
    end
    if pos > #text then
      return nil
    end
    local c = text:sub(pos, pos + n - 1)
    pos = pos + n
    return c
  end
  function f.seek(_, whence)
    if whence == "end" then
      return #text
    end
    return 0
  end
  function f.close()
    state.closed = true
    return true
  end
  return f, state
end

local function run(args, text, extra)
  extra = extra or {}
  local rec = { out = {}, err = {}, logs = {}, views = 0 }
  local file = extra.file or fake_file(text or PAGE)
  local deps = {
    out = function(l) rec.out[#rec.out + 1] = l end,
    err = function(l) rec.err[#rec.err + 1] = l end,
    width = 50,
    open = function() return file end,
    traceback = function(m) return m .. "\nstack traceback: (fake)" end,
    clock = os.clock,
    gpu = {
      getScreen = function() return "screen" end,
      maxResolution = function() return 60, 20 end,
      getResolution = function() return 40, 10 end,
    },
    view = function() rec.views = rec.views + 1 return "quit" end,
    log = function(entry)
      rec.logs[#rec.logs + 1] = entry
      return true
    end,
    on_interrupt = function() return function() end end,
  }
  for k, v in pairs(extra) do
    if k ~= "file" then
      deps[k] = v
    end
  end
  args.n = #args
  return html.main(args, deps), rec
end

function T.f4_huge_width_is_controlled()
  local code, rec = run({ "--width", "9223372036854775807", "x.html" },
    "<p>x</p><hr>")
  local text = table.concat(rec.err, "\n")
  t.ok(not text:find("unexpected error", 1, true), "got: " .. text)
  t.eq(code, 2, "exit code")
end

function T.f5_restore_closure_outside_pcall()
  t.skip("not testable here: building the closure at viewer.lua:399 cannot "
    .. "raise except by out of memory, and the sandbox has no way to force "
    .. "that at one exact allocation")
end

function T.f6_print_loop_tick_without_lines()
  guard.reset()
  computer.test.set_free(1800000)
  for _ = 1, 3 do
    guard.tick(9000)
  end
  -- 200000 is above 192 KB and below the doubling reserve of 291271.
  -- The print-mode output loop uses tick_output, which has no memory check.
  computer.test.set_free(200000)
  local ok, err = pcall(guard.tick_output)
  guard.reset()
  t.ok(ok, "tick_output() stopped: " .. tostring(err))
end

function T.f7_require_failure_is_controlled()
  -- game_deps requires OpenOS modules and the viewer, which the sandbox
  -- does not have, so it raises as a failed require does.
  local ok, code = pcall(html.run_program, { "page.html" }, html.game_deps, {})
  t.ok(ok, "raw error escaped: " .. tostring(code))
  t.eq(code, 1, "exit code")
end

-- Runs main with a loader that raises the given value.
local function run_with_failing_require(raised)
  local fresh = t.load_bin("html")({})
  local real_require = require
  local err = {}
  _G.require = function() error(raised, 0) end
  local ok, code = pcall(fresh.run_program, { "page.html" }, function()
    return { err = function(l) err[#err + 1] = l end, out = print,
      home = "/home" }
  end, {})
  _G.require = real_require
  t.ok(ok, "raw error escaped: " .. tostring(code))
  t.eq(code, 1, "exit code")
  t.eq(#err, 1, "one line")
  t.eq(err[1]:sub(1, 6), "html: ")
  t.ok(not err[1]:find("\n"), "single line")
  return err[1]
end

function T.f7b_loader_raising_a_table_gives_one_line()
  run_with_failing_require({ code = 1 })
end

function T.f7b_loader_raising_a_failing_tostring_gives_one_line()
  run_with_failing_require(setmetatable({}, {
    __tostring = function() error("boom", 0) end,
  }))
end

function T.f7b_loader_out_of_memory_gives_one_line()
  local line = run_with_failing_require("not enough memory")
  t.ok(line:find("not enough memory", 1, true), line)
end

function T.f8_raw_interrupted_exits_130()
  local code, rec = run({ "page.html" }, PAGE, {
    view = function() error("interrupted", 0) end,
  })
  t.eq(#rec.logs, 0, "log writes")
  t.eq(code, 130, "exit code")
end

function T.f8_close_error_still_removes_listener()
  local f = fake_file(PAGE)
  local listens, removes = 0, 0
  f.close = function() error("close boom", 0) end
  pcall(run, { "page.html" }, PAGE, {
    file = f,
    on_interrupt = function()
      listens = listens + 1
      return function() removes = removes + 1 end
    end,
  })
  t.eq(listens, 1, "listener installed")
  t.eq(removes, 1, "listener removed")
end

function T.f9a_write_text_closes_after_write_error()
  local closed = false
  local handle = {
    write = function() error("disk boom", 0) end,
    flush = function() return true end,
    close = function() closed = true return true end,
  }
  pcall(html.write_text, function() return handle end, "/tmp/x", "data")
  t.ok(closed, "handle was not closed")
end

function T.f9a_write_text_closes_after_flush_error()
  local closed = false
  local handle = {
    write = function() return true end,
    flush = function() error("flush boom", 0) end,
    close = function() closed = true return true end,
  }
  pcall(html.write_text, function() return handle end, "/tmp/x", "data")
  t.ok(closed, "handle was not closed")
end

-- The installer write function sits in game_deps, which needs OpenOS, so
-- this reads the source text.
function T.f9b_installer_checks_close_result()
  local src = t.read_repo("tools/installer.lua")
  t.ok(src, "tools/installer.lua not readable")
  -- OpenOS close returns no values on success, so only its reason counts.
  -- installer_test.lua runs this write with a fake OpenOS file.
  t.ok(real_find(src, "local _, cerr = f:close()", 1, true),
    "close() result of write is ignored")
  t.ok(real_find(src, "if cerr ~= nil then", 1, true),
    "close() failure is not reported")
end

function T.f9c_stats_out_equal_to_input_is_refused()
  local code, rec = run({ "--stats-out", "./page.html", "page.html" }, PAGE,
    { resolve = function(p) return "/work/" .. p:gsub("^%./", "") end })
  local text = table.concat(rec.err, " | ")
  t.eq(code, 2, "exit code")
  t.eq(#rec.err, 1, "stderr lines: " .. text)
  t.ok(text:sub(1, 6) == "html: ", "stderr was: " .. text)
end

function T.f10_dirty_check_covers_tools()
  local src = t.read_repo("tools/release.ps1")
  local line = src:match("git status %-%-porcelain[^\n]*")
  t.ok(line, "no git status line")
  t.ok(real_find(line, "tools", 1, true), "dirty check is: " .. line)
end

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
  local ok, err = pcall(drain, read)
  t.ok(ok, tostring(err))
end

function T.f11b_read_error_is_reported()
  local n = 0
  local f = fake_file("", function()
    n = n + 1
    if n == 1 then
      return "<p>hello"
    end
    return nil, "io error"
  end)
  local code, rec = run({ "page.html" }, nil, { file = f })
  local text = table.concat(rec.err, "\n")
  t.ok(real_find(text, "read error", 1, true), "stderr was: " .. text)
  t.ok(code ~= 0, "exit code " .. tostring(code))
end

return T
