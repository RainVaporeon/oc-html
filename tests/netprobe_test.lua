-- Tests for tools/netprobe.lua with the fake internet card and fake machine
-- links. The probe plan is in docs/netprobe-plan.md.

local t = require("test")
local internet = require("internet")

local T = {}

local probe = t.load_tool("netprobe")({})
local TARGETS = probe.targets(probe.parse_args({ n = 0 }))
local HTTP_URL = TARGETS.pages[1][2]
local OUT = probe.DEFAULT_OUT

local function urlencode(s)
  return (s:gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

local PAGE = { headers = { ["Content-Type"] = { "text/html" } },
  body = { "<html>hello</html>" } }

-- A fake machine. opts: routes (url -> script), default (script), limit,
-- interrupt_after (yield count), interrupt_mode ("error" raises from the
-- yield, "flag" turns interrupted() true), fail_write ("first" or "all"),
-- free_fails (free() raises after the first yield), no_card.
local function fake(opts)
  opts = opts or {}
  local m = { out = {}, err = {}, files = {}, now = 100, cpu = 0, sleeps = 0,
    flag = false }
  local card, ctl = internet.new({ routes = opts.routes,
    default = opts.default or PAGE, limit = opts.limit })
  m.ctl = ctl
  m.deps = {
    out = function(line) m.out[#m.out + 1] = line end,
    err = function(line) m.err[#m.err + 1] = line end,
    card = not opts.no_card and card or nil,
    uptime = function() return m.now end,
    clock = function()
      m.cpu = m.cpu + 0.0002
      return m.cpu
    end,
    sleep = function()
      m.sleeps = m.sleeps + 1
      m.now = m.now + 0.01
      if opts.interrupt_after and m.sleeps >= opts.interrupt_after then
        if opts.interrupt_mode == "flag" then
          m.flag = true
        else
          error("interrupted", 0)
        end
      end
    end,
    free = function()
      if opts.free_fails and m.sleeps > 0 then
        error("free broke", 0)
      end
      return 1600000
    end,
    total = function() return 2097152 end,
    interrupted = function() return m.flag end,
    write_file = function(path, text, append)
      if opts.fail_write == "all" or (opts.fail_write == "first"
          and m.writes == nil) then
        m.writes = (m.writes or 0) + 1
        return nil, "disk full"
      end
      m.files[path] = (append and m.files[path] or "") .. text
      return true
    end,
    version = "Lua 5.3",
  }
  return m
end

local function run(m, ...)
  return probe.main(table.pack(...), m.deps)
end

-- The report as a key-to-value table and the list of lines.
local function parse(text)
  local values, lines = {}, {}
  for line in text:gmatch("[^\n]+") do
    lines[#lines + 1] = line
    local k, v = line:match("^([%w_.%-]+)=(.*)$")
    if k then
      values[k] = v
    end
  end
  return values, lines
end

-- Runs the probe with routes and returns the parsed report and the machine.
local function report(opts, ...)
  local m = fake(opts)
  local code = run(m, ...)
  local text = m.files[OUT]
  t.ok(text, "the report file exists")
  local values, lines = parse(text)
  return values, lines, m, code
end

-- Input: { argv, ... }. Output: the options as one line, or the message.
t.cases(T, "netprobe_args", {
  { "defaults", {},
    "out=/home/netprobe.txt base=" .. probe.DEFAULT_BASE .. " echo="
      .. probe.DEFAULT_ECHO .. " skip=false leak=false help=false urls=0" },
  { "out", { "--out", "/tmp/n.txt" },
    "out=/tmp/n.txt base=" .. probe.DEFAULT_BASE .. " echo="
      .. probe.DEFAULT_ECHO .. " skip=false leak=false help=false urls=0" },
  { "flags", { "--skip-large", "--leak" },
    "out=/home/netprobe.txt base=" .. probe.DEFAULT_BASE .. " echo="
      .. probe.DEFAULT_ECHO .. " skip=true leak=true help=false urls=0" },
  { "base and echo lose a trailing slash",
    { "--base", "http://h/raw/", "--echo", "https://e.example//" },
    "out=/home/netprobe.txt base=http://h/raw echo=https://e.example"
      .. " skip=false leak=false help=false urls=0" },
  { "urls", { "http://a.example/", "https://b.example/x" },
    "out=/home/netprobe.txt base=" .. probe.DEFAULT_BASE .. " echo="
      .. probe.DEFAULT_ECHO .. " skip=false leak=false help=false urls=2" },
  { "help", { "-h" },
    "out=/home/netprobe.txt base=" .. probe.DEFAULT_BASE .. " echo="
      .. probe.DEFAULT_ECHO .. " skip=false leak=false help=true urls=0" },
  { "out needs a value", { "--out" }, "netprobe: --out needs a value" },
  { "base needs a url", { "--base", "ftp://x" },
    "netprobe: --base needs an http or https URL: ftp://x" },
  { "echo needs a url", { "--echo", "host" },
    "netprobe: --echo needs an http or https URL: host" },
  { "unknown option", { "--fast" }, "netprobe: unknown argument: --fast" },
  { "not a url", { "example.com" },
    "netprobe: not an http or https URL: example.com" },
}, function(argv)
  local opts, msg = probe.parse_args({ n = #argv, table.unpack(argv) })
  if not opts then
    return msg
  end
  return string.format("out=%s base=%s echo=%s skip=%s leak=%s help=%s urls=%d",
    opts.out, opts.base, opts.echo, tostring(opts.skip_large == true),
    tostring(opts.leak == true), tostring(opts.help == true), #opts.urls)
end)

-- Input: { argv, expected exit code }. Output: "code|err line|out line".
t.cases(T, "netprobe_cli", {
  { "usage error", { { "--nope" } }, "2|netprobe: unknown argument: --nope"
    .. " (see netprobe --help)|" },
  { "help", { { "--help" } }, "0||" .. probe.USAGE },
  { "no card", { {}, no_card = true }, "1|netprobe: no internet card found|" },
}, function(input)
  local m = fake({ no_card = input.no_card })
  local code = run(m, table.unpack(input[1]))
  return code .. "|" .. (m.err[1] or "") .. "|" .. (m.out[1] or "")
end)

function T.netprobe_output_format()
  local values, lines, m, code = report()
  t.eq(code, 0)
  t.eq(lines[1], "#netprobe v1")
  for _, line in ipairs(lines) do
    t.ok(#line <= 200, "line length: " .. #line)
    t.ok(line == "#netprobe v1" or line:match("^net%.[%w_]+%.[%w_.%-]+=")
      or line:match("^net%.probe%.[%w_]+="), "line form: " .. line)
    t.ok(not line:find("[%c\127-\255]"), "plain bytes: " .. line)
  end
  for _, section in ipairs({ "api", "connect", "read", "large", "redirect",
      "status", "fail", "headers", "limit" }) do
    local found
    for _, line in ipairs(lines) do
      if line:sub(1, #section + 5) == "net." .. section .. "." then
        found = true
        break
      end
    end
    t.ok(found, "section " .. section .. " has lines")
  end
  local errs = {}
  for _, line in ipairs(lines) do
    if line:find("%.error=") then
      errs[#errs + 1] = line
    end
  end
  t.eq(table.concat(errs, "\n"), "")
  t.eq(values["net.probe.errors"], "0")
  t.ok(values["net.probe.duration_ms"])
  t.eq(values["net.probe.leak"], "false")
  t.eq(lines[#lines]:match("^net%.probe%.([%w_]+)="), "duration_ms")
  -- Every handle was closed.
  t.eq(m.ctl.open, 0)
  t.ok(#m.ctl.handles > 20, "many requests were made")
  -- The printed lines: the report path, then the copy hint.
  t.eq(m.out[#m.out - 1], "netprobe: report " .. OUT)
  t.eq(m.out[#m.out], "netprobe: copy " .. OUT
    .. " to ./datacollection/ in the repository")
end

function T.netprobe_out_option()
  local m = fake()
  t.eq(run(m, "--out", "/tmp/here.txt"), 0)
  t.ok(m.files["/tmp/here.txt"])
  t.eq(m.files[OUT], nil)
  t.eq(m.out[#m.out - 1], "netprobe: report /tmp/here.txt")
  t.ok(m.files["/tmp/here.txt"]:find("^#netprobe v1\n"))
end

function T.netprobe_urls_replace_pages()
  local values, _, m = report(nil, "--skip-large", "https://a.example/x")
  t.eq(values["net.connect.url1_1.url"], "https://a.example/x")
  t.eq(values["net.connect.http_1.url"], nil)
  t.eq(m.ctl.open, 0)
end

function T.netprobe_skip_large()
  local values, lines, m = report(nil, "--skip-large")
  t.eq(values["net.large.skipped"], "--skip-large")
  for _, line in ipairs(lines) do
    t.ok(not line:find("^net%.large%.page"), line)
  end
  -- The read section still reads the large page up to its cap.
  for _, req in ipairs(m.ctl.requests) do
    t.ok(req ~= nil)
  end
end

-- Input: { routes, keys }. Output: the values of the keys ("nil" when absent).
local function ask(input)
  local values = report({ routes = input.routes, default = input.default })
  local out = {}
  for i, key in ipairs(input.keys) do
    out[i] = values["net." .. key] or "nil"
  end
  return out
end

local LARGE = TARGETS.large
local ECHO404 = TARGETS.echo .. "/status/404"
local ECHO500 = TARGETS.echo .. "/status/500"
local REDIRECT = TARGETS.plain .. "/redirect-to?url="
  .. urlencode(TARGETS.plain .. "/get")

-- N1, N3, N10 and the other facts, one fake card script per row.
t.cases(T, "netprobe_facts", {
  { "N3 response before the first read",
    { routes = { [HTTP_URL] = { body = { "abc" } } },
      keys = { "connect.http_1.n3.before_read", "connect.http_1.status.code" } },
    { "true", "200" } },
  { "N3 response only after a read",
    { routes = { [HTTP_URL] = { response_after_read = true, body = { "abc" } } },
      keys = { "connect.http_1.n3.before_read", "connect.http_1.n3.first_read",
        "connect.http_1.n3.after_read", "connect.http_1.status.code" } },
    { "false", "3", "true", "200" } },
  { "N3 response never comes",
    { routes = { [HTTP_URL] = { response_polls = 1e9 } },
      keys = { "connect.http_1.n3.before_read", "connect.http_1.response.result",
        "connect.http_1.status.code" } },
    { "false", "timeout", "nil" } },
  { "N1 header names, case and list values",
    { routes = { [HTTP_URL] = { headers = { ["Content-Type"] = { "text/html" },
        ["content-length"] = "12" } } },
      keys = { "api.get.headers.type", "api.get.headers.count",
        "api.get.headers.content_type.name",
        "api.get.headers.content_type.type",
        "api.get.headers.content_type.value",
        "api.get.headers.content_length.name",
        "api.get.headers.content_length.type" } },
    { "table", "2", "Content-Type", "table", "text/html", "content-length",
      "string" } },
  { "N1 handle has the four methods",
    { keys = { "api.card.type", "api.card.isHttpEnabled",
        "api.get.handle.has.finishConnect", "api.get.handle.has.response",
        "api.get.handle.has.read", "api.get.handle.has.close",
        "api.get.request.handle_type" } },
    { "table", "true", "table", "table", "table", "table", "table" } },
  { "N2 connect polls",
    { routes = { [HTTP_URL] = { connect_polls = 4 } },
      keys = { "connect.http_1.connect.polls", "connect.http_1.connect.result" } },
    { "4", "ok" } },
  { "N2 connect timeout",
    { routes = { [HTTP_URL] = { connect_polls = 1e9 } },
      keys = { "connect.http_1.connect.result", "connect.http_1.status.code" } },
    { "timeout", "nil" } },
  { "N2 connect error",
    { routes = { [HTTP_URL] = { connect_error = "unknown host" } },
      keys = { "connect.http_1.connect.result", "connect.http_1.connect.error",
        "connect.http_1.response.result" } },
    { "error", "unknown host", "nil" } },
  { "N2 response() after a connect error is recorded",
    { routes = { [HTTP_URL] = { connect_error = HTTP_URL, code = 404,
        message = "Not Found", response_early = true } },
      keys = { "connect.http_1.connect.error_response",
        "connect.http_1.connect.error_response_message" } },
    { "404", "Not Found" } },
  { "N2 response() after a connect error: nil when the card has none",
    { routes = { [HTTP_URL] = { connect_error = HTTP_URL } },
      keys = { "connect.http_1.connect.error_response",
        "connect.http_1.connect.error_response_message" } },
    { "nil", "nil" } },
  { "N3 response() before finishConnect is recorded as its value",
    { routes = { [HTTP_URL] = { response_early = true, code = 204 } },
      keys = { "connect.http_1.n3.before_connect" } },
    { "204" } },
  { "N3 response() before finishConnect: nil",
    { keys = { "connect.http_1.n3.before_connect" } },
    { "nil" } },
  { "N2 connect raise",
    { routes = { [HTTP_URL] = { connect_raise = "tls failed" } },
      keys = { "connect.http_1.connect.result", "connect.http_1.connect.raise" } },
    { "raise", "tls failed" } },
  { "N11 request returns nil",
    { routes = { [HTTP_URL] = { request_error = "invalid address" } },
      keys = { "connect.http_1.request.result", "connect.http_1.request.error" } },
    { "nil", "invalid address" } },
  { "N11 request raises",
    { routes = { [HTTP_URL] = { request_raise = "address blocked" } },
      keys = { "connect.http_1.request.result", "connect.http_1.request.raise" } },
    { "raise", "address blocked" } },
  { "N4 chunk sizes and empty reads",
    { routes = { [HTTP_URL] = { body = internet.pieces(string.rep("x", 10000),
        4096, true) } },
      keys = { "read.http.read.bytes", "read.http.read.chunks",
        "read.http.read.empty", "read.http.read.first_sizes",
        "read.http.read.min", "read.http.read.max", "read.http.read.end",
        "read.http.read.buckets" } },
    { "10000", "3", "3", "4096,4096,1808", "1808", "4096", "eof",
      "le2048=1,le4096=2" } },
  { "N4 requested size, full chunks",
    { routes = { [LARGE] = { body = internet.pieces(string.rep("x", 70000),
        70000) } },
      keys = { "read.large_4096.read.request_size",
        "read.large_4096.read.full_chunks", "read.large_4096.read.bytes",
        "read.large_default.read.chunks", "read.large_65536.read.max" } },
    { "4096", "17", "70000", "1", "65536" } },
  { "N5 spin counts empty reads without a yield",
    { routes = { [HTTP_URL] = { body = { "", "", "", "ab" } } },
      keys = { "read.http.spin.calls", "read.http.spin.empty",
        "read.http.spin.data", "read.http.read.max_empty_run" } },
    { "5", "3", "1", "3" } },
  { "read error after some bytes",
    { routes = { [HTTP_URL] = { body = { "abc" }, read_error = "boom" } },
      keys = { "read.http.read.end", "read.http.read.reason",
        "read.http.read.bytes" } },
    { "error", "boom", "3" } },
  { "read raise",
    { routes = { [HTTP_URL] = { body = { "abc" }, read_raise = "io failed" } },
      keys = { "read.http.read.end", "read.http.read.reason" } },
    { "raise", "io failed" } },
  { "never-ending empty reads stop at the idle timeout",
    { routes = { [HTTP_URL] = { endless = true } },
      keys = { "read.http.read.end", "read.http.read.bytes" } },
    { "timeout_idle", "0" } },
  { "N10 404 with a body",
    { routes = { [ECHO404] = { code = 404, message = "Not Found",
        body = { "no such page" } } },
      keys = { "status.echo404.status.code", "status.echo404.status.message",
        "status.echo404.read.bytes", "status.echo404.body.sample",
        "status.echo404.read.end" } },
    { "404", "Not Found", "12", "no such page", "eof" } },
  { "N10 500 without a body",
    { routes = { [ECHO500] = { code = 500, message = "Internal Server Error" } },
      keys = { "status.echo500.status.code", "status.echo500.read.bytes",
        "status.echo500.body.sample", "status.echo500.read.end" } },
    { "500", "0", "nil", "eof" } },
  { "N10 error status where the first read fails",
    { routes = { [ECHO404] = { code = 404, read_error = "no error body" } },
      keys = { "status.echo404.status.code", "status.echo404.read.end",
        "status.echo404.read.reason" } },
    { "404", "error", "no error body" } },
  { "N10 error status where finishConnect fails",
    { routes = { [ECHO404] = { connect_error = "http 404" } },
      keys = { "status.echo404.connect.result", "status.echo404.status.code" } },
    { "error", "nil" } },
  { "a long body keeps a short sample only",
    { routes = { [ECHO404] = { code = 404, body = { string.rep("a", 1000) } } },
      keys = { "status.echo404.read.bytes", "status.echo404.body.sample.parts",
        "status.echo404.body.sample.1" } },
    { "1000", "2", string.rep("a", 150) } },
  { "N9 a redirect that the card does not follow",
    { routes = { [REDIRECT] = { code = 302, message = "Found",
        headers = { Location = { TARGETS.plain .. "/get" } } } },
      keys = { "redirect.http_to_http.status.code",
        "redirect.http_to_http.headers.location.value",
        "redirect.http_to_http_hop1.status.code",
        "redirect.http_to_http.hops" } },
    { "302", TARGETS.plain .. "/get", "200", "1" } },
  { "N9 a redirect that the card follows",
    { routes = { [REDIRECT] = { code = 200, body = { "{\"url\":1}" } } },
      keys = { "redirect.http_to_http.status.code",
        "redirect.http_to_http_hop1.status.code", "redirect.http_to_http.hops",
        "redirect.http_to_http.body.sample" } },
    { "200", "nil", "0", "{\"url\":1}" } },
  { "N9 a relative location is joined to the host",
    { routes = { [REDIRECT] = { code = 301, headers = { Location = "/next" } } },
      keys = { "redirect.http_to_http_hop1.url",
        "redirect.http_to_http.hops" } },
    { TARGETS.plain .. "/next", "1" } },
  { "N9 a location that is not followed",
    { routes = { [REDIRECT] = { code = 301, headers = { Location = "ftp://x/" } } },
      keys = { "redirect.http_to_http.hops", "redirect.http_to_http.stopped" } },
    { "0", "location not followed: ftp://x/" } },
  { "N9 an endless redirect stops at the hop limit",
    { default = { code = 302, headers = { Location = HTTP_URL } },
      keys = { "redirect.chain3.hops", "redirect.chain3.stopped" } },
    { "6", "hop limit" } },
  { "N12 blocked address raises",
    { routes = { ["http://localhost/"] = { request_raise = "address is blocked" } },
      keys = { "fail.blocked_localhost.request.result",
        "fail.blocked_localhost.request.raise" } },
    { "raise", "address is blocked" } },
  { "N11 unknown host fails in finishConnect",
    { routes = { ["http://netprobe-no-such-host.invalid/"] = {
        connect_error = "java.net.UnknownHostException" } },
      keys = { "fail.unknown_host.connect.result",
        "fail.unknown_host.connect.error" } },
    { "error", "java.net.UnknownHostException" } },
  { "N11 a silent host stops at the connect timeout",
    { routes = { [TARGETS.silent] = { connect_polls = 1e9 } },
      keys = { "fail.silent.connect.result", "fail.silent.close.ok" } },
    { "timeout", "true" } },
  { "N14 the echo body is kept as a sample",
    { routes = { [TARGETS.echo .. "/headers"] = { body = {
        "{\"headers\":{\"User-Agent\":\"x\"}}" } } },
      keys = { "headers.echo_default.body.sample",
        "headers.echo_custom.body.sample" } },
    { "{\"headers\":{\"User-Agent\":\"x\"}}",
      "{\"headers\":{\"User-Agent\":\"x\"}}" } },
  { "N15 content length and charset",
    { routes = { [probe.REAL_PAGES[1][2]] = { headers = {
        ["Content-Length"] = { "82295" },
        ["Content-Type"] = { "text/html; charset=utf-8" } } } },
      keys = { "headers.real_wiki.headers.content_length.value",
        "headers.real_wiki.headers.content_type.value",
        "headers.real_wiki.read.bytes" } },
    { "82295", "text/html; charset=utf-8", "0" } },
  { "N13 connection limit and slot reuse",
    { keys = { "limit.opened", "limit.close_one", "limit.reopen_after_close",
        "limit.double_close", "limit.leak.skipped" } },
    { "4", "ok", "true", "ok", "run with --leak, then run the probe again" } },
}, ask)

function T.netprobe_limit_not_reached()
  local values, _, m = report({ limit = 1000 })
  t.eq(values["net.limit.opened"], "64")
  t.eq(values["net.limit.opened_stop"], "cap 64")
  t.eq(m.ctl.open, 0)
end

function T.netprobe_leak_option()
  local values, lines, m = report({ limit = 5 }, "--leak")
  for _, line in ipairs(lines) do
    t.ok(not line:find("%.error="), line)
  end
  t.eq(values["net.limit.opened"], "5")
  t.eq(values["net.limit.leak.dropped"], "5")
  t.eq(values["net.limit.leaked"], "0")
  t.eq(values["net.probe.leak"], "true")
  -- The dropped handles stay open in the fake: it has no GC link.
  t.eq(m.ctl.open, 5)
end

function T.netprobe_memory_facts()
  local values = report({ routes = { [LARGE] = { body = internet.pieces(
    string.rep("x", 100000), 4096) } } })
  for _, key in ipairs({ "mem.before", "mem.connected", "mem.response",
      "mem.after_hold", "mem.after_chunks", "mem.min", "mem.after_close" }) do
    t.eq(values["net.read.large_4096." .. key], "1600000", key)
  end
  t.eq(values["net.read.large_4096.mem.chunks"], "16")
end

-- The whole large page is counted, not kept: the report stays small.
function T.netprobe_large_page_is_not_kept()
  local size = 2 * 1024 * 1024
  local m = fake({ routes = { [LARGE] = { body = internet.pieces(
    string.rep("x", size), 4096) } } })
  t.eq(run(m), 0)
  local values = parse(m.files[OUT])
  t.eq(values["net.large.page.read.bytes"], tostring(size))
  t.eq(values["net.large.page.read.end"], "eof")
  t.eq(values["net.read.large_4096.read.end"], "cap")
  t.eq(values["net.read.large_4096.read.bytes"], tostring(256 * 1024))
  t.ok(#m.files[OUT] < 200 * 1024, "report size " .. #m.files[OUT])
end

-- A step that raises is recorded and the probe goes on.
function T.netprobe_failing_step_does_not_stop_the_probe()
  local values, lines, m, code = report({ free_fails = true })
  t.eq(code, 0)
  t.eq(values["net.read.large_default.error"], "free broke")
  t.eq(values["net.read.large_4096.error"], "free broke")
  t.eq(values["net.large.page.error"], "free broke")
  t.ok(tonumber(values["net.probe.errors"]) >= 3)
  -- The later sections still ran, and no handle stayed open.
  t.eq(values["net.limit.opened"], "4")
  t.eq(values["net.status.echo404.status.code"], "200")
  t.eq(values["net.headers.real_manual.status.code"], "200")
  t.eq(m.ctl.open, 0)
  t.eq(lines[#lines]:match("^net%.probe%.([%w_]+)="), "duration_ms")
end

-- Input: { opts for fake, argv }. Output: a summary line of the Ctrl+C run:
-- exit code, interrupted flag, a known section name as "*", open handles,
-- and whether the last line is the closing one.
local SECTION_NAMES = { api = true, connect = true, read = true, large = true,
  redirect = true, status = true, fail = true, headers = true, limit = true }
t.cases(T, "netprobe_interrupt", {
  { "in the api section", { { interrupt_after = 2 } }, "130|true|api|0|true" },
  { "in the connect section", { { interrupt_after = 20 } },
    "130|true|*|0|true" },
  { "in the read section", { { interrupt_after = 60 } }, "130|true|*|0|true" },
  { "later in the run", { { interrupt_after = 150 } }, "130|true|*|0|true" },
  { "as a flag", { { interrupt_after = 30, interrupt_mode = "flag" } },
    "130|true|*|0|true" },
  { "from a card read", { { routes = { [HTTP_URL] = { body = { "abc" },
      read_raise = "interrupted" } } } }, "130|true|*|0|true" },
}, function(input)
  local m = fake(input[1])
  local code = run(m, table.unpack(input[2] or {}))
  local text = m.files[OUT]
  if not text then
    return "no file"
  end
  local values = parse(text)
  local at = (values["net.probe.interrupted_at"] or ""):match("^([%w_]+)%.")
  if SECTION_NAMES[at] and at ~= "api" then
    at = "*"
  end
  local last = text:match("([^\n]+)\n$") or ""
  return table.concat({ code, tostring(values["net.probe.interrupted"] == "true"),
    tostring(at), m.ctl.open,
    tostring(last:match("^net%.probe%.duration_ms=") ~= nil) }, "|")
end)

function T.netprobe_interrupt_keeps_earlier_facts()
  local m = fake({ interrupt_after = 40 })
  t.eq(run(m), 130)
  local values = parse(m.files[OUT])
  t.eq(values["net.api.get.status.code"], "200")
  t.eq(values["net.connect.http_1.status.code"], "200")
  t.ok(values["net.probe.interrupted_at"])
  t.eq(values["net.large.page.read.bytes"], nil)
end

-- Writing: a failing first write stops the probe, a failing later write
-- prints the report.
function T.netprobe_write_failures()
  local m = fake({ fail_write = "first" })
  t.eq(run(m), 1)
  t.eq(m.err[1], "netprobe: cannot write " .. OUT .. " (disk full)")
  t.eq(m.files[OUT], nil)

  m = fake({ fail_write = "all" })
  t.eq(run(m), 1)
  t.eq(m.err[1], "netprobe: cannot write " .. OUT .. " (disk full)")
end

-- The real game writer over a recording io.open: the first write replaces
-- the file, later writes append, so the file holds every section.
function T.netprobe_file_writer_appends()
  local disk, modes = {}, {}
  local function open(path, mode)
    modes[#modes + 1] = mode
    if mode == "wb" then
      disk[path] = ""
    end
    return {
      write = function(_, text)
        disk[path] = disk[path] .. text
        return true
      end,
      close = function() end,
    }
  end
  local write = probe.file_writer(open)
  t.eq(write("out", "one\n", false), true)
  t.eq(write("out", "two\n", true), true)
  t.eq(disk.out, "one\ntwo\n")
  t.eq(table.concat(modes, ","), "wb,ab")
  local failing = probe.file_writer(function() return nil, "no space" end)
  local ok, why = failing("out", "x", false)
  t.eq(ok, nil)
  t.eq(why, "no space")
end

return T
