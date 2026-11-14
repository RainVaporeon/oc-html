-- Self-tests for the sandbox in tests/run.lua and tests/docker/test.ps1.
-- Rules: spec/testing.md "Sandbox".

local t = require("test")

local T = {}

-- The env has none of these. Each name is looked up through load, which
-- also shows that load uses the sandbox env.
t.cases(T, "sandbox_denied", {
  { "os.execute", "os.execute", "nil" },
  { "os.remove", "os.remove", "nil" },
  { "os.rename", "os.rename", "nil" },
  { "os.exit", "os.exit", "nil" },
  { "os.tmpname", "os.tmpname", "nil" },
  { "io.popen", "io.popen", "nil" },
  { "io.lines", "io.lines", "nil" },
  { "debug", "debug", "nil" },
  { "collectgarbage", "collectgarbage", "nil" },
  { "loadfile", "loadfile", "nil" },
  { "dofile", "dofile", "nil" },
  { "string.dump", "string.dump", "nil" },
}, function(name)
  return type(assert(load("return " .. name))())
end)

-- Input: { path, mode }. io.open reads only, and only under tests/.
t.cases(T, "sandbox_open_paths", {
  { "write mode w", { "tests/fuzz-failures/x", "w" }, "refused" },
  { "write mode a", { "tests/fuzz-failures/x", "a" }, "refused" },
  { "write mode r+", { "tests/fuzz-failures/x", "r+" }, "refused" },
  { "write mode w+", { "tests/fuzz-failures/x", "w+" }, "refused" },
  { "write mode a+", { "tests/fuzz-failures/x", "a+" }, "refused" },
  { "write mode wb", { "tests/fuzz-failures/x", "wb" }, "refused" },
  { "absolute path outside", { "/etc/passwd" }, "refused" },
  { "SPEC.md outside tests", { "SPEC.md" }, "refused" },
  { "lib file outside tests", { "lib/html/guard.lua" }, "refused" },
  { "tests/../ climbs out", { "tests/../SPEC.md" }, "refused" },
  { "/src/tests/run.lua", { "/src/tests/run.lua" }, "refused" },
  { "the folder tests", { "tests" }, "refused" },
  { "the folder tests/", { "tests/" }, "refused" },
  { "./tests/../.git/config", { "./tests/../.git/config" }, "refused" },
  { "tests/run.lua for reading", { "tests/run.lua" }, "opened" },
  { "tests/run.lua with mode r", { "tests/run.lua", "r" }, "opened" },
}, function(input)
  local f = io.open(input[1], input[2])
  if f then
    f:close()
    return "opened"
  end
  return "refused"
end)

-- Input: a module name. Only the shims and the project modules load.
t.cases(T, "sandbox_require", {
  { "computer shim", "computer", "loaded" },
  { "unicode shim", "unicode", "loaded" },
  { "os", "os", "refused: not found" },
  { "../run", "../run", "refused: not found" },
  { "a missing project module", "html.missing", "refused" },
}, function(name)
  local ok, err = pcall(require, name)
  if ok then
    return "loaded"
  end
  return tostring(err):find("not found", 1, true) and "refused: not found"
    or "refused"
end)

function T.binary_chunk_is_refused()
  local chunk = t.binary_chunk()
  local fn, err = load(chunk)
  t.eq(fn, nil, "load(binary)")
  t.ok(err and err:find("binary", 1, true), err)
  fn, err = load(chunk, "x", "b")
  t.eq(fn, nil, "load(binary, mode b)")
  t.ok(err and err:find("binary", 1, true), err)
end

function T.fake_clock_replaces_os_clock()
  local clock = t.fake_clock(5)
  t.eq(os.clock(), 5)
  clock.advance(1.5)
  t.eq(os.clock(), 6.5)
  clock.set(2)
  t.eq(os.clock(), 2)
  t.ok(os.clock ~= t.real_clock, "os.clock is the fake")
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
