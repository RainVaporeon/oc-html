-- Tests for the installer template (tools/installer.lua), its generator
-- (tools/mkinstall.lua) and the installers in releases/.
-- Rules: spec/installer.md, spec/release.md.

local t = require("test")

local T = {}

local mk = t.load_tool("mkinstall")({})

local SAMPLE = {
  ["bin/html.lua"] = "print('html')\n",
  ["lib/html/guard.lua"] = "return {}\n",
}

-- Returns a fresh installer module with the given files.
local function template_module(files)
  local M = t.load_tool("installer")({})
  M.VERSION = "9.9.9a"
  for path, content in pairs(files or SAMPLE) do
    M.files[path] = content
    M.sizes[path] = #content
  end
  return M
end

-- A filesystem in memory. Rename fails when the target exists, as in
-- OpenComputers. opts: files, dirs, free, read_only, fail_write(path),
-- fail_rename(from, to), corrupt(path).
local function fake_fs(opts)
  opts = opts or {}
  local fs = { files = {}, dirs = { ["/"] = true }, writes = 0 }
  for k, v in pairs(opts.files or {}) do
    fs.files[k] = v
  end
  for _, d in ipairs(opts.dirs or {}) do
    fs.dirs[d] = true
  end
  fs.out, fs.err = {}, {}
  fs.deps = {
    out = function(line) fs.out[#fs.out + 1] = line end,
    err = function(line) fs.err[#fs.err + 1] = line end,
    exists = function(p) return fs.files[p] ~= nil or fs.dirs[p] ~= nil end,
    is_dir = function(p) return fs.dirs[p] == true end,
    make_dir = function(p)
      local acc = ""
      for part in p:gmatch("[^/]+") do
        acc = acc .. "/" .. part
        if fs.files[acc] then
          return nil, "file in the way"
        end
        fs.dirs[acc] = true
      end
      return true
    end,
    read = function(p)
      local c = fs.files[p]
      if c and opts.corrupt and opts.corrupt(p) then
        return c .. "x"
      end
      return c
    end,
    write = function(p, c)
      if opts.fail_write and opts.fail_write(p) then
        return nil, "disk error"
      end
      fs.writes = fs.writes + 1
      fs.files[p] = c
      return true
    end,
    rename = function(a, b)
      if opts.fail_rename and opts.fail_rename(a, b) then
        return nil, "rename error"
      end
      if fs.files[a] == nil or fs.files[b] ~= nil then
        return nil, "cannot rename"
      end
      fs.files[b], fs.files[a] = fs.files[a], nil
      return true
    end,
    remove = function(p)
      fs.files[p] = nil
      return true
    end,
    space = function()
      return { id = "disk", free = opts.free, read_only = opts.read_only }
    end,
  }
  return fs
end

-- Everything a run leaves behind, as a list of lines: the exit code, the
-- number of writes, the output, the error output, the files and the
-- folders (the root is left out).
local function render(fs, code)
  local r = { "exit " .. code, "writes " .. fs.writes }
  for _, line in ipairs(fs.out) do
    r[#r + 1] = "out " .. line
  end
  for _, line in ipairs(fs.err) do
    r[#r + 1] = "err " .. line
  end
  local files, dirs = {}, {}
  for p, c in pairs(fs.files) do
    files[#files + 1] = "file " .. p .. " " .. string.format("%q", c)
  end
  for d in pairs(fs.dirs) do
    if d ~= "/" then
      dirs[#dirs + 1] = "dir " .. d
    end
  end
  table.sort(files)
  table.sort(dirs)
  for _, line in ipairs(files) do
    r[#r + 1] = line
  end
  for _, line in ipairs(dirs) do
    r[#r + 1] = line
  end
  return r
end

-- The expected list for render. files is a map of path to content, dirs a
-- list of paths.
local function expect(code, writes, out, err, files, dirs)
  local r = { "exit " .. code, "writes " .. writes }
  for _, line in ipairs(out) do
    r[#r + 1] = "out " .. line
  end
  for _, line in ipairs(err) do
    r[#r + 1] = "err " .. line
  end
  local fl, dl = {}, {}
  for p, c in pairs(files) do
    fl[#fl + 1] = "file " .. p .. " " .. string.format("%q", c)
  end
  for _, d in ipairs(dirs) do
    dl[#dl + 1] = "dir " .. d
  end
  table.sort(fl)
  table.sort(dl)
  for _, line in ipairs(fl) do
    r[#r + 1] = line
  end
  for _, line in ipairs(dl) do
    r[#r + 1] = line
  end
  return r
end

local function copy(list)
  local c = {}
  for k, v in pairs(list or {}) do
    c[k] = v
  end
  return c
end

local OLD = {
  ["/home/bin/html.lua"] = "old html\n",
  ["/home/lib/html/guard.lua"] = "old guard\n",
}
local OLD_DIRS = { "/home", "/home/bin", "/home/lib", "/home/lib/html" }
local HEADER = "html-install: oc-html 9.9.9a"
local BIN, GUARD = SAMPLE["bin/html.lua"], SAMPLE["lib/html/guard.lua"]
-- 14 + 10 for the files, 2 * 1024 margin, 14 for the temporary copy of the
-- largest file.
local NEED = 14 + 10 + 2 * 1024 + 14

local function installed(prefix)
  return {
    [prefix .. "/bin/html.lua"] = BIN,
    [prefix .. "/lib/html/guard.lua"] = GUARD,
  }
end

-- Runs main on a fake filesystem. The row input is a table: args, fs (the
-- fake_fs options), old (true: the old files exist), sizes (changes to the
-- recorded sizes), hook(fs) (changes the fake before the run).
local function installer_run(input)
  local M = template_module()
  for path, size in pairs(input.sizes or {}) do
    M.sizes[path] = size
  end
  local o = copy(input.fs)
  if input.old then
    o.files, o.dirs = OLD, OLD_DIRS
  end
  local fs = fake_fs(o)
  if input.hook then
    input.hook(fs)
  end
  local args = copy(input.args)
  args.n = #args
  return render(fs, M.main(args, fs.deps))
end

-- A successful install below prefix. dirs lists the folders left behind.
local function ok_result(prefix, dirs)
  local out = { HEADER, prefix .. "/bin/html.lua 14 bytes",
    prefix .. "/lib/html/guard.lua 10 bytes", "installed 2 files" }
  return expect(0, 2, out, {}, installed(prefix), dirs)
end

-- spec/installer.md "Behavior": output, prefix, --dry-run, write order.
t.cases(T, "installer_success", {
  { "default prefix /home", { fs = { dirs = { "/home" } } },
    ok_result("/home", OLD_DIRS) },
  { "--prefix with a trailing slash",
    { args = { "--prefix", "/mnt/ab/" } },
    ok_result("/mnt/ab", { "/mnt", "/mnt/ab", "/mnt/ab/bin", "/mnt/ab/lib",
      "/mnt/ab/lib/html" }) },
  { "relative --prefix goes through resolve",
    { args = { "--prefix", "x" },
      hook = function(fs)
        fs.deps.resolve = function(p) return "/home/" .. p end
      end },
    ok_result("/home/x", { "/home", "/home/x", "/home/x/bin", "/home/x/lib",
      "/home/x/lib/html" }) },
  { "--dry-run lists the files and writes nothing",
    { args = { "--dry-run" }, fs = { dirs = { "/home" } } },
    expect(0, 0, { HEADER, "/home/bin/html.lua 14 bytes",
      "/home/lib/html/guard.lua 10 bytes", "dry run: would install 2 files" },
      {}, {}, { "/home" }) },
  { "upgrade replaces the old files and leaves no .old or .new",
    { old = true }, ok_result("/home", OLD_DIRS) },
  { "a stale .old file is replaced",
    { old = true,
      hook = function(fs) fs.files["/home/bin/html.lua.old"] = "stale" end },
    ok_result("/home", OLD_DIRS) },
  { "free space equal to the need is enough",
    { old = true, fs = { free = NEED } }, ok_result("/home", OLD_DIRS) },
}, installer_run)

-- The state after a failure that keeps the old files.
local function old_state(writes, out, err)
  return expect(1, writes, out, err, OLD, OLD_DIRS)
end

local function help_out()
  return { template_module().USAGE }
end

-- spec/installer.md "Behavior": checks before any write (no suffix),
-- failures after writing started ("; old files kept"), exit codes 1 and 2.
t.cases(T, "installer_failures", {
  { "free space one byte short",
    { old = true, fs = { free = NEED - 1 } },
    old_state(0, { HEADER }, { "html-install: not enough space for "
      .. "/home/bin/html.lua: need " .. NEED .. " bytes, " .. (NEED - 1)
      .. " bytes free" }) },
  { "free space one byte short with --dry-run",
    { args = { "--dry-run" }, fs = { free = 10 } },
    expect(1, 0, { HEADER }, { "html-install: not enough space for "
      .. "/home/bin/html.lua: need " .. NEED .. " bytes, 10 bytes free" },
      {}, {}) },
  { "read-only filesystem",
    { old = true, fs = { read_only = true } },
    old_state(0, { HEADER },
      { "html-install: read-only filesystem: /home/bin/html.lua" }) },
  { "a directory is in the way",
    { fs = { dirs = { "/home/bin/html.lua" } } },
    expect(1, 0, {}, { "html-install: a directory is in the way: "
      .. "/home/bin/html.lua" }, {}, { "/home/bin/html.lua" }) },
  { "embedded size differs from the recorded size",
    { sizes = { ["bin/html.lua"] = 99 } },
    expect(1, 0, {}, { "html-install: embedded file bin/html.lua has 14 "
      .. "bytes, expected 99 (download again)" }, {}, {}) },
  { "a parent of the first file is a file (no write yet, no suffix)",
    { fs = { files = { ["/home/bin"] = "x" }, dirs = { "/home" } } },
    expect(1, 0, { HEADER }, { "html-install: not a directory: /home/bin" },
      { ["/home/bin"] = "x" }, { "/home" }) },
  { "the first folder cannot be made (no write yet, no suffix)",
    { fs = { files = { ["/home"] = "x" } } },
    expect(1, 0, { HEADER }, { "html-install: cannot create /home/bin "
      .. "(file in the way)" }, { ["/home"] = "x" }, {}) },
  { "a parent of a later file is a file (after the first write)",
    { fs = { files = { ["/home/lib/html"] = "x" },
        dirs = { "/home", "/home/lib" } } },
    expect(1, 1, { HEADER }, { "html-install: not a directory: "
      .. "/home/lib/html; old files kept" }, { ["/home/lib/html"] = "x" },
      { "/home", "/home/bin", "/home/lib" }) },
  { "a later folder cannot be made (after the first write)",
    { fs = { files = { ["/home/lib"] = "x" }, dirs = { "/home" } } },
    expect(1, 1, { HEADER }, { "html-install: cannot create "
      .. "/home/lib/html (file in the way); old files kept" },
      { ["/home/lib"] = "x" }, { "/home", "/home/bin" }) },
  { "the first write fails",
    { old = true,
      fs = { fail_write = function(p) return p:find("bin") end } },
    old_state(0, { HEADER }, { "html-install: cannot write "
      .. "/home/bin/html.lua.new (disk error); old files kept" }) },
  { "a later write fails, temporary files are removed",
    { old = true,
      fs = { fail_write = function(p) return p:find("guard") end } },
    old_state(1, { HEADER }, { "html-install: cannot write "
      .. "/home/lib/html/guard.lua.new (disk error); old files kept" }) },
  { "read-back differs",
    { old = true,
      fs = { corrupt = function(p) return p:find("%.new$") end } },
    old_state(1, { HEADER }, { "html-install: read-back differs: "
      .. "/home/bin/html.lua.new; old files kept" }) },
  { "moving an old file aside fails, old files are put back",
    { old = true, fs = { fail_rename = function(a)
      return a == "/home/lib/html/guard.lua"
    end } },
    old_state(2, { HEADER }, { "html-install: cannot move "
      .. "/home/lib/html/guard.lua (rename error); old files kept" }) },
  { "renaming a new file in place fails, old files are put back",
    { old = true, fs = { fail_rename = function(a)
      return a == "/home/lib/html/guard.lua.new"
    end } },
    old_state(2, { HEADER }, { "html-install: cannot rename "
      .. "/home/lib/html/guard.lua.new (rename error); old files kept" }) },
  { "an unexpected error is one line",
    { hook = function(fs)
      fs.deps.space = function() error("boom\nmore", 0) end
    end },
    expect(1, 0, { HEADER }, { "html-install: unexpected error: boom" },
      {}, {}) },
  { "an unexpected error after writing started keeps the old files",
    { old = true, hook = function(fs)
      local exists = fs.deps.exists
      fs.deps.exists = function(p)
        if fs.writes >= 2 then
          error("boom\nmore", 0)
        end
        return exists(p)
      end
    end },
    expect(1, 2, { HEADER }, { "html-install: unexpected error: boom; "
      .. "old files kept" }, { ["/home/bin/html.lua"] = "old html\n",
      ["/home/lib/html/guard.lua"] = "old guard\n",
      ["/home/bin/html.lua.new"] = BIN,
      ["/home/lib/html/guard.lua.new"] = GUARD }, OLD_DIRS) },
  { "unknown option exits 2", { args = { "--nope" } },
    expect(2, 0, {}, { "html-install: unknown argument: --nope "
      .. "(see html-install --help)" }, {}, {}) },
  { "--prefix without a value exits 2", { args = { "--prefix" } },
    expect(2, 0, {}, { "html-install: --prefix needs a directory "
      .. "(see html-install --help)" }, {}, {}) },
  { "--prefix with an empty value exits 2", { args = { "--prefix", "" } },
    expect(2, 0, {}, { "html-install: --prefix needs a directory "
      .. "(see html-install --help)" }, {}, {}) },
  { "a bare word exits 2", { args = { "x" } },
    expect(2, 0, {}, { "html-install: unknown argument: x "
      .. "(see html-install --help)" }, {}, {}) },
  { "--help prints the usage", { args = { "--help" } },
    expect(0, 0, help_out(), {}, {}, {}) },
}, installer_run)

-- Generator: spec/installer.md "How it is built".

local TRICKY = {
  "", "\n", "\n\nx\n", "a]]b", "]]", "]=]", "x]", "x]=", "x]==", "]==]=]",
  "[[", "[==[", "end]]\n", "\0\1\255", "]=]==]===]",
}

local function tricky_rows()
  local rows = {}
  for _, s in ipairs(TRICKY) do
    rows[#rows + 1] = { string.format("%q", s), s, s }
  end
  return rows
end

t.cases(T, "installer_long_string_round_trip", tricky_rows(), function(s)
  local literal = assert(mk.long_string(s))
  return assert(load("return " .. literal))()
end)

-- The level is the lowest whose close bracket first appears at the end of
-- content .. close. A carriage return is refused.
t.cases(T, "installer_long_string_literal", {
  { "no bracket", "a", "[[\na]]" },
  { "content ends in ]=, the end still closes", "a]=", "[[\na]=]]" },
  { "content ends in ]", "a]", "[=[\na]]=]" },
  { "content ends in ]]", "a]]", "[=[\na]]]=]" },
  { "content holds ]=] and ]] joins its end", "a]=]", "[==[\na]=]]==]" },
  { "CRLF refused", "a\r\nb", "refused: carriage return" },
  { "CR alone refused", "\r", "refused: carriage return" },
  { "CR inside refused", "a\rb", "refused: carriage return" },
}, function(s)
  local literal, why = mk.long_string(s)
  if literal then
    return literal
  end
  return why:find("carriage return", 1, true) and "refused: carriage return"
    or why
end)

local TEMPLATE = assert(t.read_repo("tools/installer.lua"))

local function sample_list()
  local list = {}
  for path, content in pairs(SAMPLE) do
    list[#list + 1] = { path = path, content = content }
  end
  table.sort(list, function(a, b) return a.path < b.path end)
  return list
end

function T.build_embeds_files_exactly_and_installs()
  local files = sample_list()
  for i, s in ipairs(TRICKY) do
    files[#files + 1] = { path = "lib/html/t" .. i .. ".lua", content = s }
  end
  local source = assert(mk.build(TEMPLATE, "1.2.3b", files))
  local M = assert(load(source, "=installer", "t"))({})
  t.eq(M.VERSION, "1.2.3b")
  local want, sizes = {}, {}
  for _, f in ipairs(files) do
    want[f.path] = f.content
    sizes[f.path] = #f.content
  end
  t.eq(M.files, want)
  t.eq(M.sizes, sizes)
  -- The built module installs on a fake filesystem.
  local fs = fake_fs()
  t.eq(M.main({ n = 0 }, fs.deps), 0)
  for path, content in pairs(want) do
    t.eq(fs.files["/home/" .. path], content, path)
  end
  t.eq(fs.out[1], "html-install: oc-html 1.2.3b")
end

local OK_FILE = { path = "bin/a.lua", content = "x" }

-- Input: { template, version, files, text the reason holds }.
t.cases(T, "installer_build_refuses", {
  { "bad version", { TEMPLATE, "1.2", { OK_FILE }, "bad version" },
    "refused" },
  { "no marker", { "no marker", "1.2.3", { OK_FILE }, "marker" },
    "refused" },
  { "two markers",
    { TEMPLATE .. "\n" .. mk.MARKER .. "\n", "1.2.3", { OK_FILE }, "marker" },
    "refused" },
  { "path with ..",
    { TEMPLATE, "1.2.3", { { path = "../x", content = "" } }, "bad path" },
    "refused" },
  { "absolute path",
    { TEMPLATE, "1.2.3", { { path = "/x", content = "" } }, "bad path" },
    "refused" },
  { "duplicate path",
    { TEMPLATE, "1.2.3", { OK_FILE, OK_FILE }, "duplicate" }, "refused" },
  { "carriage return",
    { TEMPLATE, "1.2.3", { { path = "a", content = "x\r\n" } },
      "carriage return" }, "refused" },
  { "content is not a string",
    { TEMPLATE, "1.2.3", { { path = "a", content = 5 } }, "not a string" },
    "refused" },
}, function(input)
  local source, why = mk.build(input[1], input[2], input[3])
  if source then
    return "built"
  end
  if why:find(input[4], 1, true) then
    return "refused"
  end
  return why
end)

-- Release installers.

local function lines_of(s)
  local list = {}
  for line in s:gmatch("([^\n]*)\n") do
    if line ~= "" then
      list[#list + 1] = line
    end
  end
  return list
end

-- Loads an installer source with fake OpenOS modules and returns its
-- game_deps().write. fail names the file call that fails.
local function game_write(source, fail)
  local function step(name)
    return function(self)
      if name == fail then
        return nil, "not enough space"
      end
      -- OpenOS close returns no values on success (measured).
      if name == "close" then
        return
      end
      return self
    end
  end
  local env = {
    table = table, string = string, type = type, pairs = pairs,
    ipairs = ipairs, tostring = tostring, error = error, pcall = pcall,
    math = math,
    require = function() return {} end,
    io = { open = function()
      return { write = step("write"), flush = step("flush"),
        close = step("close") }
    end },
  }
  local M = assert(load(source, "=installer", "t", env))({})
  return M.game_deps().write
end

-- A close with no values is a success. A failed write, flush or close is a
-- failure. 0.1.0a is frozen with the old write; 0.1.1a is the first fixed
-- release.
local function game_write_rows()
  local sources = { { "template", TEMPLATE } }
  local released = t.read_repo("releases/0.1.1a/html-install.lua")
  if released then
    sources[#sources + 1] = { "0.1.1a", released }
  end
  local rows = {}
  for _, s in ipairs(sources) do
    rows[#rows + 1] = { s[1] .. " no failure", { s[2], false }, "true" }
    for _, fail in ipairs({ "write", "flush", "close" }) do
      rows[#rows + 1] = { s[1] .. " " .. fail .. " fails", { s[2], fail },
        "nil: not enough space" }
    end
  end
  return rows
end

t.cases(T, "installer_game_write", game_write_rows(), function(input)
  local ok, why = game_write(input[1], input[2] or nil)("/home/x.new", "x")
  if ok then
    return tostring(ok)
  end
  return "nil: " .. tostring(why)
end)

function T.release_installers_match_release_files()
  local checked = 0
  for _, v in ipairs(t.release_versions()) do
    local dir = "releases/" .. v .. "/"
    local source = t.read_repo(dir .. "html-install.lua")
    if source then
      checked = checked + 1
      local M = assert(load(source, "=" .. v, "t"))({})
      t.eq(M.VERSION, v)
      local want, sizes = {}, {}
      for _, path in ipairs(lines_of(assert(t.read_repo(dir .. "files.txt")))) do
        want[path] = assert(t.read_repo(dir .. path), path)
        sizes[path] = #want[path]
      end
      t.eq(M.files, want, v .. " files")
      t.eq(M.sizes, sizes, v .. " sizes")
      local fs = fake_fs()
      t.eq(M.main({ n = 0 }, fs.deps), 0, v .. " install")
      for path, content in pairs(want) do
        t.eq(fs.files["/home/" .. path], content, v .. " " .. path)
      end
      t.eq(fs.out[#fs.out], "installed " .. #lines_of(t.read_repo(dir
        .. "files.txt")) .. " files")
    end
  end
  if checked == 0 then
    t.skip("no release has html-install.lua yet")
  end
end

return T
