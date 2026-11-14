-- html: shows a local HTML file in a full-screen viewer, or prints it as
-- text. Run as a program: html [options] <file>
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

-- The html modules load on first use, inside the protected run (see
-- load_modules).
local guard, tokenizer, layout

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
-- Used for "~" when HOME is not set. OpenOS sets HOME to /home.
local DEFAULT_HOME = "/home"
-- The size check before reading assumes at least this many scaled units of
-- memory per input byte. Measured: about 0.75 on large.html (751914 units
-- for 1000193 bytes), at most about 1.5 in the worst case. 0.5 is a third of
-- the worst case, so the check stops only a file that clearly cannot fit.
-- The guard still protects the render of a smaller file.
local SIZE_COST_MIN = 0.5
-- Exit codes.
local EXIT_ERROR = 1
local EXIT_USAGE = 2
local EXIT_INTERRUPTED = 130
local INTERRUPTED = "html: interrupted"
-- The largest --width.
local MAX_WIDTH = 1024

M.USAGE = [[
Usage: html [options] <file>
Shows a local HTML file in a full-screen viewer.
Options:
  --print             write the page as plain text to stdout
  --width <n>         wrap lines at n columns (sets --print,
                      default: the terminal width)
  --no-rescale        keep the current screen resolution in the viewer
  --stats             print file size, line count, render time and memory
                      to stderr (after the viewer closes)
  --stats-out <path>  also write the stats lines to a file (sets --stats)
  --help              show this help
Viewer keys: Up Down PgUp PgDn Home End, q quit, Ctrl+C exit.]]

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
    elseif a == "--print" then
      opts.print = true
    elseif a == "--no-rescale" then
      opts.no_rescale = true
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
      if not w or w < 1 or w > MAX_WIDTH then
        return nil, "html: --width needs a whole number from 1 to "
          .. MAX_WIDTH
      end
      opts.width = w
      opts.print = true
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

-- shell.resolve does not expand "~" (measured: it gives "/home/~"). Returns
-- path with a leading "~/" or a bare "~" replaced by home.
function M.expand_home(path, home)
  if type(home) ~= "string" or home == "" then
    home = DEFAULT_HOME
  end
  if path == "~" then
    return home
  end
  if sub(path, 1, 2) == "~/" then
    if sub(home, -1) == "/" then
      return home .. sub(path, 3)
    end
    return home .. sub(path, 2)
  end
  return path
end

-- The first line of a failure reason.
local function reason(why)
  return (tostring(why or "unknown reason"):match("^[^\n]*"))
end

-- Writes text to a new file at path. Checks write, flush and close, because
-- a full /tmp reports "not enough space" only at flush or close (measured).
-- Returns true, or nil and a reason.
function M.write_text(open, path, text)
  local f, why = open(path, "w")
  if not f then
    return nil, why or "cannot open"
  end
  local called, done, err = pcall(function()
    local d, e = f:write(text)
    if d then
      d, e = f:flush()
    end
    return d, e
  end)
  local closed_ok, closed, cerr = pcall(f.close, f)
  if not called then
    return nil, reason(done)
  end
  if not closed_ok then
    closed, cerr = nil, closed
  end
  if not done then
    return nil, err or "write failed"
  end
  if not closed then
    return nil, reason(cerr or "close failed")
  end
  return true
end

local function is_controlled(e)
  return type(e) == "string" and sub(e, 1, 6) == "html: "
end

-- Loads the html modules. Returns true, or nil and a controlled message
-- that names the module that failed.
local function load_modules()
  if guard and tokenizer and layout then
    return true
  end
  local names = { "guard", "tokenizer", "layout" }
  local mods = {}
  for i = 1, #names do
    local name = "html." .. names[i]
    local ok, mod = pcall(require, name)
    if not ok then
      return nil, "html: cannot load " .. name .. ": " .. reason(mod)
    end
    mods[i] = mod
  end
  guard, tokenizer, layout = mods[1], mods[2], mods[3]
  return true
end

-- Removes the style bytes.
local function plain(line)
  if find(line, "[\1-\5]") then
    return (gsub(line, "[\1-\5]", ""))
  end
  return line
end

-- Runs the tokenizer and layout over a reader. Returns the lines and the
-- document title or nil.
function M.render(read, width)
  local loaded, why = load_modules()
  if not loaded then
    error(why, 0)
  end
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
  local lines = lay.finish()
  return lines, lay.title()
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

