-- html: renders a local HTML file as text.
-- Run as a program: html [options] <file>
-- Loaded with a table as the first argument, the chunk returns its module
-- table M without running. The tests use this.

-- OpenOS keeps required modules in package.loaded until a reboot. Removing
-- the html modules loads the current code after an update and frees their
-- memory after a run. Returns the number of removed modules.
local function clear_modules(loaded)
  if type(loaded) ~= "table" then
    return 0
  end
  local names = {}
  for name in pairs(loaded) do
    if type(name) == "string" and name:sub(1, 5) == "html." then
      names[#names + 1] = name
    end
  end
  for i = 1, #names do
    loaded[names[i]] = nil
  end
  return #names
end

local function package_loaded()
  if type(package) == "table" then
    return package.loaded
  end
  return nil
end

clear_modules(package_loaded())

local guard = require("html.guard")
local tokenizer = require("html.tokenizer")
local layout = require("html.layout")

local M = {}

M.clear_modules = clear_modules

local find, gsub, sub = string.find, string.gsub, string.sub

-- Measured: io reads are fast at this size, and the tokenizer buffer stays
-- small.
local CHUNK = 4096
local ERROR_LOG = "/tmp/html-error.log"
-- /tmp is 64 KB.
local ERROR_LOG_MAX = 8192
-- Used when the screen width is not known.
local DEFAULT_WIDTH = 80

M.USAGE = [[
Usage: html [options] <file>
Renders a local HTML file as text.
Options:
  --width <n>         wrap lines at n columns (default: screen width)
  --stats             print file size, line count, render time and memory
  --stats-out <path>  also write the stats lines to a file (sets --stats)
  --help              show this help]]

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
    elseif a == "--stats-out" then
      i = i + 1
      local p = argv[i]
      if type(p) ~= "string" or p == "" then
        return nil, "html: --stats-out needs a file path"
      end
      opts.stats = true
      opts.stats_out = p
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

-- Renders the file and prints the lines. Fills st with the stats values as
-- it goes, so a render that stops still has the values up to that point.
local function run(f, opts, deps, st)
  if opts.stats then
    st.free_before = guard.settled_free()
  end
  -- The lowest free reading starts here, after the settled reading.
  guard.reset()
  local clock0, wall0 = deps.clock(), deps.uptime and deps.uptime()
  local lines = M.render(function() return f:read(CHUNK) end, st.width)
  st.cpu = deps.clock() - clock0
  if wall0 then
    st.wall = deps.uptime() - wall0
  end
  st.lines = #lines
  if opts.stats then
    st.free_after = guard.settled_free()
  end
  local out = deps.out
  for i = 1, #lines do
    guard.tick()
    out(plain(lines[i]))
  end
end

local function per_line(bytes, lines)
  if lines then
    return string.format(" (%.1f per line)", bytes / math.max(1, lines))
  end
  return ""
end

local NA = "n/a"

local function is_num(v)
  return type(v) == "number"
end

-- A whole number as text, or "n/a".
local function int_text(v)
  if not is_num(v) then
    return NA
  end
  return tostring(math.tointeger(math.floor(v)) or v)
end

-- A missing value prints as "n/a", so a stats report never fails.
local function bytes_text(v)
  if is_num(v) then
    return int_text(v) .. " bytes"
  end
  return NA
end

local function seconds_text(fmt, v)
  if is_num(v) then
    return string.format(fmt, v) .. " s"
  end
  return NA
end

-- Returns the stats lines for the values in st. lowest is the lowest free
-- memory reading of the guard, or nil. trace is the memory trace text of the
-- guard, or nil.
function M.stats_lines(st, lowest, trace)
  local s = {}
  local function add(line)
    s[#s + 1] = "stats: " .. line
  end
  add("file=" .. bytes_text(st.size))
  add("width=" .. int_text(st.width))
  local lines = is_num(st.lines) and st.lines or nil
  if st.lines ~= nil then
    add("lines=" .. int_text(st.lines))
    add("cpu=" .. seconds_text("%.3f", st.cpu))
    if st.wall ~= nil then
      add("wall=" .. seconds_text("%.2f", st.wall))
    end
  end
  if st.free_before ~= nil then
    local before = st.free_before
    add("free_before=" .. bytes_text(before))
    if st.free_after ~= nil then
      add("free_after=" .. bytes_text(st.free_after))
      if is_num(before) and is_num(st.free_after) then
        local delta = before - st.free_after
        add("delta=" .. bytes_text(delta) .. per_line(delta, lines))
      else
        add("delta=" .. NA)
      end
    end
    if not is_num(lowest) then
      lowest = is_num(st.free_after) and st.free_after or before
    end
    add("lowest_free=" .. bytes_text(lowest))
    if is_num(before) and is_num(lowest) then
      local peak = before - lowest
      add("peak_used=" .. bytes_text(peak) .. per_line(peak, lines))
    else
      add("peak_used=" .. NA)
    end
  end
  if type(trace) == "string" and trace ~= "" then
    add("trace=" .. trace)
  else
    add("trace=" .. NA)
  end
  if st.stopped ~= nil then
    add("stopped=" .. tostring(st.stopped))
  end
  return s
end

-- Calls a guard function by name. Returns nil when the function is missing
-- or fails, for example with a guard module from an older version.
local function guard_value(name)
  local fn = type(guard) == "table" and guard[name]
  if type(fn) ~= "function" then
    return nil
  end
  local ok, value = pcall(fn)
  if ok then
    return value
  end
  return nil
end

-- Prints the stats lines to stderr and writes them to opts.stats_out.
-- Returns false when the file write fails.
local function report_stats(st, opts, deps)
  local lines = M.stats_lines(st, st.free_before and guard_value("lowest_free"),
    guard_value("trace_text"))
  for i = 1, #lines do
    deps.err(lines[i])
  end
  if not opts.stats_out then
    return true
  end
  local path = deps.resolve and deps.resolve(opts.stats_out) or opts.stats_out
  local ok, done, why = false, nil, "no file access"
  if deps.write_file then
    ok, done, why = pcall(deps.write_file, path,
      table.concat(lines, "\n") .. "\n")
  end
  if ok and done then
    return true
  end
  if not ok then
    why = done
  end
  why = tostring(why or "unknown reason"):match("^[^\n]*")
  deps.err("html: cannot write stats file: " .. opts.stats_out .. " ("
    .. why .. ")")
  return false
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
--   write_file(path, text) optional, for --stats-out. Returns true, or nil
--                          and a reason
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
  local st = { width = opts.width or deps.width or DEFAULT_WIDTH }
  local ok, result = xpcall(function()
    st.size = file_size(f, path, deps)
    run(f, opts, deps, st)
  end, handler)
  f:close()
  local code = 0
  if not ok then
    code = 1
    if is_controlled(result) then
      deps.err(result)
      st.stopped = result
    else
      result = tostring(result)
      local first = result:match("^[^\n]*")
      if deps.log then
        deps.log(result)
        deps.err("html: unexpected error: " .. first .. " (details in "
          .. ERROR_LOG .. ")")
      else
        deps.err("html: unexpected error: " .. first)
      end
      st.stopped = "html: unexpected error: " .. first
    end
  end
  if opts.stats and not report_stats(st, opts, deps) then
    code = 1
  end
  return code
end

-- The links to OpenOS. Loaded only when the chunk runs as a program.
function M.game_deps()
  local computer = require("computer")
  local filesystem = require("filesystem")
  local shell = require("shell")
  local term = require("term")
  local width = DEFAULT_WIDTH
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
    write_file = function(path, text)
      local f, why = io.open(path, "w")
      if not f then
        return nil, why
      end
      local done, werr = f:write(text)
      f:close()
      if not done then
        return nil, werr
      end
      return true
    end,
  }
end

-- Runs main with the deps from get_deps and removes the html modules from
-- loaded on every exit path. An error from main is raised again after that.
function M.run_program(argv, get_deps, loaded)
  local ok, code = pcall(function()
    return M.main(argv, get_deps())
  end)
  clear_modules(loaded)
  if not ok then
    error(code, 0)
  end
  return code
end

local argv = table.pack(...)
if type(argv[1]) == "table" then
  return M
end
return M.run_program(argv, M.game_deps, package_loaded())
