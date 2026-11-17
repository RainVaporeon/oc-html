-- Tests for lib/html/download.lua against spec/download.md. The filesystem
-- is a table in memory, the response is a small fake.

local t = require("test")
local download = require("html.download")

local T = {}

-- A fake filesystem. opts: free (bytes), flush_error, close_error,
-- write_error (a reason).
local function fs(opts)
  opts = opts or {}
  local f = { files = { ["/home/old.bin"] = "OLD" }, dirs = { ["/"] = true,
    ["/home"] = true }, free = opts.free or 10 * 1024 * 1024, closed = 0 }
  f.deps = {
    cwd = function() return "/home" end,
    resolve = function(p)
      return p:sub(1, 1) == "/" and p or ("/home/" .. p)
    end,
    is_dir = function(p) return f.dirs[p] == true end,
    exists = function(p) return f.files[p] ~= nil or f.dirs[p] == true end,
    space = function() return f.free end,
    remove = function(p) f.files[p] = nil return true end,
    rename = function(a, b)
      f.files[b], f.files[a] = f.files[a], nil
      return true
    end,
    clock = os.clock,
    yield = function() end,
    open = function(p)
      local buf = {}
      f.files[p] = ""
      local h = {}
      function h:write(s)
        if opts.write_error then return nil, opts.write_error end
        buf[#buf + 1] = s
        return self
      end
      function h:flush()
        if opts.flush_error then return nil, opts.flush_error end
        f.files[p] = table.concat(buf)
        return self
      end
      function h:close()
        f.closed = f.closed + 1
        if opts.close_error then return nil, opts.close_error end
      end
      return h
    end,
  }
  return f
end

local function response(chunks, length, read_error)
  local i = 0
  local r = { length = length, closed = 0 }
  function r.read()
    i = i + 1
    if chunks[i] then return chunks[i] end
    return nil, read_error
  end
  function r.close() r.closed = r.closed + 1 end
  return r
end

local function no_part(f)
  for p in pairs(f.files) do
    t.ok(not p:find("%.part$"), "part file left: " .. p)
  end
end

t.cases(T, "default_name", {
  { "last URL segment", { "http://h/a/b.zip?x=1#f" }, "b.zip" },
  { "percent decode", { "http://h/a%20b.txt" }, "a b.txt" },
  { "bad bytes and separators", { "http://h/a%2Fb%00c" }, "a_b_c" },
  { "empty gives index.html", { "http://h/" }, "index.html" },
  { "dot dot gives index.html", { "http://h/a/.." }, "index.html" },
  { "disposition wins", { "http://h/x.zip", "../up\\y.bin" }, "y.bin" },
  { "empty disposition falls back", { "http://h/x.zip", "a/" }, "x.zip" },
  { "long name keeps the extension",
    { "http://h/" .. ("a"):rep(100) .. ".tar" }, ("a"):rep(60) .. ".tar" },
}, function(input) return download.default_name(input[1], input[2]) end)

T["resolve_path joins a directory, expands ~ and checks the parent"] = function()
  local f = fs()
  f.dirs["/home/docs"] = true
  local p, exists = download.resolve_path("docs", "n.bin", f.deps)
  t.eq(p, "/home/docs/n.bin", "directory")
  t.eq(exists, false, "new")
  p, exists = download.resolve_path("old.bin", "n.bin", f.deps)
  t.eq(p, "/home/old.bin", "relative")
  t.eq(exists, true, "existing")
  p = download.resolve_path("~/x", "n.bin", f.deps)
  t.eq(p, "/home/x", "home")
  local bad, why = download.resolve_path("/nope/x", "n.bin", f.deps)
  t.eq(bad, nil, "no path")
  t.eq(why, "html: no such directory: /nope", "message")
end

T["run saves the bytes and renames the part file"] = function()
  local f = fs()
  local r = response({ "ab", "cd" }, 4)
  local how, n = download.run(r, "/home/a.bin", f.deps)
  t.eq(how, "saved", "result")
  t.eq(n, 4, "bytes")
  t.eq(f.files["/home/a.bin"], "abcd", "content")
  t.eq(r.closed >= 1, true, "handle closed")
  no_part(f)
end

T["a stop leaves no part file and keeps the old file"] = function()
  local f = fs()
  local r = response({ "ab", "cd" })
  local stop = false
  local how = download.run(r, "/home/old.bin", f.deps, {
    stop = function() local s = stop stop = true return s end })
  t.eq(how, "stopped", "result")
  t.eq(f.files["/home/old.bin"], "OLD", "old file stays")
  t.eq(r.closed >= 1, true, "handle closed")
  no_part(f)
end

T["a read error deletes the part file and keeps the old file"] = function()
  local f = fs()
  local how, msg = download.run(response({ "ab" }, nil, "html: read error: x"),
    "/home/old.bin", f.deps)
  t.eq(how, "error", "result")
  t.eq(msg, "html: read error: x", "message")
  t.eq(f.files["/home/old.bin"], "OLD", "old file stays")
  no_part(f)
end

T["a known length over the free space stops before the first read"] = function()
  local f = fs({ free = 100 * 1024 })
  local r = response({ "ab" }, 50 * 1024)
  local how, msg = download.run(r, "/home/a.bin", f.deps)
  t.eq(how, "error", "result")
  t.eq(msg, "html: not enough disk space: 50 KB needed, 100 KB free", "text")
  t.eq(r.closed >= 1, true, "handle closed")
  t.eq(f.files["/home/a.bin"], nil, "no file")
  no_part(f)
end

T["an unknown length checks the space after 64 KB"] = function()
  local f = fs({ free = 10 * 1024 })
  local big = ("x"):rep(64 * 1024)
  local how, msg = download.run(response({ big, "y" }), "/home/a.bin",
    f.deps)
  t.eq(how, "error", "result")
  t.eq(msg, "html: not enough disk space: 64 KB needed, 10 KB free", "text")
  no_part(f)
end

T["a flush error on a full disk deletes the part file"] = function()
  local f = fs({ flush_error = "not enough space" })
  local how, msg = download.run(response({ "ab" }, 2), "/home/old.bin",
    f.deps)
  t.eq(how, "error", "result")
  t.eq(msg, "html: cannot write /home/old.bin: not enough space", "text")
  t.eq(f.files["/home/old.bin"], "OLD", "old file stays")
  no_part(f)
end

T["a close error is a failure"] = function()
  local f = fs({ close_error = "disk full" })
  local how, msg = download.run(response({ "ab" }, 2), "/home/a.bin",
    f.deps)
  t.eq(how, "error", "result")
  t.eq(msg, "html: cannot write /home/a.bin: disk full", "text")
  no_part(f)
end

return T
