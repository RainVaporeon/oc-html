-- Tests for M.ref_scheme and M.resolve in lib/html/url.lua. The rules are in
-- spec/url.md "Link resolution" and spec/navigation.md "Targets".

local t = require("test")
local url = require("html.url")

local T = {}

local BASE = "http://a/b/c/d;p?q"

local function http(u, fragment)
  return { kind = "http", url = u, fragment = fragment }
end

local function same(fragment)
  return { kind = "same", fragment = fragment }
end

local function file(path, fragment)
  return { kind = "file", path = path, fragment = fragment }
end

local function unsupported(scheme)
  return { kind = "unsupported", scheme = scheme }
end

local function err(message)
  return { err = message }
end

-- A failure becomes { err = message }, so a row can hold it.
local function run(input)
  local r, why = url.resolve(input[1], input[2])
  if r == nil then
    return err(why)
  end
  return r
end

-- A row for a remote base (BASE unless given).
local function row(name, ref, expected, base)
  return { name, { base or BASE, ref }, expected }
end

t.cases(T, "ref_scheme", {
  { "http", "http://x", "http" },
  { "upper case", "HTTPS://x", "https" },
  { "mailto", "mailto:a@b", "mailto" },
  { "with + . -", "a+b.c-d:x", "a+b.c-d" },
  { "digit first", "1a:x", nil },
  { "no colon", "abc", nil },
  { "path with colon later", "a/b:c", nil },
  { "empty", "", nil },
  { "colon first", ":x", nil },
  { "not a string", 5, nil },
}, function(s) return url.ref_scheme(s) end)

-- RFC 3986 section 5.4.1
t.cases(T, "resolve_rfc_normal", {
  row("g:h", "g:h", unsupported("g")),
  row("g", "g", http("http://a/b/c/g")),
  row("./g", "./g", http("http://a/b/c/g")),
  row("g/", "g/", http("http://a/b/c/g/")),
  row("/g", "/g", http("http://a/g")),
  row("//g", "//g", http("http://g")),
  row("?y", "?y", http("http://a/b/c/d;p?y")),
  row("g?y", "g?y", http("http://a/b/c/g?y")),
  row("#s", "#s", same("s")),
  row("g#s", "g#s", http("http://a/b/c/g", "s")),
  row("g?y#s", "g?y#s", http("http://a/b/c/g?y", "s")),
  row(";x", ";x", http("http://a/b/c/;x")),
  row("g;x", "g;x", http("http://a/b/c/g;x")),
  row("g;x?y#s", "g;x?y#s", http("http://a/b/c/g;x?y", "s")),
  row("empty", "", same(nil)),
  row(".", ".", http("http://a/b/c/")),
  row("./", "./", http("http://a/b/c/")),
  row("..", "..", http("http://a/b/")),
  row("../", "../", http("http://a/b/")),
  row("../g", "../g", http("http://a/b/g")),
  row("../..", "../..", http("http://a/")),
  row("../../", "../../", http("http://a/")),
  row("../../g", "../../g", http("http://a/g")),
}, run)

-- RFC 3986 section 5.4.2
t.cases(T, "resolve_rfc_abnormal", {
  row("../../../g", "../../../g", http("http://a/g")),
  row("../../../../g", "../../../../g", http("http://a/g")),
  row("/./g", "/./g", http("http://a/g")),
  row("/../g", "/../g", http("http://a/g")),
  row("g.", "g.", http("http://a/b/c/g.")),
  row(".g", ".g", http("http://a/b/c/.g")),
  row("g..", "g..", http("http://a/b/c/g..")),
  row("..g", "..g", http("http://a/b/c/..g")),
  row("./../g", "./../g", http("http://a/b/g")),
  row("./g/.", "./g/.", http("http://a/b/c/g/")),
  row("g/./h", "g/./h", http("http://a/b/c/g/h")),
  row("g/../h", "g/../h", http("http://a/b/c/h")),
  row("g;x=1/./y", "g;x=1/./y", http("http://a/b/c/g;x=1/y")),
  row("g;x=1/../y", "g;x=1/../y", http("http://a/b/c/y")),
  row("g?y/./x", "g?y/./x", http("http://a/b/c/g?y/./x")),
  row("g?y/../x", "g?y/../x", http("http://a/b/c/g?y/../x")),
  row("g#s/./x", "g#s/./x", http("http://a/b/c/g", "s/./x")),
  row("g#s/../x", "g#s/../x", http("http://a/b/c/g", "s/../x")),
  row("http:g has no //", "http:g", err("html: invalid URL: http:g")),
}, run)

