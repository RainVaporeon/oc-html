-- html-install: installs the oc-html files that this script holds.
-- Usage: html-install [--prefix <dir>] [--dry-run]
-- This file is the template. tools/mkinstall.lua puts the release files in
-- place of the FILES marker and writes releases/<version>/html-install.lua.
-- Loaded with a table as the first argument, the chunk returns its module
-- table M without running. The tests use this.

local M = {}

M.VERSION = "dev"
-- Relative path to file content.
M.files = {}
-- Relative path to content size in bytes. A short download changes a size.
M.sizes = {}
-- @@FILES@@

M.DEFAULT_PREFIX = "/home"
-- Room kept free per file, because a file can take more disk space than its
-- content.
local SPACE_MARGIN = 1024
local NEW_SUFFIX = ".new"
local OLD_SUFFIX = ".old"

M.USAGE = [[
Usage: html-install [--prefix <dir>] [--dry-run]
Installs oc-html into <dir>/bin and <dir>/lib/html (default: /home).
Options:
  --prefix <dir>  install below this directory
  --dry-run       check and show the files, write nothing
  --help          show this help]]

-- Returns an options table, or nil and an error message.
function M.parse_args(argv)
  local opts = { prefix = M.DEFAULT_PREFIX }
  local i, count = 1, argv.n or #argv
  while i <= count do
    local a = tostring(argv[i])
    if a == "--help" or a == "-h" then
      opts.help = true
    elseif a == "--dry-run" then
      opts.dry_run = true
    elseif a == "--prefix" then
      i = i + 1
      local p = argv[i]
      if type(p) ~= "string" or p == "" then
        return nil, "html-install: --prefix needs a directory"
      end
      opts.prefix = p
    else
      return nil, "html-install: unknown argument: " .. a
    end
    i = i + 1
  end
  return opts
end

local function sorted_paths()
  local paths = {}
  for path in pairs(M.files) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  return paths
end

local function join(prefix, rel)
  prefix = prefix:gsub("/+$", "")
  return prefix .. "/" .. rel
end

local function dir_of(path)
  return path:match("^(.*)/[^/]*$") or ""
end

-- Raises a controlled error: a string with the prefix "html-install: ".
-- main prints it as it is.
local function fail(msg)
  error("html-install: " .. msg, 0)
end

