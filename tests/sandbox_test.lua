-- Self-tests for the sandbox in tests/run.lua and tests/docker/test.ps1.

local t = require("test")

local T = {}

function T.dangerous_functions_are_nil()
  t.eq(os.execute, nil, "os.execute")
  t.eq(os.remove, nil, "os.remove")
  t.eq(os.rename, nil, "os.rename")
  t.eq(os.exit, nil, "os.exit")
  t.eq(os.tmpname, nil, "os.tmpname")
  t.eq(io.popen, nil, "io.popen")
  t.eq(io.lines, nil, "io.lines")
  t.eq(debug, nil, "debug")
  t.eq(collectgarbage, nil, "collectgarbage")
  t.eq(loadfile, nil, "loadfile")
  t.eq(dofile, nil, "dofile")
  t.eq(string.dump, nil, "string.dump")
end

function T.open_for_writing_fails()
  for _, mode in ipairs({ "w", "a", "r+", "w+", "a+", "wb" }) do
    local f, err = io.open("tests/fuzz-failures/x", mode)
    t.eq(f, nil, "mode " .. mode)
    t.ok(err and err:find("read mode only", 1, true), "mode " .. mode)
  end
end

function T.open_outside_tests_fails()
  for _, path in ipairs({
    "/etc/passwd", "SPEC.md", "lib/html/guard.lua", "tests/../SPEC.md",
    "/src/tests/run.lua", "tests", "tests/", "./tests/../.git/config",
  }) do
    local f = io.open(path)
    t.eq(f, nil, path)
  end
end

function T.open_under_tests_for_reading_works()
  local f = assert(io.open("tests/run.lua"))
  local head = f:read(2)
  f:close()
  t.eq(head, "--")
end

function T.binary_chunk_is_refused()
  local chunk = t.binary_chunk()
  local fn, err = load(chunk)
  t.eq(fn, nil, "load(binary)")
  t.ok(err and err:find("binary", 1, true), err)
  fn, err = load(chunk, "x", "b")
  t.eq(fn, nil, "load(binary, mode b)")
  t.ok(err and err:find("binary", 1, true), err)
end

function T.load_defaults_to_sandbox_env()
  local fn = assert(load("return os.execute, io.popen"))
  local execute, popen = fn()
  t.eq(execute, nil)
  t.eq(popen, nil)
end

function T.require_resolves_only_known_names()
  t.ok(require("computer").uptime, "computer shim")
  t.ok(require("unicode").wlen, "unicode shim")
  t.raises(function() require("os") end, "not found")
  t.raises(function() require("../run") end, "not found")
  t.raises(function() require("html.missing") end, "html.missing")
end

function T.fake_clock_1_replaces_os_clock()
  local clock = t.fake_clock(5)
  t.eq(os.clock(), 5)
  clock.advance(1.5)
  t.eq(os.clock(), 6.5)
end

function T.fake_clock_2_is_reset_before_next_test()
  t.ok(os.clock() < 5, "os.clock is real again")
end

function T.host_cannot_write_to_repo()
  if not t.in_docker() then
    t.skip("not running in Docker")
  end
  local ok = t.host_write("/src/x")
  t.eq(ok, false, "write to /src/x")
  ok = t.host_write("/tmp/x")
  t.eq(ok, false, "write to /tmp/x (read-only root)")
end

function T.host_can_write_fuzz_failures()
  if not t.in_docker() then
    t.skip("not running in Docker")
  end
  local ok, err = t.host_write("/src/tests/fuzz-failures/.write-probe")
  t.ok(ok, err)
end

return T
