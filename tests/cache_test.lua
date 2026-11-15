-- Tests for lib/html/cache.lua against spec/cache.md.

local t = require("test")
local cache = require("html.cache")

local T = {}

local DIR = "/home/.cache/html"
local KB = 1024

-- A fake filesystem. o.total and o.used set the disk, o.read_only the flag.
-- o.raise_write makes write raise. o.fail_write, o.fail_close, o.fail_rename and o.fail_read make that call fail.
local function fake_fs(o)
  o = o or {}
  local fs = { files = {}, dirs = {}, o = o }
  o.total = o.total or 100 * 1024 * 1024
  o.used = o.used or 0
  local proxy = {
    isReadOnly = function() return o.read_only or false end,
    spaceTotal = function() return o.total end,
    spaceUsed = function()
      local n = o.used
      for _, data in pairs(fs.files) do
        n = n + #data
      end
      return n
    end,
  }
  local deps = {
    get = function() return proxy, "/home" end,
    exists = function(p) return fs.dirs[p] or fs.files[p] ~= nil end,
    makeDirectory = function(p)
      fs.dirs[p] = true
      return true
    end,
    remove = function(p)
      fs.files[p] = nil
      return true
    end,
    rename = function(a, b)
      if o.fail_rename then
        return nil, "rename failed"
      end
      fs.files[b] = fs.files[a]
      fs.files[a] = nil
      return true
    end,
    list = function()
      local out = {}
      for p in pairs(fs.files) do
        out[#out + 1] = p:match("[^/]+$")
      end
      table.sort(out)
      local i = 0
      return function()
        i = i + 1
        return out[i]
      end
    end,
    open = function(p, mode)
      if mode == "rb" then
        if o.fail_read or fs.files[p] == nil then
          return nil, "cannot read"
        end
        local data = fs.files[p]
        return {
          read = function() return data end,
          close = function() end,
        }
      end
      -- Like OpenOS: write returns the handle, close returns nothing.
      local buf = {}
      fs.files[p] = ""
      local h = {}
      h.write = function(self, chunk)
        if o.raise_write then
          error("write raised")
        end
        if o.fail_write then
          return nil, "disk full"
        end
        buf[#buf + 1] = chunk
        return self
      end
      h.close = function()
        if o.fail_close then
          return nil, o.fail_close == true and "flush failed" or o.fail_close
        end
        if fs.files[p] ~= nil then
          fs.files[p] = table.concat(buf)
        end
      end
      return h
    end,
  }
  fs.deps = deps
  return fs
end

local function count_files(fs)
  local n = 0
  for _ in pairs(fs.files) do
    n = n + 1
  end
  return n
end

local function has_part(fs)
  for p in pairs(fs.files) do
    if p:find("%.part$") then
      return true
    end
  end
  return false
end

-- Stores a page of size bytes under key in 1 KB chunks. Returns the result
-- of commit_complete.
local function store(c, key, size, meta)
  local w = c.begin(key)
  if not w then
    return nil
  end
  local left = size
  while left > 0 do
    local n = math.min(left, KB)
    if not w.write(("x"):rep(n)) then
      return false
    end
    left = left - n
  end
  return w.commit_complete(meta or { final_url = key, status = 200 })
end

local function url(n)
  return "http://example.com/" .. n
end

-- Budget: { free bytes, read_only, opts } -> { bytes_cap, entries_cap, enabled }.
t.cases(T, "budget", {
  { "large disk is held at 2 MiB", { 100 * 1024 * KB }, { 2 * 1024 * KB, 16, true } },
  { "25 percent of a mid disk", { 4 * 1024 * KB }, { 1024 * KB, 16, true } },
  { "small disk", { 200 * KB }, { 50 * KB, 16, true } },
  { "reserve limits the cap", { 70 * KB }, { 6 * KB, 16, true } },
  { "free space under the reserve", { 64 * KB }, { 0, 16, false } },
  { "read-only disk", { 100 * 1024 * KB, true }, { 0, 16, false } },
}, function(input)
  local fs = fake_fs({ total = input[1], read_only = input[2] })
  local c = cache.new({}, fs.deps)
  local cap, entries = c.budget()
  return { cap, entries, c.enabled() }
end)

T["budget counts the leftovers freed at the start"] = function()
  local fs = fake_fs({ total = 400 * KB })
  fs.files[DIR .. "/9"] = ("x"):rep(200 * KB)
  local c = cache.new({ dir = DIR }, fs.deps)
  t.eq(c.budget(), 84 * KB + 16 * KB, "free is 400 KB, cap 100 KB")
end

T["the folder is created and a failure turns the cache off"] = function()
  local fs = fake_fs()
  local c = cache.new({}, fs.deps)
  t.ok(fs.dirs[DIR], "default folder made")
  t.ok(c.enabled(), "on")
  fs.deps.makeDirectory = function() return nil end
  local c2 = cache.new({ dir = "/other" }, fs.deps)
  t.eq(c2.enabled(), false, "off when the folder cannot be made")
  t.eq(c2.begin(url(1)), nil, "no writer when off")
end

T["store and get"] = function()
  local fs = fake_fs()
  local c = cache.new({}, fs.deps)
  t.ok(store(c, url(1), 3000, { final_url = "http://example.com/final",
    status = 404, content_type = "text/html", is_error = true }), "stored")
  local e = c.get(url(1))
  t.ok(e, "found")
  t.eq(e.bytes, 3000, "bytes")
  t.eq(e.final_url, "http://example.com/final", "final_url")
  t.eq(e.status, 404, "status")
  t.eq(e.content_type, "text/html", "content_type")
  t.eq(e.is_error, true, "is_error")
  local h = e.open()
  t.eq(#h:read(), 3000, "content read back")
  t.eq(c.get(url(2)), nil, "miss")
  t.eq(c.stats(), { entries = 1, bytes = 3000 }, "stats")
end

T["the key has no fragment"] = function()
  local fs = fake_fs()
  local c = cache.new({}, fs.deps)
  t.eq(c.key("http://a.com/p?q=1#top"), "http://a.com/p?q=1", "key")
  t.ok(store(c, "http://a.com/p#one", 10), "stored")
  t.ok(c.get("http://a.com/p#two"), "other fragment hits")
  t.ok(c.get("http://a.com/p"), "no fragment hits")
end

T["local files are not cached"] = function()
  local fs = fake_fs()
  local c = cache.new({}, fs.deps)
  t.eq(c.begin("/home/index.html"), nil, "path")
  t.eq(c.begin("./index.html"), nil, "relative path")
  t.ok(c.begin("HTTPS://a.com/"), "https")
end

T["rename only on complete"] = function()
  local fs = fake_fs()
  local c = cache.new({}, fs.deps)
  local w = c.begin(url(1))
  w.write("abc")
  t.ok(has_part(fs), "part file while writing")
  t.eq(c.get(url(1)), nil, "no entry before the commit")
  t.ok(w.commit_complete({}), "commit")
  t.eq(has_part(fs), false, "no part file after the commit")
  t.eq(count_files(fs), 1, "one file")
  t.ok(c.get(url(1)), "entry after the commit")
end

T["abort removes the part file"] = function()
  local fs = fake_fs()
  local c = cache.new({}, fs.deps)
  local w = c.begin(url(1))
  w.write("abc")
  w.abort()
  t.eq(count_files(fs), 0, "no file")
  t.eq(c.get(url(1)), nil, "no entry")
  t.eq(w.write("x"), false, "write after abort")
  t.eq(w.commit_complete({}), false, "commit after abort")
  t.ok(c.enabled(), "cache stays on")
end

T["a page over the cap is not stored"] = function()
  local fs = fake_fs({ total = 400 * KB })
  local c = cache.new({}, fs.deps)
  local cap = c.budget()
  t.eq(cap, 100 * KB, "cap")
  t.eq(store(c, url(1), cap + KB), false, "write stops")
  t.eq(count_files(fs), 0, "part file deleted")
  t.eq(c.get(url(1)), nil, "no entry")
  t.ok(c.enabled(), "cache stays on")
  t.ok(store(c, url(2), cap), "a page of exactly the cap fits")
end

T["LRU by count"] = function()
  local fs = fake_fs()
  local c = cache.new({ max_entries = 3 }, fs.deps)
  store(c, url(1), 10)
  store(c, url(2), 10)
  store(c, url(3), 10)
  t.ok(c.get(url(1)), "touch 1")
  store(c, url(4), 10)
  t.eq(c.get(url(2)), nil, "2 is the oldest and goes")
  t.ok(c.get(url(1)), "1 stays")
  t.ok(c.get(url(3)), "3 stays")
  t.ok(c.get(url(4)), "4 stays")
  t.eq(c.stats().entries, 3, "three entries")
  t.eq(count_files(fs), 3, "three files")
end

T["LRU by bytes"] = function()
  local fs = fake_fs({ total = 400 * KB })
  local c = cache.new({}, fs.deps)
  t.eq(c.budget(), 100 * KB, "cap")
  store(c, url(1), 40 * KB)
  store(c, url(2), 40 * KB)
  t.ok(c.get(url(1)), "touch 1")
  store(c, url(3), 40 * KB)
  t.eq(c.get(url(2)), nil, "2 is the oldest and goes")
  t.ok(c.get(url(1)), "1 stays")
  t.ok(c.get(url(3)), "3 stays")
  t.eq(c.stats().bytes, 80 * KB, "bytes")
  t.eq(count_files(fs), 2, "two files")
end

T["a new page of a known key replaces the entry"] = function()
  local fs = fake_fs()
  local c = cache.new({}, fs.deps)
  store(c, url(1), 100)
  store(c, url(1), 200)
  t.eq(c.stats(), { entries = 1, bytes = 200 }, "one entry")
  t.eq(count_files(fs), 1, "one file")
end

T["a write error turns the cache off"] = function()
  local fs = fake_fs()
  local c = cache.new({}, fs.deps)
  store(c, url(1), 10)
  fs.o.fail_write = true
  t.eq(store(c, url(2), 10), false, "write fails")
  t.eq(c.enabled(), false, "off")
  t.eq(c.get(url(1)), nil, "no lookup when off")
  t.eq(c.begin(url(3)), nil, "no writer when off")
  t.eq(count_files(fs), 0, "files removed")
end

T["a flush error at close turns the cache off"] = function()
  local fs = fake_fs()
  local c = cache.new({}, fs.deps)
  fs.o.fail_close = true
  t.eq(store(c, url(1), 10), false, "commit fails")
  t.eq(c.enabled(), false, "off")
  t.eq(count_files(fs), 0, "no files")
end

T["a write that raises turns the cache off"] = function()
  local fs = fake_fs()
  local c = cache.new({}, fs.deps)
  fs.o.raise_write = true
  t.eq(store(c, url(1), 10), false, "write fails")
  t.eq(c.enabled(), false, "off")
  t.eq(count_files(fs), 0, "no files")
end

T["a close that returns nothing is a success"] = function()
  local fs = fake_fs()
  local c = cache.new({}, fs.deps)
  t.eq(store(c, url(1), 10), true, "commit succeeds")
  t.eq(c.enabled(), true, "on")
  t.eq(c.get(url(1)) ~= nil, true, "entry stored")
  t.eq(c.stats().entries, 1, "one entry")
end

T["a close that returns nil and disk full turns the cache off"] = function()
  local fs = fake_fs()
  local c = cache.new({}, fs.deps)
  fs.o.fail_close = "disk full"
  t.eq(store(c, url(1), 10), false, "commit fails")
  t.eq(c.enabled(), false, "off")
  t.eq(c.get(url(1)), nil, "no entry")
end

T["a rename error turns the cache off"] = function()
  local fs = fake_fs()
  local c = cache.new({}, fs.deps)
  fs.o.fail_rename = true
  t.eq(store(c, url(1), 10), false, "commit fails")
  t.eq(c.enabled(), false, "off")
  t.eq(count_files(fs), 0, "no files")
end

T["a read error drops the entry"] = function()
  local fs = fake_fs()
  local c = cache.new({}, fs.deps)
  store(c, url(1), 10)
  store(c, url(2), 10)
  fs.o.fail_read = true
  t.eq(c.get(url(1)), nil, "get returns nil")
  fs.o.fail_read = false
  t.eq(c.get(url(1)), nil, "entry is gone")
  t.eq(c.stats().entries, 1, "other entry stays")
  t.ok(c.enabled(), "cache stays on")
  local e = c.get(url(2))
  fs.o.fail_read = true
  t.eq(e.open(), nil, "open fails")
  t.eq(c.stats().entries, 0, "entry dropped by open")
  store(c, url(3), 10)
  c.drop(url(3))
  t.eq(c.stats().entries, 0, "drop")
end

T["clear at the start and at the end"] = function()
  local fs = fake_fs()
  fs.files[DIR .. "/7"] = "old"
  fs.files[DIR .. "/8.part"] = "old"
  local c = cache.new({}, fs.deps)
  t.eq(count_files(fs), 0, "leftovers deleted at the start")
  store(c, url(1), 10)
  store(c, url(2), 10)
  local w = c.begin(url(3))
  w.write("abc")
  c.clear()
  t.eq(count_files(fs), 0, "files deleted at the end")
  t.eq(c.stats(), { entries = 0, bytes = 0 }, "index empty")
  t.eq(w.commit_complete({}), false, "writer in flight stops")
  t.eq(count_files(fs), 0, "no file from the writer")
end

return T
