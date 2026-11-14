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

-- Link resolution -----------------------------------------------------------
-- See spec/url.md "Link resolution".

-- Returns the scheme of s in lower case when s starts with
-- "<letter>[letters, digits, + . -]:" (RFC 3986), or nil.
function M.ref_scheme(s)
  local scheme = type(s) == "string" and s:match("^(%a[%w+.-]*):")
  return scheme and lower(scheme) or nil
end

-- Removes the "." and ".." segments of an absolute path (RFC 3986 5.2.4).
local function remove_dots(path)
  if sub(path, 1, 1) ~= "/" then
    return path
  end
  local segs = {}
  for seg in (sub(path, 2) .. "/"):gmatch("([^/]*)/") do
    segs[#segs + 1] = seg
  end
  local out = {}
  for i, seg in ipairs(segs) do
    local last = i == #segs
    if seg == "." then
      if last then
        out[#out + 1] = ""
      end
    elseif seg == ".." then
      out[#out] = nil
      if last then
        out[#out + 1] = ""
      end
    else
      out[#out + 1] = seg
    end
  end
  return "/" .. table.concat(out, "/")
end

-- Splits "path?query#fragment". The query and the fragment are nil when the
-- text has no "?" or "#".
local function split_ref(s)
  local fragment
  local hash = find(s, "#", 1, true)
  if hash then
    fragment = sub(s, hash + 1)
    s = sub(s, 1, hash - 1)
  end
  local mark = find(s, "?", 1, true)
  if mark then
    return sub(s, 1, mark - 1), sub(s, mark + 1), fragment
  end
  return s, nil, fragment
end

-- Resolves a link of a local page. base is the absolute path of the page.
local function resolve_local(base, ref, scheme)
  if scheme == "file" then
    local rest = ref:match("^[^:]*:///(.*)$")
    if not rest then
      return nil, "html: invalid URL: " .. ref
    end
    ref = "/" .. rest
  elseif ref == "" or sub(ref, 1, 1) == "#" then
    return { kind = "same", fragment = select(3, split_ref(ref)) }
  end
  local path, _, fragment = split_ref(ref)
  path = path:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end)
  if path == "" then
    path = base
  elseif sub(path, 1, 1) ~= "/" then
    path = (base:match("^(.*/)") or "/") .. path
  end
  return { kind = "file", path = remove_dots(path), fragment = fragment }
end

-- Resolves a link against a base. base is an http(s) URL (a remote page) or
-- an absolute path (a local page). Returns one of
-- { kind = "http", url, fragment }, { kind = "file", path, fragment },
-- { kind = "same", fragment } and { kind = "unsupported", scheme },
-- or nil and a controlled message.
function M.resolve(base, ref)
  ref = ref:match("^%s*(.-)%s*$")
  local remote = M.scheme(base) ~= nil
  local scheme = M.ref_scheme(ref)
  if scheme == "file" and remote then
    return nil, "html: unsupported URL scheme: file"
  end
  if scheme == "file" or (not scheme and not remote) then
    return resolve_local(base, ref, scheme)
  end
  if scheme and scheme ~= "http" and scheme ~= "https" then
    return { kind = "unsupported", scheme = scheme }
  end
  ref = ref:gsub("[%z\1-\32\127-\255]", function(c)
    return string.format("%%%02X", byte(c))
  end)
  local target, fragment
  if scheme then
    local head, rest = ref:match("^(%a[%w+.-]*://[^/?#]*)(.*)$")
    if not head then
      return nil, "html: invalid URL: " .. ref
    end
    local path, query
    path, query, fragment = split_ref(rest)
    target = head .. remove_dots(path) .. (query and "?" .. query or "")
  else
    local u, why = M.parse_url(base)
    if not u then
      return nil, why
    end
    local path, query
    path, query, fragment = split_ref(ref)
    if path == "" and not query then
      return { kind = "same", fragment = fragment }
    end
    local tail = query and "?" .. query or ""
    local bpath = u.path:match("^[^?]*")
    if bpath == "" then
      bpath = "/"
    end
    if sub(path, 1, 2) == "//" then
      local auth = path:match("^//([^/]*)")
      target = u.scheme .. "://" .. auth
        .. remove_dots(sub(path, 3 + #auth)) .. tail
    elseif path == "" then
      target = u.origin .. bpath .. tail
    elseif sub(path, 1, 1) == "/" then
      target = u.origin .. remove_dots(path) .. tail
    else
      target = u.origin .. remove_dots(bpath:match("^(.*/)") .. path) .. tail
    end
  end
  local parsed, why = M.parse_url(target)
  if not parsed then
    return nil, why
  end
  return { kind = "http", url = parsed.url, fragment = fragment }
end

return M
