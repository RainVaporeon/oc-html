-- Disk page cache of one browsing session (spec/cache.md).
-- The module keeps an index only. The page bytes live in files.
-- Nothing is called at load time. Every filesystem call comes from deps.
--
--   local c = cache.new(opts, deps)
--     opts.dir          folder, default "/home/.cache/html"
--     opts.max_bytes    limit of the byte cap, default 2 MiB
--     opts.fraction     share of the free space, default 0.25
--     opts.max_entries  default 16
--     opts.reserve      free bytes the cache never uses, default 64 KB
--     deps.get(dir)         returns proxy (spaceTotal, spaceUsed, isReadOnly)
--     deps.exists(path), deps.makeDirectory(path), deps.remove(path),
--     deps.rename(from, to), deps.list(dir) (iterator or table of names),
--     deps.open(path, mode) returns a file handle or nil, err
--   c.key(url)             key of a URL: the URL without its fragment
--   c.enabled()            false after the cache turned itself off
--   c.budget()             bytes_cap, entries_cap
--   c.begin(key)           writer, or nil when the cache is off or key is not
--                          an http(s) URL
--     w.write(chunk)       true, or false when the writer stopped
--     w.commit_complete(meta)  rename the part file in; meta is
--                          { final_url, status, content_type, is_error }
--     w.abort()            delete the part file
--   c.get(key)             entry { key, file, bytes, final_url, status,
--                          content_type, is_error, last_used, open }, or nil
--     entry.open()         file handle for reading, or nil, err
--   c.drop(key)            remove one entry (the caller saw a read error)
--   c.clear()              delete the content of the folder, empty the index
--   c.stats()              { entries, bytes }

local M = {}

local DEFAULT_DIR = "/home/.cache/html"
local MAX_BYTES = 2 * 1024 * 1024
local FRACTION = 0.25
local MAX_ENTRIES = 16
local RESERVE = 64 * 1024

local function join(dir, name)
  return (dir:gsub("/+$", "")) .. "/" .. name
end

-- True when a pcall of a handle call failed. A raised error fails. So does
-- (nil|false, reason). A bare nil or no values is success: OpenOS close()
-- returns nothing on success (docs/probe/FACTS.md).
local function failed(ok, res, reason)
  return not ok or ((res == nil or res == false) and reason ~= nil)
end

