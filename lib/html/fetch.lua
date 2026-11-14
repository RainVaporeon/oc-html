-- Fetches a page with the internet card and streams its body. The card
-- proxy, the clock, the sleep function and the interrupt check come from the
-- caller (links), so this module never loads component.

local M = {}

local byte, find, lower, sub = string.byte, string.find, string.lower,
  string.sub

local MAX_URL = 2048
local MAX_LABEL = 63

-- Arguments with one of these last labels stay local files (decision D5).
local FILE_LABELS = { html = true, htm = true, xhtml = true, txt = true,
  lua = true }

-- Returns the scheme of s in lower case when s starts with
-- "<letter>[letters, digits, + . -]://", or nil.
function M.scheme(s)
  local scheme = type(s) == "string" and s:match("^(%a[%w+.-]*)://")
  return scheme and lower(scheme) or nil
end

-- True when s has a space, a control byte or a byte above 0x7E.
local function has_bad_byte(s)
  return find(s, "[%z\1-\32\127-\255]") ~= nil
end

-- Parses an http or https URL. Returns a table (scheme, host, port, path,
-- url without the fragment, origin) or nil and a controlled message.
function M.parse_url(s)
  if #s > MAX_URL then
    return nil, "html: invalid URL: too long"
  end
  local scheme = M.scheme(s)
  if scheme and scheme ~= "http" and scheme ~= "https" then
    return nil, "html: unsupported URL scheme: " .. scheme
  end
  local invalid = "html: invalid URL: " .. s
  if not scheme or has_bad_byte(s) then
    return nil, invalid
  end
  local url = s
  local hash = find(s, "#", 1, true)
  if hash then
    url = sub(s, 1, hash - 1)
  end
  local start = #scheme + 4
  local stop = find(url, "[/?]", start) or #url + 1
  local hostport = sub(url, start, stop - 1)
  local host, port_text = hostport:match("^([^:]*):(.*)$")
  if not host then
    host = hostport
  end
  if host == "" then
    return nil, invalid
  end
  local port
  if port_text then
    port = math.tointeger(tonumber(port_text:match("^%d+$") or ""))
  else
    port = scheme == "https" and 443 or 80
  end
  local path = sub(url, stop)
  if path == "" then
    path = "/"
  end
  return { scheme = scheme, host = host, port = port, path = path, url = url,
    origin = sub(url, 1, stop - 1) }
end

-- True when a label is 1 to 63 bytes of letters, digits and "-", and does
-- not start or end with "-".
local function good_label(label)
  return #label >= 1 and #label <= MAX_LABEL
    and not find(label, "[^%w-]") and byte(label, 1) ~= 45
    and byte(label, -1) ~= 45
end

