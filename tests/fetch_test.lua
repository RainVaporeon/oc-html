-- Tests for lib/html/fetch.lua through its public functions (parse_url,
-- looks_like_host and open with the fake card). The rules are in
-- spec/fetch.md and spec/url.md. Each table row names the rule it checks.

local t = require("test")
local fetch = require("html.fetch")
local internet = require("internet")
local computer = require("computer")

local T = {}

local URL = "http://example.com/"
local PAGE = "<title>T</title><p>Hello world</p>"

-- The links for fetch.open: the fake card, the shim clock and sleep, and an
-- interrupt check that returns flag.on.
local function links(card, flag)
  return {
    internet = card,
    clock = computer.uptime,
    sleep = os.sleep,
    interrupted = function() return flag ~= nil and flag.on end,
  }
end

-- Opens url on a fake card with one script for every url. Returns the
-- response (or nil), the message, the controller and the info table.
local function open(script, url, opts)
  opts = opts or {}
  local card, ctl = internet.new({ default = script, routes = opts.routes,
    http = opts.http, limit = opts.limit })
  local info = {}
  local resp, why = fetch.open(url or URL, links(card, opts.flag), info)
  return resp, why, ctl, info
end

-- Reads a response to its end. Returns the text and the error message.
-- Every chunk has 1 to 4096 bytes (spec "Stream into the pipeline", rule 5).
local function read_all(resp)
  local out = {}
  while true do
    local s, why = resp.read()
    if s == nil then
      return table.concat(out), why
    end
    t.ok(#s > 0 and #s <= 4096, "chunk size " .. #s)
    out[#out + 1] = s
  end
end

-- Every handle was closed (the handle closes on every exit path).
local function all_closed(ctl)
  for i, h in ipairs(ctl.handles) do
    t.ok(h.closed >= 1, "handle " .. i .. " closes")
  end
  t.eq(ctl.open, 0, "no open connection")
end

-- Closes a response (when there is one) and checks that no handle is left.
local function finish(resp, ctl)
  if resp then
    resp.close()
  end
  all_closed(ctl)
end

-- URL parsing (spec/url.md "URL parsing") -----------------------------------

local LONG_BASE = "http://example.com/"
local LONG_OK = LONG_BASE .. string.rep("a", 2048 - #LONG_BASE)

local function parts(scheme, host, port, path, url)
  return { scheme = scheme, host = host, port = port, path = path, url = url }
end

local function invalid(s)
  return "html: invalid URL: " .. s
end

t.cases(T, "parse_url", {
  { "all parts, fragment removed", "http://example.com:8080/a/b?x=1#top",
    parts("http", "example.com", 8080, "/a/b?x=1",
      "http://example.com:8080/a/b?x=1") },
  { "https default port 443, path /", "https://example.com",
    parts("https", "example.com", 443, "/", "https://example.com") },
  { "http default port 80, path /", "http://example.com",
    parts("http", "example.com", 80, "/", "http://example.com") },
  { "query without path is the path", "http://example.com?q",
    parts("http", "example.com", 80, "?q", "http://example.com?q") },
  { "fragment without path", "http://x.com#a/b",
    parts("http", "x.com", 80, "/", "http://x.com") },
  { "scheme is not case-sensitive, text keeps its case", "HTTP://Example.com/",
    parts("http", "Example.com", 80, "/", "HTTP://Example.com/") },
  { "mixed case https", "hTtPs://x.org",
    parts("https", "x.org", 443, "/", "hTtPs://x.org") },
  { "host and path keep their case", "http://EXAMPLE.com/Path?Q=A",
    parts("http", "EXAMPLE.com", 80, "/Path?Q=A",
      "http://EXAMPLE.com/Path?Q=A") },
  { "port checks are left to the card", "http://example.com:abc/",
    parts("http", "example.com", nil, "/", "http://example.com:abc/") },
  { "2048 bytes are accepted", LONG_OK,
    parts("http", "example.com", 80, LONG_OK:sub(#"http://example.com" + 1),
      LONG_OK) },
  { "2049 bytes are too long", LONG_OK .. "a", "html: invalid URL: too long" },
  { "ftp scheme", "ftp://example.com",
    "html: unsupported URL scheme: ftp" },
  { "scheme in the message is lowercase", "FILE://x",
    "html: unsupported URL scheme: file" },
  { "scheme letters, digits and + . -", "svn+ssh://x",
    "html: unsupported URL scheme: svn+ssh" },
  { "scheme with dot and dash", "a.b-c+d://x",
    "html: unsupported URL scheme: a.b-c+d" },
  { "empty host", "http://", invalid("http://") },
  { "empty host before a path", "http:///path", invalid("http:///path") },
  { "empty host before a port", "http://:80/", invalid("http://:80/") },
  { "empty host before a fragment", "http://#frag", invalid("http://#frag") },
  { "space in the host", "http://exa mple.com",
    invalid("http://exa mple.com") },
  { "space in the path", "http://example.com/a b",
    invalid("http://example.com/a b") },
  { "control byte", "http://x.com/\1", invalid("http://x.com/\1") },
  { "byte 0x7F", "http://x.com/\127", invalid("http://x.com/\127") },
  { "byte above 0x7E", "http://x.com/\195\169",
    invalid("http://x.com/\195\169") },
  { "no scheme", "example.com", invalid("example.com") },
  { "scheme must start with a letter", "1ftp://x", invalid("1ftp://x") },
  { "scheme needs two slashes", "http:/x", invalid("http:/x") },
  { "scheme must be at the start", "dir/http://x", invalid("dir/http://x") },
}, function(s)
  local u, why = fetch.parse_url(s)
  if not u then
    return why
  end
  return parts(u.scheme, u.host, u.port, u.path, u.url)
end)

-- Arguments without a scheme (spec/url.md "Arguments without a scheme") -----

t.cases(T, "looks_like_host", {
  { "domain", "example.com", true },
  { "upper case", "EXAMPLE.COM", true },
  { "with path", "example.com/path", true },
  { "with a slash only", "example.com/", true },
  { "port, path and query", "example.com:8080/a?b=1", true },
  { "fragment", "example.com#top", true },
  { "localhost", "localhost", true },
  { "localhost not case-sensitive", "LocalHost", true },
  { "localhost with port", "localhost:8080", true },
  { "ipv4", "192.168.0.1", true },
  { "dash and digit labels", "a-b.c0.org", true },
  { "highest port", "x.y:65535", true },
  { "lowest port", "x.y:1", true },
  { "extension only in the query", "example.com?q=a.html", true },
  { "label of 63 bytes", "x." .. string.rep("a", 63), true },
  { "empty", "", false },
  { "starts with a dot", "./x.html", false },
  { "html extension", "x.html", false },
  { "extension not case-sensitive", "X.HTM", false },
  { "xhtml extension", "a.xhtml", false },
  { "txt extension", "notes.txt", false },
  { "lua extension", "prog.lua", false },
  { "slash before the first dot", "dir/x.html", false },
  { "slash before the first dot, domain", "dir/example.com", false },
  { "one label", "foo", false },
  { "one label with port", "foo:8080", false },
  { "empty label", "example..com", false },
  { "leading dot", ".example.com", false },
  { "trailing dot", "example.com.", false },
  { "label starts with dash", "a.-b.com", false },
  { "label ends with dash", "a.b-.com", false },
  { "empty port", "example.com:", false },
  { "port 0", "example.com:0", false },
  { "port above 65535", "example.com:99999", false },
  { "port with 6 digits", "example.com:123456", false },
  { "port with a letter", "example.com:8a", false },
  { "space", "exa mple.com", false },
  { "byte above 0x7E", "ex\195\164mple.com", false },
  { "starts with ~", "~/example.com", false },
  { "only ~", "~", false },
  { "starts with /", "/example.com", false },
  { "underscore in a label", "a_b.com", false },
  { "label of 64 bytes", "x." .. string.rep("a", 64), false },
  { "control byte", "example.com\t", false },
  { "two colons", "a.b:c:80", false },
}, function(arg)
  return fetch.looks_like_host(arg)
end)

-- Request flow --------------------------------------------------------------

-- Spec "Internet card API" and "Stream into the pipeline": one end-to-end
-- request with the headers sent, the response fields and the chunk size.
function T.open_reads_the_body_and_sends_the_headers()
  local resp, why, ctl = open({ connect_polls = 3, response_polls = 2,
    headers = { ["Content-Type"] = { "text/html; charset=utf-8" },
      ["Content-Length"] = { tostring(#PAGE) } },
    body = internet.pieces(PAGE, 5, true) })
  t.eq(why, nil)
  assert(resp, why)
  t.eq(resp.status, 200)
  t.eq(resp.length, #PAGE)
  t.eq(resp.final_url, URL)
  t.eq(resp.content_type, "text/html; charset=utf-8")
  t.eq(read_all(resp), PAGE)
  t.eq(resp.read(), nil, "read after the end")
  t.eq(ctl.requests, { URL })
  t.eq(ctl.data, nil)
  t.eq(ctl.headers, { ["User-Agent"] = "oc-html/" .. fetch.VERSION,
    ["Accept-Encoding"] = "identity" })
  resp.close()
  resp.close()
  all_closed(ctl)
  local text = string.rep("abcdefgh", 2000)
  resp, _, ctl = open({ body = { text } })
  assert(resp, "open failed")
  t.eq(read_all(resp), text, "a large piece comes in chunks of 4096 bytes")
  finish(resp, ctl)
end

-- Spec "Redirects" and spec/probe.md: a chain with an absolute and a path
-- Location, the requests made, the final URL and the redirect count.
function T.redirect_absolute_and_path()
  local routes = {
    ["http://a.com/"] = { code = 301, message = "Moved",
      headers = { Location = { "https://b.com:8443/x?y#frag" } } },
    ["https://b.com:8443/x?y"] = { code = 302, message = "Moved",
      headers = { Location = { "/z" } } },
    ["https://b.com:8443/z"] = { body = { "done" } },
  }
  local resp, why, ctl, info = open({}, "http://a.com/", { routes = routes })
  t.eq(why, nil)
  assert(resp, why)
  t.eq(ctl.requests, { "http://a.com/", "https://b.com:8443/x?y",
    "https://b.com:8443/z" })
  t.eq(resp.final_url, "https://b.com:8443/z")
  t.eq(info.redirects, 2)
  t.eq(read_all(resp), "done")
  finish(resp, ctl)
end

-- Spec/probe.md "fetch": seconds from the request to the end of the body.
function T.fetch_time_runs_to_the_end_of_the_body()
  local body = { "a" }
  for _ = 1, 20 do
    body[#body + 1] = ""
  end
  local resp = open({ connect_polls = 10, body = body })
  assert(resp, "open failed")
  read_all(resp)
  local done = resp.fetch_time()
  t.ok(done >= 1.5 and done < 1.6, "fetch time " .. done)
  computer.test.advance(5)
  t.eq(resp.fetch_time(), done, "the clock stops at the end")
end

-- Request URL: the fragment is not sent, the text keeps its case.
t.cases(T, "request_url", {
  { "fragment is not sent", "http://example.com/a#top",
    { requests = { "http://example.com/a" },
      final_url = "http://example.com/a" } },
  { "the user's case is kept", "HTTP://Example.COM/Path",
    { requests = { "HTTP://Example.COM/Path" },
      final_url = "HTTP://Example.COM/Path" } },
  { "unsupported scheme makes no request", "ftp://x.org",
    { requests = {}, why = "html: unsupported URL scheme: ftp" } },
  { "invalid URL makes no request", "http://",
    { requests = {}, why = "html: invalid URL: http://" } },
}, function(url)
  local resp, why, ctl = open({ body = { "x" } }, url)
  local out = { requests = ctl.requests, why = why }
  if resp then
    out.final_url = resp.final_url
  end
  finish(resp, ctl)
  return out
end)

-- Errors (spec/fetch.md "Errors") --------------------------------------------

t.cases(T, "fetch_open_errors", {
  { "no internet card", { no_card = true },
    { why = "html: no internet card found (needed for " .. URL .. ")",
      requests = 0 } },
  { "HTTP disabled in the server config", { opts = { http = false } },
    { why = "html: HTTP requests are disabled on this server",
      requests = 0 } },
  { "request returns nil and a reason",
    { script = { request_error = "address is not allowed" } },
    { why = "html: cannot fetch " .. URL .. ": address is not allowed",
      requests = 1 } },
  { "request raises a string", { script = { request_raise = "bad address" } },
    { why = "html: cannot fetch " .. URL .. ": bad address", requests = 1 } },
  { "the message is one line", { script = { request_raise = "bad\nmore" } },
    { why = "html: cannot fetch " .. URL .. ": bad", requests = 1 } },
  { "a reason that is not a string", { script = { request_raise = { 1 } } },
    { why = "html: cannot fetch " .. URL .. ": table: ADDR", requests = 1 } },
  { "too many open connections", { opts = { limit = 0 } },
    { why = "html: cannot fetch " .. URL .. ": too many open connections",
      requests = 1 } },
  { "finishConnect fails",
    { script = { connect_polls = 2, connect_error = "unknown host" } },
    { why = "html: cannot connect: " .. URL .. ": unknown host",
      requests = 1 } },
  { "finishConnect raises", { script = { connect_raise = "refused" } },
    { why = "html: cannot connect: " .. URL .. ": refused", requests = 1 } },
  { "unsupported scheme", { url = "ftp://x.org" },
    { why = "html: unsupported URL scheme: ftp", requests = 0 } },
}, function(input)
  if input.no_card then
    local resp, why = fetch.open(URL, links(nil), {})
    return { why = resp and "opened" or why, requests = 0 }
  end
  local resp, why, ctl = open(input.script or {}, input.url, input.opts)
  finish(resp, ctl)
  if resp then
    why = "opened"
  end
  return { why = (why:gsub("table: %w+", "table: ADDR")),
    requests = #ctl.requests }
end)

-- A read that fails (2xx status): the part before the error is delivered.
t.cases(T, "fetch_read_errors", {
  { "read returns nil and a reason",
    { body = { "abc" }, read_error = "reset" },
    { text = "abc", why = "html: read error: reset" } },
  { "read raises", { body = { "abc" }, read_raise = "broken\npipe" },
    { text = "abc", why = "html: read error: broken" } },
  { "read fails at once", { read_error = "gone" },
    { text = "", why = "html: read error: gone" } },
}, function(script)
  local resp, _, ctl = open(script)
  assert(resp, "open failed")
  local text, why = read_all(resp)
  finish(resp, ctl)
  return { text = text, why = why }
end)

-- Timeouts (spec/fetch.md "Timeouts and yields") ------------------------------

local function gaps(count, first)
  local body = { first }
  for _ = 1, count do
    body[#body + 1] = ""
  end
  return body
end

local function three_chunks_with_gaps()
  local body = {}
  for _ = 1, 3 do
    for _, piece in ipairs(gaps(500, "abc")) do
      body[#body + 1] = piece
    end
  end
  return body
end

t.cases(T, "fetch_timeouts", {
  { "connect never completes", { connect_polls = 1000000 },
    { why = "html: timed out connecting to " .. URL, secs = 15 } },
  { "response never comes: one budget for connect and response",
    { connect_polls = 100, response_polls = 1000000 },
    { why = "html: timed out connecting to " .. URL, secs = 15 } },
  { "12.5 s of connecting and waiting is inside the budget",
    { connect_polls = 150, response_polls = 100, body = { "x" } },
    { text = "x", secs = 12 } },
  { "no byte at all", { body = {}, endless = true },
    { text = "", why = "html: timed out reading " .. URL
      .. " (0 bytes received)", secs = 30 } },
  { "29 s without a byte is inside the budget",
    { body = gaps(580, "x") }, { text = "x", secs = 29 } },
  { "each chunk restarts the 30 s timer",
    { body = three_chunks_with_gaps(), endless = true },
    { text = "abcabcabc", why = "html: timed out reading " .. URL
      .. " (9 bytes received)", secs = 80 } },
}, function(script)
  local t0 = computer.uptime()
  local resp, why, ctl = open(script)
  local text
  if resp then
    text, why = read_all(resp)
  end
  finish(resp, ctl)
  return { text = text, why = why,
    secs = math.floor(computer.uptime() - t0 + 0.01) }
end)

-- Ctrl+C (spec/fetch.md "Timeouts and yields", note 10) -----------------------

t.cases(T, "fetch_interrupt", {
  { "during connect", { script = { connect_polls = 10 }, flag = true },
    { open_why = "html: interrupted" } },
  { "during the wait for the response",
    { script = { response_polls = 10 }, flag = true },
    { open_why = "html: interrupted" } },
  { "during a read that gets no data",
    { script = { body = { "abc", "", "def" } }, after_first = true },
    { first = "abc", why = "html: interrupted" } },
  { "during a read of an error status",
    { script = { code = 404, body = { "", "x" } }, flag = true },
    { why = "html: interrupted" } },
  { "a raised sleep error passes through and closes the handle",
    { script = { connect_polls = 5 }, sleep_raises = true },
    { raised = "interrupted" } },
}, function(input)
  local flag = { on = input.flag == true }
  local card, ctl = internet.new({ default = input.script })
  local l = links(card, flag)
  if input.sleep_raises then
    l.sleep = function() error("interrupted", 0) end
  end
  local ok, resp, why = pcall(fetch.open, URL, l, {})
  local out = {}
  if not ok then
    out.raised = resp
  elseif not resp then
    out.open_why = why
  else
    if input.after_first then
      out.first = resp.read()
      flag.on = true
    end
    out.why = select(2, resp.read())
    resp.close()
  end
  all_closed(ctl)
  return out
end)

-- Redirects (spec/fetch.md "Redirects") ---------------------------------------

local function redirect(code, location, name)
  return { code = code, message = "Moved", headers = location
    and { [name or "Location"] = { location } } or {} }
end

local function chain(last)
  local routes = {}
  for i = 0, 5 do
    routes["http://h.com/" .. i] = redirect(302, "/" .. (i + 1))
  end
  routes["http://h.com/5"] = last
  return { routes = routes, url = "http://h.com/0" }
end

local redirect_rows = {
  { "chain of 5 redirects", chain({ body = { "end" } }),
    { final = "http://h.com/5", redirects = 5, text = "end" } },
  { "the 6th redirect stops", chain(redirect(302, "/6")),
    { why = "html: too many redirects: http://h.com/0", requests = 6 } },
  { "Location header name is not case-sensitive",
    { routes = {
      [URL] = redirect(302, "http://b.com/", "location"),
      ["http://b.com/"] = { body = { "b" } } } },
    { final = "http://b.com/", redirects = 1, text = "b" } },
  { "a path Location keeps the query and drops the fragment",
    { routes = {
      [URL] = redirect(302, "/z?x=1#f"),
      ["http://example.com/z?x=1"] = { body = { "z" } } } },
    { final = "http://example.com/z?x=1", redirects = 1, text = "z" } },
  { "redirect to ftp", { script = redirect(302, "ftp://x.com/f") },
    { why = "html: unsupported URL scheme: ftp", requests = 1 } },
  { "redirect to an upper case scheme", { script = redirect(302, "FTP://x.com") },
    { why = "html: unsupported URL scheme: ftp", requests = 1 } },
  { "relative name", { script = redirect(302, "x.html") },
    { why = "html: cannot follow redirect: x.html", requests = 1 } },
  { "dot dot path", { script = redirect(302, "../up") },
    { why = "html: cannot follow redirect: ../up", requests = 1 } },
  { "scheme-relative", { script = redirect(302, "//other.com/p") },
    { why = "html: cannot follow redirect: //other.com/p", requests = 1 } },
  { "absolute URL that does not parse",
    { script = redirect(302, "http://bad host/") },
    { why = "html: cannot follow redirect: http://bad host/", requests = 1 } },
  { "path with a space", { script = redirect(302, "/a b") },
    { why = "html: cannot follow redirect: /a b", requests = 1 } },
}
for _, code in ipairs({ 301, 302, 303, 307, 308 }) do
  redirect_rows[#redirect_rows + 1] = { "status " .. code .. " follows",
    { routes = { [URL] = redirect(code, "http://b.com/"),
      ["http://b.com/"] = { body = { "b" } } } },
    { final = "http://b.com/", redirects = 1, text = "b" } }
end

t.cases(T, "redirects", redirect_rows, function(input)
  local resp, why, ctl, info = open(input.script or {}, input.url,
    { routes = input.routes })
  local out = {}
  if resp then
    out.final, out.redirects = resp.final_url, info.redirects
    out.text = read_all(resp)
  else
    out.why, out.requests = why, #ctl.requests
  end
  finish(resp, ctl)
  return out
end)

-- Content type and encoding (spec/fetch.md "HTTP status and content type") ----

t.cases(T, "content_type_and_encoding", {
  { "no Content-Type", { headers = {} }, { text = "x" } },
  { "text/html", { headers = { ["Content-Type"] = "text/html" } },
    { text = "x" } },
  { "list value as the card gives it",
    { headers = { ["Content-Type"] = { "text/html" } } }, { text = "x" } },
  { "case and parameter", { headers = { ["Content-Type"] =
    "TEXT/HTML; charset=UTF-8" } }, { text = "x" } },
  { "application/xhtml+xml", { headers = { ["Content-Type"] =
    "application/xhtml+xml" } }, { text = "x" } },
  { "text/plain", { headers = { ["Content-Type"] = "text/plain" } },
    { text = "x" } },
  { "spaces around the type", { headers = { ["Content-Type"] =
    " text/html ;q" } }, { text = "x" } },
  { "empty value counts as missing", { headers = { ["Content-Type"] = "" } },
    { text = "x" } },
  { "header name in lower case", { headers = { ["content-type"] =
    "image/png" } }, { why = "html: not an HTML page: image/png", reads = 0 } },
  { "header name in upper case", { headers = { ["CONTENT-TYPE"] =
    "image/png" } }, { why = "html: not an HTML page: image/png", reads = 0 } },
  { "other type stops before the body", { headers = { ["Content-Type"] =
    "image/png" }, body = { "\137PNG" } },
    { why = "html: not an HTML page: image/png", reads = 0 } },
  { "the message has no parameters", { headers = { ["Content-Type"] =
    "application/json; charset=utf-8" } },
    { why = "html: not an HTML page: application/json", reads = 0 } },
  { "gzip stops", { headers = { ["Content-Encoding"] = "gzip" } },
    { why = "html: compressed response not supported: gzip", reads = 0 } },
  { "Content-Encoding name in lower case", { headers = {
    ["content-encoding"] = "gzip" } },
    { why = "html: compressed response not supported: gzip", reads = 0 } },
  { "identity is accepted", { headers = { ["Content-Encoding"] =
    "identity" } }, { text = "x" } },
  { "identity not case-sensitive", { headers = { ["Content-Encoding"] =
    "Identity" } }, { text = "x" } },
}, function(input)
  local resp, why, ctl = open({ headers = input.headers,
    body = input.body or { "x" } })
  local out = {}
  if resp then
    out.text, out.why = read_all(resp)
  else
    out.why, out.reads = why, ctl.handles[1].reads
  end
  finish(resp, ctl)
  return out
end)

-- Response header names are not case-sensitive; Content-Length (spec/fetch.md
-- "Internet card API", "Stream into the pipeline", "Memory").
t.cases(T, "response_headers", {
  { "names as the card gives them",
    { headers = { ["Content-Length"] = { "12" },
      ["Content-Type"] = { "text/plain" } } },
    { length = 12, content_type = "text/plain", text = "x" } },
  { "lower case names", { headers = { ["content-length"] = "12",
    ["content-type"] = "text/plain" } },
    { length = 12, content_type = "text/plain", text = "x" } },
  { "upper case names", { headers = { ["CONTENT-LENGTH"] = "12",
    ["CONTENT-TYPE"] = "text/plain" } },
    { length = 12, content_type = "text/plain", text = "x" } },
  { "no headers", { headers = {} }, { text = "x" } },
  { "Content-Length that is not a number", { headers = {
    ["Content-Length"] = "abc" } }, { text = "x" } },
  { "body longer than Content-Length is read to its end",
    { headers = { ["Content-Length"] = "3" }, body = { "abcdef" } },
    { length = 3, text = "abcdef" } },
}, function(script)
  script.body = script.body or { "x" }
  local resp, _, ctl = open(script)
  assert(resp, "open failed")
  local out = { length = resp.length, content_type = resp.content_type,
    text = read_all(resp) }
  finish(resp, ctl)
  return out
end)

-- Charset (spec/fetch.md "Charset") ------------------------------------------

-- Windows-1252 code points for 0x80 to 0x9F. A byte with no character gives
-- the C1 code point (note 8).
local WIN1252 = { 0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F, 0x90, 0x2018,
  0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161,
  0x203A, 0x0153, 0x9D, 0x017E, 0x0178 }

local ALL_BYTES, ALL_CODEPOINTS = {}, {}
for b = 0x80, 0xFF do
  ALL_BYTES[#ALL_BYTES + 1] = string.char(b)
  ALL_CODEPOINTS[#ALL_CODEPOINTS + 1] = b <= 0x9F and WIN1252[b - 0x7F] or b
end
ALL_BYTES = table.concat(ALL_BYTES)

local charset_rows = {}
for _, cs in ipairs({ "iso-8859-1", "ISO-8859-1", "latin1", "windows-1252",
    "\"windows-1252\"" }) do
  charset_rows[#charset_rows + 1] = { "every byte 0x80 to 0xFF as " .. cs,
    { content_type = "text/html; charset=" .. cs, bytes = ALL_BYTES },
    ALL_CODEPOINTS, sizes = { 1, 3, 4096 } }
end

t.cases(T, "charset_all_bytes", charset_rows, function(input, size)
  local resp, _, ctl = open({ headers = { ["Content-Type"] =
    input.content_type }, body = internet.pieces(input.bytes, size) })
  assert(resp, "open failed")
  local text = read_all(resp)
  finish(resp, ctl)
  return { utf8.codepoint(text, 1, -1) }
end)

local MIXED = "caf\233 \128 \150 \129 \255"
local MIXED_UTF8 = "caf\195\169 \226\130\172 \226\128\147 \194\129 \195\191"
local UTF8_BYTES = "caf\233 \195\169"

t.cases(T, "charset_parameter", {
  { "latin1 converts and keeps ASCII", { "text/html; charset=latin1", MIXED },
    MIXED_UTF8 },
  { "no space after the semicolon", { "text/html;charset=latin1", MIXED },
    MIXED_UTF8 },
  { "spaces around the equal sign", { "text/html; charset = latin1", MIXED },
    MIXED_UTF8 },
  { "charset after another parameter",
    { "text/html; format=x; charset=latin1", MIXED }, MIXED_UTF8 },
  { "parameter name in upper case", { "text/html; CHARSET=latin1", MIXED },
    MIXED_UTF8 },
  { "text/plain converts too", { "text/plain; charset=windows-1252", MIXED },
    MIXED_UTF8 },
  { "utf-8 passes through", { "text/html; charset=utf-8", UTF8_BYTES },
    UTF8_BYTES },
  { "other charset passes through", { "text/html; charset=koi8-r",
    UTF8_BYTES }, UTF8_BYTES },
  { "no charset passes through", { "text/html", UTF8_BYTES }, UTF8_BYTES },
}, function(input, size)
  local resp, _, ctl = open({ headers = { ["Content-Type"] = input[1] },
    body = internet.pieces(input[2], size) })
  assert(resp, "open failed")
  local text = read_all(resp)
  finish(resp, ctl)
  return text
end, { sizes = { 1, 3, 4096 } })

-- Error status (spec/fetch.md "HTTP status and content type") ------------------

local function page(head, url, title)
  return (title and ("<title>" .. title .. "</title>") or "") .. "<h1>" .. head
    .. "</h1><p>" .. url .. "</p>"
end

local NF = page("HTTP 404 Not Found", URL, "Not Found")

local function not_found(extra)
  extra.code, extra.message = 404, "Not Found"
  return extra
end

-- These rows serve a body with a 4xx or 5xx status. The game never does: a
-- 4xx or 5xx status fails in finishConnect (netprobe v1, see
-- "http_status_from_connect_failure"). The rows stay for a card that may give
-- the body, and are "not seen in game".
t.cases(T, "error_status_body", {
  { "404 renders the body", { script = { code = 404, message = "Bad",
    headers = { ["Content-Type"] = { "text/html" } },
    body = { "<h1>Oops</h1>", "", "<p>more</p>" } } },
    { status = 404, text = "<h1>Oops</h1><p>more</p>" } },
  { "500 renders the body", { script = { code = 500, message = "Bad",
    body = { "<p>x</p>" } } }, { status = 500, text = "<p>x</p>" } },
  { "302 without Location renders", { script = { code = 302,
    message = "Found", body = { "<p>moved</p>" } } },
    { status = 302, text = "<p>moved</p>" } },
  { "type and parameters follow the same rules as for 200",
    { script = not_found({ headers = { ["content-type"] =
      " TEXT/HTML ; charset=utf-8" }, body = { "<p>b</p>" } }) },
    { status = 404, text = "<p>b</p>" } },
  { "text/plain renders", { script = not_found({ headers = {
    ["Content-Type"] = "text/plain" }, body = { "b" } }) },
    { status = 404, text = "b" } },
  { "empty Content-Type renders", { script = not_found({ headers = {
    ["Content-Type"] = "" }, body = { "b" } }) },
    { status = 404, text = "b" } },
  { "empty body gives the short page", { script = not_found({ body = {} }) },
    { status = 404, text = NF } },
  { "first read fails with a reason", { script = not_found({ body = {},
    read_error = "no body" }) }, { status = 404, text = NF } },
  { "first read raises", { script = not_found({ body = {},
    read_raise = "FileNotFoundException" }) },
    { status = 404, text = NF } },
  { "read times out before the first byte", { script = not_found({
    body = { "", "", "" }, endless = true }) }, { status = 404, text = NF } },
  { "other content type gives the short page", { script = not_found({
    headers = { ["Content-Type"] = "application/json" }, body = { "{}" } }) },
    { status = 404, text = NF } },
  { "compressed body gives the short page", { script = not_found({
    headers = { ["Content-Encoding"] = "br" }, body = { "zz" } }) },
    { status = 404, text = NF } },
  { "304 is an error status", { script = { code = 304,
    message = "Not Modified", body = {} } },
    { status = 304, text = page("HTTP 304 Not Modified", URL,
      "Not Modified") } },
  { "message and URL escape & and <", { script = { code = 500,
    message = "<b>&" }, url = "http://x.com/?a=1&b=<2>" },
    { status = 500, text = page("HTTP 500 &lt;b>&amp;",
      "http://x.com/?a=1&amp;b=&lt;2>", "&lt;b>&amp;") } },
  { "empty message has no trailing space", { script = { code = 503,
    message = "" } }, { status = 503, text = page("HTTP 503", URL) } },
  { "read error after the first byte: the error comes, no part is kept",
    { script = { code = 500, message = "Error", body = { "<p>part" },
      read_error = "reset" } },
    { status = 500, text = "<p>part", why = "html: read error: reset" } },
  { "read raises after the first byte", { script = { code = 500,
    body = { "<p>part" }, read_raise = "broken" } },
    { status = 500, text = "<p>part", why = "html: read error: broken" } },
  { "read timeout after the first byte", { script = {
    code = 500, body = { "<p>part" }, endless = true } },
    { status = 500, text = "<p>part", why = "html: timed out reading "
      .. URL .. " (7 bytes received)" } },
}, function(input)
  local resp, why, ctl = open(input.script, input.url)
  t.eq(why, nil)
  assert(resp, why)
  local text, rwhy = read_all(resp)
  local out = { status = resp.status, text = text, why = rwhy }
  finish(resp, ctl)
  return out
end)


-- HTTP error status from a connect failure (spec/fetch.md "HTTP error
-- statuses"). Measured in game: for 4xx and 5xx finishConnect returns nil and
-- a reason, and response() and read() are never reached.

local R404 = internet.reason_404
local RSTATUS = internet.reason_status
local function mapped(code, phrase)
  local head = "HTTP " .. code .. (phrase ~= "" and (" " .. phrase) or "")
  return { status = code, is_error = true,
    popup = "[HTTP " .. code .. "]" .. (phrase ~= "" and (" " .. phrase) or "")
      .. "\n" .. URL,
    notice = "html: " .. head .. ": " .. URL,
    text = page(head, URL, phrase ~= "" and phrase or nil) }
end
local function conn(reason)
  return { why = "html: cannot connect: " .. URL .. ": " .. reason }
end

t.cases(T, "http_status_from_connect_failure", {
  { "404: the reason is exactly the URL", { script = { connect_error = R404(URL) } },
    mapped(404, "Not Found") },
  { "500 by the Java message", { script = { connect_error = RSTATUS(500, URL) } },
    mapped(500, "Internal Server Error") },
  { "403 by the Java message", { script = { connect_error = RSTATUS(403, URL) } },
    mapped(403, "Forbidden") },
  { "503 by the Java message", { script = { connect_error = RSTATUS(503, URL) } },
    mapped(503, "Service Unavailable") },
  { "an unknown code has no phrase",
    { script = { connect_error = RSTATUS(418, URL) } }, mapped(418, "") },
  { "the phrase table", { script = { connect_error = RSTATUS(429, URL) } },
    mapped(429, "Too Many Requests") },
  { "the status comes after slow polls",
    { script = { connect_polls = 3, connect_error = R404(URL) } },
    mapped(404, "Not Found") },
  { "response() with a code after the failure wins over the text",
    { script = { connect_error = "odd", response_early = true, code = 502 } },
    mapped(502, "Bad Gateway") },
  { "response() with a code below 400 is ignored",
    { script = { connect_error = "odd", response_early = true, code = 200 } },
    conn("odd") },
  { "a reason with the URL inside is a connection error",
    { script = { connect_error = "Not found: " .. URL } },
    conn("Not found: " .. URL) },
  { "a reason with text after the URL is a connection error",
    { script = { connect_error = URL .. "x" } }, conn(URL .. "x") },
  { "TLS failure is a connection error",
    { script = { connect_error = "(certificate_expired) PKIX path validation "
      .. "failed: timestamp check failed" } },
    conn("(certificate_expired) PKIX path validation failed: timestamp check "
      .. "failed") },
  { "Connection reset is a connection error",
    { script = { connect_error = "Connection reset" } },
    conn("Connection reset") },
  { "unknown host is a connection error",
    { script = { connect_error = "unknown host: example.com: Name or service "
      .. "not known" } },
    conn("unknown host: example.com: Name or service not known") },
  { "a code below 400 in the text is a connection error",
    { script = { connect_error = RSTATUS(200, URL) } },
    conn(RSTATUS(200, URL)) },
  { "a code above 599 in the text is a connection error",
    { script = { connect_error = RSTATUS(999, URL) } },
    conn(RSTATUS(999, URL)) },
  { "a raise with the status text maps too",
    { script = { connect_raise = RSTATUS(500, URL) } },
    mapped(500, "Internal Server Error") },
}, function(input)
  local resp, why, ctl, info = open(input.script, input.url)
  local out
  if resp then
    local text = read_all(resp)
    out = { status = resp.status, is_error = resp.is_error,
      popup = resp.popup, notice = resp.notice, text = text }
    t.eq(info.status, resp.status)
  else
    out = { why = why }
  end
  finish(resp, ctl)
  return out
end)

-- A 404 after a redirect that the program follows itself names the target.
function T.http_status_after_a_followed_redirect()
  local next_url = "http://example.com/next"
  local resp, _, ctl, info = open(nil, URL, { routes = {
    [URL] = { code = 302, headers = { Location = { "/next" } } },
    [next_url] = { connect_error = R404(next_url) } } })
  t.eq(resp.status, 404)
  t.eq(resp.final_url, next_url)
  t.eq(info.redirects, 1)
  t.eq(resp.notice, "html: HTTP 404 Not Found: " .. next_url)
  finish(resp, ctl)
end

-- The card follows a redirect of the same scheme itself and gives no final
-- URL (measured). The response is the last one: no redirect for the program.
function T.card_followed_redirect_looks_like_a_plain_page()
  local resp, _, ctl, info = open({ body = { "x" } })
  t.eq(resp.status, 200)
  t.eq(info.redirects, 0)
  t.eq(resp.redirects, 0)
  t.eq(resp.final_url, URL)
  finish(resp, ctl)
end

-- A scheme change comes back as a 302 with an absolute Location and an empty
-- body (measured). The program follows it.
function T.scheme_change_redirect_is_followed()
  local https = "https://example.com/"
  local resp, _, ctl, info = open(nil, URL, { routes = {
    [URL] = { code = 302, headers = { Location = { https } }, body = {} },
    [https] = { body = { "s" } } } })
  t.eq(resp.final_url, https)
  t.eq(info.redirects, 1)
  t.eq(read_all(resp), "s")
  finish(resp, ctl)
end

-- The card allows 4 open connections (measured). The 5th request gets a
-- reason, and close() frees a slot.
function T.fifth_connection_is_refused()
  local card, ctl = internet.new({ default = { body = { "x" } } })
  local handles = {}
  for i = 1, 4 do
    local h = card.request(URL .. i)
    t.ok(h, "connection " .. i)
    handles[i] = h
  end
  local h, why = card.request(URL .. 5)
  t.eq(h, nil)
  t.eq(why, "too many open connections")
  handles[1].close()
  handles[1].close()
  t.ok(card.request(URL .. 6), "a slot is free after close")
  -- The program reports the 5th request in its own words.
  local card2, ctl2 = internet.new({ default = { body = { "x" } } })
  for i = 1, 4 do
    card2.request(URL .. i)
  end
  local resp, rwhy = fetch.open(URL, links(card2), {})
  t.eq(resp, nil)
  t.eq(rwhy, "html: cannot fetch " .. URL .. ": too many open connections")
  t.eq(ctl2.open, 4)
  t.eq(ctl.max_open, 4)
end

-- The fake card copies the measured API: callable tables, and response() is
-- nil until finishConnect has returned true.
function T.fake_card_methods_are_callable_tables()
  local card = internet.new({ default = { body = { "x" } } })
  t.eq(type(card.request), "table")
  t.eq(type(card.isHttpEnabled), "table")
  local h = card.request(URL)
  for _, m in ipairs({ "finishConnect", "response", "read", "close" }) do
    t.eq(type(h[m]), "table", m)
  end
  t.eq(h.response(), nil)
  t.eq(h.finishConnect(), true)
  t.eq(h.response(), 200)
  local early = internet.new({ default = { response_early = true } }).request(URL)
  t.eq(early.response(), 200)
end

-- spec/loading.md "Status line during load": fetch.open reports its phases to
-- an optional progress callback. "connect" and "redirect" come with the parsed
-- URL, "response" when the connection is up, and "wait" before each sleep.

local progress_rows = {
  { "connect and response", { script = { body = { "x" } } },
    { "connect " .. URL, "response" } },
  { "slow connect: a wait for each poll",
    { script = { connect_polls = 2, body = { "x" } } },
    { "connect " .. URL, "wait", "wait", "response" } },
  { "slow response: the wait comes after the response phase",
    { script = { response_polls = 2, body = { "x" } } },
    { "connect " .. URL, "response", "wait", "wait" } },
  { "redirect: the target comes with the redirect phase",
    { routes = { [URL] = { code = 302, headers = { Location = { "/b" } } },
      ["http://example.com/b"] = { body = { "x" } } } },
    { "connect " .. URL, "response", "redirect http://example.com/b",
      "response" } },
  { "a gap in the body is a wait",
    { script = { body = { "a", "", "b" } }, read = true },
    { "connect " .. URL, "response", "wait" } },
  { "an error before the body still reports the phases",
    { script = { connect_error = "refused" } }, { "connect " .. URL } },
}

t.cases(T, "progress_phases", progress_rows, function(input)
  local card, ctl = internet.new({ default = input.script,
    routes = input.routes })
  local seen = {}
  local l = links(card)
  l.progress = function(phase, u)
    seen[#seen + 1] = phase .. (u and (" " .. u.url) or "")
  end
  local resp = fetch.open(URL, l, {})
  if resp and input.read then
    read_all(resp)
  end
  finish(resp, ctl)
  return seen
end)

return T
