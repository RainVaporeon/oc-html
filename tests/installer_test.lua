-- Tests for the installer template (tools/installer.lua), its generator
-- (tools/mkinstall.lua) and the installers in releases/.

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

local function run(M, fs, args)
  args = args or {}
  args.n = #args
  return M.main(args, fs.deps)
end

-- Paths in fs that end with .new or .old.
local function leftovers(fs)
  local found = {}
  for p in pairs(fs.files) do
    if p:find("%.new$") or p:find("%.old$") then
      found[#found + 1] = p
    end
  end
  table.sort(found)
  return found
end

local OLD = {
  ["/home/bin/html.lua"] = "old html\n",
  ["/home/lib/html/guard.lua"] = "old guard\n",
}

local function old_fs(opts)
  opts.files = OLD
  opts.dirs = { "/home", "/home/bin", "/home/lib", "/home/lib/html" }
  return fake_fs(opts)
end

local function assert_old_kept(fs)
  t.eq(fs.files, OLD, "old files kept, nothing else left")
end

-- Template: main with a fake filesystem.

function T.installs_into_default_prefix()
  local fs = fake_fs({ dirs = { "/home" } })
  t.eq(run(template_module(), fs), 0)
  t.eq(fs.files, {
    ["/home/bin/html.lua"] = SAMPLE["bin/html.lua"],
    ["/home/lib/html/guard.lua"] = SAMPLE["lib/html/guard.lua"],
  })
  t.eq(fs.out, {
    "html-install: oc-html 9.9.9a",
    "/home/bin/html.lua 14 bytes",
    "/home/lib/html/guard.lua 10 bytes",
    "installed 2 files",
  })
  t.eq(fs.err, {})
end

function T.prefix_option()
  local fs = fake_fs()
  t.eq(run(template_module(), fs, { "--prefix", "/mnt/ab/" }), 0)
  t.eq(fs.files["/mnt/ab/bin/html.lua"], SAMPLE["bin/html.lua"])
  t.eq(fs.out[#fs.out], "installed 2 files")
end

function T.relative_prefix_is_resolved()
  local fs = fake_fs()
  fs.deps.resolve = function(p) return "/home/" .. p end
  t.eq(run(template_module(), fs, { "--prefix", "x" }), 0)
  t.ok(fs.files["/home/x/bin/html.lua"], "resolved")
end

function T.dry_run_writes_nothing()
  local fs = fake_fs({ dirs = { "/home" } })
  t.eq(run(template_module(), fs, { "--dry-run" }), 0)
  t.eq(fs.writes, 0)
  t.eq(fs.files, {})
  t.eq(fs.dirs["/home/bin"], nil, "no directory made")
  t.eq(fs.out[#fs.out], "dry run: would install 2 files")
end

function T.upgrade_replaces_old_files()
  local fs = old_fs({})
  t.eq(run(template_module(), fs), 0)
  t.eq(fs.files["/home/bin/html.lua"], SAMPLE["bin/html.lua"])
  t.eq(fs.files["/home/lib/html/guard.lua"], SAMPLE["lib/html/guard.lua"])
  t.eq(leftovers(fs), {})
end

function T.stale_old_file_is_replaced()
  local fs = old_fs({})
  fs.files["/home/bin/html.lua.old"] = "stale"
  t.eq(run(template_module(), fs), 0)
  t.eq(leftovers(fs), {})
end

function T.short_space_stops_before_writing()
  -- Need: 14 + 10 + 2 * 1024 margin + 14 for the largest temporary copy.
  local need = 14 + 10 + 2 * 1024 + 14
  local fs = old_fs({ free = need - 1 })
  t.eq(run(template_module(), fs), 1)
  t.eq(fs.writes, 0)
  t.eq(fs.err, { "html-install: not enough space for /home/bin/html.lua: need "
    .. need .. " bytes, " .. (need - 1) .. " bytes free" })
  assert_old_kept(fs)
  fs = old_fs({ free = need })
  t.eq(run(template_module(), fs), 0)
end

function T.short_space_stops_dry_run_too()
  local fs = fake_fs({ free = 10 })
  t.eq(run(template_module(), fs, { "--dry-run" }), 1)
  t.eq(#fs.err, 1)
end

function T.read_only_filesystem_stops()
  local fs = old_fs({ read_only = true })
  t.eq(run(template_module(), fs), 1)
  t.eq(fs.err, { "html-install: read-only filesystem: /home/bin/html.lua" })
  assert_old_kept(fs)
end

function T.write_failure_keeps_old_files()
  local fs = old_fs({ fail_write = function(p) return p:find("guard") end })
  t.eq(run(template_module(), fs), 1)
  t.eq(#fs.err, 1)
  t.ok(fs.err[1]:find("^html%-install: cannot write /home/lib/html/guard%.lua%.new"),
    fs.err[1])
  assert_old_kept(fs)
end

function T.read_back_difference_keeps_old_files()
  local fs = old_fs({ corrupt = function(p) return p:find("%.new$") end })
  t.eq(run(template_module(), fs), 1)
  t.eq(fs.err, { "html-install: read-back differs: /home/bin/html.lua.new; "
    .. "old files kept" })
  assert_old_kept(fs)
end

function T.rename_failure_puts_old_files_back()
  local fs = old_fs({ fail_rename = function(a)
    return a == "/home/lib/html/guard.lua.new"
  end })
  t.eq(run(template_module(), fs), 1)
  t.eq(#fs.err, 1)
  t.ok(fs.err[1]:find("^html%-install: cannot rename "), fs.err[1])
  assert_old_kept(fs)
end

function T.directory_in_the_way_stops()
  local fs = fake_fs({ dirs = { "/home/bin/html.lua" } })
  t.eq(run(template_module(), fs), 1)
  t.eq(fs.err, { "html-install: a directory is in the way: /home/bin/html.lua" })
end

function T.size_mismatch_stops()
  local M = template_module()
  M.sizes["bin/html.lua"] = 99
  local fs = fake_fs()
  t.eq(run(M, fs), 1)
  t.ok(fs.err[1]:find("expected 99 %(download again%)$"), fs.err[1])
  t.eq(fs.writes, 0)
end

function T.unexpected_error_is_one_line()
  local fs = fake_fs()
  fs.deps.space = function() error("boom\nmore") end
  t.eq(run(template_module(), fs), 1)
  t.eq(#fs.err, 1)
  t.ok(fs.err[1]:find("^html%-install: unexpected error: .*boom$"), fs.err[1])
end

function T.bad_arguments_and_help()
  local M = template_module()
  for _, args in ipairs({ { "--nope" }, { "--prefix" }, { "x" } }) do
    local fs = fake_fs()
    t.eq(run(M, fs, args), 2)
    t.eq(#fs.err, 1)
    t.ok(fs.err[1]:find("^html%-install: "), fs.err[1])
  end
  local fs = fake_fs()
  t.eq(run(M, fs, { "--help" }), 0)
  t.eq(fs.out, { M.USAGE })
end

-- Generator.

local TRICKY = {
  "", "\n", "\n\nx\n", "a]]b", "]]", "]=]", "x]", "x]=", "x]==", "]==]=]",
  "[[", "[==[", "end]]\n", "\0\1\255", "]=]==]===]",
}

function T.long_string_round_trip()
  for _, s in ipairs(TRICKY) do
    local literal = assert(mk.long_string(s))
    local back = assert(load("return " .. literal))()
    t.eq(back, s, "content " .. s)
  end
end

function T.long_string_level_avoids_content()
  t.eq(mk.long_string("a"), "[[\na]]")
  -- "a]=" followed by "]]" still closes at the end.
  t.eq(mk.long_string("a]="), "[[\na]=]]")
  t.eq(mk.long_string("a]"), "[=[\na]]=]")
  t.eq(mk.long_string("a]]"), "[=[\na]]]=]")
  -- "]=]" is in the content, and "]]" joins its end, so level 2 is used.
  t.eq(mk.long_string("a]=]"), "[==[\na]=]]==]")
end

function T.long_string_refuses_carriage_return()
  for _, s in ipairs({ "a\r\nb", "\r", "a\rb" }) do
    local literal, why = mk.long_string(s)
    t.eq(literal, nil)
    t.ok(why:find("carriage return"), why)
  end
end

local TEMPLATE = assert(t.read_repo("tools/installer.lua"))

local function sample_list()
  local list = {}
  for path, content in pairs(SAMPLE) do
    list[#list + 1] = { path = path, content = content }
  end
  table.sort(list, function(a, b) return a.path < b.path end)
  return list
end

function T.build_embeds_files_exactly()
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
end

function T.built_installer_installs()
  local source = assert(mk.build(TEMPLATE, "1.2.3b", sample_list()))
  local M = assert(load(source, "=installer", "t"))({})
  local fs = fake_fs()
  t.eq(run(M, fs), 0)
  t.eq(fs.files["/home/bin/html.lua"], SAMPLE["bin/html.lua"])
  t.eq(fs.out[1], "html-install: oc-html 1.2.3b")
end

function T.build_refuses_bad_input()
  local ok_file = { path = "bin/a.lua", content = "x" }
  local cases = {
    { TEMPLATE, "1.2", { ok_file }, "bad version" },
    { "no marker", "1.2.3", { ok_file }, "marker" },
    { TEMPLATE .. "\n" .. mk.MARKER .. "\n", "1.2.3", { ok_file }, "marker" },
    { TEMPLATE, "1.2.3", { { path = "../x", content = "" } }, "bad path" },
    { TEMPLATE, "1.2.3", { { path = "/x", content = "" } }, "bad path" },
    { TEMPLATE, "1.2.3", { ok_file, ok_file }, "duplicate" },
    { TEMPLATE, "1.2.3", { { path = "a", content = "x\r\n" } },
      "carriage return" },
    { TEMPLATE, "1.2.3", { { path = "a", content = 5 } }, "not a string" },
  }
  for i, c in ipairs(cases) do
    local source, why = mk.build(c[1], c[2], c[3])
    t.eq(source, nil, "case " .. i)
    t.ok(why:find(c[4], 1, true), "case " .. i .. ": " .. why)
  end
end

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

function T.game_write_accepts_close_without_values()
  local sources = { assert(t.read_repo("tools/installer.lua")) }
  -- 0.1.0a is frozen with the old write. 0.1.1a is the first fixed release.
  local source = t.read_repo("releases/0.1.1a/html-install.lua")
  if source then
    sources[#sources + 1] = source
  end
  for _, s in ipairs(sources) do
    local write = game_write(s, nil)
    t.eq({ write("/home/x.new", "x") }, { true })
    for _, fail in ipairs({ "write", "flush", "close" }) do
      write = game_write(s, fail)
      t.eq({ write("/home/x.new", "x") }, { nil, "not enough space" }, fail)
    end
  end
end

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
      t.eq(run(M, fs), 0, v .. " install")
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