-- Returns the names in a folder as a list. Never raises.
local function names(deps, dir)
  local ok, res = pcall(deps.list, dir)
  local out = {}
  if not ok or not res then
    return out
  end
  if type(res) == "function" then
    for name in res do
      out[#out + 1] = name
    end
  else
    for _, name in ipairs(res) do
      out[#out + 1] = name
    end
  end
  return out
end

function M.new(opts, deps)
  opts = opts or {}
  local dir = opts.dir or DEFAULT_DIR
  local max_entries = opts.max_entries or MAX_ENTRIES
  local reserve = opts.reserve or RESERVE
  local cap = 0
  local on = true
  local index = {}
  local total = 0
  local count = 0
  local tick = 0
  local serial = 0
  local writers = {}

  local self = {}

  local function remove(path)
    pcall(deps.remove, path)
  end

  local function forget(key)
    local e = index[key]
    if e then
      index[key] = nil
      total = total - e.bytes
      count = count - 1
      remove(e.file)
    end
  end

  -- Deletes the content of the folder. Errors are ignored.
  local function wipe()
    for _, name in ipairs(names(deps, dir)) do
      remove(join(dir, (name:gsub("/+$", ""))))
    end
    index = {}
    total = 0
    count = 0
  end

  local function turn_off()
    if on then
      on = false
      wipe()
    end
  end

  local function evict_oldest()
    local oldest
    for key, e in pairs(index) do
      if not oldest or e.last_used < index[oldest].last_used then
        oldest = key
      end
    end
    if not oldest then
      return false
    end
    forget(oldest)
    return true
  end

  function self.key(url)
    return (tostring(url):gsub("#.*$", ""))
  end

  function self.enabled()
    return on
  end

  function self.budget()
    return cap, max_entries
  end

  function self.stats()
    return { entries = count, bytes = total }
  end

  function self.clear()
    -- Writers in flight lose their part files and stop at the next call.
    for w in pairs(writers) do
      w.stopped = true
    end
    wipe()
  end

  function self.get(key)
    if not on then
      return nil
    end
    key = self.key(key)
    local e = index[key]
    if not e then
      return nil
    end
    local ok, h = pcall(deps.open, e.file, "rb")
    if not ok or not h then
      forget(key)
      return nil
    end
    pcall(h.close, h)
    tick = tick + 1
    e.last_used = tick
    local entry = {}
    for k, v in pairs(e) do
      entry[k] = v
    end
    entry.open = function()
      local ok2, h2, err = pcall(deps.open, e.file, "rb")
      if not ok2 or not h2 then
        forget(key)
        return nil, ok2 and err or h2
      end
      return h2
    end
    return entry
  end

  function self.drop(key)
    forget(self.key(key))
  end

  function self.begin(key)
    if not on or type(key) ~= "string" then
      return nil
    end
    key = self.key(key)
    if not key:lower():match("^https?://") then
      return nil
    end
    forget(key)
    while count >= max_entries do
      if not evict_oldest() then
        break
      end
    end
    serial = serial + 1
    local path = join(dir, tostring(serial))
    local part = path .. ".part"
    local ok, h = pcall(deps.open, part, "wb")
    if not ok or not h then
      turn_off()
      return nil
    end

    local w = { stopped = false }
    local written = 0
    local writer = {}

    local function finish()
      writers[w] = nil
      w.stopped = true
      pcall(h.close, h)
      remove(part)
    end

    function writer.abort()
      if writers[w] then
        finish()
      end
    end

    function writer.write(chunk)
      if w.stopped or not on then
        writer.abort()
        return false
      end
      written = written + #chunk
      -- A page over the cap stops this writer. The cache stays on.
      if written > cap then
        finish()
        return false
      end
      while total + written > cap do
        if not evict_oldest() then
          break
        end
      end
      if failed(pcall(h.write, h, chunk)) then
        finish()
        turn_off()
        return false
      end
      return true
    end

    function writer.commit_complete(meta)
      if w.stopped or not on then
        writer.abort()
        return false
      end
      meta = meta or {}
      local cclosed = failed(pcall(h.close, h))
      writers[w] = nil
      w.stopped = true
      if cclosed then
        remove(part)
        turn_off()
        return false
      end
      local rok, rres = pcall(deps.rename, part, path)
      if not rok or not rres then
        remove(part)
        turn_off()
        return false
      end
      while count >= max_entries or total + written > cap do
        if not evict_oldest() then
          break
        end
      end
      tick = tick + 1
      index[key] = {
        key = key,
        file = path,
        bytes = written,
        final_url = meta.final_url,
        status = meta.status,
        content_type = meta.content_type,
        is_error = meta.is_error and true or false,
        last_used = tick,
      }
      total = total + written
      count = count + 1
      return true
    end

    writers[w] = true
    return writer
  end

  -- Session start: make the folder, check the disk, drop leftovers, and
  -- read the free space.
  local function setup()
    local ok = pcall(function()
      if not deps.exists(dir) and not deps.makeDirectory(dir) then
        error("no folder")
      end
    end)
    if not ok then
      on = false
      return
    end
    local sok, proxy = pcall(deps.get, dir)
    if not sok or not proxy then
      on = false
      return
    end
    local rok, read_only = pcall(proxy.isReadOnly)
    if not rok or read_only then
      on = false
      return
    end
    wipe()
    local fok, free = pcall(function()
      return proxy.spaceTotal() - proxy.spaceUsed()
    end)
    if not fok then
      on = false
      return
    end
    cap = math.min(math.floor(free * (opts.fraction or FRACTION)),
      opts.max_bytes or MAX_BYTES, free - reserve)
    if cap < 1 then
      cap = 0
      on = false
    end
  end

  setup()
  return self
end

return M
