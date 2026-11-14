-- html: renders a local HTML file as text.
-- Run as a program: html [options] <file>
-- Loaded with a table as the first argument, the chunk returns its module
-- table M without running. The tests use this.

local guard = require("html.guard")
local tokenizer = require("html.tokenizer")
local layout = require("html.layout")

local M = {}

local find, gsub, sub = string.find, string.gsub, string.sub

-- Measured: io reads are fast at this size, and the tokenizer buffer stays
-- small.
local CHUNK = 4096
local ERROR_LOG = "/tmp/html-error.log"
-- /tmp is 64 KB.
local ERROR_LOG_MAX = 8192

M.USAGE = [[
Usage: html [options] <file>
Renders a local HTML file as text.
Options:
  --width <n>  wrap lines at n columns (default: screen width)
  --stats      print file size, line count, render time and free memory
  --help       show this help]]

-- Returns an options table, or nil and a controlled error message.
function M.parse_args(argv)
  local opts = {}
  local i, count = 1, argv.n or #argv
  while i <= count do
    local a = tostring(argv[i])
    if a == "--help" or a == "-h" then
      opts.help = true
    elseif a == "--stats" then
      opts.stats = true
    elseif a == "--width" then
      i = i + 1
      local w = math.tointeger(tonumber(argv[i]))
      if not w or w < 1 then
        return nil, "html: --width needs a positive whole number"
      end
      opts.width = w
    elseif #a > 1 and sub(a, 1, 1) == "-" then
      return nil, "html: unknown option: " .. a
    elseif opts.file then
      return nil, "html: too many arguments"
    else
      opts.file = a
    end
    i = i + 1
  end
  if not opts.file then
    opts.help = true
  end
  return opts
end

local function is_controlled(e)
  return type(e) == "string" and sub(e, 1, 6) == "html: "
end

-- Removes the style bytes.
local function plain(line)
  if find(line, "[\1-\5]") then
    return (gsub(line, "[\1-\5]", ""))
  end
  return line
end

-- Runs the tokenizer and layout over a reader. Returns the lines.
function M.render(read, width)
  local lay = layout.new(width)
  local next_token = tokenizer.new(read, lay.count)
  local push = lay.push
  while true do
    local kind, value, attrs, self_closing = next_token()
    if not kind then
      break
    end
    push(kind, value, attrs, self_closing)
  end
  return lay.finish()
end

local function run(f, size, opts, deps)
  local width = opts.width or deps.width
  local free_before = opts.stats and guard.settled_free()
  guard.reset()
  local clock0, wall0 = deps.clock(), deps.uptime and deps.uptime()
  local lines = M.render(function() return f:read(CHUNK) end, width)
  local clock1, wall1 = deps.clock(), deps.uptime and deps.uptime()
  local free_after = opts.stats and guard.settled_free()
  local out = deps.out
  for i = 1, #lines do
    guard.tick()
    out(plain(lines[i]))
  end
  if opts.stats then
    local err = deps.err
    local used = free_before - free_after
    err("stats: file=" .. tostring(size) .. " bytes")
    err("stats: width=" .. width)
    err("stats: lines=" .. #lines)
    err(string.format("stats: cpu=%.3f s", clock1 - clock0))
    if wall0 and wall1 then
      err(string.format("stats: wall=%.2f s", wall1 - wall0))
    end
    err("stats: free_before=" .. free_before .. " bytes")
    err("stats: free_after=" .. free_after .. " bytes")
    err(string.format("stats: used=%d bytes (%.1f per line)", used,
      used / math.max(1, #lines)))
  end
end

-- Returns the file size from deps.size, or from seek.
local function file_size(f, path, deps)
  if deps.size then
    return deps.size(path)
  end
  local size = f:seek("end")
  f:seek("set", 0)
  return size
end

-- argv: the program arguments (a table, n is optional).
-- deps: the machine links:
--   out(line), err(line)   print to stdout and stderr
--   width                  default wrap width
--   open(path, mode)       io.open
--   traceback(msg)         debug.traceback, or a fake in the tests
--   clock()                os.clock
--   uptime()               optional, wall time in seconds
--   resolve(path)          optional, makes a path absolute
--   is_dir(path)           optional
--   size(path)             optional, file size in bytes
--   log(text)              optional, keeps the details of an unexpected error
-- Returns the exit code.
function M.main(argv, deps)
  local opts, msg = M.parse_args(argv)
  if not opts then
    deps.err(msg .. " (see html --help)")
    return 2
  end
  if opts.help then
    deps.out(M.USAGE)
    return 0
  end
  local path = deps.resolve and deps.resolve(opts.file) or opts.file
  if deps.is_dir and deps.is_dir(path) then
    deps.err("html: not a file: " .. opts.file)
    return 1
  end
  local f = deps.open(path, "rb")
  if not f then
    deps.err("html: cannot open file: " .. opts.file)
    return 1
  end
  local traceback = deps.traceback
  local function handler(e)
    if is_controlled(e) then
      return e
    end
    return traceback(tostring(e), 2)
  end
  local ok, result = xpcall(function()
    run(f, file_size(f, path, deps), opts, deps)
  end, handler)
  f:close()
  if ok then
    return 0
  end
  if is_controlled(result) then
    deps.err(result)
    return 1
  end
  result = tostring(result)
  local first = result:match("^[^\n]*")
  if deps.log then
    deps.log(result)
    deps.err("html: unexpected error: " .. first .. " (details in "
      .. ERROR_LOG .. ")")
  else
    deps.err("html: unexpected error: " .. first)
  end
  return 1
end

-- The links to OpenOS. Loaded only when the chunk runs as a program.
function M.game_deps()
  local computer = require("computer")
  local filesystem = require("filesystem")
  local shell = require("shell")
  local term = require("term")
  local width = 80
  local ok, w = pcall(term.getViewport)
  if ok and math.tointeger(w) and w > 0 then
    width = w
  end
  return {
    out = function(line) io.write(line, "\n") end,
    err = function(line) io.stderr:write(line, "\n") end,
    width = width,
    open = io.open,
    traceback = debug.traceback,
    clock = os.clock,
    uptime = computer.uptime,
    resolve = shell.resolve,
    is_dir = filesystem.isDirectory,
    size = filesystem.size,
    log = function(text)
      if #text > ERROR_LOG_MAX then
        text = sub(text, -ERROR_LOG_MAX)
      end
      local f = io.open(ERROR_LOG, "w")
      if f then
        f:write(text)
        f:close()
      end
    end,
  }
end

local argv = table.pack(...)
if type(argv[1]) == "table" then
  return M
end
return M.main(argv, M.game_deps())
