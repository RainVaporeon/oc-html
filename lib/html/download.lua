-- Saves a fetch response to a file (spec/download.md). The part file, the
-- chunk streaming, the space checks and the rename live here. This module
-- makes no component calls: the filesystem, the clock and the yield come
-- from deps.
--
--   download.default_name(url, filename)   the default file name
--   download.default_path(url, filename, deps)   cwd and the default name
--   download.resolve_path(text, name, deps)   the target path of the prompt
--       text: returns path and whether it exists, or nil and a message
--   download.run(resp, path, deps, opts)   streams resp to path; returns
--       "saved", bytes | "stopped" | "error", message. It always closes resp.
--
-- deps: open, exists, is_dir, resolve, home, cwd, space(path) (free bytes),
-- remove, rename, clock, yield(what) ("slice" about each 0.1 s).
-- opts: stop() (true stops), progress(bytes, length).

local M = {}
local find, sub, byte = string.find, string.sub, string.byte

local RESERVE = 64 * 1024
local CHECK_EVERY = 64 * 1024
local SLICE = 0.1
local MAX_NAME = 64
local DEFAULT_HOME = "/home"

-- Steps 3 to 5 of "Default path": a clean name from any text.
local function clean(name)
  name = name:gsub("[^\32-\126]", "_"):gsub('[/\\:*?"<>|]', "_")
  if #name > MAX_NAME then
    local ext = name:match("(%.[^.]*)$")
    if ext and #ext < MAX_NAME then
      name = sub(name, 1, MAX_NAME - #ext) .. ext
    else
      name = sub(name, 1, MAX_NAME)
    end
  end
  return name
end

local function final(name)
  if name == "" or name == "." or name == ".." then
    return "index.html"
  end
  return name
end

local function url_name(url)
  local path = tostring(url or ""):match("^%a[%w+.-]*://[^/?#]*(.*)$")
    or tostring(url or "")
  path = path:match("^[^?#]*")
  local last = path:match("[^/]*$")
  last = last:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  return clean(last)
end

-- The default file name: the Content-Disposition name when it gives one,
-- else the last segment of the URL path.
function M.default_name(url, filename)
  if filename then
    local name = clean(tostring(filename):match("[^/\\]*$"))
    if name ~= "" then
      return final(name)
    end
  end
  return final(url_name(url))
end

local function join(dir, name)
  if sub(dir, -1) == "/" then
    return dir .. name
  end
  return dir .. "/" .. name
end

function M.default_path(url, filename, deps)
  return join(deps.cwd(), M.default_name(url, filename))
end

local function expand_home(path, home)
  if type(home) ~= "string" or home == "" then
    home = DEFAULT_HOME
  end
  if path == "~" then
    return home
  end
  if sub(path, 1, 2) == "~/" then
    return join(home, sub(path, 3))
  end
  return path
end

function M.resolve_path(text, name, deps)
  local path = deps.resolve(expand_home(text, deps.home))
  if deps.is_dir(path) then
    path = join(path, name)
  end
  local dir = path:match("^(.*)/[^/]*$")
  if dir == "" then
    dir = "/"
  end
  if dir and not deps.is_dir(dir) then
    return nil, "html: no such directory: " .. dir
  end
  return path, deps.exists(path) and true or false
end

local function reason(why)
  return (tostring(why or "unknown reason"):match("^[^\n]*"))
end

local function write_error(path, why)
  why = reason(why)
  if find(why, "[Rr]ead%-?[ ]?only") or find(why, "readonly") then
    why = "read-only filesystem"
  end
  return "html: cannot write " .. path .. ": " .. why
end

local function no_space(kb, free)
  return "html: not enough disk space: " .. kb .. " KB needed, "
    .. (free // 1024) .. " KB free"
end

function M.run(resp, path, deps, opts)
  opts = opts or {}
  local part = path .. ".part"
  local f
  local function cleanup()
    if f then
      pcall(f.close, f)
      f = nil
    end
    pcall(deps.remove, part)
  end
  local function fail(msg)
    cleanup()
    resp.close()
    return "error", msg
  end

  if resp.length then
    local ok, free = pcall(deps.space, path)
    if ok and type(free) == "number" and resp.length > free - RESERVE then
      resp.close()
      return "error", no_space((resp.length + 1023) // 1024, free)
    end
  end
  local why
  f, why = deps.open(part, "wb")
  if not f then
    resp.close()
    return "error", write_error(path, why)
  end

  local bytes, next_check = 0, CHECK_EVERY
  local sliced = deps.clock()
  while true do
    if opts.stop and opts.stop() then
      cleanup()
      resp.close()
      return "stopped"
    end
    local s, rwhy = resp.read()
    if s == nil then
      if rwhy == "html: interrupted" then
        cleanup()
        resp.close()
        return "stopped"
      end
      if rwhy ~= nil then
        return fail(rwhy)
      end
      break
    end
    local called, done, err = pcall(f.write, f, s)
    if not called or not done then
      return fail(write_error(path, called and err or done))
    end
    bytes = bytes + #s
    if opts.progress then
      opts.progress(bytes, resp.length)
    end
    if not resp.length and bytes >= next_check then
      next_check = bytes + CHECK_EVERY
      local ok, free = pcall(deps.space, path)
      if ok and type(free) == "number" and free < RESERVE then
        return fail(no_space((bytes + 1023) // 1024, free))
      end
    end
    if deps.clock() - sliced >= SLICE then
      deps.yield("slice")
      sliced = deps.clock()
    end
  end

  -- The end: flush and close are checked like write_text does.
  local called, done, err = pcall(f.flush, f)
  if not called or not done then
    return fail(write_error(path, called and err or done))
  end
  local closed_ok, closed, cerr = pcall(f.close, f)
  f = nil
  resp.close()
  if not closed_ok then
    closed, cerr = nil, closed
  end
  -- OpenOS close returns no values on success. Only a reason is a failure.
  if not closed_ok or (not closed and cerr ~= nil) then
    pcall(deps.remove, part)
    return "error", write_error(path, cerr)
  end
  local renamed, rwhy = deps.rename(part, path)
  if not renamed then
    pcall(deps.remove, part)
    return "error", write_error(path, rwhy or "rename failed")
  end
  return "saved", bytes
end

return M
