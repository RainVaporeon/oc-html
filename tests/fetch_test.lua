-- Tests for lib/html/fetch.lua: URL parsing, the host rule for arguments
-- without a scheme, the request flow with the fake card, redirects, status
-- and content-type rules, charset conversion, timeouts and Ctrl+C.

local t = require("test")
local fetch = require("html.fetch")
local internet = require("internet")

local T = {}

-- URL parsing ---------------------------------------------------------------

function T.parse_url_parts()
  local u = fetch.parse_url("http://example.com:8080/a/b?x=1#top")
  t.eq(u.scheme, "http")
  t.eq(u.host, "example.com")
  t.eq(u.port, 8080)
  t.eq(u.path, "/a/b?x=1")
  t.eq(u.url, "http://example.com:8080/a/b?x=1")
  t.eq(u.origin, "http://example.com:8080")
end

function T.parse_url_defaults()
  local u = fetch.parse_url("https://example.com")
  t.eq(u.scheme, "https")
  t.eq(u.port, 443)
  t.eq(u.path, "/")
  t.eq(u.url, "https://example.com")
  t.eq(fetch.parse_url("http://example.com?q").path, "?q")
  t.eq(fetch.parse_url("http://example.com").port, 80)
end

function T.parse_url_scheme_is_not_case_sensitive()
  local u = fetch.parse_url("HTTP://Example.com/")
  t.eq(u.scheme, "http")
  t.eq(u.url, "HTTP://Example.com/")
  t.eq(fetch.parse_url("hTtPs://x.org").scheme, "https")
end

function T.parse_url_other_scheme()
  t.eq(select(2, fetch.parse_url("ftp://example.com")),
    "html: unsupported URL scheme: ftp")
  t.eq(select(2, fetch.parse_url("FILE://x")),
    "html: unsupported URL scheme: file")
  t.eq(select(2, fetch.parse_url("svn+ssh://x")),
    "html: unsupported URL scheme: svn+ssh")
end

function T.parse_url_scheme_detection()
  t.eq(fetch.scheme("http://x"), "http")
  t.eq(fetch.scheme("a.b-c+d://x"), "a.b-c+d")
  t.eq(fetch.scheme("1ftp://x"), nil)
  t.eq(fetch.scheme("example.com"), nil)
  t.eq(fetch.scheme("dir/http://x"), nil)
  t.eq(fetch.scheme("http:/x"), nil)
end

function T.parse_url_invalid()
  for _, s in ipairs({ "http://", "http:///path", "http://:80/",
      "http://exa mple.com", "http://example.com/a b", "http://x.com/\1",
      "http://x.com/\127", "http://x.com/\195\169", "http://#frag" }) do
    local u, why = fetch.parse_url(s)
    t.eq(u, nil, s)
    t.eq(why, "html: invalid URL: " .. s, s)
  end
end