-- Checks the file size, renders the file, and prints the lines or opens
-- the viewer. Fills st with the stats values as it goes, so a render that
-- stops still has the values up to that point. done() is called when the
-- render ends. Returns the viewer result, or nil in print mode.
local function run(f, opts, deps, st, done)
  local free = guard.settled_free()
  if opts.stats then
    st.free_before = free
  end
  if is_num(st.size) and st.size * SIZE_COST_MIN > free then
    error("html: file too large for available memory (" .. int_text(st.size)
      .. " bytes, " .. int_text(free) .. " free)", 0)
  end
  -- The lowest free reading starts here, after the settled reading.
  guard.reset()
  local clock0, wall0 = deps.clock(), deps.uptime and deps.uptime()
  local lines, title = M.render(function()
    local chunk, why = f:read(CHUNK)
    -- A plain nil is the end of the input. A nil with a message is an error.
    if chunk == nil and why then
      error("html: read error: " .. reason(why), 0)
    end
    return chunk
  end, st.width)
  st.cpu = deps.clock() - clock0
  if wall0 then
    st.wall = deps.uptime() - wall0
  end
  st.lines = #lines
  if opts.stats then
    st.free_after = guard.settled_free()
  end
  done()
  if not opts.print then
    if title == "" then
      title = nil
    end
    return deps.view(lines, { title = title, file = opts.file,
      no_rescale = opts.no_rescale })
  end
  local out = deps.out
  for i = 1, #lines do
    guard.tick_output()
    out(plain(lines[i]))
  end
end

local function per_line(bytes, lines)
  if lines then
    return string.format(" (%.1f per line)", bytes / math.max(1, lines))
  end
  return ""
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
-- guard, or nil. counts is nil or a table with the guard settle counters
-- settles, gc_seen and settle_yields.
function M.stats_lines(st, lowest, trace, counts)
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
    counts = type(counts) == "table" and counts or {}
    add("settles=" .. int_text(counts.settles) .. " gc_seen="
      .. int_text(counts.gc_seen) .. " settle_yields="
      .. int_text(counts.settle_yields))
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
    guard_value("trace_text"), {
      settles = guard_value("settles"),
      gc_seen = guard_value("gc_seen"),
      settle_yields = guard_value("settle_yields"),
    })
  for i = 1, #lines do
    deps.err(lines[i])
  end
  if not opts.stats_out then
    return true
  end
  local path = opts.stats_path
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
  deps.err("html: cannot write stats file: " .. opts.stats_out .. " ("
    .. reason(why) .. ")")
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

-- Returns the viewer width: the maximum screen width, or the current width
-- with no_rescale. Returns nil when there is no GPU or no screen.
local function screen_width(gpu, no_rescale)
  if type(gpu) ~= "table" then
    return nil
  end
  local ok, w = pcall(function()
    if gpu.getScreen and not gpu.getScreen() then
      return nil
    end
    if no_rescale then
      return (gpu.getResolution())
    end
    return (gpu.maxResolution())
  end)
  if ok and math.tointeger(w) and w > 0 then
    return w
  end
  return nil
end

-- Prints one line for an unexpected error and writes the details to the
-- error log. Returns the line.
local function report_unexpected(result, deps)
  result = tostring(result)
  local first = result:match("^[^\n]*")
  if deps.log then
    local called, done, why = pcall(deps.log, result)
    if called and done then
      deps.err("html: unexpected error: " .. first .. " (details in "
        .. ERROR_LOG .. ")")
    else
      if not called then
        why = done
      end
      deps.err("html: unexpected error: " .. first .. " (cannot write "
        .. ERROR_LOG .. ": " .. reason(why) .. ")")
    end
  else
    deps.err("html: unexpected error: " .. first)
  end
  return "html: unexpected error: " .. first
end

