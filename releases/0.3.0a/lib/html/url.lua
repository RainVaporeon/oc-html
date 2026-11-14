-- Parses URL arguments. The program loads this small module while it checks
-- the arguments, so a bad URL is found before the TUI opens and before the
-- heavy modules load. It has no dependencies.

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
-- See spec/url.md "Arguments without a scheme".
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

return M