-- True when an argument without a scheme looks like a host (decision D4).
-- See SPEC.md "Arguments without a scheme".
function M.looks_like_host(arg)
  if type(arg) ~= "string" or arg == "" or find(arg, "^[/.~]")
      or has_bad_byte(arg) then
    return false
  end
  local hostpart = sub(arg, 1, (find(arg, "[/?#]") or #arg + 1) - 1)
  local name, port = hostpart:match("^([^:]*):(.*)$")
  if name then
    local n = math.tointeger(tonumber(port:match("^%d%d?%d?%d?%d?$") or ""))
    if not n or n < 1 or n > 65535 then
      return false
    end
  else
    name = hostpart
  end
  if lower(name) == "localhost" then
    return true
  end
  local labels, last = 0, nil
  for label in (name .. "."):gmatch("([^.]*)%.") do
    if not good_label(label) then
      return false
    end
    labels, last = labels + 1, label
  end
  return labels >= 2 and not FILE_LABELS[lower(last)]
end

-- Request and body ----------------------------------------------------------

-- The release version. It goes into the User-Agent header.
M.VERSION = "0.2.0a"

-- The same chunk size as a file read.
local CHUNK = 4096
-- Every wait loop sleeps this long, so the program yields well inside the
-- 5 s OpenOS limit. First guesses until N2, N4, N5 and N11 are measured.
local WAIT_STEP = 0.05
local CONNECT_TIMEOUT = 15
local READ_TIMEOUT = 30
local MAX_REDIRECTS = 5
local INTERRUPTED = "html: interrupted"

local HEADERS = { ["User-Agent"] = "oc-html/" .. M.VERSION,
  ["Accept-Encoding"] = "identity" }

local REDIRECT = { [301] = true, [302] = true, [303] = true, [307] = true,
  [308] = true }

local ACCEPTED = { [""] = true, ["text/html"] = true,
  ["application/xhtml+xml"] = true, ["text/plain"] = true }

local LATIN_CHARSETS = { ["iso-8859-1"] = true, latin1 = true,
  ["windows-1252"] = true }

-- The first line of a reason from the card. It can be any value.
local function why_text(v)
  if v == nil then
    v = "unknown reason"
  end
  return (tostring(v):match("^[^\n]*"))
end

local function trim(s)
  return (s:match("^%s*(.-)%s*$"))
end

-- The first value of a response header. The name is not case-sensitive.
-- The card gives a list of values per name, but a plain value also works.
local function header(headers, name)
  if type(headers) ~= "table" then
    return nil
  end
  for k, v in pairs(headers) do
    if type(k) == "string" and lower(k) == name then
      if type(v) == "table" then
        v = v[1]
      end
      if v ~= nil then
        return tostring(v)
      end
    end
  end
  return nil
end

local latin_map

-- Converts Latin-1 or Windows-1252 text to UTF-8. Bytes 0x80 to 0x9F use the
-- Windows-1252 table of entities.lua. Each input byte is one character, so a
-- chunk converts without state.
function M.latin_to_utf8(s)
  if not find(s, "[\128-\255]") then
    return s
  end
  if not latin_map then
    local win = require("html.entities").WIN1252
    latin_map = {}
    for b = 0x80, 0xFF do
      latin_map[string.char(b)] = utf8.char(win[b] or b)
    end
  end
  return (s:gsub("[\128-\255]", latin_map))
end

-- Text for the generated short page: "&" and "<" become entities.
local function escape(s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"))
end

-- The page shown for an error status when the body cannot be shown.
local function short_page(code, message, url)
  local head = escape("HTTP " .. code .. (message ~= "" and (" " .. message)
    or ""))
  return "<title>" .. head .. "</title><h1>" .. head .. "</h1><p>"
    .. escape(url) .. "</p>"
end

-- Waits for the connection and the status line. Returns true, code, message
-- and headers, or false and a controlled message.
local function wait_response(h, url, links)
  local clock, interrupted = links.clock, links.interrupted
  local t0 = clock()
  local function wait()
    if interrupted() then
      return INTERRUPTED
    end
    if clock() - t0 > CONNECT_TIMEOUT then
      return "html: timed out connecting to " .. url
    end
    links.sleep(WAIT_STEP)
    return nil
  end
  while true do
    local ok, done, why = pcall(h.finishConnect)
    if not ok or done == nil then
      return false, "html: cannot connect: " .. url .. ": "
        .. why_text(ok and why or done)
    end
    if done then
      break
    end
    local stop = wait()
    if stop then
      return false, stop
    end
  end
  while true do
    local ok, code, message, headers = pcall(h.response)
    if not ok then
      return false, "html: cannot connect: " .. url .. ": " .. why_text(code)
    end
    if code ~= nil then
      return true, code, message, headers
    end
    local stop = wait()
    if stop then
      return false, stop
    end
  end
end

-- Returns the absolute URL of a redirect, or nil and a controlled message.
local function redirect_target(u, location)
  local target
  if M.scheme(location) then
    target = location
  elseif sub(location, 1, 1) == "/" and sub(location, 2, 2) ~= "/" then
    target = u.origin .. location
  end
  local parsed, why
  if target then
    parsed, why = M.parse_url(target)
  end
  if parsed then
    return parsed.url
  end
  if why and find(why, "^html: unsupported URL scheme") then
    return nil, why
  end
  return nil, "html: cannot follow redirect: " .. why_text(location)
end

-- Builds the response object for an open handle. Returns it, or nil and a
-- controlled message (the handle is then closed).
local function make_response(h, u, code, message, headers, links, info)
  local clock = links.clock
  local closed = false
  local function close()
    if not closed then
      closed = true
      pcall(h.close)
    end
  end
  local ctype = header(headers, "content-type")
  local media = ctype and lower(trim(ctype:match("^[^;]*"))) or ""
  local encoding = lower(trim(header(headers, "content-encoding")
    or "identity"))
  local plain = encoding == "identity" or encoding == ""
  local is_error = code < 200 or code > 299
  if not is_error and not plain then
    close()
    return nil, "html: compressed response not supported: "
      .. why_text(encoding)
  end
  if not is_error and not ACCEPTED[media] then
    close()
    return nil, "html: not an HTML page: " .. why_text(media)
  end
  local charset = ctype and ctype:match(";%s*[Cc][Hh][Aa][Rr][Ss][Ee][Tt]"
    .. "%s*=%s*\"?([^;\"%s]+)")
  local convert = charset and LATIN_CHARSETS[lower(charset)]
  local length = header(headers, "content-length")
  local resp = {
    status = code,
    message = message ~= nil and why_text(message) or "",
    content_type = ctype,
    length = length and math.tointeger(tonumber(length:match("^%s*(%d+)%s*$")
      or "")),
    final_url = u.url,
    redirects = info.redirects,
    is_error = is_error,
    bytes = 0,
    close = close,
  }

  local ended = false
  local function finish()
    ended = true
    info.ended = clock()
  end
  local last = clock()
  -- Returns a chunk, nil at the end, or nil and a controlled message.
  local function body_read()
    if ended or closed then
      return nil
    end
    while true do
      local ok, s, why = pcall(h.read, CHUNK)
      if not ok then
        finish()
        return nil, "html: read error: " .. why_text(s)
      end
      if s == nil then
        finish()
        if why ~= nil then
          return nil, "html: read error: " .. why_text(why)
        end
        return nil
      end
      s = tostring(s)
      if s ~= "" then
        last = clock()
        resp.bytes = resp.bytes + #s
        return convert and M.latin_to_utf8(s) or s
      end
      if links.interrupted() then
        return nil, INTERRUPTED
      end
      if clock() - last > READ_TIMEOUT then
        finish()
        return nil, "html: timed out reading " .. u.url .. " ("
          .. resp.bytes .. " bytes received)"
      end
      links.sleep(WAIT_STEP)
    end
  end

  function resp.fetch_time()
    return (info.ended or clock()) - info.started
  end

  if not is_error then
    resp.read = body_read
    return resp
  end

  -- An error status renders its body (decision D2). The short page replaces
  -- a body that is empty, cannot be read or has another type.
  local short
  local function use_short()
    short = short_page(code, resp.message, u.url)
  end
  if not ACCEPTED[media] or not plain then
    close()
    finish()
    resp.length = nil
    use_short()
  end
  local first = true
  function resp.read()
    if short then
      local s = short
      short = false
      return s
    end
    if short == false then
      return nil
    end
    local s, why = body_read()
    if first and why ~= INTERRUPTED then
      first = false
      if s == nil then
        use_short()
        return resp.read()
      end
    elseif s == nil and why ~= nil and why ~= INTERRUPTED then
      resp.read_error = why
      return nil
    end
    return s, why
  end
  return resp
end

-- Opens url with the card in links.internet and follows redirects.
-- links: internet (the card proxy), clock() (wall time in seconds),
-- sleep(seconds), interrupted() (true after Ctrl+C).
-- info is filled as the request goes: url, redirects, status, started and
-- ended (clock values).
-- Returns a response (status, message, is_error, length, content_type,
-- final_url, redirects, bytes, read_error, read(), close(), fetch_time()),
-- or nil and a controlled message.
function M.open(url, links, info)
  info.redirects = 0
  info.started = links.clock()
  local card = links.internet
  if type(card) ~= "table" then
    return nil, "html: no internet card found (needed for " .. url .. ")"
  end
  if card.isHttpEnabled then
    local ok, on = pcall(card.isHttpEnabled)
    if ok and on == false then
      return nil, "html: HTTP requests are disabled on this server"
    end
  end
  local start_url = url
  while true do
    local u, why = M.parse_url(url)
    if not u then
      return nil, why
    end
    info.url = u.url
    local ok, h, reason = pcall(card.request, u.url, nil, HEADERS)
    if not ok or not h then
      return nil, "html: cannot fetch " .. u.url .. ": "
        .. why_text(ok and reason or h)
    end
    local called, got, code, message, headers = pcall(wait_response, h,
      u.url, links)
    if not called then
      -- A raised sleep (for example Ctrl+C) still closes the handle.
      pcall(h.close)
      error(got, 0)
    end
    if not got then
      pcall(h.close)
      return nil, code
    end
    code = math.tointeger(tonumber(code)) or 0
    info.status = code
    local location = REDIRECT[code] and header(headers, "location")
    if not location then
      local called2, resp, rwhy = pcall(make_response, h, u, code, message,
        headers, links, info)
      if not called2 then
        pcall(h.close)
        error(resp, 0)
      end
      return resp, rwhy
    end
    pcall(h.close)
    if info.redirects >= MAX_REDIRECTS then
      return nil, "html: too many redirects: " .. start_url
    end
    local target, rwhy = redirect_target(u, location)
    if not target then
      return nil, rwhy
    end
    info.redirects = info.redirects + 1
    url = target
  end
end

return M
