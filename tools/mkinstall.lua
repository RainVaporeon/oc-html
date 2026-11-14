-- mkinstall: builds the one-file installer of a release.
-- Run in the container, from the project root:
--   lua5.3 tools/mkinstall.lua <version> <release dir>
--     writes the installer source to stdout
--   lua5.3 tools/mkinstall.lua --check <version> <release dir>
--     checks <release dir>/html-install.lua against files.txt
-- Loaded with a table as the first argument, the chunk returns its module
-- table M without running. The tests use this.

local M = {}

M.MARKER = "-- @@FILES@@"
M.TEMPLATE = "tools/installer.lua"
M.INSTALLER = "html-install.lua"
-- Higher levels are never needed for real files.
local MAX_LEVEL = 32

local function is_version(v)
  return type(v) == "string" and v:find("^%d+%.%d+%.%d+[ab]?$") ~= nil
end

local function is_rel_path(p)
  if type(p) ~= "string" or not p:find("^[%w_][%w_./-]*$") then
    return false
  end
  for part in p:gmatch("[^/]+") do
    if part == "." or part == ".." then
      return false
    end
  end
  return p:sub(-1) ~= "/" and not p:find("//", 1, true)
end

-- Returns content as a long-bracket literal, or nil and a reason.
-- Lua turns "\r", "\r\n" and "\n\r" in a long string into "\n", so "\r" is
-- refused. Lua drops one newline right after the opening bracket, so the
-- literal always has one there.
function M.long_string(content)
  if type(content) ~= "string" then
    return nil, "content is not a string"
  end
  if content:find("\r", 1, true) then
    return nil, "content has a carriage return (byte 13)"
  end
  for level = 0, MAX_LEVEL do
    local eq = string.rep("=", level)
    local close = "]" .. eq .. "]"
    -- The first close bracket must be the one after the content. A content
    -- end such as "]=" can join the close bracket and end it early.
    if (content .. close):find(close, 1, true) == #content + 1 then
      return "[" .. eq .. "[\n" .. content .. close
    end
  end
  return nil, "no long-bracket level up to " .. MAX_LEVEL .. " fits"
end

-- template: the installer template source.
-- files: a list of { path = <relative path>, content = <string> }.
-- Returns the installer source, or nil and a reason.
function M.build(template, version, files)
  if not is_version(version) then
    return nil, "bad version: " .. tostring(version)
  end
  if type(template) ~= "string" then
    return nil, "template is not a string"
  end
  local at = template:find(M.MARKER, 1, true)
  if not at or template:find(M.MARKER, at + 1, true) then
    return nil, "template must have the marker line exactly once"
  end
  local out = { string.format("M.VERSION = %q", version) }
  local seen = {}
  for _, file in ipairs(files) do
    if not is_rel_path(file.path) then
      return nil, "bad path: " .. tostring(file.path)
    end
    if seen[file.path] then
      return nil, "duplicate path: " .. file.path
    end
    seen[file.path] = true
    local literal, why = M.long_string(file.content)
    if not literal then
      return nil, file.path .. ": " .. why
    end
    out[#out + 1] = string.format("M.sizes[%q] = %d", file.path,
      #file.content)
    out[#out + 1] = string.format("M.files[%q] = ", file.path) .. literal
  end
  local source = template:sub(1, at - 1) .. table.concat(out, "\n")
    .. template:sub(at + #M.MARKER)
  -- The installer must give back each file exactly.
  local chunk, err = load(source, "=" .. M.INSTALLER, "t", {
    table = table, string = string, type = type, pairs = pairs,
    ipairs = ipairs, tostring = tostring, error = error, pcall = pcall,
    math = math,
  })
  if not chunk then
    return nil, "installer does not load: " .. tostring(err)
  end
  local ok, mod = pcall(chunk, {})
  if not ok or type(mod) ~= "table" or mod.VERSION ~= version then
    return nil, "installer does not return its module: " .. tostring(mod)
  end
  local count = 0
  for path, content in pairs(mod.files) do
    count = count + 1
    if not seen[path] then
      return nil, "installer has an extra file: " .. tostring(path)
    end
    if content ~= M.content_of(files, path) then
      return nil, "embedded copy differs: " .. path
    end
  end
  if count ~= #files then
    return nil, "installer has " .. count .. " files, expected " .. #files
  end
  return source
end

function M.content_of(files, path)
  for _, file in ipairs(files) do
    if file.path == path then
      return file.content
    end
  end
end

local function read(path)
  local f, err = io.open(path, "rb")
  if not f then
    error("mkinstall: cannot read " .. tostring(err), 0)
  end
  local s = f:read("a")
  f:close()
  return s
end

-- Reads files.txt of a release and the files it lists.
local function release_files(dir)
  local files = {}
  for line in read(dir .. "/files.txt"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      if not is_rel_path(line) then
        error("mkinstall: bad path in files.txt: " .. line, 0)
      end
      files[#files + 1] = { path = line, content = read(dir .. "/" .. line) }
    end
  end
  if #files == 0 then
    error("mkinstall: files.txt lists no files", 0)
  end
  return files
end

-- Loads <dir>/html-install.lua and compares its files with files.txt.
local function check(version, dir)
  local files = release_files(dir)
  local chunk, err = load(read(dir .. "/" .. M.INSTALLER),
    "=" .. M.INSTALLER, "t", _ENV)
  if not chunk then
    error("mkinstall: installer does not load: " .. tostring(err), 0)
  end
  local mod = chunk({})
  if mod.VERSION ~= version then
    error("mkinstall: installer version is " .. tostring(mod.VERSION), 0)
  end
  local count = 0
  for path, content in pairs(mod.files) do
    count = count + 1
    local want = M.content_of(files, path)
    if want == nil then
      error("mkinstall: installer has a file not in files.txt: " .. path, 0)
    end
    if content ~= want then
      error("mkinstall: embedded copy differs from the release: " .. path, 0)
    end
    if mod.sizes[path] ~= #want then
      error("mkinstall: size entry differs: " .. path, 0)
    end
  end
  if count ~= #files then
    error("mkinstall: installer has " .. count .. " files, files.txt lists "
      .. #files, 0)
  end
  print("mkinstall: " .. M.INSTALLER .. " matches files.txt (" .. count
    .. " files)")
end

local function program(args)
  if args[1] == "--check" and args.n == 3 then
    check(args[2], args[3])
    return
  end
  if args.n ~= 2 then
    error("usage: lua5.3 tools/mkinstall.lua [--check] <version> <release dir>",
      0)
  end
  local source, why = M.build(read(M.TEMPLATE), args[1],
    release_files(args[2]))
  if not source then
    error("mkinstall: " .. why, 0)
  end
  io.write(source)
end

local args = table.pack(...)
if type(args[1]) == "table" then
  return M
end
local ok, err = pcall(program, args)
if not ok then
  io.stderr:write(tostring(err), "\n")
  os.exit(1)
end