-- Checks the space on each target filesystem. Each file needs its size,
-- the largest file is also needed once for the temporary copy, and a
-- margin per file. Old files that the install replaces are not counted.
local function check_space(plan, deps)
  local by_fs, order = {}, {}
  for _, item in ipairs(plan) do
    local info = deps.space(item.target)
    if not info then
      fail("no filesystem for " .. item.target)
    end
    if info.read_only then
      fail("read-only filesystem: " .. item.target)
    end
    local key = info.id or "?"
    local g = by_fs[key]
    if not g then
      g = { info = info, need = 0, largest = 0, first = item.target }
      by_fs[key] = g
      order[#order + 1] = key
    end
    g.need = g.need + item.size + SPACE_MARGIN
    if item.size > g.largest then
      g.largest = item.size
    end
  end
  for _, key in ipairs(order) do
    local g = by_fs[key]
    local free = g.info.free
    local need = g.need + g.largest
    if free and free < need then
      fail("not enough space for " .. g.first .. ": need " .. need
        .. " bytes, " .. free .. " bytes free")
    end
  end
end

local function call(deps, name, ...)
  local ok, a, b = pcall(deps[name], ...)
  if not ok then
    return nil, tostring(a):match("^[^\n]*")
  end
  return a, b
end

-- Phase 1: writes every file to <target>.new and compares the read-back
-- copy with the embedded content. Returns the temporary paths written and
-- a failure reason. state.started becomes true at the first write.
local function write_temps(plan, deps, state)
  local written = {}
  for _, item in ipairs(plan) do
    local dir = dir_of(item.target)
    if dir ~= "" and not deps.is_dir(dir) then
      if deps.exists(dir) then
        return written, "not a directory: " .. dir
      end
      local ok, why = call(deps, "make_dir", dir)
      if not ok then
        return written, "cannot create " .. dir .. " (" .. tostring(why) .. ")"
      end
      state.started = true
    end
    state.started = true
    written[#written + 1] = item.temp
    local ok, why = call(deps, "write", item.temp, item.content)
    if not ok then
      return written, "cannot write " .. item.temp .. " (" .. tostring(why) .. ")"
    end
    local back = call(deps, "read", item.temp)
    if back ~= item.content then
      return written, "read-back differs: " .. item.temp
    end
  end
  return written
end

-- Phase 2: moves each old file to <target>.old and the new file in place.
-- On a failure, it puts the old files back.
local function swap(plan, deps)
  local done = {}
  local function undo()
    for i = #done, 1, -1 do
      local item = done[i]
      if item.had_old then
        call(deps, "remove", item.target)
        call(deps, "rename", item.old, item.target)
      else
        call(deps, "remove", item.target)
      end
    end
  end
  for _, item in ipairs(plan) do
    item.had_old = deps.exists(item.target)
    if item.had_old then
      if deps.exists(item.old) then
        call(deps, "remove", item.old)
      end
      local ok, why = call(deps, "rename", item.target, item.old)
      if not ok then
        undo()
        return "cannot move " .. item.target .. " (" .. tostring(why) .. ")"
      end
    end
    local ok, why = call(deps, "rename", item.temp, item.target)
    if not ok then
      if item.had_old then
        call(deps, "rename", item.old, item.target)
      end
      undo()
      return "cannot rename " .. item.temp .. " (" .. tostring(why) .. ")"
    end
    done[#done + 1] = item
  end
  for _, item in ipairs(done) do
    if item.had_old then
      call(deps, "remove", item.old)
    end
  end
end

-- state.started becomes true at the first write, so M.main can tell an
-- unexpected error that came after writing started.
local function install(opts, deps, state)
  local prefix = opts.prefix
  if deps.resolve then
    prefix = deps.resolve(prefix)
  end
  local plan = {}
  for _, rel in ipairs(sorted_paths()) do
    local content = M.files[rel]
    if M.sizes[rel] and #content ~= M.sizes[rel] then
      fail("embedded file " .. rel .. " has " .. #content
        .. " bytes, expected " .. M.sizes[rel] .. " (download again)")
    end
    local target = join(prefix, rel)
    if deps.is_dir(target) then
      fail("a directory is in the way: " .. target)
    end
    plan[#plan + 1] = {
      rel = rel, content = content, size = #content, target = target,
      temp = target .. NEW_SUFFIX, old = target .. OLD_SUFFIX,
    }
  end
  if #plan == 0 then
    fail("this installer holds no files")
  end
  deps.out("html-install: oc-html " .. M.VERSION)
  check_space(plan, deps)
  if opts.dry_run then
    for _, item in ipairs(plan) do
      deps.out(item.target .. " " .. item.size .. " bytes")
    end
    deps.out("dry run: would install " .. #plan .. " files")
    return
  end
  local written, why = write_temps(plan, deps, state)
  if why then
    for _, temp in ipairs(written) do
      call(deps, "remove", temp)
    end
    -- Before the first write nothing changed, so the line has no suffix.
    fail(state.started and why .. "; old files kept" or why)
  end
  why = swap(plan, deps)
  if why then
    for _, item in ipairs(plan) do
      if deps.exists(item.temp) then
        call(deps, "remove", item.temp)
      end
    end
    fail(why .. "; old files kept")
  end
  for _, item in ipairs(plan) do
    deps.out(item.target .. " " .. item.size .. " bytes")
  end
  deps.out("installed " .. #plan .. " files")
end

-- argv: the program arguments (a table, n is optional).
-- deps: the machine links:
--   out(line), err(line)    print to stdout and stderr
--   resolve(path)           optional, makes a path absolute
--   exists(path), is_dir(path)
--   make_dir(path)          creates a directory and its parents
--   read(path)              returns the content, or nil and a reason
--   write(path, content)    returns true, or nil and a reason
--   rename(from, to)        returns true, or nil and a reason
--   remove(path)
--   space(path)             returns { id, free, read_only } for the
--                           filesystem of path (free may be nil), or nil
-- Returns the exit code.
function M.main(argv, deps)
  local opts, msg = M.parse_args(argv)
  if not opts then
    deps.err(msg .. " (see html-install --help)")
    return 2
  end
  if opts.help then
    deps.out(M.USAGE)
    return 0
  end
  local state = {}
  local ok, e = pcall(install, opts, deps, state)
  if ok then
    return 0
  end
  if type(e) == "string" and e:sub(1, 14) == "html-install: " then
    deps.err(e)
  else
    deps.err("html-install: unexpected error: "
      .. tostring(e):match("^[^\n]*")
      .. (state.started and "; old files kept" or ""))
  end
  return 1
end

-- The links to OpenOS. Loaded only when the chunk runs as a program.
function M.game_deps()
  local filesystem = require("filesystem")
  local shell = require("shell")
  return {
    out = function(line) io.write(line, "\n") end,
    err = function(line) io.stderr:write(line, "\n") end,
    resolve = shell.resolve,
    exists = filesystem.exists,
    is_dir = filesystem.isDirectory,
    make_dir = function(path)
      local ok, why = filesystem.makeDirectory(path)
      if not ok and not filesystem.isDirectory(path) then
        return nil, why or "makeDirectory failed"
      end
      return true
    end,
    read = function(path)
      local f, why = io.open(path, "rb")
      if not f then
        return nil, why
      end
      local s = f:read("*a")
      f:close()
      return s
    end,
    write = function(path, content)
      local f, why = io.open(path, "wb")
      if not f then
        return nil, why
      end
      local done, werr = f:write(content)
      -- A full disk reports "not enough space" only at flush (measured).
      if done then
        done, werr = f:flush()
      end
      -- OpenOS close returns no values on success (measured). Only a
      -- reason is a failure.
      local _, cerr = f:close()
      if not done then
        return nil, werr or "write failed"
      end
      if cerr ~= nil then
        return nil, cerr
      end
      return true
    end,
    rename = function(from, to)
      local ok, why = filesystem.rename(from, to)
      if not ok then
        return nil, why or "rename failed"
      end
      return true
    end,
    remove = filesystem.remove,
    space = function(path)
      local proxy = filesystem.get(path)
      if not proxy then
        return nil
      end
      local free
      local total, used = proxy.spaceTotal(), proxy.spaceUsed()
      if type(total) == "number" and type(used) == "number"
        and total < math.huge then
        free = total - used
      end
      return { id = proxy.address, free = free, read_only = proxy.isReadOnly() }
    end,
  }
end

local argv = table.pack(...)
if type(argv[1]) == "table" then
  return M
end
return M.main(argv, M.game_deps())
