-- Desktop test runner. Runs every tests/*_test.lua file in a sandbox env.
-- Run inside the container: lua5.3 tests/run.lua

local real_open = io.open
local real_loadfile = loadfile
local real_load = load
local real_remove = os.remove
local real_clock = os.clock
local real_dump = string.dump
local real_traceback = debug.traceback

-- Test discovery runs once, before any env exists. The command is a constant
-- and the env never gets io.popen. A fixed list file would skip new tests
-- silently when someone forgets to add them.
local function find_test_files()
  local pipe = assert(io.popen("ls -1 tests", "r"))
  local files = {}
  for name in pipe:lines() do
    if name:match("^[%w_]+_test%.lua$") then
      files[#files + 1] = "tests/" .. name
    end
  end
  pipe:close()
  table.sort(files)
  return files
end

-- Release folder names, listed once like the test files.
local function find_release_versions()
  local pipe = assert(io.popen("ls -1 releases", "r"))
  local versions = {}
  for name in pipe:lines() do
    if name:match("^%d+%.%d+%.%d+[ab]?$") then
      versions[#versions + 1] = name
    end
  end
  pipe:close()
  table.sort(versions)
  return versions
end


-- Test case names (tests/cases/*.html), listed once like the test files.
local function find_cases()
  local pipe = assert(io.popen("ls -1 tests/cases", "r"))
  local cases = {}
  for name in pipe:lines() do
    local base = name:match("^([%w_%-]+)%.html$")
    if base then
      cases[#cases + 1] = base
    end
  end
  pipe:close()
  table.sort(cases)
  return cases
end

local CASES = find_cases()
local RELEASE_VERSIONS = find_release_versions()

local SKIP = {}

local function copy(t, except)
  local c = {}
  for k, v in pairs(t) do
    if not (except and except[k]) then
      c[k] = v
    end
  end
  return c
end

local function escape(v)
  if type(v) ~= "string" then
    return tostring(v)
  end
  return '"' .. v:gsub("[^\32-\126]", function(c)
    return string.format("\\x%02X", c:byte())
  end) .. '"'
end

local function deep_eq(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

local function with_msg(msg, text)
  if msg then
    return msg .. ": " .. text
  end
  return text
end

-- Allows only relative paths under tests/ without "..". The Lua env may read
-- test data. Modules are loaded by require in the runner, not through io.open.
local function allowed_path(path)
  if type(path) ~= "string" then
    return false
  end
  path = path:gsub("^%./", "")
  if path:find("\\", 1, true) or path:find("%z") then
    return false
  end
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      return false
    end
  end
  return path:sub(1, 6) == "tests/" and #path > 6
end

local function safe_open(path, mode)
  mode = mode or "r"
  if mode ~= "r" and mode ~= "rb" then
    return nil, tostring(path) .. ": sandbox allows read mode only"
  end
  if not allowed_path(path) then
    return nil, tostring(path) .. ": sandbox allows only paths under tests/"
  end
  return real_open(path, mode)
end

-- Every chunk loads as text. A missing env means the sandbox env, never _G.
local function text_loader(env)
  return function(chunk, name, _, chunk_env)
    if chunk_env == nil then
      chunk_env = env
    end
    return real_load(chunk, name, "t", chunk_env)
  end
end

local function in_docker()
  local f = real_open("/.dockerenv", "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function build_env()
  local env = {
    _VERSION = _VERSION,
    assert = assert, error = error, ipairs = ipairs, next = next,
    pairs = pairs, pcall = pcall, print = print, rawequal = rawequal,
    rawget = rawget, rawlen = rawlen, rawset = rawset, select = select,
    setmetatable = setmetatable, getmetatable = getmetatable,
    tonumber = tonumber, tostring = tostring, type = type, xpcall = xpcall,
    coroutine = copy(coroutine),
    math = copy(math),
    string = copy(string, { dump = true }),
    table = copy(table),
    utf8 = copy(utf8),
    os = {
      clock = real_clock, date = os.date, difftime = os.difftime,
      time = os.time,
    },
    io = { open = safe_open },
  }
  env._G = env
  env.load = text_loader(env)

  local loaded = {}
  local shims = {}
  local test_api = {}

  local function load_module(path, name)
    local chunk, err = real_loadfile(path, "t", env)
    if not chunk then
      error(err, 0)
    end
    local result = chunk(name)
    if result == nil then
      result = true
    end
    return result
  end

  local function module_path(name)
    if type(name) ~= "string" then
      return nil
    end
    local sub = name:match("^html%.([%w_]+)$")
    if sub then
      return "lib/html/" .. sub .. ".lua", false
    end
    if name:match("^[%w_]+$") then
      local path = "tests/shim/" .. name .. ".lua"
      local f = real_open(path, "r")
      if f then
        f:close()
        return path, true
      end
    end
    return nil
  end

  function env.require(name)
    if name == "test" then
      return test_api
    end
    if loaded[name] ~= nil then
      return loaded[name]
    end
    local path, is_shim = module_path(name)
    if not path then
      error("module '" .. tostring(name) .. "' not found in the test sandbox", 2)
    end
    local result = load_module(path, name)
    loaded[name] = result
    if is_shim then
      shims[#shims + 1] = result
    end
    return result
  end

  -- OpenOS os.sleep yields. Here it advances the fake uptime.
  function env.os.sleep(seconds)
    env.require("computer").test.sleep(seconds or 0)
  end

  function test_api.eq(actual, expected, msg)
    if not deep_eq(actual, expected) then
      error(with_msg(msg, "expected " .. escape(expected) .. ", got "
        .. escape(actual)), 2)
    end
  end

  function test_api.ok(value, msg)
    if not value then
      error(with_msg(msg, "expected a true value, got " .. escape(value)), 2)
    end
  end

  function test_api.raises(fn, pattern, msg)
    local ok, err = pcall(fn)
    if ok then
      error(with_msg(msg, "expected an error, none raised"), 2)
    end
    if pattern and not tostring(err):find(pattern) then
      error(with_msg(msg, "error " .. escape(tostring(err))
        .. " does not match " .. escape(pattern)), 2)
    end
  end

  -- Shows a value in a failure message. Long strings are cut.
  local function show(v)
    if type(v) == "table" then
      local parts = {}
      for k, item in ipairs(v) do
        parts[k] = show(item)
      end
      return "{ " .. table.concat(parts, ", ") .. " }"
    end
    local s = escape(v)
    if #s > 200 then
      s = s:sub(1, 200) .. "... (" .. #s .. " chars)"
    end
    return s
  end

  -- Registers T[name], a test that runs every row of rows.
  -- A row is { "row name", input, expected, sizes = {...} }.
  -- run(input, size) returns the actual output. It runs once per entry of
  -- row.sizes or opts.sizes, or once with size nil when there are none.
  -- The test reports every failing row, not only the first one.
  function test_api.cases(T, name, rows, run, opts)
    T[name] = function()
      local failures = {}
      for _, row in ipairs(rows) do
        local sizes = row.sizes or (opts and opts.sizes) or { false }
        for _, size in ipairs(sizes) do
          local ok, actual = pcall(run, row[2], size or nil)
          if not ok then
            actual = "error: " .. tostring(actual)
          end
          if not (ok and deep_eq(actual, row[3])) then
            failures[#failures + 1] = "row " .. escape(row[1])
              .. (size and " size " .. size or "") .. "\n  input:    "
              .. show(row[2]) .. "\n  expected: " .. show(row[3])
              .. "\n  actual:   " .. show(actual)
            break
          end
        end
      end
      if #failures > 0 then
        error(#failures .. " of " .. #rows .. " rows failed\n"
          .. table.concat(failures, "\n"), 0)
      end
    end
  end

  function test_api.skip(reason)
    error({ [SKIP] = reason }, 0)
  end

  -- Replaces os.clock in the env until the next test. Returns a controller.
  function test_api.fake_clock(start)
    local now = start or 0
    env.os.clock = function() return now end
    return {
      advance = function(dt) now = now + dt end,
      set = function(v) now = v end,
    }
  end

  -- The real os.clock the runner keeps. Read-only use.
  test_api.real_clock = real_clock

  -- A binary chunk built outside the env, where string.dump exists.
  function test_api.binary_chunk()
    return real_dump(function() return 1 end)
  end

  -- Loads bin/<name>.lua as a text chunk in the env, without running it.
  function test_api.load_bin(name)
    if type(name) ~= "string" or not name:match("^[%w_]+$") then
      error("load_bin: bad name " .. escape(name), 2)
    end
    local chunk, err = real_loadfile("bin/" .. name .. ".lua", "t", env)
    if not chunk then
      error(err, 0)
    end
    return chunk
  end

  -- Loads tools/<name>.lua as a text chunk in the env, without running it.
  function test_api.load_tool(name)
    if type(name) ~= "string" or not name:match("^[%w_]+$") then
      error("load_tool: bad name " .. escape(name), 2)
    end
    local chunk, err = real_loadfile("tools/" .. name .. ".lua", "t", env)
    if not chunk then
      error(err, 0)
    end
    return chunk
  end

  -- The release folder names under releases/, sorted.
  function test_api.release_versions()
    return copy(RELEASE_VERSIONS)
  end

  -- The base names of tests/cases/*.html, sorted.
  function test_api.list_cases()
    return copy(CASES)
  end

  -- Reads a file under releases/<version>/ or tools/, outside the env
  -- io.open limit. Returns the content, or nil when the file is missing.
  function test_api.read_repo(path)
    local root = type(path) == "string" and (path:match("^releases/[^/]+/")
      or path:match("^tools/"))
    if not root or not path:match("^[%w_./-]+$") or path:find("..", 1, true)
        or path:find("//", 1, true) then
      error("read_repo: path not allowed " .. escape(path), 2)
    end
    local f = real_open(path, "rb")
    if not f then
      return nil
    end
    local s = f:read("a")
    f:close()
    return s
  end

  test_api.in_docker = in_docker

  -- Tries a real write outside the env and removes the file on success.
  function test_api.host_write(path)
    local f, err = real_open(path, "w")
    if not f then
      return false, err
    end
    f:close()
    real_remove(path)
    return true
  end

  local function reset()
    env.os.clock = real_clock
    for _, shim in ipairs(shims) do
      if type(shim) == "table" and type(shim.test) == "table" then
        shim.test.reset()
      end
    end
  end

  return env, reset
end

local function run_file(path, report)
  local env, reset = build_env()
  local chunk, err = real_loadfile(path, "t", env)
  local ok, tests = false, err
  if chunk then
    ok, tests = xpcall(chunk, real_traceback)
  end
  if not ok or type(tests) ~= "table" then
    report(path, "(load)", ok and "file did not return a table of tests"
      or tostring(tests))
    return
  end
  local names = {}
  for name, fn in pairs(tests) do
    if type(fn) == "function" then
      names[#names + 1] = tostring(name)
    end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    reset()
    local passed, result = pcall(tests[name])
    if passed then
      report(path, name, nil)
    elseif type(result) == "table" and result[SKIP] then
      report(path, name, nil, result[SKIP])
    else
      report(path, name, tostring(result))
    end
  end
end

local function main()
  local passed, failed, skipped = 0, 0, 0
  local function report(path, name, failure, skip_reason)
    if skip_reason then
      skipped = skipped + 1
      print("SKIP " .. path .. " " .. name .. ": " .. tostring(skip_reason))
    elseif failure then
      failed = failed + 1
      print("FAIL " .. path .. " " .. name .. ": " .. failure)
    else
      passed = passed + 1
    end
  end
  for _, path in ipairs(find_test_files()) do
    run_file(path, report)
  end
  local summary = passed .. " passed, " .. failed .. " failed"
  if skipped > 0 then
    summary = summary .. ", " .. skipped .. " skipped"
  end
  print(summary)
  os.exit(failed == 0 and 0 or 1)
end

main()