function T.parse_url_length_limit()
  local base = "http://example.com/"
  local ok = base .. string.rep("a", 2048 - #base)
  t.ok(fetch.parse_url(ok), "2048 bytes")
  local u, why = fetch.parse_url(ok .. "a")
  t.eq(u, nil)
  t.eq(why, "html: invalid URL: too long")
end

function T.parse_url_leaves_port_checks_to_the_card()
  local u = fetch.parse_url("http://example.com:abc/")
  t.eq(u.host, "example.com")
  t.eq(u.port, nil)
  t.eq(u.url, "http://example.com:abc/")
end

-- Arguments without a scheme -----------------------------------------------

function T.looks_like_host_yes()
  for _, s in ipairs({ "example.com", "EXAMPLE.COM", "example.com/path",
      "example.com/", "example.com:8080/a?b=1", "example.com#top",
      "localhost", "LocalHost", "localhost:8080", "192.168.0.1",
      "a-b.c0.org", "x.y:65535", "x.y:1", "example.com?q=a.html" }) do
    t.eq(fetch.looks_like_host(s), true, s)
  end
end

function T.looks_like_host_no()
  for _, s in ipairs({ "", "./x.html", "x.html", "X.HTM", "a.xhtml",
      "notes.txt", "prog.lua", "dir/x.html", "dir/example.com", "foo",
      "foo:8080", "example..com", ".example.com", "example.com.",
      "a.-b.com", "a.b-.com", "example.com:", "example.com:0",
      "example.com:99999", "example.com:123456", "example.com:8a",
      "exa mple.com", "ex\195\164mple.com", "~/example.com", "~",
      "/example.com", "a_b.com", "x." .. string.rep("a", 64),
      "example.com\t", "a.b:c:80" }) do
    t.eq(fetch.looks_like_host(s), false, s)
  end
  t.eq(fetch.looks_like_host("x." .. string.rep("a", 63)), true, "63 bytes")
end

-- Request flow -------------------------------------------------------------

local computer = require("computer")

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

-- Every handle was closed exactly once.
local function all_closed(ctl)
  for i, h in ipairs(ctl.handles) do
    t.eq(h.closed, 1, "handle " .. i .. " closes")
  end
  t.eq(ctl.open, 0, "no open connection")
end

function T.open_reads_the_body_and_sends_the_headers()
  local resp, why, ctl = open({ connect_polls = 3, response_polls = 2,
    headers = { ["Content-Type"] = { "text/html; charset=utf-8" },
      ["Content-Length"] = { tostring(#PAGE) } },
    body = internet.pieces(PAGE, 5, true) })
  t.eq(why, nil)
  t.eq(resp.status, 200)
  t.eq(resp.message, "OK")
  t.eq(resp.is_error, false)
  t.eq(resp.length, #PAGE)
  t.eq(resp.final_url, URL)
  t.eq(resp.content_type, "text/html; charset=utf-8")
  t.eq(read_all(resp), PAGE)
  t.eq(resp.bytes, #PAGE)
  t.eq(resp.read(), nil, "read after the end")
  t.eq(ctl.requests, { URL })
  t.eq(ctl.data, nil)
  t.eq(ctl.headers, { ["User-Agent"] = "oc-html/" .. fetch.VERSION,
    ["Accept-Encoding"] = "identity" })
  resp.close()
  resp.close()
  all_closed(ctl)
end

function T.open_reads_large_pieces_in_4096_byte_chunks()
  local text = string.rep("abcdefgh", 2000)
  local resp, _, ctl = open({ body = { text } })
  t.eq(read_all(resp), text)
  resp.close()
  all_closed(ctl)
end

function T.header_names_are_not_case_sensitive()
  local resp = open({ headers = { ["content-length"] = "12",
    ["CONTENT-TYPE"] = "text/plain" } })
  t.eq(resp.length, 12)
  t.eq(resp.content_type, "text/plain")
end

function T.fragment_is_not_sent()
  local resp, _, ctl = open({ body = { "x" } }, "http://example.com/a#top")
  t.eq(ctl.requests, { "http://example.com/a" })
  t.eq(resp.final_url, "http://example.com/a")
end

function T.open_with_a_bad_url()
  local resp, why, ctl = open({}, "ftp://x.org")
  t.eq(resp, nil)
  t.eq(why, "html: unsupported URL scheme: ftp")
  t.eq(#ctl.requests, 0)
end

function T.no_card()
  local resp, why = fetch.open(URL, links(nil), {})
  t.eq(resp, nil)
  t.eq(why, "html: no internet card found (needed for " .. URL .. ")")
end

function T.http_disabled()
  local resp, why, ctl = open({}, URL, { http = false })
  t.eq(resp, nil)
  t.eq(why, "html: HTTP requests are disabled on this server")
  t.eq(#ctl.requests, 0)
end

function T.request_fails()
  local _, why, ctl = open({ request_error = "address is not allowed" })
  t.eq(why, "html: cannot fetch " .. URL .. ": address is not allowed")
  t.eq(#ctl.handles, 0)
  _, why = open({ request_raise = "bad address\nmore" })
  t.eq(why, "html: cannot fetch " .. URL .. ": bad address")
  _, why = open({ request_raise = { 1 } })
  t.ok(why:find("^html: cannot fetch " .. URL .. ": table"), why)
end

function T.connection_limit()
  local _, why, ctl = open({}, URL, { limit = 0 })
  t.eq(why, "html: cannot fetch " .. URL .. ": too many open connections")
  t.eq(ctl.open, 0)
end

function T.connect_fails()
  local _, why, ctl = open({ connect_polls = 2, connect_error = "unknown host" })
  t.eq(why, "html: cannot connect: " .. URL .. ": unknown host")
  all_closed(ctl)
  _, why, ctl = open({ connect_raise = "refused" })
  t.eq(why, "html: cannot connect: " .. URL .. ": refused")
  all_closed(ctl)
end

function T.connect_timeout()
  local _, why, ctl = open({ connect_polls = 1000000 })
  t.eq(why, "html: timed out connecting to " .. URL)
  all_closed(ctl)
  local now = computer.uptime()
  t.ok(now >= 15 and now < 16, "gave up after 15 s: " .. now)
end

function T.response_timeout()
  local _, why, ctl = open({ connect_polls = 100, response_polls = 1000000 })
  t.eq(why, "html: timed out connecting to " .. URL)
  all_closed(ctl)
  local now = computer.uptime()
  t.ok(now >= 15 and now < 16, "one budget for connect and response: "
    .. now)
end

function T.slow_connect_inside_the_timeout()
  -- 250 polls of 0.05 s is 12.5 s.
  local resp, why, ctl = open({ connect_polls = 150, response_polls = 100,
    body = { "x" } })
  t.eq(why, nil)
  t.eq(read_all(resp), "x")
  resp.close()
  all_closed(ctl)
end

function T.read_timeout_restarts_with_each_chunk()
  local body = {}
  for i = 1, 3 do
    body[#body + 1] = "abc"
    for _ = 1, 500 do
      body[#body + 1] = ""
    end
  end
  local resp, _, ctl = open({ body = body, endless = true })
  local text, why = read_all(resp)
  t.eq(text, "abcabcabc")
  t.eq(why, "html: timed out reading " .. URL .. " (9 bytes received)")
  resp.close()
  all_closed(ctl)
end

function T.read_errors()
  local resp, _, ctl = open({ body = { "abc" }, read_error = "reset" })
  local text, why = read_all(resp)
  t.eq(text, "abc")
  t.eq(why, "html: read error: reset")
  resp.close()
  all_closed(ctl)
  resp = open({ body = { "abc" }, read_raise = "broken\npipe" })
  text, why = read_all(resp)
  t.eq(why, "html: read error: broken")
end

function T.interrupt_during_connect()
  local flag = { on = true }
  local _, why, ctl = open({ connect_polls = 10 }, URL, { flag = flag })
  t.eq(why, "html: interrupted")
  all_closed(ctl)
  _, why, ctl = open({ response_polls = 10 }, URL, { flag = flag })
  t.eq(why, "html: interrupted")
  all_closed(ctl)
end

function T.interrupt_during_read()
  local flag = { on = false }
  local resp, _, ctl = open({ body = { "abc", "", "def" } }, URL,
    { flag = flag })
  t.eq(resp.read(), "abc")
  flag.on = true
  t.eq(select(2, resp.read()), "html: interrupted")
  resp.close()
  all_closed(ctl)
end

function T.raised_sleep_closes_the_handle()
  local card, ctl = internet.new({ default = { connect_polls = 5 } })
  local l = links(card)
  l.sleep = function() error("interrupted", 0) end
  local ok, err = pcall(fetch.open, URL, l, {})
  t.eq(ok, false)
  t.eq(err, "interrupted")
  all_closed(ctl)
end

-- Redirects -----------------------------------------------------------------

local function redirect(code, location)
  return { code = code, message = "Moved", headers = location
    and { Location = { location } } or {} }
end

function T.redirect_absolute_and_path()
  local routes = {
    ["http://a.com/"] = redirect(301, "https://b.com:8443/x?y#frag"),
    ["https://b.com:8443/x?y"] = redirect(302, "/z"),
    ["https://b.com:8443/z"] = { body = { "done" } },
  }
  local resp, why, ctl, info = open({}, "http://a.com/", { routes = routes })
  t.eq(why, nil)
  t.eq(ctl.requests, { "http://a.com/", "https://b.com:8443/x?y",
    "https://b.com:8443/z" })
  t.eq(resp.final_url, "https://b.com:8443/z")
  t.eq(resp.redirects, 2)
  t.eq(info.redirects, 2)
  t.eq(read_all(resp), "done")
  resp.close()
  all_closed(ctl)
end

function T.redirect_codes()
  for _, code in ipairs({ 301, 302, 303, 307, 308 }) do
    local resp = open({}, "http://a.com/", { routes = {
      ["http://a.com/"] = redirect(code, "http://b.com/"),
      ["http://b.com/"] = { body = { "b" } } } })
    t.eq(resp.final_url, "http://b.com/", "code " .. code)
  end
end

function T.redirect_chain_of_five_and_the_sixth()
  local routes = {}
  for i = 0, 5 do
    routes["http://h.com/" .. i] = redirect(302, "/" .. (i + 1))
  end
  routes["http://h.com/5"] = { body = { "end" } }
  local resp, why, ctl, info = open({}, "http://h.com/0", { routes = routes })
  t.eq(why, nil)
  t.eq(info.redirects, 5)
  t.eq(read_all(resp), "end")
  resp.close()
  all_closed(ctl)
  routes["http://h.com/5"] = redirect(302, "/6")
  resp, why, ctl = open({}, "http://h.com/0", { routes = routes })
  t.eq(resp, nil)
  t.eq(why, "html: too many redirects: http://h.com/0")
  t.eq(#ctl.requests, 6)
  all_closed(ctl)
end

function T.redirect_to_other_scheme_or_form()
  local cases = {
    { "ftp://x.com/f", "html: unsupported URL scheme: ftp" },
    { "x.html", "html: cannot follow redirect: x.html" },
    { "../up", "html: cannot follow redirect: ../up" },
    { "//other.com/p", "html: cannot follow redirect: //other.com/p" },
    { "http://bad host/", "html: cannot follow redirect: http://bad host/" },
    { "/a b", "html: cannot follow redirect: /a b" },
  }
  for _, c in ipairs(cases) do
    local resp, why, ctl = open(redirect(302, c[1]))
    t.eq(resp, nil, c[1])
    t.eq(why, c[2], c[1])
    all_closed(ctl)
  end
end

function T.redirect_without_location_is_an_error_status()
  local resp, why, ctl = open({ code = 302, message = "Found",
    body = { "<p>moved</p>" } })
  t.eq(why, nil)
  t.eq(resp.is_error, true)
  t.eq(resp.status, 302)
  t.eq(read_all(resp), "<p>moved</p>")
  t.eq(#ctl.requests, 1)
end

-- Content type, encoding and charset -----------------------------------------

function T.accepted_content_types()
  for _, ct in ipairs({ "text/html", "TEXT/HTML; charset=UTF-8",
      "application/xhtml+xml", "text/plain", " text/html ;q", "" }) do
    local resp, why = open({ headers = { ["Content-Type"] = ct },
      body = { "x" } })
    t.eq(why, nil, ct)
    t.eq(read_all(resp), "x", ct)
  end
  local resp = open({ body = { "x" } })
  t.eq(read_all(resp), "x", "no type")
end

function T.other_content_type_stops()
  local resp, why, ctl = open({ headers = { ["Content-Type"] =
    "image/png" }, body = { "\137PNG" } })
  t.eq(resp, nil)
  t.eq(why, "html: not an HTML page: image/png")
  t.eq(ctl.handles[1].reads, 0)
  all_closed(ctl)
end

function T.compressed_response_stops()
  local resp, why, ctl = open({ headers = { ["Content-Encoding"] = "gzip" },
    body = { "x" } })
  t.eq(resp, nil)
  t.eq(why, "html: compressed response not supported: gzip")
  all_closed(ctl)
  resp, why = open({ headers = { ["Content-Encoding"] = "Identity" },
    body = { "x" } })
  t.eq(why, nil)
end

function T.latin1_and_windows_1252_convert()
  local bytes = "caf\233 \128 \150 \129 \255"
  local want = "caf\195\169 \226\130\172 \226\128\147 \194\129 \195\191"
  for _, cs in ipairs({ "iso-8859-1", "ISO-8859-1", "latin1",
      "windows-1252", "\"windows-1252\"" }) do
    local resp = open({ headers = { ["Content-Type"] =
      "text/html; charset=" .. cs }, body = internet.pieces(bytes, 3) })
    t.eq(read_all(resp), want, cs)
    t.eq(resp.bytes, #bytes, "bytes received count the input")
  end
end

function T.other_charsets_pass_through()
  local bytes = "caf\233 \195\169"
  for _, ct in ipairs({ "text/html; charset=utf-8", "text/html; charset=koi8-r",
      "text/html" }) do
    local resp = open({ headers = { ["Content-Type"] = ct }, body = { bytes } })
    t.eq(read_all(resp), bytes, ct)
  end
end

function T.latin_conversion_function()
  t.eq(fetch.latin_to_utf8("plain"), "plain")
  local all = {}
  for b = 0x80, 0xFF do
    all[#all + 1] = string.char(b)
  end
  local out = fetch.latin_to_utf8(table.concat(all))
  t.ok(utf8.len(out), "valid UTF-8")
  t.eq(utf8.len(out), 128)
end

-- Error status ------------------------------------------------------------

local function short_page(code, message, url)
  local head = "HTTP " .. code .. (message ~= "" and (" " .. message) or "")
  return "<title>" .. head .. "</title><h1>" .. head .. "</h1><p>" .. url
    .. "</p>"
end

function T.error_status_renders_the_body()
  for _, code in ipairs({ 404, 500 }) do
    local resp, why, ctl = open({ code = code, message = "Bad",
      headers = { ["Content-Type"] = { "text/html" } },
      body = { "<h1>Oops</h1>", "", "<p>more</p>" } })
    t.eq(why, nil)
    t.eq(resp.is_error, true)
    t.eq(resp.status, code)
    t.eq(resp.message, "Bad")
    t.eq(read_all(resp), "<h1>Oops</h1><p>more</p>")
    t.eq(resp.read_error, nil)
    resp.close()
    all_closed(ctl)
  end
end

function T.error_status_short_page_cases()
  local cases = {
    { body = {} },
    { body = {}, read_error = "no body" },
    { body = {}, read_raise = "FileNotFoundException" },
    { body = { "", "", "" }, endless = true },
    { headers = { ["Content-Type"] = "application/json" },
      body = { "{}" } },
    { headers = { ["Content-Encoding"] = "br" }, body = { "zz" } },
  }
  for i, c in ipairs(cases) do
    c.code, c.message = 404, "Not Found"
    local resp, why, ctl = open(c)
    t.eq(why, nil, "case " .. i)
    t.eq(resp.is_error, true)
    t.eq(read_all(resp), short_page(404, "Not Found", URL), "case " .. i)
    t.eq(resp.read_error, nil, "case " .. i)
    t.eq(resp.bytes, 0, "case " .. i)
    resp.close()
    all_closed(ctl)
  end
end

function T.short_page_escapes_and_empty_message()
  local resp = open({ code = 500, message = "<b>&" },
    "http://x.com/?a=1&b=<2>")
  t.eq(read_all(resp), short_page(500, "&lt;b>&amp;",
    "http://x.com/?a=1&amp;b=&lt;2>"))
  resp = open({ code = 503, message = "" })
  t.eq(read_all(resp), short_page(503, "", URL))
  resp = open({ code = 503 })
  t.ok(resp.message ~= nil)
end

function T.error_status_read_error_after_the_first_byte()
  local resp, _, ctl = open({ code = 500, message = "Error",
    body = { "<p>part" }, read_error = "reset" })
  t.eq(read_all(resp), "<p>part")
  t.eq(resp.read_error, "html: read error: reset")
  resp.close()
  all_closed(ctl)
  resp = open({ code = 500, body = { "<p>part" }, endless = true })
  t.eq(read_all(resp), "<p>part")
  t.eq(resp.read_error, "html: timed out reading " .. URL
    .. " (7 bytes received)")
end

function T.error_status_interrupt_passes_through()
  local flag = { on = true }
  local resp = open({ code = 404, body = { "", "x" } }, URL, { flag = flag })
  t.eq(select(2, resp.read()), "html: interrupted")
end

function T.fetch_time_runs_to_the_end_of_the_body()
  local body = { "a" }
  for _ = 1, 20 do
    body[#body + 1] = ""
  end
  local resp = open({ connect_polls = 10, body = body })
  read_all(resp)
  local done = resp.fetch_time()
  t.ok(done >= 1.5 and done < 1.6, "fetch time " .. done)
  computer.test.advance(5)
  t.eq(resp.fetch_time(), done, "the clock stops at the end")
end

return T
