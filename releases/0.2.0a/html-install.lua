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
M.VERSION = "0.2.0a"
M.sizes["bin/html.lua"] = 26048
M.files["bin/html.lua"] = [=[
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
Usage: html [options] <file | url>
Shows a local HTML file or a web page in a full-screen viewer.
  html page.html          a local file
  html http://host/path   a web page (https:// also works, needs an
                          internet card)
  html host/path          http://host/path, when no local file has
                          that name
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
  -- OpenOS close returns no values on success (measured). Only a reason
  -- is a failure.
  if not closed and cerr ~= nil then
    return nil, reason(cerr)
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

-- Loads html.fetch, only for a URL or a missing local file. Returns true,
-- or nil and a controlled message.
local fetch
local function load_fetch()
  if fetch then
    return true
  end
  local ok, mod = pcall(require, "html.fetch")
  if not ok then
    return nil, "html: cannot load html.fetch: " .. reason(mod)
  end
  fetch = mod
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

-- Checks the input size, renders the input, and prints the lines or opens
-- the viewer. source: read() (a chunk, or nil at the end; it raises on an
-- error), size (bytes known before reading, or nil), kind ("file" or
-- "page", for the size message), name (shown without a title) and prefix
-- (put before the title, or nil).
-- Fills st with the stats values as it goes, so a render that stops still
-- has the values up to that point. done() is called when the render ends.
-- Returns the viewer result, or nil in print mode.
local function run(source, opts, deps, st, done)
  local free = guard.settled_free()
  if opts.stats then
    st.free_before = free
  end
  local size = source.size
  if is_num(size) and size * SIZE_COST_MIN > free then
    error("html: " .. source.kind .. " too large for available memory ("
      .. int_text(size) .. " bytes, " .. int_text(free) .. " free)", 0)
  end
  -- The lowest free reading starts here, after the settled reading.
  guard.reset()
  local clock0, wall0 = deps.clock(), deps.uptime and deps.uptime()
  local lines, title = M.render(source.read, st.width)
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
    if source.prefix then
      title = source.prefix .. (title or source.name)
    end
    return deps.view(lines, { title = title, file = source.name,
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
  if st.url ~= nil then
    add("url=" .. tostring(st.url))
    add("http=" .. int_text(st.http) .. " redirects="
      .. int_text(st.redirects) .. " fetch=" .. seconds_text("%.2f", st.fetch))
  end
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
--   internet               optional, the internet card proxy (for a URL)
--   sleep(seconds)         optional, os.sleep. The fetch waits with it
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
  local arg = opts.file
  -- An argument with a scheme is a URL. Any other argument is a local path
  -- first (see SPEC.md "Arguments without a scheme").
  local url, path, guessed
  if find(arg, "^%a[%w+.-]*://") then
    url = arg
  else
    path = M.expand_home(arg, deps.home)
    path = deps.resolve and deps.resolve(path) or path
  end
  if opts.stats_out then
    local out_path = M.expand_home(opts.stats_out, deps.home)
    out_path = deps.resolve and deps.resolve(out_path) or out_path
    opts.stats_path = out_path
    if path and out_path == path then
      deps.err("html: --stats-out must not be the input file: "
        .. opts.stats_out)
      return EXIT_USAGE
    end
  end
  -- load_modules can fail while it builds its message (for example out of
  -- memory), so it runs protected and any failure gives one controlled line.
  local called, loaded, load_why = pcall(load_modules)
  if not called then
    local built, line = pcall(function()
      return "html: cannot load modules: " .. reason(loaded)
    end)
    loaded = nil
    load_why = built and line or "html: cannot load modules"
  end
  if not loaded then
    deps.err(load_why)
    return EXIT_ERROR
  end
  if path and deps.exists and not deps.exists(path) then
    local fetch_loaded, fetch_why = load_fetch()
    if not fetch_loaded then
      deps.err(fetch_why)
      return EXIT_ERROR
    end
    if not fetch.looks_like_host(arg) then
      deps.err("html: file not found: " .. arg)
      return EXIT_ERROR
    end
    url, path, guessed = "http://" .. arg, nil, true
  end
  if url then
    local fetch_loaded, fetch_why = load_fetch()
    if not fetch_loaded then
      deps.err(fetch_why)
      return EXIT_ERROR
    end
    local u, why = fetch.parse_url(url)
    if not u then
      deps.err(why)
      return EXIT_USAGE
    end
    url = u.url
  elseif deps.is_dir and deps.is_dir(path) then
    deps.err("html: not a file: " .. arg)
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
  local f
  if path then
    f = deps.open(path, "rb")
    if not f then
      deps.err("html: cannot open file: " .. arg)
      return EXIT_ERROR
    end
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
  -- For a URL: the fetch progress (fetch.open fills it), the response and
  -- the clock of the fetch.
  local info, resp = {}, nil
  local fetch_clock = deps.uptime or deps.clock
  -- A fetch error for a guessed URL names the argument, so a mistyped file
  -- name is clear.
  local suffix = guessed and (" (no local file named " .. arg .. ")") or ""
  local function fetch_error(why)
    if why ~= INTERRUPTED then
      why = why .. suffix
    end
    error(why, 0)
  end

  -- Returns the source for run: the file, or the response of url.
  local function open_source()
    if not url then
      st.size = file_size(f, path, deps)
      return {
        read = function()
          local chunk, why = f:read(CHUNK)
          -- A plain nil is the end of the input. A nil with a message is an
          -- error.
          if chunk == nil and why then
            error("html: read error: " .. reason(why), 0)
          end
          return chunk
        end,
        size = st.size, kind = "file", name = arg,
      }
    end
    st.url = url
    local why
    resp, why = fetch.open(url, { internet = deps.internet,
      clock = fetch_clock, sleep = deps.sleep or os.sleep,
      interrupted = function() return interrupted end }, info)
    if not resp then
      fetch_error(why)
    end
    open_file = resp
    local status = "HTTP " .. int_text(resp.status)
    if resp.is_error and opts.print then
      -- A notice, not an error: the body renders (decision D2).
      deps.err("html: " .. status .. (resp.message ~= "" and (" "
        .. resp.message) or "") .. ": " .. resp.final_url)
    end
    return {
      read = function()
        local chunk, err = resp.read()
        if chunk == nil and err then
          fetch_error(err)
        end
        return chunk
      end,
      size = resp.length, kind = "page", name = resp.final_url,
      prefix = resp.is_error and ("[" .. status .. "] ") or nil,
    }
  end

  local ok, result = xpcall(function()
    local source = open_source()
    local viewed = run(source, opts, deps, st, function()
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
    -- An error status ends its body at a read error. The received part
    -- rendered, so the error follows the page text or the viewer.
    if resp and resp.read_error then
      deps.err(resp.read_error .. suffix)
    end
    return viewed
  end, handler)
  -- Each step runs alone, so a failure in one does not skip the other.
  pcall(stop_listening)
  pcall(close_file)
  if url then
    st.url = info.url or url
    st.size = resp and resp.bytes or 0
    st.http = info.status
    st.redirects = info.redirects
    if is_num(info.started) then
      local ended = info.ended
      if not is_num(ended) then
        ended = fetch_clock()
      end
      st.fetch = ended - info.started
    end
  end

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
  local internet
  if component.isAvailable("internet") then
    internet = component.internet
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
    internet = internet,
    sleep = os.sleep,
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
      -- Prints any controlled "html: " error that reaches this point, in one
      -- line, and exits with code 1. Today only module load errors do.
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
]=]
M.sizes["lib/html/entities.lua"] = 5791
M.files["lib/html/entities.lua"] = [[
-- Named and numeric character references.
-- The caller cleans the text first: decode(text.clean(s)). Every
-- replacement is complete UTF-8 that already follows the cleaning rules,
-- so the result stays clean.

local M = {}

local byte, find, sub, char = string.byte, string.find, string.sub, utf8.char
local concat = table.concat

local MAX_NAME = 32
-- Eight hex or decimal digits are enough to pass U+10FFFF.
local MAX_DIGITS = 8

local NAMED = {
  amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
  -- Invisible marks; the cleaning rules remove zero-width characters.
  zwnj = "", zwj = "", lrm = "", rlm = "",
}

local LATIN1 = {
  "nbsp", "iexcl", "cent", "pound", "curren", "yen", "brvbar", "sect",
  "uml", "copy", "ordf", "laquo", "not", "shy", "reg", "macr",
  "deg", "plusmn", "sup2", "sup3", "acute", "micro", "para", "middot",
  "cedil", "sup1", "ordm", "raquo", "frac14", "frac12", "frac34", "iquest",
  "Agrave", "Aacute", "Acirc", "Atilde", "Auml", "Aring", "AElig", "Ccedil",
  "Egrave", "Eacute", "Ecirc", "Euml", "Igrave", "Iacute", "Icirc", "Iuml",
  "ETH", "Ntilde", "Ograve", "Oacute", "Ocirc", "Otilde", "Ouml", "times",
  "Oslash", "Ugrave", "Uacute", "Ucirc", "Uuml", "Yacute", "THORN", "szlig",
  "agrave", "aacute", "acirc", "atilde", "auml", "aring", "aelig", "ccedil",
  "egrave", "eacute", "ecirc", "euml", "igrave", "iacute", "icirc", "iuml",
  "eth", "ntilde", "ograve", "oacute", "ocirc", "otilde", "ouml", "divide",
  "oslash", "ugrave", "uacute", "ucirc", "uuml", "yacute", "thorn", "yuml",
}
for k, name in ipairs(LATIN1) do
  NAMED[name] = char(0x9F + k)
end
-- The soft hyphen is removed like the other invisible characters.
NAMED.shy = ""

local OTHER = {
  OElig = 0x152, oelig = 0x153, Scaron = 0x160, scaron = 0x161,
  Yuml = 0x178, fnof = 0x192, circ = 0x2C6, tilde = 0x2DC,
  ensp = 0x2002, emsp = 0x2003, thinsp = 0x2009,
  ndash = 0x2013, mdash = 0x2014, lsquo = 0x2018, rsquo = 0x2019,
  sbquo = 0x201A, ldquo = 0x201C, rdquo = 0x201D, bdquo = 0x201E,
  dagger = 0x2020, Dagger = 0x2021, bull = 0x2022, hellip = 0x2026,
  permil = 0x2030, prime = 0x2032, Prime = 0x2033, lsaquo = 0x2039,
  rsaquo = 0x203A, oline = 0x203E, euro = 0x20AC, trade = 0x2122,
  larr = 0x2190, uarr = 0x2191, rarr = 0x2192, darr = 0x2193,
  harr = 0x2194, minus = 0x2212, infin = 0x221E, asymp = 0x2248,
  ne = 0x2260, le = 0x2264, ge = 0x2265,
}
for name, cp in pairs(OTHER) do
  NAMED[name] = char(cp)
end

-- Legacy names that decode without ";" when the next byte is not
-- alphanumeric and not "=", as HTML does in attributes. This keeps
-- "?a=1&copy=2" and "&ampx" as written.
local LEGACY = { amp = true, lt = true, gt = true, quot = true, nbsp = true,
  copy = true, reg = true }

-- HTML maps references to 0x80..0x9F to Windows-1252 characters.
local WIN1252 = {
  [0x80] = 0x20AC, [0x82] = 0x201A, [0x83] = 0x0192, [0x84] = 0x201E,
  [0x85] = 0x2026, [0x86] = 0x2020, [0x87] = 0x2021, [0x88] = 0x02C6,
  [0x89] = 0x2030, [0x8A] = 0x0160, [0x8B] = 0x2039, [0x8C] = 0x0152,
  [0x8E] = 0x017D, [0x91] = 0x2018, [0x92] = 0x2019, [0x93] = 0x201C,
  [0x94] = 0x201D, [0x95] = 0x2022, [0x96] = 0x2013, [0x97] = 0x2014,
  [0x98] = 0x02DC, [0x99] = 0x2122, [0x9A] = 0x0161, [0x9B] = 0x203A,
  [0x9C] = 0x0153, [0x9E] = 0x017E, [0x9F] = 0x0178,
}
-- fetch.lua uses the same table to convert Windows-1252 bodies.
M.WIN1252 = WIN1252

-- Applies the cleaning rules to one code point.
local function code_point(cp)
  if cp == 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
    return "?"
  end
  if cp >= 0x80 and cp <= 0x9F then
    cp = WIN1252[cp]
    return cp and char(cp) or ""
  end
  if (cp < 0x20 and cp ~= 0x09 and cp ~= 0x0A) or cp == 0x7F
      or cp == 0xAD or (cp >= 0x200B and cp <= 0x200F) or cp == 0xFEFF then
    return ""
  end
  return char(cp)
end

local function is_alnum(b)
  return b and ((b >= 0x30 and b <= 0x39) or (b >= 0x41 and b <= 0x5A)
    or (b >= 0x61 and b <= 0x7A))
end

-- Parses the reference at p ("&"). Returns the replacement and the index
-- after it, or nil when the text is not a reference.
local function reference(s, p)
  if byte(s, p + 1) == 0x23 then
    local q, digits, base = p + 2, "^%d+", 10
    local x = byte(s, q)
    if x == 0x78 or x == 0x58 then
      q, digits, base = q + 1, "^%x+", 16
    end
    local _, e = find(s, digits, q)
    if not e then
      return nil
    end
    -- Skip leading zeros so a long zero run still parses.
    local _, z = find(s, "^0+", q)
    local first = z and z < e and z + 1 or (z or q)
    local cp
    if e - first + 1 > MAX_DIGITS then
      cp = 0x110000
    else
      cp = tonumber(sub(s, first, e), base)
    end
    if byte(s, e + 1) == 0x3B then
      e = e + 1
    end
    return code_point(cp), e + 1
  end
  local _, e = find(s, "^%w+", p + 1)
  if not e or e - p > MAX_NAME then
    return nil
  end
  local name = sub(s, p + 1, e)
  local value = NAMED[name]
  if not value then
    return nil
  end
  if byte(s, e + 1) == 0x3B then
    return value, e + 2
  end
  local next_byte = byte(s, e + 1)
  if LEGACY[name] and not is_alnum(next_byte) and next_byte ~= 0x3D then
    return value, e + 1
  end
  return nil
end

-- Decodes references in s. Unknown references stay as written.
function M.decode(s)
  local p = find(s, "&", 1, true)
  if not p then
    return s
  end
  local parts, n = {}, 0
  local run = 1
  while p do
    local value, after = reference(s, p)
    if value and after then
      if p > run then
        n = n + 1
        parts[n] = sub(s, run, p - 1)
      end
      n = n + 1
      parts[n] = value
      run = after
      p = find(s, "&", after, true)
    else
      p = find(s, "&", p + 1, true)
    end
  end
  if run <= #s then
    n = n + 1
    parts[n] = sub(s, run)
  end
  return concat(parts)
end

return M
]]
M.sizes["lib/html/fetch.lua"] = 13477
M.files["lib/html/fetch.lua"] = [[
-- Fetches a page with the internet card and streams its body. The card
-- proxy, the clock, the sleep function and the interrupt check come from the
-- caller (links), so this module never loads component.

local M = {}

local byte, find, lower, sub = string.byte, string.find, string.lower,
  string.sub

local MAX_URL = 2048
local MAX_LABEL = 63

-- Arguments with one of these last labels stay local files (decision D5).
local FILE_LABELS = { html = true, htm = true, xhtml = true, txt = true,
  lua = true }

-- Returns the scheme of s in lower case when s starts with
-- "<letter>[letters, digits, + . -]://", or nil.
function M.scheme(s)
  local scheme = type(s) == "string" and s:match("^(%a[%w+.-]*)://")
  return scheme and lower(scheme) or nil
end

-- True when s has a space, a control byte or a byte above 0x7E.
local function has_bad_byte(s)
  return find(s, "[%z\1-\32\127-\255]") ~= nil
end

-- Parses an http or https URL. Returns a table (scheme, host, port, path,
-- url without the fragment, origin) or nil and a controlled message.
function M.parse_url(s)
  if #s > MAX_URL then
    return nil, "html: invalid URL: too long"
  end
  local scheme = M.scheme(s)
  if scheme and scheme ~= "http" and scheme ~= "https" then
    return nil, "html: unsupported URL scheme: " .. scheme
  end
  local invalid = "html: invalid URL: " .. s
  if not scheme or has_bad_byte(s) then
    return nil, invalid
  end
  local url = s
  local hash = find(s, "#", 1, true)
  if hash then
    url = sub(s, 1, hash - 1)
  end
  local start = #scheme + 4
  local stop = find(url, "[/?]", start) or #url + 1
  local hostport = sub(url, start, stop - 1)
  local host, port_text = hostport:match("^([^:]*):(.*)$")
  if not host then
    host = hostport
  end
  if host == "" then
    return nil, invalid
  end
  local port
  if port_text then
    port = math.tointeger(tonumber(port_text:match("^%d+$") or ""))
  else
    port = scheme == "https" and 443 or 80
  end
  local path = sub(url, stop)
  if path == "" then
    path = "/"
  end
  return { scheme = scheme, host = host, port = port, path = path, url = url,
    origin = sub(url, 1, stop - 1) }
end

-- True when a label is 1 to 63 bytes of letters, digits and "-", and does
-- not start or end with "-".
local function good_label(label)
  return #label >= 1 and #label <= MAX_LABEL
    and not find(label, "[^%w-]") and byte(label, 1) ~= 45
    and byte(label, -1) ~= 45
end

-- True when an argument without a scheme looks like a host (decision D4).
-- See SPEC.md "Arguments without a scheme".
function M.looks_like_host(arg)
  if type(arg) ~= "string" or arg == "" or find(arg, "^[/.~]")
      or has_bad_byte(arg) then
    return false
  end
  local hostpart = sub(arg, 1, (find(arg, "[/?#]") or #arg + 1) - 1)
  local name, port = hostpart:match("^([^:]*):(.*)$")
  if name then
    local n = math.tointeger(tonumber(port:match("^%d%d?%d?%d?%d?$") or ""))
    if not n or n < 1 or n > 65535 then
      return false
    end
  else
    name = hostpart
  end
  if lower(name) == "localhost" then
    return true
  end
  local labels, last = 0, nil
  for label in (name .. "."):gmatch("([^.]*)%.") do
    if not good_label(label) then
      return false
    end
    labels, last = labels + 1, label
  end
  return labels >= 2 and not FILE_LABELS[lower(last)]
end

-- Request and body ----------------------------------------------------------

-- The release version. It goes into the User-Agent header.
M.VERSION = "0.2.0a"

-- The same chunk size as a file read.
local CHUNK = 4096
-- Every wait loop sleeps this long, so the program yields well inside the
-- 5 s OpenOS limit. First guesses until N2, N4, N5 and N11 are measured.
local WAIT_STEP = 0.05
local CONNECT_TIMEOUT = 15
local READ_TIMEOUT = 30
local MAX_REDIRECTS = 5
local INTERRUPTED = "html: interrupted"

local HEADERS = { ["User-Agent"] = "oc-html/" .. M.VERSION,
  ["Accept-Encoding"] = "identity" }

local REDIRECT = { [301] = true, [302] = true, [303] = true, [307] = true,
  [308] = true }

local ACCEPTED = { [""] = true, ["text/html"] = true,
  ["application/xhtml+xml"] = true, ["text/plain"] = true }

local LATIN_CHARSETS = { ["iso-8859-1"] = true, latin1 = true,
  ["windows-1252"] = true }

-- The first line of a reason from the card. It can be any value.
local function why_text(v)
  if v == nil then
    v = "unknown reason"
  end
  return (tostring(v):match("^[^\n]*"))
end

local function trim(s)
  return (s:match("^%s*(.-)%s*$"))
end

-- The first value of a response header. The name is not case-sensitive.
-- The card gives a list of values per name, but a plain value also works.
local function header(headers, name)
  if type(headers) ~= "table" then
    return nil
  end
  for k, v in pairs(headers) do
    if type(k) == "string" and lower(k) == name then
      if type(v) == "table" then
        v = v[1]
      end
      if v ~= nil then
        return tostring(v)
      end
    end
  end
  return nil
end

local latin_map

-- Converts Latin-1 or Windows-1252 text to UTF-8. Bytes 0x80 to 0x9F use the
-- Windows-1252 table of entities.lua. Each input byte is one character, so a
-- chunk converts without state.
function M.latin_to_utf8(s)
  if not find(s, "[\128-\255]") then
    return s
  end
  if not latin_map then
    local win = require("html.entities").WIN1252
    latin_map = {}
    for b = 0x80, 0xFF do
      latin_map[string.char(b)] = utf8.char(win[b] or b)
    end
  end
  return (s:gsub("[\128-\255]", latin_map))
end

-- Text for the generated short page: "&" and "<" become entities.
local function escape(s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"))
end

-- The page shown for an error status when the body cannot be shown.
local function short_page(code, message, url)
  local head = escape("HTTP " .. code .. (message ~= "" and (" " .. message)
    or ""))
  return "<title>" .. head .. "</title><h1>" .. head .. "</h1><p>"
    .. escape(url) .. "</p>"
end

-- Waits for the connection and the status line. Returns true, code, message
-- and headers, or false and a controlled message.
local function wait_response(h, url, links)
  local clock, interrupted = links.clock, links.interrupted
  local t0 = clock()
  local function wait()
    if interrupted() then
      return INTERRUPTED
    end
    if clock() - t0 > CONNECT_TIMEOUT then
      return "html: timed out connecting to " .. url
    end
    links.sleep(WAIT_STEP)
    return nil
  end
  while true do
    local ok, done, why = pcall(h.finishConnect)
    if not ok or done == nil then
      return false, "html: cannot connect: " .. url .. ": "
        .. why_text(ok and why or done)
    end
    if done then
      break
    end
    local stop = wait()
    if stop then
      return false, stop
    end
  end
  while true do
    local ok, code, message, headers = pcall(h.response)
    if not ok then
      return false, "html: cannot connect: " .. url .. ": " .. why_text(code)
    end
    if code ~= nil then
      return true, code, message, headers
    end
    local stop = wait()
    if stop then
      return false, stop
    end
  end
end

-- Returns the absolute URL of a redirect, or nil and a controlled message.
local function redirect_target(u, location)
  local target
  if M.scheme(location) then
    target = location
  elseif sub(location, 1, 1) == "/" and sub(location, 2, 2) ~= "/" then
    target = u.origin .. location
  end
  local parsed, why
  if target then
    parsed, why = M.parse_url(target)
  end
  if parsed then
    return parsed.url
  end
  if why and find(why, "^html: unsupported URL scheme") then
    return nil, why
  end
  return nil, "html: cannot follow redirect: " .. why_text(location)
end

-- Builds the response object for an open handle. Returns it, or nil and a
-- controlled message (the handle is then closed).
local function make_response(h, u, code, message, headers, links, info)
  local clock = links.clock
  local closed = false
  local function close()
    if not closed then
      closed = true
      pcall(h.close)
    end
  end
  local ctype = header(headers, "content-type")
  local media = ctype and lower(trim(ctype:match("^[^;]*"))) or ""
  local encoding = lower(trim(header(headers, "content-encoding")
    or "identity"))
  local plain = encoding == "identity" or encoding == ""
  local is_error = code < 200 or code > 299
  if not is_error and not plain then
    close()
    return nil, "html: compressed response not supported: "
      .. why_text(encoding)
  end
  if not is_error and not ACCEPTED[media] then
    close()
    return nil, "html: not an HTML page: " .. why_text(media)
  end
  local charset = ctype and ctype:match(";%s*[Cc][Hh][Aa][Rr][Ss][Ee][Tt]"
    .. "%s*=%s*\"?([^;\"%s]+)")
  local convert = charset and LATIN_CHARSETS[lower(charset)]
  local length = header(headers, "content-length")
  local resp = {
    status = code,
    message = message ~= nil and why_text(message) or "",
    content_type = ctype,
    length = length and math.tointeger(tonumber(length:match("^%s*(%d+)%s*$")
      or "")),
    final_url = u.url,
    redirects = info.redirects,
    is_error = is_error,
    bytes = 0,
    close = close,
  }

  local ended = false
  local function finish()
    ended = true
    info.ended = clock()
  end
  local last = clock()
  -- Returns a chunk, nil at the end, or nil and a controlled message.
  local function body_read()
    if ended or closed then
      return nil
    end
    while true do
      local ok, s, why = pcall(h.read, CHUNK)
      if not ok then
        finish()
        return nil, "html: read error: " .. why_text(s)
      end
      if s == nil then
        finish()
        if why ~= nil then
          return nil, "html: read error: " .. why_text(why)
        end
        return nil
      end
      s = tostring(s)
      if s ~= "" then
        last = clock()
        resp.bytes = resp.bytes + #s
        return convert and M.latin_to_utf8(s) or s
      end
      if links.interrupted() then
        return nil, INTERRUPTED
      end
      if clock() - last > READ_TIMEOUT then
        finish()
        return nil, "html: timed out reading " .. u.url .. " ("
          .. resp.bytes .. " bytes received)"
      end
      links.sleep(WAIT_STEP)
    end
  end

  function resp.fetch_time()
    return (info.ended or clock()) - info.started
  end

  if not is_error then
    resp.read = body_read
    return resp
  end

  -- An error status renders its body (decision D2). The short page replaces
  -- a body that is empty, cannot be read or has another type.
  local short
  local function use_short()
    short = short_page(code, resp.message, u.url)
  end
  if not ACCEPTED[media] or not plain then
    close()
    finish()
    resp.length = nil
    use_short()
  end
  local first = true
  function resp.read()
    if short then
      local s = short
      short = false
      return s
    end
    if short == false then
      return nil
    end
    local s, why = body_read()
    if first and why ~= INTERRUPTED then
      first = false
      if s == nil then
        use_short()
        return resp.read()
      end
    elseif s == nil and why ~= nil and why ~= INTERRUPTED then
      resp.read_error = why
      return nil
    end
    return s, why
  end
  return resp
end

-- Opens url with the card in links.internet and follows redirects.
-- links: internet (the card proxy), clock() (wall time in seconds),
-- sleep(seconds), interrupted() (true after Ctrl+C).
-- info is filled as the request goes: url, redirects, status, started and
-- ended (clock values).
-- Returns a response (status, message, is_error, length, content_type,
-- final_url, redirects, bytes, read_error, read(), close(), fetch_time()),
-- or nil and a controlled message.
function M.open(url, links, info)
  info.redirects = 0
  info.started = links.clock()
  local card = links.internet
  if type(card) ~= "table" then
    return nil, "html: no internet card found (needed for " .. url .. ")"
  end
  if card.isHttpEnabled then
    local ok, on = pcall(card.isHttpEnabled)
    if ok and on == false then
      return nil, "html: HTTP requests are disabled on this server"
    end
  end
  local start_url = url
  while true do
    local u, why = M.parse_url(url)
    if not u then
      return nil, why
    end
    info.url = u.url
    local ok, h, reason = pcall(card.request, u.url, nil, HEADERS)
    if not ok or not h then
      return nil, "html: cannot fetch " .. u.url .. ": "
        .. why_text(ok and reason or h)
    end
    local called, got, code, message, headers = pcall(wait_response, h,
      u.url, links)
    if not called then
      -- A raised sleep (for example Ctrl+C) still closes the handle.
      pcall(h.close)
      error(got, 0)
    end
    if not got then
      pcall(h.close)
      return nil, code
    end
    code = math.tointeger(tonumber(code)) or 0
    info.status = code
    local location = REDIRECT[code] and header(headers, "location")
    if not location then
      local called2, resp, rwhy = pcall(make_response, h, u, code, message,
        headers, links, info)
      if not called2 then
        pcall(h.close)
        error(resp, 0)
      end
      return resp, rwhy
    end
    pcall(h.close)
    if info.redirects >= MAX_REDIRECTS then
      return nil, "html: too many redirects: " .. start_url
    end
    local target, rwhy = redirect_target(u, location)
    if not target then
      return nil, rwhy
    end
    info.redirects = info.redirects + 1
    url = target
  end
end

return M
]]
M.sizes["lib/html/guard.lua"] = 9618
M.files["lib/html/guard.lua"] = [[
local computer = require("computer")

local M = {}

-- OpenOS kills a program that runs for 5 s without yielding.
local YIELD_INTERVAL = 1
-- In freeMemory() units (real bytes / ramScale).
local MEMORY_RESERVE = 192 * 1024
-- freeMemory() units are real bytes / RAM_SCALE (measured 1.800 in probe v2).
local RAM_SCALE = 1.8
-- The caller keeps one table slot per line. Lua doubles the array part of a
-- table when it is full: from capacity c to 2c it allocates 2c new slots of
-- 16 real bytes while the old slots are still live, so the doubling needs
-- 32 * c / RAM_SCALE free units at once. On large.html free memory hit 0 at
-- the 8192 to 16384 doubling. So the effective reserve is
-- max(MEMORY_RESERVE, 32 * c / RAM_SCALE), where c is the smallest power of
-- two >= the line count, at least TABLE_SLOTS_MIN.
local SLOT_DOUBLING = 32 / RAM_SCALE
local TABLE_SLOTS_MIN = 1024
-- A raw freeMemory() reading can be up to about 1.3 MB too low (measured),
-- because it includes garbage that is not collected yet. The OpenOS kernel
-- runs a full GC on every 10th resume of the main coroutine, so 11 yields
-- always include one GC.
local SETTLE_YIELDS = 11
-- A rise above the previous reading by more than this is a GC.
local GC_RISE_MIN = 16384
local GC_RISE_PART = 0.05
-- The rate limit waits at least this many lines between two settles.
local SETTLE_GAP_MIN = 25
-- Live cost per line in scaled units. Probe v2 measured about 66.5 per line
-- on large.html in 0.0.4a, and 46 to 76 between settles that saw a GC. The
-- start value and the floor stay a little above these values.
local LINE_COST_MIN = 80
local LINE_COST_START = 100
-- The stats trace line must stay under about 1000 characters.
local TRACE_MAX = 60

local last_yield = os.clock()
-- A function that returns true after Ctrl+C, or nil. reset() keeps it.
local interrupted
-- The lowest freeMemory() reading since the last reset. It includes garbage
-- that is not collected yet, so it is a lower bound of the real free memory.
local lowest

-- The memory trace: line count, freeMemory() reading and mark of every
-- trace_every-th tick, and of every settle in tick(). The mark is "" for a
-- raw reading, "s" for a settle and "S" for a settle that saw a GC. When the
-- trace is full, every second sample is dropped and trace_every doubles, so
-- the samples spread across the whole run.
local trace_lines, trace_free, trace_mark = {}, {}, {}
local trace_every, trace_ticks = 1, 0
local last_lines = 0

-- Settle counters since the last reset.
local settle_count, gc_count, yield_count = 0, 0, 0
-- The last settle in tick(): progress value, result, and whether it saw a GC.
-- Progress is the line count, or the tick count for a tick() without lines.
local settle_at, settle_result, settle_gc
-- The last settle in tick() that saw a GC, for the live cost per line.
local gc_line, gc_free
local line_cost = LINE_COST_START
local cost_measured = false
-- The table capacity c for the last line count and the effective reserve.
local slots = TABLE_SLOTS_MIN
local reserve = math.max(MEMORY_RESERVE, SLOT_DOUBLING * slots)

local function trace_add(free, mark)
  local n = #trace_lines
  if n >= TRACE_MAX then
    local j = 0
    for i = 2, n, 2 do
      j = j + 1
      trace_lines[j], trace_free[j], trace_mark[j] =
        trace_lines[i], trace_free[i], trace_mark[i]
    end
    for i = n, j + 1, -1 do
      trace_lines[i], trace_free[i], trace_mark[i] = nil, nil, nil
    end
    trace_every = trace_every * 2
    n = j
  end
  trace_lines[n + 1], trace_free[n + 1], trace_mark[n + 1] =
    last_lines, free, mark
end

local function yield()
  os.sleep(0)
  last_yield = os.clock()
end

local function read_free()
  local free = computer.freeMemory()
  if not lowest or free < lowest then
    lowest = free
  end
  return free
end

-- Yields until a GC is seen, at most SETTLE_YIELDS times. Returns the
-- highest reading and true when a GC was seen.
local function settle()
  local prev = read_free()
  local best = prev
  local gc = false
  for _ = 1, SETTLE_YIELDS do
    yield()
    yield_count = yield_count + 1
    local free = read_free()
    best = math.max(best, free)
    if free - prev > math.max(GC_RISE_MIN, prev * GC_RISE_PART) then
      gc = true
      break
    end
    prev = free
  end
  settle_count = settle_count + 1
  if gc then
    gc_count = gc_count + 1
  end
  return best, gc
end

-- The highest free memory reading over up to 11 yields. It stops at the
-- first GC it sees. The stats output uses it, because a single reading can
-- be up to about 1.3 MB too low.
function M.settled_free()
  return (settle())
end

-- The lowest reading seen by tick() and settled_free() since the last
-- reset, or nil when there was no reading.
function M.lowest_free()
  return lowest
end

-- The number of settles, the number of settles that saw a GC, and the
-- yields of all settles since the last reset.
function M.settles()
  return settle_count
end

function M.gc_seen()
  return gc_count
end

function M.settle_yields()
  return yield_count
end

-- The memory trace as "<line>:<free><mark>,...", oldest first, or "" when
-- there is no sample. <line> is the last line count given to tick(). <mark>
-- is "" for a raw reading, "s" for a settle, "S" for a settle with a GC.
function M.trace_text()
  local parts = {}
  for i = 1, #trace_lines do
    parts[i] = trace_lines[i] .. ":" .. trace_free[i] .. trace_mark[i]
  end
  return table.concat(parts, ",")
end

-- Starts the yield timer again and clears the lowest reading, the trace,
-- the settle state and the counters. Tests call this after they set the
-- clock.
function M.reset()
  last_yield = os.clock()
  lowest = nil
  trace_lines, trace_free, trace_mark = {}, {}, {}
  trace_every, trace_ticks = 1, 0
  last_lines = 0
  settle_count, gc_count, yield_count = 0, 0, 0
  settle_at, settle_result, settle_gc = nil, nil, nil
  gc_line, gc_free = nil, nil
  line_cost = LINE_COST_START
  cost_measured = false
  slots = TABLE_SLOTS_MIN
  reserve = math.max(MEMORY_RESERVE, SLOT_DOUBLING * slots)
end

-- Sets the function that tick() calls to check for Ctrl+C. When it returns
-- true, tick() raises "html: interrupted". nil removes the check.
function M.set_interrupt_check(fn)
  interrupted = fn
end

-- The effective reserve for the current line count. See SLOT_DOUBLING.
function M.reserve()
  return reserve
end

local function stop(lines)
  local progress = ""
  if lines then
    progress = " (rendered " .. lines .. " lines before stopping)"
  end
  error("html: page too large for available memory" .. progress, 0)
end

-- Settle rule. "reserve" is the effective reserve (see SLOT_DOUBLING).
-- A raw reading under the reserve settles only when the rate
-- limit allows it. After a settle at progress P with result F, the wait is
-- gap = max(25, (F - reserve) / (2 * B)). B is the live cost per line: 100
-- at the start, then the highest cost measured between two settles that saw
-- a GC, but at least 80. At B per line, one gap uses at most half of the
-- headroom F - reserve. The next settle comes when progress grew by gap, or
-- when progress grew by gap / 2 and a raw reading is under reserve / 2. The
-- second case covers lines that cost up to 2 * B. Between settles, a raw
-- reading under the reserve does not stop the render. A raw reading under
-- reserve / 2 after a settle that saw no GC stops the render at once:
-- without a GC, no settle lifts it over the reserve. Otherwise only a
-- settle result under the reserve stops the render. Every settle saw a GC
-- or used all 11 yields, so if the kernel stops its GC, the guard stops
-- early with the controlled message and never crashes.
local function check(free, lines)
  local progress = lines or trace_ticks
  if settle_at then
    if progress < settle_at then
      settle_at = progress
    end
    local low = free < reserve / 2
    if low and not settle_gc then
      stop(lines)
    end
    local gap = math.max(SETTLE_GAP_MIN,
      (settle_result - reserve) / (2 * line_cost))
    if low then
      gap = math.max(SETTLE_GAP_MIN, gap / 2)
    end
    if progress - settle_at < gap then
      return
    end
  end
  local best, gc = settle()
  trace_add(best, gc and "S" or "s")
  if best < reserve then
    stop(lines)
  end
  settle_at, settle_result, settle_gc = progress, best, gc
  if gc and lines then
    if gc_line and lines > gc_line then
      local cost = math.max(LINE_COST_MIN, (gc_free - best) / (lines - gc_line))
      if cost_measured then
        line_cost = math.max(line_cost, cost)
      else
        line_cost, cost_measured = cost, true
      end
    end
    gc_line, gc_free = lines, best
  end
end

local function yield_and_check()
  if os.clock() - last_yield > YIELD_INTERVAL then
    yield()
  end
  -- An event listener sets the flag during a yield, here or in a settle.
  if interrupted and interrupted() then
    error("html: interrupted", 0)
  end
end

-- Yields on time and checks the interrupt, with no memory check. For the
-- output loop, which keeps no new data.
function M.tick_output()
  yield_and_check()
end

-- lines is optional. It is the progress value in the memory error message.
function M.tick(lines)
  yield_and_check()
  if lines then
    last_lines = lines
    if lines > slots then
      repeat
        slots = slots * 2
      until slots >= lines
      reserve = math.max(MEMORY_RESERVE, SLOT_DOUBLING * slots)
    end
  end
  local free = read_free()
  trace_ticks = trace_ticks + 1
  if trace_ticks % trace_every == 0 then
    trace_add(free, "")
  end
  if free < reserve then
    check(free, lines)
  end
end

return M
]]
M.sizes["lib/html/layout.lua"] = 15010
M.files["lib/html/layout.lua"] = [[
-- Turns tokens into wrapped lines. There is no DOM tree, only a bounded
-- stack of open elements.
-- A line is one string. A non-empty line starts with a style byte (see
-- M.NORMAL and the others). A style lasts until the next style byte. Style
-- bytes never count toward the width. An empty line is "".

local guard = require("html.guard")
local unicode = require("unicode")

local M = {}

local byte, find, sub, rep, gsub = string.byte, string.find, string.sub,
  string.rep, string.gsub
local concat = table.concat
local tick = guard.tick

M.NORMAL = "\1"
M.HEADING = "\2"
M.EMPHASIS = "\3"
M.LINK = "\4"
M.PRE = "\5"

-- Open elements above this depth are not kept (see push_open).
M.MAX_DEPTH = 256

-- The title buffer takes at most this many bytes of raw text.
local TITLE_BUF = 1024
-- The first title text is kept up to this many bytes.
local TITLE_MAX = 256

local function set(...)
  local s = {}
  for _, k in ipairs({ ... }) do
    s[k] = true
  end
  return s
end

-- Dropped with all content. The text of title goes to title().
local DROP = set("script", "style", "template", "svg", "math", "iframe",
  "object", "noscript", "head", "title")

local BLOCK = set("p", "div", "section", "article", "main", "header",
  "footer", "nav", "aside", "blockquote", "table", "tr", "td", "th", "ul",
  "ol", "dl", "dt", "dd", "form", "input", "button", "select", "textarea",
  "pre", "li")

local HEADING = set("h1", "h2", "h3", "h4", "h5", "h6")

local EMPHASIS = set("b", "strong", "i", "em", "u", "mark")

-- Elements without content. They never go on the stack.
local VOID = set("area", "base", "br", "col", "embed", "hr", "img", "input",
  "keygen", "link", "meta", "param", "source", "track", "wbr")

-- A start tag of one of these closes an open p, as in HTML.
local CLOSES_P = set("p", "div", "section", "article", "main", "header",
  "footer", "nav", "aside", "blockquote", "table", "ul", "ol", "dl", "form",
  "pre", "li", "hr", "h1", "h2", "h3", "h4", "h5", "h6")

-- Implied ends: a start tag closes an open element of the listed names. The
-- search stops at an element in stops.
local P_SET = set("p")
local P_STOPS = {}
for k in pairs(BLOCK) do
  P_STOPS[k] = true
end
for k in pairs(HEADING) do
  P_STOPS[k] = true
end
local IMPLIED = {
  li = { set("li"), set("ul", "ol", "menu") },
  dt = { set("dt", "dd"), set("dl") },
  dd = { set("dt", "dd"), set("dl") },
  tr = { set("tr", "td", "th"), set("table") },
  td = { set("td", "th"), set("tr", "table") },
  th = { set("td", "th"), set("tr", "table") },
  option = { set("option"), set("select") },
}

local SPACE = "[ \t\n]"
local NOT_SPACE = "[^ \t\n]"
local NON_ASCII = "[\128-\255]"
local PRE_BREAK = "[\t\n]"

-- Returns a layout object for lines of at most width columns:
--   push(kind, value, attrs, self_closing)   one token from the tokenizer
--   count()                                  number of finished lines
--   finish()                                 ends the input, returns lines
--   title()                                  the document title, or nil
-- lines holds the finished lines while push runs.
function M.new(width)
  if width < 1 then
    width = 1
  end
  local lines, n = {}, 0
  -- Pieces of the current line, its width and the style of its last piece.
  local parts, np, cur_w = {}, 0, 0
  local lstyle = M.NORMAL
  -- Pieces of a word that is not placed yet, with their styles and widths.
  -- A word can span text tokens and inline tags.
  local word, wst, wwd, nw, ww = {}, {}, {}, 0, 0
  -- True when white space came after the last placed word.
  local space = false
  -- True when the pending word continues a word that was placed early
  -- because it was wider than the width.
  local cont = false
  -- True when the current line has a word. A prefix such as "- " is not a
  -- word, so white space after it is not kept.
  local has_word = false
  -- The open elements: name, style inside and pre flag inside.
  local sname, sstyle, spre, sd = {}, {}, {}, 0
  local style, in_pre = M.NORMAL, false
  -- Stack index of the outermost dropped element, or 0.
  local drop_at = 0
  -- Stack index of the open title element, or 0, and its text.
  local title_at, title_buf, title_len, title_text = 0, {}, 0, nil
  local title_bytes = 0
  -- True right after a pre start tag: one newline there is skipped.
  local pre_first = false
  local hr_line

  local function emit(line)
    n = n + 1
    lines[n] = line
    tick(n)
  end

  local function end_line()
    if np > 0 then
      emit(concat(parts, "", 1, np))
    else
      emit("")
    end
    np, cur_w = 0, 0
    has_word = false
  end

  -- Adds s (not empty) of w columns in style st to the current line.
  local function place(s, st, w)
    if np == 0 then
      parts[1], parts[2] = st, s
      np, lstyle = 2, st
    else
      if st ~= lstyle then
        np = np + 1
        parts[np] = st
        lstyle = st
      end
      np = np + 1
      parts[np] = s
    end
    cur_w = cur_w + w
  end

  -- Places s (not empty) at character boundaries. It fills the current line
  -- and goes on in new lines. A wide character never straddles the width.
  local function split(s, st)
    local len = #s
    if not find(s, NON_ASCII) then
      local i = 1
      while i <= len do
        local room = width - cur_w
        if room <= 0 then
          end_line()
          room = width
        end
        local j = i + room - 1
        if j > len then
          j = len
        end
        place(sub(s, i, j), st, j - i + 1)
        i = j + 1
      end
      return
    end
    local wlen = unicode.wlen
    local i, from, w = 1, 1, 0
    while i <= len do
      local b = byte(s, i)
      local size = b < 0x80 and 1 or b >= 0xF0 and 4 or b >= 0xE0 and 3
        or 2
      local cw = b < 0x80 and 1 or wlen(sub(s, i, i + size - 1))
      if cur_w + w + cw > width and cur_w + w > 0 then
        if i > from then
          place(sub(s, from, i - 1), st, w)
        end
        end_line()
        from, w = i, 0
      end
      w = w + cw
      i = i + size
    end
    if from <= len then
      place(sub(s, from), st, w)
    end
  end

  -- Places the pending word, with one space before it when white space
  -- came before it. With partial, the word goes on in later pieces.
  local function commit(partial)
    if nw == 0 then
      cont = cont and partial or false
      return
    end
    local gap = (space and has_word and not cont) and 1 or 0
    space = false
    if cur_w + gap + ww > width and has_word and not cont then
      end_line()
      gap = 0
    end
    if cur_w + gap + ww <= width then
      if gap == 1 then
        place(" ", lstyle, 1)
      end
      for i = 1, nw do
        place(word[i], wst[i], wwd[i])
      end
    else
      for i = 1, nw do
        if cur_w + wwd[i] <= width then
          place(word[i], wst[i], wwd[i])
        else
          split(word[i], wst[i])
        end
      end
    end
    nw, ww = 0, 0
    has_word = true
    cont = partial or false
  end

  local function add_piece(s, ascii)
    local w = ascii and #s or unicode.wlen(s)
    nw = nw + 1
    word[nw], wst[nw], wwd[nw] = s, style, w
    ww = ww + w
    -- A word wider than the width is split now, so it stays small.
    if ww > width then
      commit(true)
    end
  end

  -- Text outside pre: white space collapses, words wrap.
  local function add_text(s)
    local ascii = not find(s, NON_ASCII)
    local i, len = 1, #s
    while i <= len do
      local ws = find(s, SPACE, i)
      if not ws then
        add_piece(i == 1 and s or sub(s, i), ascii)
        return
      end
      if ws > i then
        add_piece(sub(s, i, ws - 1), ascii)
      end
      commit()
      space = has_word
      local nxt = find(s, NOT_SPACE, ws + 1)
      if not nxt then
        return
      end
      i = nxt
    end
  end

  -- Text inside pre: spaces and newlines stay, a tab goes to the next
  -- 8-column stop, long lines wrap hard at the width.
  local function pre_text(s)
    if pre_first then
      pre_first = false
      if byte(s, 1) == 10 then
        s = sub(s, 2)
      end
    end
    local i, len = 1, #s
    while i <= len do
      local j = find(s, PRE_BREAK, i)
      local stop = j and j - 1 or len
      if stop >= i then
        split(sub(s, i, stop), style)
      end
      if not j then
        return
      end
      if byte(s, j) == 10 then
        end_line()
      else
        if cur_w >= width then
          end_line()
        end
        local sp = 8 - cur_w % 8
        if cur_w + sp > width then
          sp = width - cur_w
        end
        place(rep(" ", sp), style, sp)
      end
      i = j + 1
    end
  end

  -- Ends the current line if it has content.
  local function block()
    commit()
    space = false
    if np > 0 then
      end_line()
    end
  end

  -- Adds one blank line, never two in a row and never at the start.
  local function blank()
    if n > 0 and lines[n] ~= "" then
      emit("")
    end
  end

  -- Adds text to the title buffer. Stops at TITLE_BUF bytes and cuts the
  -- piece that crosses the limit at a character boundary. Leading white
  -- space is dropped and does not count toward the limit.
  local function add_title(value)
    if title_at == 0 or title_len >= 64 or title_bytes >= TITLE_BUF then
      return
    end
    if title_bytes == 0 then
      value = gsub(value, "^[ \t\n\r\f]+", "")
      if value == "" then
        return
      end
    end
    local room = TITLE_BUF - title_bytes
    if #value > room then
      local cut = room
      while cut > 0 do
        local b = byte(value, cut + 1)
        if b < 0x80 or b >= 0xC0 then
          break
        end
        cut = cut - 1
      end
      value = sub(value, 1, cut)
    end
    title_bytes = title_bytes + #value
    title_len = title_len + 1
    title_buf[title_len] = value
  end

  local function end_title()
    local s = concat(title_buf, "", 1, title_len)
    s = gsub(gsub(s, "[ \t\n]+", " "), "^ ", "")
    s = gsub(s, " $", "")
    if #s > TITLE_MAX then
      local cut = TITLE_MAX
      -- Cut at a character boundary.
      while cut > 0 do
        local b = byte(s, cut + 1)
        if b < 0x80 or b >= 0xC0 then
          break
        end
        cut = cut - 1
      end
      s = sub(s, 1, cut)
    end
    if s ~= "" then
      title_text = s
    end
    title_buf, title_len, title_bytes = nil, 0, 0
  end

  -- Closes the innermost open element and applies its end rule.
  local function close_top()
    local name = sname[sd]
    sname[sd] = nil
    sd = sd - 1
    if sd > 0 then
      style, in_pre = sstyle[sd], spre[sd]
    else
      style, in_pre = M.NORMAL, false
    end
    if title_at > sd then
      title_at = 0
      end_title()
    end
    if drop_at > 0 then
      if drop_at > sd then
        drop_at = 0
      end
      return
    end
    if HEADING[name] then
      block()
      blank()
    elseif BLOCK[name] then
      block()
    end
  end

  -- Closes open elements down to and including index i.
  local function close_to(i)
    while sd >= i do
      close_top()
    end
  end

  -- Closes the innermost open element named in names, unless an element
  -- in stops comes first.
  local function close_open(names, stops)
    for i = sd, 1, -1 do
      local name = sname[i]
      if names[name] then
        close_to(i)
        return
      elseif stops[name] then
        return
      end
    end
  end

  -- Opens an element. At the depth bound, the new element is not kept:
  -- its start rule still applies, but its style, pre and drop rules do not.
  -- A dropped element is the exception outside a dropped part: it closes
  -- the innermost element to make room, so its content stays hidden.
  local function push_open(name, st, pre)
    if sd >= M.MAX_DEPTH then
      if drop_at > 0 or not DROP[name] then
        return false
      end
      close_top()
    end
    sd = sd + 1
    sname[sd], sstyle[sd], spre[sd] = name, st, pre
    style, in_pre = st, pre
    return true
  end

  local function start_tag(name, attrs, self_closing)
    pre_first = false
    local void = VOID[name] or self_closing
    if name == "body" then
      -- An unclosed head ends at body.
      for i = sd, 1, -1 do
        if sname[i] == "head" then
          close_to(i)
          break
        end
      end
    end
    if drop_at > 0 then
      -- A title in head is the document title. A title in svg is not.
      if not void and push_open(name, style, in_pre) and name == "title"
          and sname[drop_at] == "head" and title_buf and title_at == 0 then
        title_at = sd
      end
      return
    end
    if CLOSES_P[name] then
      close_open(P_SET, P_STOPS)
    end
    local imp = IMPLIED[name]
    if imp then
      close_open(imp[1], imp[2])
    end
    if DROP[name] then
      if not void and push_open(name, style, in_pre) then
        drop_at = sd
        if name == "title" and title_buf then
          title_at = sd
        end
      end
      return
    end
    local st, pre = style, in_pre
    if HEADING[name] then
      block()
      blank()
      st = M.HEADING
    elseif EMPHASIS[name] then
      st = M.EMPHASIS
    elseif name == "a" then
      if attrs and attrs.href then
        st = M.LINK
      end
    elseif name == "br" then
      commit()
      space = false
      end_line()
    elseif name == "hr" then
      block()
      hr_line = hr_line or M.NORMAL .. rep("─", width)
      emit(hr_line)
    elseif name == "img" then
      local alt = attrs and attrs.alt
      if alt then
        alt = gsub(gsub(gsub(alt, "[ \t\n]+", " "), "^ ", ""), " $", "")
      end
      local s = (alt and alt ~= "") and "[img: " .. alt .. "]" or "[img]"
      if in_pre then
        pre_text(s)
      else
        add_text(s)
      end
    elseif name == "li" then
      block()
      if width > 2 then
        place("- ", style, 2)
      end
    elseif name == "pre" then
      block()
      st, pre = M.PRE, true
    elseif BLOCK[name] then
      block()
    end
    if not void then
      push_open(name, st, pre)
      if name == "pre" then
        pre_first = true
      end
    end
  end

  local function end_tag(name)
    pre_first = false
    for i = sd, 1, -1 do
      if sname[i] == name then
        close_to(i)
        return
      end
    end
  end

  local self = { lines = lines }

  function self.push(kind, value, attrs, self_closing)
    if kind == "text" then
      if value == "" then
        return
      end
      if drop_at > 0 then
        add_title(value)
      elseif in_pre then
        pre_text(value)
      else
        add_text(value)
      end
      tick(n)
    elseif kind == "start" then
      start_tag(value, attrs, self_closing)
    elseif kind == "end" then
      end_tag(value)
    end
  end

  function self.count()
    return n
  end

  function self.title()
    return title_text
  end

  function self.finish()
    close_to(1)
    block()
    while n > 0 and lines[n] == "" do
      lines[n] = nil
      n = n - 1
    end
    return lines
  end

  return self
end

return M
]]
M.sizes["lib/html/text.lua"] = 4590
M.files["lib/html/text.lua"] = [[
-- Text cleaning. Runs in plain Lua before any unicode.* call, because
-- unicode.* turns bad bytes into U+FFFD silently and utf8.len accepts
-- encoded surrogates.

local M = {}

local byte, find, sub = string.byte, string.find, string.sub
local concat = table.concat

-- Any byte that is not printable ASCII, tab or newline.
local SPECIAL = "[^\t\n\32-\126]"

-- An entity name or numeric reference is never longer than this.
M.MAX_ENTITY = 32

-- Returns the length of the valid UTF-8 sequence at i, or nil and the
-- length of the maximal invalid subpart (Unicode recommended practice).
local function sequence(s, i, b)
  local need, lo, hi
  if b >= 0xC2 and b <= 0xDF then
    need, lo, hi = 1, 0x80, 0xBF
  elseif b == 0xE0 then
    need, lo, hi = 2, 0xA0, 0xBF
  elseif b == 0xED then
    -- A0..BF here would encode a surrogate.
    need, lo, hi = 2, 0x80, 0x9F
  elseif b >= 0xE1 and b <= 0xEF then
    need, lo, hi = 2, 0x80, 0xBF
  elseif b == 0xF0 then
    need, lo, hi = 3, 0x90, 0xBF
  elseif b == 0xF4 then
    -- 90..BF here would be above U+10FFFF.
    need, lo, hi = 3, 0x80, 0x8F
  elseif b >= 0xF1 and b <= 0xF3 then
    need, lo, hi = 3, 0x80, 0xBF
  else
    return nil, 1
  end
  local c = byte(s, i + 1)
  if not c or c < lo or c > hi then
    return nil, 1
  end
  for k = 2, need do
    c = byte(s, i + k)
    if not c or c < 0x80 or c > 0xBF then
      return nil, k
    end
  end
  return need + 1
end

-- True for C1 controls (U+0080..U+009F), the soft hyphen (U+00AD),
-- zero-width or invisible characters (U+200B..U+200F, U+FEFF) and the
-- variation selectors (U+FE00..U+FE0F). unicode.wlen counts U+200B and
-- U+FE0F as width 2 (measured).
local function removed(s, i, len)
  local b1, b2, b3 = byte(s, i, i + 2)
  if len == 2 then
    return b1 == 0xC2 and (b2 <= 0x9F or b2 == 0xAD)
  end
  if len == 3 then
    return (b1 == 0xE2 and b2 == 0x80 and b3 >= 0x8B and b3 <= 0x8F)
      or (b1 == 0xEF and b2 == 0xBB and b3 == 0xBF)
      or (b1 == 0xEF and b2 == 0xB8 and b3 >= 0x80 and b3 <= 0x8F)
  end
  return false
end

-- Returns s as valid UTF-8 with no control bytes except tab and newline.
-- Bad sequences become one "?" per maximal invalid subpart.
function M.clean(s)
  local i = find(s, SPECIAL)
  if not i then
    return s
  end
  local parts, n = {}, 0
  local run = 1
  local len = #s
  while i do
    local b = byte(s, i)
    local keep, skip, mark
    if b < 0x80 then
      -- Control bytes (0x01-0x05 are style bytes), \r and DEL.
      skip = 1
    else
      local ok, bad = sequence(s, i, b)
      if ok then
        if removed(s, i, ok) then
          skip = ok
        else
          keep = ok
        end
      else
        skip, mark = bad, true
      end
    end
    if keep then
      i = i + keep
    else
      if i > run then
        n = n + 1
        parts[n] = sub(s, run, i - 1)
      end
      if mark then
        n = n + 1
        parts[n] = "?"
      end
      i = i + skip
      run = i
    end
    if i > len then
      break
    end
    i = find(s, SPECIAL, i)
  end
  if run <= len then
    n = n + 1
    parts[n] = sub(s, run)
  end
  return concat(parts)
end

-- Returns the start of a partial UTF-8 sequence at the end of s[i..j], or
-- j + 1 when there is none. A partial sequence is a lead byte in the last
-- 3 bytes with too few followers. Bytes before the result can be cleaned
-- apart from the bytes after it: clean(a .. b) == clean(a) .. clean(b).
function M.utf8_cut(s, i, j)
  for k = j, math.max(i, j - 2), -1 do
    local b = byte(s, k)
    if b < 0x80 or b >= 0xC0 then
      local need = b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC2 and 2 or 1
      if j - k + 1 < need then
        return k
      end
      return j + 1
    end
  end
  return j + 1
end

-- Splits s into head and tail. The tail is a trailing piece that the next
-- chunk may complete: a partial UTF-8 sequence or a partial entity. A
-- streaming caller cleans the head and puts the tail before the next chunk.
-- At the end of a text run the caller passes the whole rest, not split.
function M.split_tail(s)
  local len = #s
  local cut = M.utf8_cut(s, 1, len)
  -- Partial entity: "&" then only "#" and alphanumerics up to the end.
  for k = cut - 1, math.max(1, cut - 1 - M.MAX_ENTITY), -1 do
    local b = byte(s, k)
    if b == 0x26 then
      cut = k
      break
    end
    if not (b == 0x23 or (b >= 0x30 and b <= 0x39)
        or (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A)) then
      break
    end
  end
  if cut > len then
    return s, ""
  end
  return sub(s, 1, cut - 1), sub(s, cut)
end

return M
]]
M.sizes["lib/html/tokenizer.lua"] = 15231
M.files["lib/html/tokenizer.lua"] = [=[
-- Streaming, forgiving tokenizer. It reads chunks from a reader function
-- and returns one token per call. It scans with plain string.find and
-- string.byte. A pattern find runs only on a tag name. gsub and gmatch are
-- slow on large text and do not yield.
--
-- Tokens (the values a call returns):
--   "start", name, attrs, self_closing
--   "end", name
--   "text", s           (cleaned and decoded, maybe empty)
--   nil                 (end of input)
-- Names are lowercase. attrs maps a lowercase name to its cleaned and
-- decoded value, or is nil when the tag has no attributes.
-- Comments, doctype, CDATA and processing instructions are skipped. The
-- content of script and style is skipped up to the matching end tag. The
-- content of title and textarea is text up to the matching end tag.
--
-- Recovery for broken markup:
--   "<" + non-letter is text. "</>" is dropped. "</" + non-letter is a bogus
--   comment up to ">".
--   A "<" with no ">" within MAX_TAG bytes is text. At the end of input,
--   such a tag is dropped.
--   A broken quoted value ends the tag at the first ">" in the value. The
--   value's attribute is dropped. A quoted value is broken when it does not
--   close within MAX_TAG bytes of "<" or before the end of input, or when
--   it holds a ">" and then "</" (as in <a href="x>text</a>).
--   A tag that does not end within MAX_TAG bytes for another reason ends at
--   the first ">" after its "<", with no attributes.
--   An attribute name with a quote or "<", or one that starts with "=", is
--   dropped. For a duplicate name, the first value is kept.
--   An unclosed comment, bogus comment, CDATA or raw text element ends with
--   the input. Unclosed title or textarea content is text.

local guard = require("html.guard")
local text = require("html.text")
local entities = require("html.entities")

local M = {}

local byte, find, sub, lower = string.byte, string.find, string.sub,
  string.lower
local max = math.max
local clean, split_tail, utf8_cut, decode = text.clean, text.split_tail,
  text.utf8_cut, entities.decode

-- A "<" with no ">" within this many bytes is text. This bounds the buffer.
M.MAX_TAG = 16384

-- Raw text elements. true: the content is text (RCDATA). false: the
-- content is skipped.
local RAW = { script = false, style = false, title = true, textarea = true }

-- HTML whitespace: tab, LF, FF, CR, space.
local WS = { [9] = true, [10] = true, [12] = true, [13] = true, [32] = true }

-- Attribute scanner states.
local BEFORE_NAME, NAME, AFTER_NAME, BEFORE_VALUE, UNQUOTED, QUOTED, SLASH =
  1, 2, 3, 4, 5, 6, 7

local function is_letter(b)
  return b ~= nil and ((b >= 65 and b <= 90) or (b >= 97 and b <= 122))
end

-- Adds one attribute. Returns the attrs table, made on the first call.
local function add(attrs, name, value)
  name = lower(name)
  attrs = attrs or {}
  if attrs[name] == nil then
    attrs[name] = value ~= "" and decode(clean(value)) or ""
  end
  return attrs
end

-- read() returns the next chunk, or nil at the end of input.
-- progress() is optional. Its result is the line count in a memory error.
-- Returns a function that returns the next token.
function M.new(read, progress)
  local buf, pos, eof = "", 1, false
  -- Stream offset of buf: byte i of buf is byte base + i of the input.
  local base = 0
  -- Stream offset of the last byte of a run with no ">". A later search
  -- for ">" starts after it, so many "<" with no ">" stay linear.
  local nogt
  -- Terminator of a skipped comment or bogus tag.
  local skip_to
  -- Name of the open raw text element, and true when its content is text.
  local raw, rcdata
  -- Cleaned end of the current text run that may start an entity. It waits
  -- for the rest of the run, so the run gives decode(clean(run)).
  local pend = ""

  local function tick()
    guard.tick(progress and progress())
  end

  -- Keeps the bytes from pos and appends the next chunk. Positions in buf
  -- move: pos becomes 1. Returns false at the end of input.
  local function fill()
    if eof then
      return false
    end
    local chunk = read()
    if chunk == nil then
      eof = true
      return false
    end
    if pos > #buf then
      base = base + #buf
      buf = chunk
    else
      base = base + pos - 1
      buf = sub(buf, pos) .. chunk
    end
    pos = 1
    return true
  end

  -- Makes sure that n bytes from pos are in buf. False at the end of input.
  local function want(n)
    while #buf - pos + 1 < n do
      tick()
      if not fill() then
        return false
      end
    end
    return true
  end

  -- Takes buf[pos..j] as a part of a text run. A cut UTF-8 sequence at the
  -- end stays in buf, so clean never sees half a character. A possible
  -- entity at the end of the cleaned text goes to pend. Returns the decoded
  -- rest.
  local function take(j)
    local cut = utf8_cut(buf, pos, j)
    local s = clean(sub(buf, pos, cut - 1))
    pos = cut
    if pend ~= "" then
      s = pend .. s
    end
    s, pend = split_tail(s)
    return decode(s)
  end

  -- Ends a text run with buf[pos..j]. Returns the decoded text with pend.
  local function finish(j)
    local s = clean(sub(buf, pos, j))
    pos = j + 1
    if pend ~= "" then
      s, pend = pend .. s, ""
    end
    return decode(s)
  end

  -- Skips to the end of a comment or bogus tag.
  local function skip()
    local _, e = find(buf, skip_to, pos, true)
    if e then
      pos = e + 1
      skip_to = nil
      return
    end
    -- Keep the bytes that can start the terminator.
    pos = max(pos, #buf - #skip_to + 2)
    if not fill() then
      pos = #buf + 1
      skip_to = nil
    end
  end

  -- Streams the content of a raw text element up to "</name" followed by
  -- whitespace, "/" or ">". Returns a text token for RCDATA content.
  local function raw_step()
    if pos > #buf then
      if not fill() then
        raw = nil
        if pend ~= "" then
          return "text", finish(#buf)
        end
      end
      return nil
    end
    local k = find(buf, "</", pos, true)
    if not k then
      -- Keep a last "<" and, for text, a cut UTF-8 sequence or entity.
      local keep = byte(buf, #buf) == 60 and #buf or #buf + 1
      local s = ""
      if rcdata then
        s = take(keep - 1)
      else
        pos = keep
      end
      if not fill() then
        if rcdata then
          s = s .. finish(#buf)
        end
        pos = #buf + 1
        raw = nil
      end
      if s ~= "" then
        return "text", s
      end
      return nil
    end
    if rcdata and (k > pos or pend ~= "") then
      return "text", finish(k - 1)
    end
    pos = k
    if not want(#raw + 3) then
      -- Too short for an end tag. The rest of the input is content.
      local s = sub(buf, pos)
      pos = #buf + 1
      raw = nil
      if rcdata then
        return "text", decode(clean(s))
      end
      return nil
    end
    local c = byte(buf, pos + 2 + #raw)
    if lower(sub(buf, pos + 2, pos + 1 + #raw)) == raw
        and (WS[c] or c == 47 or c == 62) then
      -- The main loop reads the end tag.
      raw = nil
      return nil
    end
    pos = pos + 2
    if rcdata then
      return "text", "</"
    end
    return nil
  end

  -- Ends a broken tag. In a broken quoted value (vs is its start), the tag
  -- ends at the first ">" in the value and keeps the attributes before it.
  -- Otherwise it ends at gt, the first ">" after "<", with no attributes.
  local function cut(attrs, vs, gt)
    if vs then
      local g = find(buf, ">", vs, true)
      if g and g - pos <= M.MAX_TAG then
        pos = g + 1
        return attrs, false
      end
    end
    pos = gt + 1
    return nil, false
  end

  -- Scans the attributes from i up to the ">" that ends the tag. gt is the
  -- first ">" after the "<" at pos. Sets pos after the tag. Returns attrs
  -- and the self-closing flag. An end tag (closing) collects no attrs.
  -- A quoted value is broken when it does not close within MAX_TAG bytes of
  -- "<" or before the end of input, or when it holds a ">" and then "</"
  -- (as in <a href="x>text</a>).
  local function attributes(i, gt, closing)
    local state = BEFORE_NAME
    local attrs, name, ns, vs, quote, bad
    while true do
      if i - pos > M.MAX_TAG then
        return cut(attrs, state == QUOTED and vs, gt)
      end
      if i > #buf then
        -- Only a quoted value can carry the scan past gt.
        tick()
        local old = pos
        if not fill() then
          return cut(attrs, state == QUOTED and vs, gt)
        end
        local d = old - 1
        i, gt = i - d, gt - d
        if ns then
          ns = ns - d
        end
        if vs then
          vs = vs - d
        end
      end
      local b = byte(buf, i)
      if state == QUOTED then
        local k = find(buf, quote, i, true)
        if not k then
          i = #buf + 1
        elseif k - pos > M.MAX_TAG then
          -- The same result as a scan that never sees this quote.
          return cut(attrs, vs, gt)
        else
          if k > gt then
            -- The value may hold ">" and then "</".
            -- Search only inside the tag, from the value start up to k.
            local seg = sub(buf, vs, k - 1)
            local g = find(seg, ">", 1, true)
            if g and find(seg, "</", g, true) then
              return cut(attrs, vs, gt)
            end
          end
          if not (closing or bad) then
            attrs = add(attrs, name, sub(buf, vs, k - 1))
          end
          state, vs, i = BEFORE_NAME, nil, k + 1
        end
      elseif state == BEFORE_NAME then
        if b == 62 then
          break
        elseif b == 47 then
          state = SLASH
        elseif not WS[b] then
          state, ns = NAME, i
          bad = b == 61 or b == 34 or b == 39 or b == 60
        end
        i = i + 1
      elseif state == NAME then
        if WS[b] or b == 61 or b == 62 or b == 47 then
          name, ns = sub(buf, ns, i - 1), nil
          if b == 61 then
            state = BEFORE_VALUE
          elseif WS[b] then
            state = AFTER_NAME
          else
            if not (closing or bad) then
              attrs = add(attrs, name, "")
            end
            if b == 62 then
              break
            end
            state = SLASH
          end
        elseif b == 34 or b == 39 or b == 60 then
          bad = true
        end
        i = i + 1
      elseif state == AFTER_NAME then
        if b == 61 then
          state = BEFORE_VALUE
        elseif not WS[b] then
          if not (closing or bad) then
            attrs = add(attrs, name, "")
          end
          if b == 62 then
            break
          elseif b == 47 then
            state = SLASH
          else
            state, ns = NAME, i
            bad = b == 34 or b == 39 or b == 60
          end
        end
        i = i + 1
      elseif state == BEFORE_VALUE then
        if b == 34 or b == 39 then
          state, quote, vs = QUOTED, b == 34 and '"' or "'", i + 1
        elseif b == 62 then
          if not (closing or bad) then
            attrs = add(attrs, name, "")
          end
          break
        elseif not WS[b] then
          state, vs = UNQUOTED, i
        end
        i = i + 1
      elseif state == UNQUOTED then
        if WS[b] or b == 62 then
          if not (closing or bad) then
            attrs = add(attrs, name, sub(buf, vs, i - 1))
          end
          if b == 62 then
            break
          end
          state, vs = BEFORE_NAME, nil
        end
        i = i + 1
      else -- SLASH
        if b == 62 then
          pos = i + 1
          return attrs, true
        end
        -- Read the byte again as the start of a name.
        state = BEFORE_NAME
      end
    end
    pos = i + 1
    return attrs, false
  end

  -- Reads the markup at pos, which is "<". Returns a token, or nil when the
  -- markup was skipped.
  local function tag()
    if not want(2) then
      pos = #buf + 1
      return "text", "<"
    end
    local b = byte(buf, pos + 1)
    if b == 33 then -- "!"
      want(9)
      if sub(buf, pos, pos + 3) == "<!--" then
        local c1, c2 = byte(buf, pos + 4, pos + 5)
        if c1 == 62 then -- "<!-->"
          pos = pos + 5
        elseif c1 == 45 and c2 == 62 then -- "<!--->"
          pos = pos + 6
        else
          skip_to, pos = "-->", pos + 4
        end
      elseif sub(buf, pos + 2, pos + 8) == "[CDATA[" then
        skip_to, pos = "]]>", pos + 9
      else
        skip_to, pos = ">", pos + 2
      end
      return nil
    end
    if b == 63 then -- "?"
      skip_to, pos = ">", pos + 2
      return nil
    end
    local closing = b == 47 -- "/"
    local rel = closing and 2 or 1
    if closing and not want(3) then
      pos = #buf + 1
      return "text", "</"
    end
    if not is_letter(byte(buf, pos + rel)) then
      if closing then
        -- "</>" is dropped. "</ x>" is a bogus comment.
        skip_to, pos = ">", pos + 2
        return nil
      end
      pos = pos + 1
      return "text", "<"
    end
    local from = pos + rel
    if nogt and nogt - base >= from then
      from = nogt - base + 1
    end
    local gt = find(buf, ">", from, true)
    while not gt do
      nogt = base + #buf
      if #buf - pos + 1 > M.MAX_TAG then
        pos = pos + 1
        return "text", "<"
      end
      tick()
      if not fill() then
        -- A tag cut by the end of input is dropped.
        pos = #buf + 1
        return nil
      end
      gt = find(buf, ">", nogt - base + 1, true)
    end
    if gt - pos > M.MAX_TAG then
      pos = pos + 1
      return "text", "<"
    end
    local start = pos + rel
    local _, e = find(buf, "^[^%s/>]+", start)
    local name = lower(sub(buf, start, e))
    local attrs, self_closing
    local nb = byte(buf, e + 1)
    if nb == 62 then
      pos, self_closing = e + 2, false
    elseif nb == 47 and byte(buf, e + 2) == 62 then
      pos, self_closing = e + 3, true
    else
      attrs, self_closing = attributes(e + 1, gt, closing)
    end
    if closing then
      return "end", name
    end
    local r = RAW[name]
    if r ~= nil then
      raw, rcdata = name, r
    end
    return "start", name, attrs, self_closing
  end

  return function()
    while true do
      tick()
      if skip_to then
        skip()
      elseif raw then
        local kind, s = raw_step()
        if kind then
          return kind, s
        end
      else
        if pos > #buf and not fill() then
          if pend ~= "" then
            return "text", finish(#buf)
          end
          return nil
        end
        local lt = find(buf, "<", pos, true)
        if not lt then
          if eof then
            return "text", finish(#buf)
          end
          -- A UTF-8 sequence or entity cut by the chunk end waits for the
          -- next chunk.
          local s = take(#buf)
          fill()
          if s ~= "" then
            return "text", s
          end
        elseif lt > pos or pend ~= "" then
          return "text", finish(lt - 1)
        else
          local kind, name, attrs, self_closing = tag()
          if kind then
            return kind, name, attrs, self_closing
          end
        end
      end
    end
  end
end

return M
]=]
M.sizes["lib/html/viewer.lua"] = 8913
M.files["lib/html/viewer.lua"] = [[
-- Full-screen viewer for laid-out lines (see lib/html/layout.lua).
-- Rows 1 to h-1 show lines. Row h is the status line.
-- All screen and input access goes through deps, so tests can fake it:
--   deps.gpu    a GPU component proxy
--   deps.pull   event.pull: pull(timeout) returns name, ... or nil
--   deps.term   a table with clear() and setCursor(x, y)

local unicode = require("unicode")

local M = {}

local byte, find, sub, rep, format = string.byte, string.find, string.sub,
  string.rep, string.format
local wlen, wtrunc = unicode.wlen, unicode.wtrunc

-- Style bytes, as in lib/html/layout.lua.
local NORMAL, HEADING, EMPHASIS, LINK, PRE = 1, 2, 3, 4, 5
local STYLE_BYTES = "[\1-\5]"

local BLACK = 0x000000
local WHITE = 0xFFFFFF

-- RGB values on a black background. They are colors of the default tier 2
-- palette, so depth 4 shows them without a shift to another color.
local COLORS = {
  [NORMAL] = 0xFFFFFF,
  [HEADING] = 0xFFFF33,
  [EMPHASIS] = 0xFFCC33,
  [LINK] = 0x6699FF,
  [PRE] = 0x33CC33,
}
local PLAIN = {
  [NORMAL] = WHITE, [HEADING] = WHITE, [EMPHASIS] = WHITE, [LINK] = WHITE,
  [PRE] = WHITE,
}

-- Standard key codes are always navigation keys.
local STANDARD_KEYS = {
  [200] = "up", [208] = "down", [201] = "pgup", [209] = "pgdn",
  [199] = "home", [207] = "end",
}
-- NumPad codes navigate only with char 0. A digit char means NumLock is on.
local NUMPAD_KEYS = {
  [72] = "up", [80] = "down", [73] = "pgup", [81] = "pgdn",
  [71] = "home", [79] = "end",
}
local CHAR_CTRL_C = 3
local CHAR_ENTER = 13
local CODE_ENTER = 28
local CHAR_Q, CHAR_UPPER_Q = 113, 81
local CHAR_Y, CHAR_UPPER_Y = 121, 89

-- event.pull with a timeout, so the program yields while it waits.
local IDLE_TIMEOUT = 1

local HINT = "Up Dn PgUp PgDn Home End q:quit"
local SHORT_HINT = "q:quit"
-- The full hint is used only when the title keeps this many columns.
local TITLE_MIN = 20
local PROMPT = " Quit? (y/n)"

-- Returns "interrupted", "quit", a navigation name, or nil for other events.
local function classify(name, char, code)
  if name == "interrupted" then
    return "interrupted"
  end
  if name ~= "key_down" then
    return nil
  end
  if char == CHAR_CTRL_C then
    return "interrupted"
  end
  local nav = STANDARD_KEYS[code]
  if not nav and char == 0 then
    nav = NUMPAD_KEYS[code]
  end
  if nav then
    return nav
  end
  if char == CHAR_Q or char == CHAR_UPPER_Q then
    return "quit"
  end
  return nil
end

local function is_nav(action)
  return action ~= nil and action ~= "quit" and action ~= "interrupted"
end

-- Truncates s to at most width columns.
local function fit(s, width)
  if width <= 0 then
    return ""
  end
  if wlen(s) <= width then
    return s
  end
  -- wtrunc keeps characters while the width is below its limit.
  return wtrunc(s, width + 1)
end

local function view(lines, opts, gpu, pull)
  local w, h = gpu.getResolution()
  local rows = h - 1
  local count = #lines
  local max_top = math.max(1, count - rows + 1)
  local page = math.max(1, rows - 1)
  local top = 1

  local color = gpu.getDepth() > 1 and COLORS or PLAIN
  local status_fg, status_bg = WHITE, BLACK
  if color == COLORS then
    status_fg, status_bg = BLACK, WHITE
  end

  local title = opts.title or opts.file or ""
  title = title:gsub("%c", " ")

  -- The colors are unknown at start, so the first set always happens.
  local cur_fg, cur_bg
  local function set_fg(c)
    if c ~= cur_fg then
      gpu.setForeground(c)
      cur_fg = c
    end
  end
  local function set_bg(c)
    if c ~= cur_bg then
      gpu.setBackground(c)
      cur_bg = c
    end
  end

  local function draw_row(y)
    local line = lines[top + y - 1] or ""
    set_bg(BLACK)
    local x, pos, len = 1, 1, #line
    local style = NORMAL
    while pos <= len do
      local b = byte(line, pos)
      if b >= NORMAL and b <= PRE then
        style = b
        pos = pos + 1
      else
        local stop = find(line, STYLE_BYTES, pos)
        local last = (stop or len + 1) - 1
        local text = sub(line, pos, last)
        set_fg(color[style])
        gpu.set(x, y, text)
        x = x + wlen(text)
        pos = last + 1
      end
    end
    if x <= w then
      gpu.fill(x, y, w - x + 1, 1, " ")
    end
  end

  local function draw_rows(from, to)
    for y = from, to do
      draw_row(y)
    end
  end

  local function draw_status_text(text)
    set_fg(status_fg)
    set_bg(status_bg)
    text = fit(text, w)
    gpu.set(1, h, text .. rep(" ", w - wlen(text)))
  end

  local function draw_status()
    local pct = 100
    if max_top > 1 then
      pct = (top - 1) * 100 // (max_top - 1)
    end
    local right = format(" %3d%%  %s ", pct, HINT)
    if w - 1 - #right < TITLE_MIN then
      right = format(" %3d%%  %s ", pct, SHORT_HINT)
    end
    local left = " " .. fit(title, w - 1 - #right)
    draw_status_text(left .. rep(" ", w - #right - wlen(left)) .. right)
  end

  local function move(target, action)
    if action == "up" then
      target = target - 1
    elseif action == "down" then
      target = target + 1
    elseif action == "pgup" then
      target = target - page
    elseif action == "pgdn" then
      target = target + page
    elseif action == "home" then
      target = 1
    else
      target = max_top
    end
    return math.max(1, math.min(max_top, target))
  end

  -- A scroll of 1 to rows - 1 lines moves the rest with copy. copy leaves
  -- the source rows as they were, so the exposed rows are always drawn.
  local function scroll_to(target)
    local d = target - top
    if d == 0 then
      return
    end
    top = target
    if d > 0 and d < rows then
      gpu.copy(1, 1 + d, w, rows - d, 0, -d)
      draw_rows(rows - d + 1, rows)
    elseif d < 0 and -d < rows then
      gpu.copy(1, 1, w, rows + d, 0, -d)
      draw_rows(1, -d)
    else
      draw_rows(1, rows)
    end
    draw_status()
  end

  -- Returns "quit", "interrupted", or nil when the user cancels.
  local function confirm_quit()
    draw_status_text(PROMPT)
    while true do
      local name, _, char, code = pull(IDLE_TIMEOUT)
      if name == "interrupted" then
        return "interrupted"
      end
      if name == "key_down" then
        if char == CHAR_CTRL_C then
          return "interrupted"
        end
        if char == CHAR_Y or char == CHAR_UPPER_Y or char == CHAR_ENTER
            or code == CODE_ENTER then
          return "quit"
        end
        draw_status()
        return nil
      end
    end
  end

  draw_rows(1, rows)
  draw_status()

  local pending
  while true do
    local action
    if pending then
      action, pending = pending, nil
    else
      local name, _, char, code = pull(IDLE_TIMEOUT)
      action = classify(name, char, code)
    end
    if action == "interrupted" then
      return "interrupted"
    elseif action == "quit" then
      local result = confirm_quit()
      if result then
        return result
      end
    elseif action then
      -- Takes all queued events, so a burst of key repeat gives one redraw.
      local target = move(top, action)
      while true do
        local name, _, char, code = pull(0)
        if name == nil then
          break
        end
        local next_action = classify(name, char, code)
        if is_nav(next_action) then
          target = move(target, next_action)
        elseif next_action then
          pending = next_action
          break
        end
      end
      scroll_to(target)
    end
  end
end

-- Shows lines until the user quits. Returns "quit" or "interrupted".
-- opts: title, file (shown when there is no title), no_rescale.
-- An error inside restores the screen and is raised again.
function M.run(lines, opts, deps)
  opts = opts or {}
  local gpu, term = deps.gpu, deps.term
  local old_w, old_h = gpu.getResolution()
  local old_fg, old_fg_palette = gpu.getForeground()
  local old_bg, old_bg_palette = gpu.getBackground()
  local rescaled = false

  local function restore()
    if rescaled then
      gpu.setResolution(old_w, old_h)
    end
    gpu.setForeground(old_fg, old_fg_palette or nil)
    gpu.setBackground(old_bg, old_bg_palette or nil)
    gpu.fill(1, 1, old_w, old_h, " ")
    term.clear()
    term.setCursor(1, 1)
  end

  local ok, result = pcall(function()
    if not opts.no_rescale then
      local max_w, max_h = gpu.maxResolution()
      if max_w ~= old_w or max_h ~= old_h then
        rescaled = true
        gpu.setResolution(max_w, max_h)
      end
    end
    return view(lines, opts, gpu, deps.pull)
  end)

  local restored, restore_err = pcall(restore)

  if not ok then
    error(result, 0)
  end
  if not restored then
    error(restore_err, 0)
  end
  return result
end

-- Builds deps from the OpenOS libraries.
function M.game_deps()
  local component = require("component")
  local event = require("event")
  local term = require("term")
  return { gpu = component.gpu, pull = event.pull, term = term }
end

return M
]]

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
-- copy with the embedded content. Returns the temporary paths written.
local function write_temps(plan, deps)
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
    end
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

local function install(opts, deps)
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
  local written, why = write_temps(plan, deps)
  if why then
    for _, temp in ipairs(written) do
      call(deps, "remove", temp)
    end
    fail(why .. "; old files kept")
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
  local ok, e = pcall(install, opts, deps)
  if ok then
    return 0
  end
  if type(e) == "string" and e:sub(1, 14) == "html-install: " then
    deps.err(e)
  else
    deps.err("html-install: unexpected error: "
      .. tostring(e):match("^[^\n]*"))
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