t.cases(T, "resolve_remote", {
  row("absolute http", "http://x.org/p/../q?z#f",
    http("http://x.org/q?z", "f")),
  row("absolute https", "https://x.org", http("https://x.org")),
  row("scheme in upper case", "HTTP://x.org/a", http("HTTP://x.org/a")),
  row("absolute with port", "http://x.org:8080/a/./b",
    http("http://x.org:8080/a/b")),
  row("absolute, dots in the query stay", "http://x.org/a?b=/../c",
    http("http://x.org/a?b=/../c")),
  row("absolute, empty host", "http:///a", err("html: invalid URL: http:///a")),
  row("// keeps the scheme", "//h.org/x", http("http://h.org/x"),
    "http://a/b"),
  row("// keeps https", "//h.org/x?q#f", http("https://h.org/x?q", "f"),
    "https://a/b"),
  row("// with dots", "//h.org/a/../b", http("http://h.org/b")),
  row("query only keeps the path", "?x=1", http("http://a/b/c/d;p?x=1")),
  row("fragment only is the same document", "#top", same("top")),
  row("empty fragment", "#", same("")),
  row("empty ref", "", same(nil)),
  row("white space trim", "  \t g \n", http("http://a/b/c/g")),
  row("white space only", " \n ", same(nil)),
  row("trim before the scheme", " mailto:x ", unsupported("mailto")),
  row("space in the path", "my file.html",
    http("http://a/b/c/my%20file.html")),
  row("space in the query", "g?a b", http("http://a/b/c/g?a%20b")),
  row("space in the fragment", "g#a b", http("http://a/b/c/g", "a%20b")),
  row("space in an absolute URL", "http://x.org/a b",
    http("http://x.org/a%20b")),
  row("UTF-8 bytes", "caf\195\169", http("http://a/b/c/caf%C3%A9")),
  row("control bytes and DEL", "a\1\127b", http("http://a/b/c/a%01%7Fb")),
  row("existing %20 stays", "a%20b", http("http://a/b/c/a%20b")),
  row("base without a path", "g", http("http://a/g"), "http://a"),
  row("base with a query and no path", "g", http("http://a/g"),
    "http://a?x=1"),
  row("base with a port", "g", http("http://a:81/b/g"), "http://a:81/b/c"),
  row("bad base", "g", err("html: unsupported URL scheme: ftp"),
    "ftp://x/y"),
}, run)

-- A reference that fills the URL to the limit (spec/url.md "URL parsing").
local ROOT = "http://example.com/"
t.cases(T, "resolve_limit", {
  { "2048 bytes", { ROOT, string.rep("a", 2048 - #ROOT) },
    http(ROOT .. string.rep("a", 2048 - #ROOT)) },
  { "2049 bytes", { ROOT, string.rep("a", 2049 - #ROOT) },
    err("html: invalid URL: too long") },
  { "absolute URL of 2049 bytes",
    { ROOT, ROOT .. string.rep("a", 2049 - #ROOT) },
    err("html: invalid URL: too long") },
  { "encoding counts", { ROOT, "a" .. string.rep(" ", 683) .. "b" },
    err("html: invalid URL: too long") },
}, run)

t.cases(T, "resolve_unsupported", {
  row("javascript", "javascript:void(0)", unsupported("javascript")),
  row("mailto", "mailto:a@b.c", unsupported("mailto")),
  row("data", "data:text/html,x", unsupported("data")),
  row("ftp", "ftp://x.org/f", unsupported("ftp")),
  row("tel", "tel:+123", unsupported("tel")),
  row("scheme in upper case", "JavaScript:x", unsupported("javascript")),
  row("from a local page", "mailto:a@b", unsupported("mailto"),
    "/home/p.html"),
  row("file from a remote page", "file:///etc/x",
    err("html: unsupported URL scheme: file")),
  row("FILE from a remote page", "FILE:///etc/x",
    err("html: unsupported URL scheme: file")),
}, run)

local LOCAL = "/home/user/docs/a.html"

local function lrow(name, ref, expected)
  return { name, { LOCAL, ref }, expected }
end

t.cases(T, "resolve_local", {
  lrow("x.html", "x.html", file("/home/user/docs/x.html")),
  lrow("./x.html", "./x.html", file("/home/user/docs/x.html")),
  lrow("../x.html", "../x.html", file("/home/user/x.html")),
  lrow("above the root", "../../../../../x.html", file("/x.html")),
  lrow("sub directory", "s/x.html", file("/home/user/docs/s/x.html")),
  lrow("/abs", "/abs/x.html", file("/abs/x.html")),
  lrow("/abs with dots", "/abs/../x.html", file("/x.html")),
  lrow("%20", "my%20file.html", file("/home/user/docs/my file.html")),
  lrow("%XX of a UTF-8 name", "caf%C3%A9",
    file("/home/user/docs/caf\195\169")),
  lrow("bad %XX stays", "a%zz", file("/home/user/docs/a%zz")),
  lrow("?q is dropped", "x.html?q=1", file("/home/user/docs/x.html")),
  lrow("?q#f", "x.html?q#f", file("/home/user/docs/x.html", "f")),
  lrow("fragment is kept", "x.html#top",
    file("/home/user/docs/x.html", "top")),
  lrow("fragment is not decoded", "x.html#a%20b",
    file("/home/user/docs/x.html", "a%20b")),
  lrow("only ?q is the page itself", "?q", file(LOCAL)),
  lrow("?q#f is the page itself", "?q#f", file(LOCAL, "f")),
  lrow("#f is the same document", "#f", same("f")),
  lrow("# is the same document", "#", same("")),
  lrow("empty ref", "", same(nil)),
  lrow("white space trim", " x.html \n", file("/home/user/docs/x.html")),
  lrow("directory link", "sub/", file("/home/user/docs/sub/")),
  lrow("file:///p", "file:///tmp/x.html", file("/tmp/x.html")),
  lrow("file:///p with %20, ?q and #f", "file:///tmp/a%20b.html?q#f",
    file("/tmp/a b.html", "f")),
  lrow("FILE:///p", "FILE:///tmp/x", file("/tmp/x")),
  lrow("file://host/p", "file://host/p",
    err("html: invalid URL: file://host/p")),
  lrow("file:/p", "file:/p", err("html: invalid URL: file:/p")),
  lrow("absolute http", "http://x.org/a/../b#f",
    http("http://x.org/b", "f")),
  lrow("// is an absolute path", "//x", file("//x")),
}, run)

return T