-- argv: the program arguments (a table, n is optional).
-- deps: the machine links:
--   out(line), err(line)   print to stdout and stderr
--   width                  default wrap width for --print
--   open(path, mode)       io.open
--   traceback(msg)         debug.traceback, or a fake in the tests
--   clock()                os.clock
--   uptime()               optional, wall time in seconds
--   resolve(path)          optional, makes a path absolute
--   home                   optional, the home directory for "~"
--   exists(path)           optional
--   is_dir(path)           optional
--   size(path)             optional, file size in bytes
--   log(text)              optional, keeps the details of an unexpected
--                          error. Returns true, or nil and a reason
--   write_file(path, text) optional, for --stats-out. Returns true, or nil
--                          and a reason
--   gpu                    optional, the GPU proxy. Without it, or without
--                          a screen, the page prints as text
--   view(lines, opts)      optional, runs the viewer (see viewer.run).
--                          Returns "quit" or "interrupted"
--   on_interrupt(fn)       optional, calls fn on Ctrl+C. Returns a function
--                          that removes the listener
-- Returns the exit code.
function M.main(argv, deps)
  local opts, msg = M.parse_args(argv)
  if not opts then
    deps.err(msg .. " (see html --help)")
    return EXIT_USAGE
  end
  if opts.help then
    deps.out(M.USAGE)
    return 0
  end
  local path = M.expand_home(opts.file, deps.home)
  path = deps.resolve and deps.resolve(path) or path
  if opts.stats_out then
    local out_path = M.expand_home(opts.stats_out, deps.home)
    out_path = deps.resolve and deps.resolve(out_path) or out_path
    opts.stats_path = out_path
    if out_path == path then
      deps.err("html: --stats-out must not be the input file: "
        .. opts.stats_out)
      return EXIT_USAGE
    end
  end
  local loaded, load_why = load_modules()
  if not loaded then
    deps.err(load_why)
    return EXIT_ERROR
  end
  if deps.exists and not deps.exists(path) then
    deps.err("html: file not found: " .. opts.file)
    return EXIT_ERROR
  end
  if deps.is_dir and deps.is_dir(path) then
    deps.err("html: not a file: " .. opts.file)
    return EXIT_ERROR
  end
  local width = opts.width or deps.width or DEFAULT_WIDTH
  if not opts.print then
    local w = deps.view and screen_width(deps.gpu, opts.no_rescale)
    if w then
      width = w
    else
      deps.err("html: no screen found, printing the text")
      opts.print = true
    end
  end
  local f = deps.open(path, "rb")
  if not f then
    deps.err("html: cannot open file: " .. opts.file)
    return EXIT_ERROR
  end

  -- Ctrl+C during the render: the listener sets the flag during a yield,
  -- and the next guard.tick raises INTERRUPTED.
  local interrupted, remove = false, nil
  if deps.on_interrupt then
    remove = deps.on_interrupt(function() interrupted = true end)
  end
  guard.set_interrupt_check(function() return interrupted end)
  local function stop_listening()
    guard.set_interrupt_check(nil)
    if remove then
      local fn = remove
      remove = nil
      pcall(fn)
    end
  end
  local open_file = f
  local function close_file()
    if open_file then
      local h = open_file
      open_file = nil
      h:close()
    end
  end

  local traceback = deps.traceback
  local function handler(e)
    if e == "interrupted" then
      return INTERRUPTED
    end
    if is_controlled(e) then
      return e
    end
    return traceback(tostring(e), 2)
  end
  local st = { width = width }
  local ok, result = xpcall(function()
    st.size = file_size(f, path, deps)
    return run(f, opts, deps, st, function()
      close_file()
      if interrupted then
        error(INTERRUPTED, 0)
      end
      -- The viewer handles Ctrl+C itself. Print mode keeps the check for
      -- the output loop.
      if not opts.print then
        stop_listening()
      end
    end)
  end, handler)
  -- Each step runs alone, so a failure in one does not skip the other.
  pcall(stop_listening)
  pcall(close_file)

  local code = 0
  if not ok and result == "interrupted" then
    -- A bare "interrupted" error is Ctrl+C from the event system.
    result = INTERRUPTED
  end
  if not ok then
    code = EXIT_ERROR
    if is_controlled(result) then
      deps.err(result)
      st.stopped = result
      if result == INTERRUPTED then
        code = EXIT_INTERRUPTED
      end
    else
      st.stopped = report_unexpected(result, deps)
    end
  elseif result == "interrupted" then
    code = EXIT_INTERRUPTED
  end
  if opts.stats and not report_stats(st, opts, deps) then
    code = EXIT_ERROR
  end
  return code
end

-- The links to OpenOS. Loaded only when the chunk runs as a program.
function M.game_deps()
  local function need(name)
    local ok, mod = pcall(require, name)
    if not ok then
      error("html: cannot load " .. name .. ": " .. reason(mod), 0)
    end
    return mod
  end
  local component = need("component")
  local computer = need("computer")
  local event = need("event")
  local filesystem = need("filesystem")
  local shell = need("shell")
  local term = need("term")
  local width = DEFAULT_WIDTH
  local ok, w = pcall(term.getViewport)
  if ok and math.tointeger(w) and w > 0 then
    width = w
  end
  local gpu
  if component.isAvailable("gpu") then
    gpu = component.gpu
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
    home = os.getenv("HOME"),
    exists = filesystem.exists,
    is_dir = filesystem.isDirectory,
    size = filesystem.size,
    log = function(text)
      if #text > ERROR_LOG_MAX then
        text = sub(text, -ERROR_LOG_MAX)
      end
      return M.write_text(io.open, ERROR_LOG, text)
    end,
    write_file = function(path, text)
      return M.write_text(io.open, path, text)
    end,
    gpu = gpu,
    view = function(lines, opts)
      local viewer = need("html.viewer")
      return viewer.run(lines, opts, { gpu = gpu, pull = event.pull,
        term = term })
    end,
    on_interrupt = function(fn)
      event.listen("interrupted", fn)
      return function() event.ignore("interrupted", fn) end
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
    if is_controlled(code) then
      -- A failed module load: one line and exit code 1.
      if type(io) == "table" and io.stderr then
        io.stderr:write(code, "\n")
      else
        print(code)
      end
      return EXIT_ERROR
    end
    error(code, 0)
  end
  return code
end

local argv = table.pack(...)
if type(argv[1]) == "table" then
  return M
end
return M.run_program(argv, M.game_deps, package_loaded())
