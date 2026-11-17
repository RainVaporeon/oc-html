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
-- Seconds between two byte counts on the status line while loading.
local LOAD_TICK = 0.25
-- Seconds of work between two yields of the render to the viewer loop. An
-- event pull costs about 15 ms in game, so this is about 15% of the time of
-- a render that never waits for the network.
local SLICE = 0.1
-- Exit codes.
local EXIT_ERROR = 1
-- The second line of the popup of a broken page.
local RELOAD_LINE = "Reload to try again."
local EXIT_USAGE = 2
local EXIT_INTERRUPTED = 130
local INTERRUPTED = "html: interrupted"
-- The result of a load that found a file (see load_page).
local FILE_MARK = {}
-- The largest --width with no GPU or no screen (the tier 3 maximum).
local NO_SCREEN_MAX_WIDTH = 160
-- Tabs (spec/tabs.md "Tab limit option (experimental)"). The default limit,
-- the largest --tabs value, and the scaled memory units that one tab costs.
local DEFAULT_TABS = 8
local MAX_TABS = 32
local TAB_COST = 40 * 1024
-- The most events that the return from the shell drops (spec/shell.md).
local DRAIN_MAX = 64

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
  --tabs <n|auto>     experimental: the tab limit, 1 to 32, or auto (from
                      the free memory). The default is 8
  --help              show this help
Viewer keys: Up Down PgUp PgDn Home End scroll, Tab Shift+Tab Enter links,
Left or Bksp back, Right forward, g go to, r reload, z abort a load,
t new tab, c close tab, < > switch tabs, Ctrl+S download, ! shell,
? key list, q quit, Ctrl+C exit.]]

-- max_width is the largest --width (see max_width_of). Returns an options
-- table, or nil and a controlled error message.
function M.parse_args(argv, max_width)
  max_width = max_width or NO_SCREEN_MAX_WIDTH
  local opts = {}
  local i, count = 1, argv.n or #argv
  while i <= count do
    local a = tostring(argv[i])
    if a == "--help" or a == "-h" then
      opts.help = true
    elseif a == "--print" then
      opts.print = true
    elseif a == "--no-rescale" then
      opts.no_rescale = true
    elseif a == "--width" then
      i = i + 1
      local w = math.tointeger(tonumber(argv[i]))
      if not w or w < 2 or w > max_width then
        return nil, "html: --width needs a whole number from 2 to "
          .. max_width
      end
      opts.width = w
      opts.print = true
    elseif a == "--tabs" then
      i = i + 1
      local v = argv[i] ~= nil and tostring(argv[i]) or ""
      local n = find(v, "^%d+$") and tonumber(v) or nil
      if v == "auto" then
        opts.tabs = "auto"
      elseif n and n >= 1 and n <= MAX_TABS then
        opts.tabs = n
      else
        return nil, "html: --tabs needs a number from 1 to 32, or auto"
      end
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

-- Loads html.url, for a URL or a missing local file. It is small and loads
-- during the argument checks. Returns true, or nil and a controlled message.
local urlmod
local function load_url()
  if urlmod then
    return true
  end
  local ok, mod = pcall(require, "html.url")
  if not ok then
    return nil, "html: cannot load html.url: " .. reason(mod)
  end
  urlmod = mod
  return true
end

-- Loads html.fetch, only for a URL. Returns true, or nil and a controlled
-- message.
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

-- Runs the tokenizer and layout over a reader. Returns the lines, the
-- document title or nil, and page = { links = { span, href, count }, anchors
-- = { list, count }, base = raw <base href> or nil }. before_read(lines,
-- count, lay) is optional. It runs
-- before each read, with the live lines table, the number of finished
-- lines and the layout object (its count(), links(), title() and the other
-- accessors give the part that is laid out so far).
function M.render(read, width, before_read)
  local loaded, why = load_modules()
  if not loaded then
    error(why, 0)
  end
  local lay = layout.new(width)
  if before_read then
    local inner = read
    read = function()
      before_read(lay.lines, lay.count(), lay)
      return inner()
    end
  end
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
  local span, href, link_count = lay.links()
  local anc, anc_count = lay.anchors()
  local page = {
    links = { span = span, href = href, count = link_count },
    anchors = { list = anc, count = anc_count },
    base = lay.base(),
  }
  return lines, lay.title(), page
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

-- A byte count as whole kilobytes, rounded up: "12 KB".
local function kb(n)
  return int_text(math.ceil(n / 1024)) .. " KB"
end

-- Checks the input size, renders the input, and prints the lines or returns
-- them for the viewer. source: read() (a chunk, or nil at the end; it raises on an
-- error), size (bytes known before reading, or nil), kind ("file" or
-- "page", for the size message), name (shown without a title), prefix (put
-- before the title, or nil), head_line (optional, a line for stderr in print
-- mode before the text) and tail_error() (optional, a line for the popup or
-- stderr after the render: the status notice of a connect failure, or nil).
-- A source that breaks off raises instead: a broken page is not rendered.
-- width is the output width: the
-- layout wraps at width - 1 (see spec/cli.md "Output width"). done() is
-- called when the render ends. ui is optional, for the live page:
-- before_read(lines, count, lay).
-- Returns nil, the lines, the title (with the prefix, in the viewer) and the
-- page table of M.render. In the viewer it adds a fifth value, the table
-- { error = popup text or nil, file = source.name } for the viewer call.
local function run(source, opts, deps, width, done, ui)
  local size = source.size
  -- Without a known size there is no check before reading, so no settle.
  if is_num(size) then
    local free = guard.settled_free()
    if size * SIZE_COST_MIN > free then
      source.size_stop = true
      error("html: " .. source.kind .. " too large for available memory ("
        .. int_text(size) .. " bytes, " .. int_text(free) .. " free)", 0)
    end
  end
  -- The lowest free reading starts here, after the settled reading.
  guard.reset()
  local lines, title, page = M.render(source.read, width - 1,
    ui and ui.before_read)
  done()
  local tail_error = source.tail_error and source.tail_error()
  if not opts.print then
    if title == "" then
      title = nil
    end
    if source.prefix then
      title = source.prefix .. (title or source.name)
    end
    return nil, lines, title, page, { error = tail_error,
      file = source.name }
  end
  if source.head_line then
    deps.err(source.head_line)
  end
  local out = deps.out
  for i = 1, #lines do
    guard.tick_output()
    out(plain(lines[i]))
  end
  if tail_error then
    deps.err(tail_error)
  end
  return nil, lines, title, page
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

-- Returns the largest --width: the width of gpu.maxResolution(), or 160 with
-- no GPU or no screen.
local function max_width_of(gpu)
  if type(gpu) == "table" then
    local ok, w = pcall(function()
      if gpu.getScreen and not gpu.getScreen() then
        return nil
      end
      return (gpu.maxResolution())
    end)
    if ok and math.tointeger(w) and w > 0 then
      return w
    end
  end
  return NO_SCREEN_MAX_WIDTH
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

-- Classifies the argument. An argument with a scheme is a URL. Any other
-- argument is a local path first, then a guessed URL (see spec/url.md
-- "Arguments without a scheme"). Returns { url = , fragment = , guessed =
-- true or nil } or { path = } (absolute), or nil, a controlled message and
-- the exit code. The URL and path checks run before the screen opens (see
-- spec/loading.md).
function M.classify(arg, deps)
  local url, path, guessed
  if find(arg, "^%a[%w+.-]*://") then
    url = arg
  else
    path = M.expand_home(arg, deps.home)
    path = deps.resolve and deps.resolve(path) or path
  end
  -- A missing local path can be a host, and a URL must parse.
  if path and deps.exists and not deps.exists(path) then
    local url_loaded, url_why = load_url()
    if not url_loaded then
      return nil, url_why, EXIT_ERROR
    end
    if not urlmod.looks_like_host(arg) then
      return nil, "html: file not found: " .. arg, EXIT_ERROR
    end
    url, path, guessed = "http://" .. arg, nil, true
  end
  if url then
    local url_loaded, url_why = load_url()
    if not url_loaded then
      return nil, url_why, EXIT_ERROR
    end
    local u, why = urlmod.parse_url(url)
    if not u then
      return nil, why, EXIT_USAGE
    end
    -- parse_url drops the fragment. The session jumps to it after the load.
    local hash = find(url, "#", 1, true)
    return { url = u.url, fragment = hash and sub(url, hash + 1) or nil,
      guessed = guessed }
  elseif deps.is_dir and deps.is_dir(path) then
    return nil, "html: not a file: " .. arg, EXIT_ERROR
  end
  return { path = path }
end

-- Makes the error handler of xpcall: it maps an error value to the text that
-- the session reports (see spec/errors.md).
local function error_handler(deps)
  return function(e)
    if e == "interrupted" then
      return INTERRUPTED
    end
    if is_controlled(e) then
      return e
    end
    return deps.traceback(tostring(e), 2)
  end
end

-- Runs one load inside the session. All the state of a load lives here. It
-- never shows the page: the session loop does (see run_session).
-- target: the result of classify. ctx: opts, deps, arg (the text of the
-- target), width, session (the screen session of the viewer path, or nil),
-- need_modules (true for the first load of a framed run: the load loads the
-- modules after the frame opened), load_all() (loads the modules, returns
-- true or nil and a message), modules_loaded() (optional, called after
-- load_all), nav (true for a load after the first one), on_commit()
-- (optional, called after phase 1 and before the size check: the point where
-- the old page goes), state (optional table, filled for the viewer: see
-- below).
-- With a session the load is interactive: it must run in a coroutine that
-- the viewer loop drives (spec/loading.md "Keys during load"). It never
-- calls os.sleep. It yields "wait", seconds (a fetch wait), "slice" (CPU
-- work or a phase change), and "commit" (once, after phase 1). The loop
-- reads all keys and calls state.cancel() to stop the load: the next stop
-- check raises, and the load ends with the aborted result after it closed
-- everything. Without a session (print mode, the no-screen path) the load is
-- synchronous and waits with deps.sleep or os.sleep.
-- ctx.state gets: status() (the label and the tail of the status line:
-- phase texts have no tail), cancel(), live (after the commit: the live
-- source of the viewer, see below) and name().
-- The live source: lines, count(), links() (the table { span, href, count }),
-- title(), anchors() (list, count), base(), location, name and prefix.
-- Returns one of:
--   { ok = true, lines =, title =, page =, location = absolute path or final
--     URL, show = { file =, error = popup text or nil } (nil in print mode) }
--   { failed = true, committed = bool, text = popup text, reload = bool,
--     name = text }  an error that keeps the session (spec/navigation.md
--     "Two phases of a load"). committed is false for a phase 1 failure
--   { aborted = true, committed = bool, name = text }  the load was stopped
--   { error = text, reload = bool, kind = "controlled" or "unexpected" }
--   { interrupted = true, message = text or nil }
--   { file = true, resp = the open response, name = text }  a link to a file
--     (only with ctx.file_ok): the caller offers the download
local function load_page(target, ctx)
  local opts, deps, arg = ctx.opts, ctx.deps, ctx.arg
  local width = ctx.width
  local session = ctx.session
  local interactive = session ~= nil
  local url, path, guessed = target.url, target.path, target.guessed
  local f
  local state = ctx.state or {}
  if path then
    -- Phase 1 of a local load. The first load was checked by classify. A
    -- later target (a link) is checked here.
    local text, retry
    if ctx.nav and deps.exists and not deps.exists(path) then
      text = "html: file not found: " .. arg
    elseif ctx.nav and deps.is_dir and deps.is_dir(path) then
      text = "html: not a file: " .. arg
    else
      local why
      f, why = deps.open(path, "rb")
      if not f then
        -- The file can vanish between the check and the open. An open that
        -- fails on an existing file is a read error.
        if deps.exists and deps.exists(path) then
          text, retry = "html: read error: " .. reason(why or "cannot open"),
            true
        else
          text = "html: file not found: " .. arg
        end
      end
    end
    if text then
      if interactive or ctx.nav then
        -- The session goes on: the loop shows a popup.
        return { failed = true, committed = false, name = arg,
          text = retry and (text .. "\n" .. RELOAD_LINE) or text,
          reload = retry or false }
      end
      return { error = text, reload = false, kind = "controlled" }
    end
  end

  -- A replay (back, forward, prev): a cached copy of a remote page loads
  -- through the same path as a local file (spec/cache.md "Lookup"). A copy
  -- that does not open is dropped, and the page is fetched.
  local entry
  if url and ctx.replay and ctx.cache then
    entry = ctx.cache.get(url)
    if entry then
      f = entry.open()
      if not f then
        ctx.cache.drop(url)
        entry = nil
      end
    end
  end

  -- Ctrl+C is a flag that the "interrupted" listener sets, and the next
  -- guard.tick raises INTERRUPTED. cancel() (the viewer loop: abort, a link,
  -- quit) stops the load in the same way (spec/navigation.md "Abort").
  local interrupted, abort_requested, committed = false, false, false
  local remove
  if deps.on_interrupt then
    remove = deps.on_interrupt(function() interrupted = true end)
  end
  local function stop_flag()
    return interrupted or abort_requested
  end
  function state.cancel()
    abort_requested = true
  end
  local now = deps.uptime or deps.clock
  -- The loop gets the control at every yield. The time of the last one lets
  -- the render yield about every SLICE seconds, before a read.
  local last_yield = now()
  local function yield_to_loop(what, seconds)
    coroutine.yield(what, seconds)
    last_yield = now()
  end
  local function arm_guard()
    guard.set_interrupt_check(stop_flag)
    if interactive then
      guard.set_yield(function() yield_to_loop("slice") end)
    end
  end
  local function stop_listening()
    if guard then
      guard.set_interrupt_check(nil)
      guard.set_yield(nil)
    end
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

  local handler = error_handler(deps)
  -- For a URL: the fetch progress (fetch.open fills it), the response and
  -- the clock of the fetch.
  local info, resp = {}, nil
  local fetch_clock = deps.uptime or deps.clock
  -- A fetch error for a guessed URL names the argument, so a mistyped file
  -- name is clear.
  local suffix = guessed and (" (no local file named " .. arg .. ")") or ""
  -- A fetch error after the frame opened does not end the session: the
  -- viewer shows it in a popup (see spec/loading.md "Errors after the
  -- frame"). kept_error is the text of such an error.
  -- offer_reload is true when a retry may fix the error or the page broke off
  -- after it started to load: the popup then says to reload. A broken page
  -- shows no part of the page.
  -- active is the source of the render. It tells a size stop before reading
  -- (a retry does not help) from a memory stop during the render.
  local kept_error, offer_reload, active
  -- The cache writer of a remote load, until the load completes or fails.
  local writer

  local function fetch_error(why, reload)
    if why ~= INTERRUPTED then
      why = why .. suffix
      kept_error = why
      offer_reload = reload
    end
    error(why, 0)
  end

  -- The status line of the load (spec/loading.md "Status line during
  -- load"). Before the commit it is the phase text. After it, the viewer
  -- asks status() at each pass: it gives the label and the tail. A byte
  -- count update is rate-limited to LOAD_TICK, and the last one is not.
  local name, total, bytes = arg, nil, 0
  if entry then
    name = entry.final_url or url
  end
  function state.name()
    return name
  end
  local in_body, final = false, false
  local phase_text = "Loading " .. name .. "..."
  local shown_tail, shown_at
  local live
  local function load_tail()
    local text = "Loading"
    if bytes > 0 then
      text = text .. " " .. kb(bytes)
      if type(total) == "number" then
        text = text .. " of " .. kb(math.max(total, bytes))
      end
    end
    return text
  end
  function state.status()
    if not in_body then
      return phase_text
    end
    local title = live and live.title()
    local label = (live and live.prefix or "")
      .. (title and title ~= "" and title or name)
    local t = now()
    if final or not shown_tail or t - shown_at >= LOAD_TICK then
      shown_tail, shown_at = load_tail(), t
    end
    return (gsub(label, "%c", " ")), shown_tail
  end
  -- A phase text shows at once: the loop gets a slice to draw it.
  local function set_phase(text)
    in_body, phase_text = false, text
    if interactive then
      yield_to_loop("slice")
    end
  end
  -- The phases of the fetch (see fetch.open).
  local function progress(phase, u)
    if phase == "connect" then
      set_phase("Connecting to " .. u.host .. "...")
    elseif phase == "response" then
      set_phase("Waiting for response...")
    elseif phase == "redirect" then
      set_phase("Redirect to " .. u.url .. "...")
    end
  end

  -- The live source of the viewer. lay is the layout of the render: it
  -- exists from the first read on.
  local lay, location
  local EMPTY = { span = {}, href = {}, count = 0 }
  local link_table = { span = EMPTY.span, href = EMPTY.href, count = 0 }
  local function new_live(source)
    return {
      lines = nil,
      count = function() return lay and lay.count() or 0 end,
      links = function()
        if not lay then
          return EMPTY
        end
        link_table.span, link_table.href, link_table.count = lay.links()
        return link_table
      end,
      title = function() return lay and lay.title() or nil end,
      anchors = function()
        if lay then
          return lay.anchors()
        end
        return {}, 0
      end,
      base = function() return lay and lay.base() or nil end,
      location = location, name = source.name, prefix = source.prefix,
    }
  end
  -- The render reads through this hook. It gives the viewer the layout and
  -- yields a slice about every SLICE seconds.
  local ui = {
    before_read = function(lines, _, layout_object)
      if not lay then
        lay = layout_object
        live.lines = lines
      end
      if now() - last_yield >= SLICE then
        yield_to_loop("slice")
      end
    end,
  }

  -- Returns the source for run: the file, the cached copy, or the response of
  -- url.
  local function open_source()
    if not url or entry then
      local cached = entry ~= nil
      if entry then
        total = entry.bytes
      else
        name, total = arg, file_size(f, path, deps)
      end
      return {
        read = function()
          local chunk, why = f:read(CHUNK)
          -- A plain nil is the end of the input. A nil with a message is an
          -- error.
          if chunk == nil and why then
            if cached then
              ctx.cache.drop(url)
            end
            kept_error = "html: read error: " .. reason(why)
            offer_reload = true
            error(kept_error, 0)
          end
          if chunk then
            bytes = bytes + #chunk
          end
          return chunk
        end,
        size = total, kind = cached and "page" or "file", name = name,
      }
    end
    local fetch_loaded, fetch_why = load_fetch()
    if not fetch_loaded then
      error(fetch_why, 0)
    end
    local why
    local retry
    local sleep = deps.sleep or os.sleep
    if interactive then
      sleep = function(seconds) yield_to_loop("wait", seconds) end
    end
    resp, why, retry = fetch.open(url, { internet = deps.internet,
      clock = fetch_clock, sleep = sleep, interrupted = stop_flag,
      progress = interactive and progress or nil,
      file_ok = ctx.file_ok }, info)
    if not resp then
      fetch_error(why, retry)
    end
    open_file = resp
    name, total = resp.final_url, resp.length
    if resp.is_file then
      -- A file, not a page (spec/download.md "Link to a file"): the open
      -- response goes to the session loop. Nothing is cached or committed.
      return nil
    end
    -- Only a page with a 2xx status is stored (spec/cache.md "Storing").
    if ctx.cache and not resp.is_error and not resp.notice then
      writer = ctx.cache.begin(url)
    end
    local status = "HTTP " .. int_text(resp.status)
    -- A notice, not an error: the body renders (decision D2). It prints
    -- after the render, so a broken page prints only its error line.
    local head_line
    if resp.is_error and opts.print and not resp.notice then
      head_line = "html: " .. status .. (resp.message ~= "" and (" "
        .. resp.message) or "") .. ": " .. resp.final_url
    end
    return {
      read = function()
        local chunk, err = resp.read()
        if chunk == nil and err then
          fetch_error(err, true)
        end
        bytes = resp.bytes
        if chunk and writer then
          writer.write(chunk)
        end
        return chunk
      end,
      size = resp.length, kind = "page", name = resp.final_url,
      prefix = resp.is_error and ("[" .. status .. "] ") or nil,
      head_line = head_line,
      tail_error = function()
        if resp.notice then
          -- A status from a connect failure: the line in print mode, the
          -- popup in the viewer. The short page has rendered.
          return opts.print and resp.notice or resp.popup
        end
        return nil
      end,
    }
  end

  local ok, result, lines, title, page, shown_info = xpcall(function()
    if interactive then
      if ctx.need_modules then
        -- The first load of a framed run: the frame is open, the modules
        -- load now.
        set_phase("Loading modules...")
        local loaded, why = ctx.load_all()
        if not loaded then
          error(why, 0)
        end
        if ctx.modules_loaded then
          ctx.modules_loaded()
        end
      end
    end
    arm_guard()
    local source = open_source()
    location = resp and resp.final_url or entry and name or path
    if stop_flag() then
      error(INTERRUPTED, 0)
    end
    if resp and resp.is_file then
      return FILE_MARK
    end
    -- The commit: phase 1 is over. The caller releases the old page here,
    -- before the size check measures the free memory. The loop then shows
    -- the new, empty live page.
    committed = true
    if ctx.on_commit then
      ctx.on_commit()
    end
    active = source
    in_body = true
    if interactive then
      live = new_live(source)
      state.live = live
      yield_to_loop("commit")
    end
    return run(source, opts, deps, width, function()
      close_file()
      final = true
      if stop_flag() then
        error(INTERRUPTED, 0)
      end
      if writer and resp then
        local w = writer
        writer = nil
        w.commit_complete({ final_url = resp.final_url, status = resp.status,
          content_type = resp.content_type, is_error = false })
      end
      -- Print mode keeps the guard checks for the output loop.
      if not opts.print then
        stop_listening()
      end
    end, interactive and ui or nil)
  end, handler)
  -- An error that keeps the session: a fetch error, a file read error or a
  -- memory stop after the frame opened. The caller shows a popup (over the
  -- old page after a phase 1 failure, else over an empty page). A broken
  -- page is not rendered: the lines so far are dropped.
  local failed
  if not ok and (interactive or ctx.nav) and not opts.print
      and type(result) == "string"
      and (result == kept_error or find(result,
        "^html: %a+ too large for available memory")) then
    local text = result
    local reload = offer_reload
    if result ~= kept_error then
      reload = not (active and active.size_stop)
    end
    if reload then
      text = text .. "\n" .. RELOAD_LINE
    end
    failed = { failed = true, committed = committed, text = text,
      reload = reload and true or false, name = name }
    ok, result = true, nil
  end
  -- A file response stays open for the caller.
  local kept_file
  if ok and result == FILE_MARK then
    kept_file, open_file = open_file, nil
  end
  -- Each step runs alone, so a failure in one does not skip the other.
  pcall(stop_listening)
  pcall(close_file)
  -- A load that did not complete leaves no cache entry.
  if writer then
    pcall(writer.abort)
  end

  if kept_file then
    return { file = true, resp = kept_file, committed = false, name = name }
  end
  if not ok and result == "interrupted" then
    -- A bare "interrupted" error is Ctrl+C from the event system.
    result = INTERRUPTED
  end
  if not ok and result == INTERRUPTED and not interrupted
      and abort_requested then
    return { aborted = true, committed = committed, name = name }
  end
  if not ok then
    if result == INTERRUPTED then
      return { interrupted = true, message = result }
    end
    return { error = result,
      reload = result == kept_error and offer_reload and true or false,
      kind = is_controlled(result) and "controlled" or "unexpected" }
  elseif failed then
    return failed
  end
  return { ok = true, lines = lines, title = title, page = page,
    location = location, show = shown_info }
end

M.load_page = load_page

-- The session loop ----------------------------------------------------------
-- See spec/navigation.md.

local HISTORY_CAP = 32

-- Loads html.history. Returns true, or nil and a controlled message.
local history, tabs
local function load_history()
  if history then
    return true
  end
  local ok, mod = pcall(require, "html.history")
  if not ok then
    return nil, "html: cannot load html.history: " .. reason(mod)
  end
  local ok2, mod2 = pcall(require, "html.tabs")
  if not ok2 then
    return nil, "html: cannot load html.tabs: " .. reason(mod2)
  end
  history, tabs = mod, mod2
  return true
end

local function key_of(spec)
  return spec.url or spec.path
end

-- Makes a load target from a history key: a URL or an absolute path.
-- guesses maps the key of a guessed URL to the text that was typed.
local function spec_of(key, guesses)
  local spec
  if find(key, "^%a[%w+.-]*://") then
    spec = { url = key }
  else
    spec = { path = key }
  end
  if guesses[key] then
    spec.guessed, spec.arg = true, guesses[key]
  end
  return spec
end

local function unescape(s)
  return (gsub(s, "%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

-- Returns the line of the anchor that fragment names. An empty fragment is
-- line 1. Returns nil for no fragment or an unknown one.
local function anchor_line(page, fragment)
  if fragment == nil then
    return nil
  end
  if fragment == "" then
    return 1
  end
  local anchors = page and page.anchors
  if not anchors then
    return nil
  end
  local wanted = layout.hash40(unescape(fragment))
  local list = anchors.list
  for i = 1, anchors.count do
    if list[i] >> 24 == wanted then
      return list[i] & 0xFFFFFF
    end
  end
  return nil
end

-- Returns the base of the links of a page: its <base href> resolved against
-- the page location, else the location.
local function page_base(location, base)
  if base then
    local r = urlmod.resolve(location, base)
    if r and r.kind == "http" then
      return r.url
    elseif r and r.kind == "file" then
      return r.path
    end
  end
  return location
end

-- Runs the viewer path: loads the first target, shows the page and acts on
-- the action of the viewer until the user quits. target: the result of
-- classify, with arg (the text of the target). ctx: see load_page. Returns
-- the same kinds as load_page: { quit }, { interrupted, message } or
-- { error, kind }.
--
-- With a screen session the loads are interactive: a load is a coroutine
-- (the loader) that the viewer drives from its own loop (session.show with
-- opts.load). The loop is the only reader of events. The loader is bg while
-- it runs. The viewer returns the action "commit" when phase 1 is over (the
-- loop then shows the live page), "done" when the load ended, "abort" for
-- z, Backspace and Left, and any other action as usual. An action that is
-- not "commit" or "done" stops the loader first. Without a session (the
-- no-screen path with deps.view) a load runs to its end before the page
-- shows.
local function run_session(target, ctx)
  local deps, opts = ctx.deps, ctx.opts
  local loaded, why = load_url()
  if loaded then
    loaded, why = load_history()
  end
  if not loaded then
    return { error = why, reload = false, kind = "controlled" }
  end
  local handler = error_handler(deps)
  -- The screen opens before the modules load (spec/loading.md "Startup").
  if ctx.framed and not ctx.session then
    local opened, session = xpcall(deps.open_screen, handler,
      { no_rescale = opts.no_rescale,
        status = "Loading " .. ctx.arg .. "..." })
    if not opened then
      return { error = session, reload = false,
        kind = is_controlled(session) and "controlled" or "unexpected" }
    end
    ctx.session = session
    ctx.need_modules = true
  end
  -- The disk cache of the session. The program clears it on every exit (see
  -- main). Without deps.cache, or without the module, nothing is cached.
  if deps.cache then
    local cache_ok, cache_mod = pcall(require, "html.cache")
    if cache_ok then
      ctx.cache = cache_mod.new(nil, deps.cache)
    end
  end
  -- The active tab: the record of spec/tabs.md (guesses, shown, pending, job)
  -- plus the live objects of the page on screen:
  --   hist     the history object
  --   held     the page on screen: { lines, title, name, page, location,
  --            base, resolve } or nil. The commit of a load drops it.
  --   shown    nil, or { kind = "broken" | "aborted", name } while held is
  --            the empty page of a failed or aborted load
  --   cur      the target of the page on screen
  --   top, sel the view position
  --   popup    the text of a popup for the next show
  --   bg       the loader that runs, or nil: { r, spec, had, state,
  --            committed, finished, result, drive(), cancel() }
  -- The tab limit (spec/tabs.md "Tab limit option (experimental)"). Only
  -- the option --tabs turns on the memory check of t.
  local function guard_lib()
    if guard then
      return guard
    end
    local ok, mod = pcall(require, "html.guard")
    return ok and mod or nil
  end
  local tab_limit = DEFAULT_TABS
  if type(opts.tabs) == "number" then
    tab_limit = opts.tabs
  elseif opts.tabs == "auto" then
    local g = guard_lib()
    if g then
      local avail = g.settled_free() - g.MEMORY_RESERVE
      tab_limit = math.max(1, math.min(MAX_TABS,
        (avail - avail / 2) // TAB_COST))
      tab_limit = math.tointeger(tab_limit) or 1
    end
  end
  local tab = tabs.new_tab()
  -- file_wait: a response that a followed link opened and the save prompt
  -- has not used yet. arrive is defined further down.
  local file_wait, arrive, open_tab
  tab.hist = history.new(HISTORY_CAP)
  tab.top = 1
  local tab_list = tabs.new(tab_limit)
  tab_list.add_after(tab)
  -- The next load: { spec, mode = "first" | "link" | "go" | "back" |
  -- "forward" | "reload" | "prev", top, sel, fragment }.
  local req = { spec = target, mode = "first", fragment = target.fragment }
  if target.guessed then
    tab.guesses[key_of(target)] = target.arg
  end

  -- An empty page with a title: a broken or an aborted load. It sets
  -- tab.shown.
  local function empty_page(kind, name)
    tab.shown = { kind = kind, name = name, target = tab.cur and key_of(tab.cur) }
    return { lines = {}, title = "[" .. (kind == "broken" and "error" or kind)
      .. "] " .. name, name = name }
  end

  -- The resolver of the viewer: the text of the status line, or nil and a
  -- notice. A link that cannot resolve gives its href, so that Enter
  -- reaches the loop and the popup shows the reason. base_of() gives the
  -- base of the page.
  local function make_resolve(base_of)
    return function(href)
      local base = base_of()
      local r = urlmod.resolve(base, href)
      if not r then
        return href
      elseif r.kind == "unsupported" then
        return nil, r.scheme .. ": links are not supported"
      end
      local frag = r.fragment and ("#" .. r.fragment) or ""
      if r.kind == "http" then
        return r.url .. frag
      elseif r.kind == "file" then
        return r.path .. frag
      end
      return base .. frag
    end
  end

  -- Makes the page record from the result of a load that ended well.
  local function page_of(res)
    local h = { lines = res.lines, title = res.title, name = res.show.file,
      page = res.page, location = res.location }
    h.base = page_base(res.location, res.page.base)
    h.resolve = make_resolve(function() return h.base end)
    return h
  end

  -- The page that a stopped load had loaded, for the action that stopped
  -- it: the complete lines, the links and the base so far.
  local function snapshot(b)
    local live = b.state.live
    local lk = live.links()
    local anc, anc_count = live.anchors()
    local h = { lines = live.lines or {}, title = live.title(),
      name = live.name,
      page = { links = { span = lk.span, href = lk.href, count = lk.count },
        anchors = { list = anc, count = anc_count }, base = live.base() },
      location = live.location }
    h.base = page_base(live.location, live.base())
    h.resolve = make_resolve(function() return h.base end)
    return h
  end

  -- A load found a file: the old page stays, nothing is pushed, and the
  -- save prompt opens (spec/download.md "Link to a file"). A new tab load
  -- (r.newtab) has opened no tab yet, so no tab opens.
  local function file_found(res, view_top, view_sel)
    ctx.kept = res.resp
    file_wait = { resp = res.resp, url = res.resp.final_url }
    tab.top, tab.sel = view_top, view_sel
    return nil
  end

  -- Takes the result of a load. Sets held, cur, top, sel, popup and req.
  -- Returns a final result, or nil to show. view_top and view_sel are the
  -- position of the view at the end of an interactive load.
  local function settle(r, had, res, view_top, view_sel)
    local spec = r.spec
    if res.quit or res.interrupted or res.error then
      return res
    end
    if res.file then
      return file_found(res, view_top, view_sel)
    end
    if res.ok then
      tab.cur = spec
      tab.held = page_of(res)
      tab.popup = res.show.error
      -- A user who did not move keeps the rules of a load that did not
      -- show: the anchor, or the saved position.
      local moved = view_top ~= 1 or view_sel ~= nil
      if moved then
        tab.top, tab.sel = view_top, view_sel
      elseif r.mode == "first" or r.mode == "link" or r.mode == "go" then
        tab.top, tab.sel = anchor_line(tab.held.page, r.fragment) or 1, nil
      else
        tab.top, tab.sel = r.top, r.sel
      end
      return nil
    end
    -- A phase 1 failure or an abort before the commit leaves the old page.
    -- A back or forward move of the history goes back.
    local function undo()
      if r.mode == "back" then
        tab.hist.forward()
      elseif r.mode == "forward" then
        tab.hist.back()
      end
    end
    if r.newtab and not res.committed then
      -- A new tab load that stopped in phase 1: no tab opened, and the
      -- current page stays as it is.
      tab.popup = res.failed and res.text or nil
      return nil
    end
    if res.failed then
      tab.popup = res.text
      if r.from_pending and not res.committed and tab.hist.size() > 0 then
        -- spec/tabs.md "A load at a tab switch": the popup shows, then the
        -- tab loads its current entry.
        local entry = tab.hist.current()
        req = { spec = spec_of(entry.target, tab.guesses), mode = "switch",
          top = entry.top, sel = entry.sel }
      elseif res.committed or not had then
        tab.cur = spec
        tab.held = empty_page("broken", res.name)
        tab.top, tab.sel = 1, nil
      else
        undo()
      end
    elseif not res.committed then
      if had then
        undo()
      else
        tab.cur = spec
        tab.held = empty_page("aborted", res.name)
        tab.top, tab.sel = 1, nil
      end
    elseif (r.mode == "link" or r.mode == "go") and tab.hist.can_back() then
      -- The old page is gone: load the previous page again. The entry of the
      -- aborted new target goes. An abort of a reload, back or forward keeps
      -- its entry and shows the empty page, so r loads it again.
      local prev = tab.hist.drop_current()
      req = { spec = spec_of(prev.target, tab.guesses), mode = "prev",
        top = prev.top, sel = prev.sel }
    else
      tab.cur = spec
      tab.held = empty_page("aborted", res.name)
      tab.top, tab.sel = 1, nil
    end
    return nil
  end

  -- Starts the load of r. Returns a final result, or nil to show. With a
  -- session the loader starts as bg and the viewer drives it. Without one
  -- the load runs to its end here.
  local function start(r)
    local spec = r.spec
    local had = tab.held ~= nil
    -- A load has its own copy of the context, so a later change of the
    -- fields does not reach a load that still runs.
    local lctx = {}
    for k, v in pairs(ctx) do
      lctx[k] = v
    end
    lctx.arg = spec.arg or key_of(spec)
    lctx.nav = r.mode ~= "first" or r.from_pending == true
    -- A link, the go prompt and the first load of a new tab can lead to a
    -- file (spec/download.md "Link to a file").
    lctx.file_ok = ctx.session ~= nil
      and (r.mode == "link" or r.mode == "go")
    lctx.on_commit = function()
      if r.newtab then
        -- The tab opens at the commit (open_tab). The old tab keeps its page
        -- until then.
        return
      end
      tab.held = nil
      tab.shown = nil
      if r.mode == "link" or r.mode == "go" or tab.hist.size() == 0 then
        tab.hist.push(key_of(spec))
      elseif r.mode == "reload" then
        tab.hist.replace({ target = key_of(spec), top = r.top, sel = r.sel })
      end
    end
    -- Back, forward and the load of the previous page use the cached copy.
    -- Reload, link and go fetch.
    lctx.replay = r.replay or r.mode == "back" or r.mode == "forward"
      or r.mode == "prev" or r.mode == "switch"
    lctx.state = {}
    lctx.modules_loaded = function()
      ctx.need_modules = false
    end
    if not ctx.session then
      return settle(r, had, load_page(spec, lctx), 1, nil)
    end
    local co = coroutine.create(load_page)
    local b = { r = r, spec = spec, had = had, state = lctx.state,
      committed = false, finished = false, started = false }
    local first_text = "Loading " .. lctx.arg .. "..."
    function b.status()
      if b.state.status then
        return b.state.status()
      end
      return first_text
    end
    function b.drive()
      if b.finished then
        return "done"
      end
      b.started = true
      local ok, what, secs = coroutine.resume(co, spec, lctx)
      if not ok then
        b.finished = true
        b.result = { error = what, reload = false,
          kind = is_controlled(what) and "controlled" or "unexpected" }
        return "done"
      elseif coroutine.status(co) == "dead" then
        b.finished = true
        b.result = what
        return "done"
      end
      if what == "commit" then
        b.committed = true
      end
      return what, secs
    end
    -- Stops the load: raises the stop flag and runs the loader until it has
    -- closed everything. The yields in between are not waited for.
    function b.cancel()
      if b.finished then
        return
      end
      b.finished = true
      if not b.started then
        return
      end
      b.state.cancel()
      for _ = 1, 10000 do
        if coroutine.status(co) == "dead" then
          break
        end
        coroutine.resume(co)
      end
    end
    tab.bg = b
    return nil
  end

  -- Shows the page. Returns ok and the result of the viewer.
  local function present()
    local h = tab.held
    local b = tab.bg
    local o = { no_rescale = opts.no_rescale, error = tab.popup, top = tab.top,
      sel = tab.sel }
    local lines = {}
    if b and b.committed then
      local live = b.state.live
      o.live = live
      o.title = live.name and ((live.prefix or "") .. live.name) or nil
      o.file = live.name
      o.resolve = make_resolve(function()
        return page_base(live.location, live.base())
      end)
    elseif h then
      lines = h.lines
      o.title, o.file = h.title, h.name
      if h.page then
        o.links = h.page.links
        o.resolve = h.resolve
      end
    end
    if b and not b.finished then
      o.load = { drive = b.drive, status = b.status, kind = b.kind }
    end
    local count = tab_list.count()
    o.tab_count = count
    if count >= 2 then
      o.tab_label = "[" .. tab_list.index() .. "/" .. count .. "]"
      o.quit_text = " Quit and close " .. count .. " tabs? (y/n)"
    end
    if count >= tab_limit then
      o.tab_full = "tab limit: " .. tab_limit .. " tabs"
    end
    o.notice = tab.notice
    tab.notice = nil
    tab.popup = nil
    local session = ctx.session
    return xpcall(session and session.show or deps.view, handler, lines, o)
  end

  -- A same-document link: a new history entry and a jump to the anchor.
  local function jump(fragment)
    tab.top = anchor_line(tab.held.page, fragment) or tab.top
    tab.hist.push(key_of(tab.cur))
    tab.hist.set_pos(tab.top, tab.sel)
  end

  -- The action of the user stops the load that runs. Returns true when the
  -- action is used up here. A stop (z, Backspace, Left) is an abort with
  -- the rules of spec/navigation.md "Abort". For any other action the page
  -- that was loaded becomes the page on screen (after the commit), or the
  -- old page stays (before it).
  local function stop_load(kind)
    local b = tab.bg
    if kind == "forward" and not tab.hist.can_forward() then
      -- Forward does nothing at the last entry: the load goes on.
      return true
    end
    tab.bg = nil
    b.cancel()
    local name = b.state.name and b.state.name() or b.spec.arg
      or key_of(b.spec)
    if kind == "abort" or not b.committed then
      settle(b.r, b.had, { aborted = true, committed = b.committed,
        name = name })
      return kind == "abort"
    end
    tab.held = snapshot(b)
    tab.cur = b.spec
    return false
  end

  -- Handles "commit" and "done" from the viewer. Returns a final result, or
  -- nil.
  local function advance(kind, out)
    local b = tab.bg
    if kind == "commit" then
      if b.r.newtab then
        open_tab(b, out.top, out.sel)
        return nil
      end
      -- The old page is gone. The new page starts at the top.
      tab.held = nil
      tab.top, tab.sel = 1, nil
      return nil
    end
    tab.bg = nil
    if b.r.newtab and b.result and b.result.ok then
      open_tab(b, out.top, out.sel)
      tab.bg = nil
    end
    return settle(b.r, b.had, b.result, out.top, out.sel)
  end

  -- Tabs (spec/tabs.md). The live fields of the active tab (hist, held, cur,
  -- popup, bg, top, sel, notice) are not part of its plain record. leave
  -- turns the active tab into the record, and arrive makes a record the
  -- active tab and sets req (or the broken page) to show it.
  local PENDING_MODES = { first = true, link = true, go = true, back = true,
    forward = true, reload = true }

  -- Stops the load of the tab and stores the view position. A load that
  -- stopped before its commit stays as tab.pending. Then it drops the live
  -- objects.
  local function leave(top, sel)
    local b = tab.bg
    tab.bg = nil
    local r
    if b and b.r.newtab then
      -- A pending new tab load has no tab: it stops and leaves nothing.
      b.cancel()
      b = nil
    end
    if b then
      b.cancel()
      if not b.committed and PENDING_MODES[b.r.mode] then
        r = b.r
      end
    end
    if r then
      -- A back or forward already moved the index. The position belongs to
      -- the entry of the old page.
      if r.mode == "back" then
        tab.hist.forward()
      elseif r.mode == "forward" then
        tab.hist.back()
      end
      if tab.held and not tab.shown then
        tab.hist.set_pos(top, sel)
      end
      if r.mode == "back" then
        tab.hist.back()
      elseif r.mode == "forward" then
        tab.hist.forward()
      end
      tab.pending = { target = key_of(b.spec), mode = r.mode,
        fragment = r.fragment, top = r.top, sel = r.sel, arg = b.spec.arg,
        replay = r.replay }
      tab.shown = nil
    elseif b and b.committed or (not b and tab.held and not tab.shown) then
      tab.hist.set_pos(top, sel)
    end
    local e = tab.hist.export()
    tab.entries, tab.pos = e.entries, e.pos
    tab.hist, tab.held, tab.cur, tab.popup, tab.notice = nil, nil, nil, nil,
      nil
    tab.top, tab.sel = nil, nil
  end

  -- Makes the record t the active tab (spec/tabs.md "Showing a tab").
  function arrive(t)
    tab = t
    tab.hist = history.import({ entries = t.entries, pos = t.pos },
      HISTORY_CAP)
    tab.held, tab.cur, tab.popup, tab.bg = nil, nil, nil, nil
    tab.top, tab.sel = 1, nil
    local pend = tab.pending
    tab.pending = nil
    if pend then
      local spec = spec_of(pend.target, tab.guesses)
      spec.arg = pend.arg or spec.arg
      tab.shown = nil
      req = { spec = spec, mode = pend.mode, fragment = pend.fragment,
        top = pend.top, sel = pend.sel, replay = pend.replay,
        from_pending = true }
    elseif tab.shown then
      local shown = tab.shown
      tab.cur = shown.target and spec_of(shown.target, tab.guesses)
      tab.held = empty_page(shown.kind, shown.name)
    else
      local entry = tab.hist.current()
      if entry then
        req = { spec = spec_of(entry.target, tab.guesses), mode = "switch",
          top = entry.top, sel = entry.sel }
      else
        tab.held = { lines = {}, title = "", name = "" }
      end
    end
  end

  -- The commit of a new tab load: the departing tab keeps its state (leave),
  -- and the new tab becomes active with the load b and its first entry.
  function open_tab(b, top, sel)
    local spec = b.spec
    tab.bg = nil
    leave(top, sel)
    local new = tabs.new_tab()
    tab_list.add_after(new)
    if tab.guesses[key_of(spec)] then
      new.guesses[key_of(spec)] = tab.guesses[key_of(spec)]
    end
    tab = new
    tab.hist = history.new(HISTORY_CAP)
    tab.hist.push(key_of(spec))
    tab.held, tab.cur, tab.popup = nil, nil, nil
    tab.top, tab.sel = 1, nil
    b.r.newtab = nil
    tab.bg = b
  end

  -- The base that a link of the page on screen resolves against.
  local function link_base()
    local b = tab.bg
    if b and b.committed then
      local live = b.state.live
      return page_base(live.location, live.base())
    end
    return tab.held and tab.held.base
  end

  -- t: opens a new tab after the active one. The target is a link of the
  -- page (out.href) or the typed text (out.text).
  local function new_tab(out)
    local spec, fragment, replay
    if out.href then
      local b = tab.bg
      local here = (b and b.committed) and b.spec or tab.cur
      local base = link_base()
      if not here or not base then
        return
      end
      local r, why_not = urlmod.resolve(base, out.href)
      if not r then
        tab.popup = why_not
        return
      elseif r.kind == "unsupported" then
        return
      elseif r.kind == "same" or (r.url or r.path) == key_of(here) then
        -- A same-document link: the current page with the fragment. The
        -- cache can serve it.
        spec, fragment, replay = { url = here.url, path = here.path },
          r.fragment, true
        spec.arg = key_of(here)
      else
        spec, fragment = spec_of(r.url or r.path, {}), r.fragment
      end
    else
      local msg
      spec, msg = M.classify(out.text, deps)
      if not spec then
        tab.popup = msg
        return
      end
      spec.arg = out.text
      fragment = spec.fragment
    end
    if tab_list.count() >= tab_limit then
      tab.notice = "tab limit: " .. tab_limit .. " tabs"
      return
    end
    if opts.tabs then
      local g = guard_lib()
      if g and g.settled_free() < g.MEMORY_RESERVE + TAB_COST then
        tab.notice = "not enough memory for a new tab"
        return
      end
    end
    -- A load that runs stops first (one connection at a time).
    if tab.bg and tab.bg.kind == "download" then
      tab.bg.cancel()
      tab.bg = nil
    elseif tab.bg then
      stop_load("tab_new")
    end
    -- The current tab stays active. The tab opens at the commit (open_tab).
    if spec.guessed then
      tab.guesses[key_of(spec)] = spec.arg
    end
    req = { spec = spec, mode = "link", fragment = fragment, replay = replay,
      newtab = true }
  end

  -- The shell tab-out (spec/shell.md "Sequence"). Returns a final result when
  -- the screen cannot open again, else nil.
  local function shell_out(out)
    if not ctx.session or not deps.shell then
      return nil
    end
    leave(out.top, out.sel)
    pcall(ctx.session.close)
    ctx.session = nil
    deps.out("html: shell started. Type exit to return to the browser.")
    local setenv = deps.setenv or os.setenv
    if setenv then
      setenv("HTML_TABOUT", "1")
    end
    local shell_ok, shell_why = pcall(deps.shell)
    if setenv then
      setenv("HTML_TABOUT", nil)
    end
    local opened, session = xpcall(deps.open_screen, handler,
      { no_rescale = opts.no_rescale, status = "Returning...",
        enter_held = true })
    if not opened then
      return { error = "html: cannot reopen the screen: " .. reason(session),
        reload = false, kind = "controlled" }
    end
    ctx.session = session
    ctx.width = screen_width(deps.gpu, opts.no_rescale) or ctx.width
    if deps.pull then
      for _ = 1, DRAIN_MAX do
        if deps.pull(0) == nil then
          break
        end
      end
    end
    arrive(tab)
    if not shell_ok then
      tab.popup = "html: shell error: " .. reason(shell_why)
    end
    return nil
  end

  -- Downloads (spec/download.md). html.download loads at the first use.
  local download
  local function need_download()
    if download then
      return download
    end
    local ok, mod = pcall(require, "html.download")
    if ok then
      download = mod
      return mod
    end
    tab.popup = "html: cannot load html.download: " .. reason(mod)
    return nil
  end

  local function download_deps()
    return { open = deps.open, exists = deps.exists, is_dir = deps.is_dir,
      resolve = deps.resolve, home = deps.home, cwd = deps.cwd,
      space = deps.space, remove = deps.remove, rename = deps.rename,
      clock = deps.uptime or deps.clock, yield = coroutine.yield }
  end

  -- Starts the download job of dl ({ url, resp = an open response or nil })
  -- to path, as the loader of the tab. A response that is open already goes
  -- to the job. Without one the job fetches the url with the option raw.
  local function start_download(dl, path)
    local name = path:match("[^/]*$")
    local resp = dl.resp
    local now = deps.uptime or deps.clock
    local stopped, receiving = false, false
    local bytes, length = 0, nil
    local phase_text = "Loading " .. dl.url .. "..."
    local shown_tail, shown_at
    local b = { kind = "download", r = { mode = "download" }, spec = {},
      had = false, state = {}, committed = false, finished = false,
      started = false, path = path }
    local function stop_flag()
      return stopped
    end
    -- The response that the job reads, so a stop can close it.
    local live_resp = resp
    if resp and resp.set_interrupted then
      -- The check of the load that found the file is over. The stop of the
      -- job takes its place.
      resp.set_interrupted(stop_flag)
    end
    local function body()
      local r = resp
      if not r then
        local loaded, why = load_fetch()
        if not loaded then
          return "error", why
        end
        local opened, open_why = fetch.open(dl.url, { internet = deps.internet,
          clock = now, interrupted = stop_flag, raw = true,
          sleep = function(seconds) coroutine.yield("wait", seconds) end,
          progress = function(phase, u)
            if phase == "connect" then
              phase_text = "Connecting to " .. u.host .. "..."
            elseif phase == "response" then
              phase_text = "Waiting for response..."
            elseif phase == "redirect" then
              phase_text = "Redirect to " .. u.url .. "..."
            end
            coroutine.yield("slice")
          end }, {})
        if not opened then
          return stopped and "stopped" or "error", open_why
        end
        r = opened
        live_resp = r
      end
      if r.is_error then
        local text = r.popup or ("[HTTP " .. int_text(r.status) .. "]"
          .. (r.message ~= "" and (" " .. r.message) or "") .. "\n"
          .. r.final_url)
        r.close()
        return "error", text
      end
      length, receiving = r.length, true
      return download.run(r, path, download_deps(), { stop = stop_flag,
        progress = function(n, len) bytes, length = n, len end })
    end
    local co = coroutine.create(body)
    function b.status()
      if not receiving then
        return phase_text
      end
      local t = now()
      if not shown_tail or t - shown_at >= LOAD_TICK then
        local text = kb(bytes)
        if type(length) == "number" then
          text = text .. " of " .. kb(math.max(length, bytes))
        end
        shown_tail, shown_at = text, t
      end
      return "Downloading " .. name, shown_tail
    end
    function b.drive()
      if b.finished then
        return "done"
      end
      b.started = true
      local ok, what, value = coroutine.resume(co)
      if not ok then
        b.finished = true
        what = reason(what)
        b.result = { "error", is_controlled(what) and what
          or ("html: download failed: " .. what) }
        return "done"
      elseif coroutine.status(co) == "dead" then
        b.finished = true
        b.result = { what, value }
        return "done"
      end
      return what, value
    end
    -- Stops the job: the loader runs until it has closed the response and
    -- deleted the part file.
    function b.cancel()
      if b.finished then
        return
      end
      b.finished = true
      if not b.started then
        if resp then
          resp.close()
        end
        return
      end
      stopped = true
      -- A closed response gives the read an error at once, so a slow server
      -- does not hold the stop.
      if live_resp then
        pcall(live_resp.close)
      end
      for _ = 1, 10000 do
        if coroutine.status(co) == "dead" then
          break
        end
        coroutine.resume(co)
      end
    end
    tab.bg = b
  end

  -- The save prompt, the checks of the path and the start of the job. Takes
  -- ownership of dl.resp. Returns a final result (Ctrl+C), or nil.
  local function offer_download(dl)
    local resp = dl.resp
    local function drop()
      if resp then
        resp.close()
      end
    end
    local mod = need_download()
    if not mod then
      drop()
      return nil
    end
    local ddeps = download_deps()
    local filename = resp and resp.filename
    local name = mod.default_name(dl.url, filename)
    local text = ctx.session.prompt(" Save to: ",
      mod.default_path(dl.url, filename, ddeps))
    if text == "interrupted" then
      drop()
      return { interrupted = true }
    elseif not text then
      drop()
      return nil
    end
    local path, exists = mod.resolve_path(text, name, ddeps)
    if not path then
      drop()
      tab.popup = exists
      return nil
    end
    if exists then
      local answer = ctx.session.confirm_overwrite(path:match("[^/]*$"))
      if answer == "interrupted" then
        drop()
        return { interrupted = true }
      elseif answer ~= "yes" then
        drop()
        return nil
      end
    end
    start_download(dl, path)
    return nil
  end

  -- Ctrl+S: the target is the selected link, else the page.
  local function download_action(out)
    tab.top, tab.sel = out.top, out.sel
    local url
    if out.href then
      local base = link_base()
      if not base then
        return nil
      end
      local r, why_not = urlmod.resolve(base, out.href)
      if not r then
        tab.popup = why_not
        return nil
      elseif r.kind == "unsupported" then
        tab.notice = r.scheme .. ": links are not supported"
        return nil
      elseif r.kind == "http" then
        url = r.url
      elseif r.kind == "same" then
        url = tab.cur and tab.cur.url
      end
    else
      url = tab.cur and tab.cur.url
    end
    if not url then
      tab.notice = "Ctrl+S: only web files can be downloaded"
      return nil
    end
    return offer_download({ url = url })
  end

  -- The end of the download job: z, or the job ended.
  local function end_download(out, stop)
    local b = tab.bg
    tab.bg = nil
    tab.top, tab.sel = out.top, out.sel
    if stop then
      b.cancel()
      tab.notice = "download stopped"
      return
    end
    local status, value = b.result[1], b.result[2]
    if status == "saved" then
      tab.notice = "Saved " .. b.path .. " (" .. kb(value) .. ")"
    elseif status == "stopped" then
      tab.notice = "download stopped"
    else
      tab.popup = value
    end
  end

  -- The actions of the tab keys.
  local TAB_ACTIONS = { tab_new = true, tab_prev = true, tab_next = true,
    tab_close = true, shell = true }
  local function tab_action(kind, out)
    tab.top, tab.sel = out.top, out.sel
    if kind == "shell" then
      return shell_out(out)
    elseif kind == "tab_new" then
      new_tab(out)
    elseif kind == "tab_prev" or kind == "tab_next" then
      if tab_list.count() > 1 then
        leave(out.top, out.sel)
        arrive(kind == "tab_prev" and tab_list.prev() or tab_list.next())
      end
    elseif kind == "tab_close" and tab_list.count() > 1 then
      if tab.bg then
        tab.bg.cancel()
        tab.bg = nil
      end
      arrive(tab_list.close())
    end
  end

  while true do
    if req then
      local r = req
      req = nil
      local final = start(r)
      if final then
        return final
      end
    end
    if file_wait and not req and not tab.bg then
      local waiting = file_wait
      file_wait = nil
      local final = offer_download(waiting)
      if final then
        return final
      end
    end
    if not req then
      local ok, out = present()
      if not ok then
        if tab.bg then
          tab.bg.cancel()
          tab.bg = nil
        end
        if out == "interrupted" or out == INTERRUPTED then
          return { interrupted = true, message = INTERRUPTED }
        end
        return { error = out, reload = false,
          kind = is_controlled(out) and "controlled" or "unexpected" }
      elseif out == "quit" or out == "interrupted" then
        -- Ctrl+C during a load prints the interrupted line, as a load that
        -- the guard stops does.
        local loading = tab.bg ~= nil
        if tab.bg then
          tab.bg.cancel()
          tab.bg = nil
        end
        if out == "quit" then
          return { quit = true }
        end
        return { interrupted = true, message = loading and INTERRUPTED or nil }
      end
      local kind = out.kind
      if tab.bg and tab.bg.kind == "download" and (kind == "done"
          or kind == "abort") then
        end_download(out, kind == "abort")
      elseif tab.bg and (kind == "commit" or kind == "done") then
        local final = advance(kind, out)
        if final then
          return final
        end
      elseif kind == "download" then
        local final = download_action(out)
        if final then
          return final
        end
      elseif TAB_ACTIONS[kind] then
        local final = tab_action(kind, out)
        if final then
          return final
        end
      elseif tab.bg and stop_load(kind) then
        -- The action was used up by the stop.
        kind = nil
      else
        -- An action: store the position before the page goes.
        tab.top, tab.sel = out.top, out.sel
        tab.hist.set_pos(tab.top, tab.sel)
        if kind == "link" then
          local r, why_not = urlmod.resolve(tab.held.base, out.href)
          if not r then
            tab.popup = why_not
          elseif r.kind == "same" then
            jump(r.fragment)
          elseif r.kind ~= "unsupported" then
            local key = r.url or r.path
            if key == key_of(tab.cur) or key == tab.held.location then
              jump(r.fragment)
            else
              req = { spec = spec_of(key, tab.guesses), mode = "link",
                fragment = r.fragment }
            end
          end
        elseif kind == "back" or kind == "forward" then
          local entry
          if kind == "back" then
            entry = tab.hist.back()
          else
            entry = tab.hist.forward()
          end
          if entry then
            if not tab.shown and entry.target == key_of(tab.cur) then
              tab.top, tab.sel = entry.top, entry.sel
            else
              req = { spec = spec_of(entry.target, tab.guesses), mode = kind,
                top = entry.top, sel = entry.sel }
            end
          end
        elseif kind == "reload" then
          req = { spec = tab.cur, mode = "reload", top = tab.top,
            sel = tab.sel }
          if tab.shown then
            req.top, req.sel = 1, nil
          end
        elseif kind == "go" then
          local spec, msg = M.classify(out.text, deps)
          if not spec then
            tab.popup = msg
          else
            spec.arg = out.text
            if spec.guessed then
              tab.guesses[key_of(spec)] = out.text
            end
            req = { spec = spec, mode = "go", fragment = spec.fragment }
          end
        end
      end
    end
  end
end


-- argv: the program arguments (a table, n is optional).
-- deps: the machine links:
--   out(line), err(line)   print to stdout and stderr
--   width                  default wrap width for --print
--   open(path, mode)       io.open
--   traceback(msg)         debug.traceback, or a fake in the tests
--   clock()                os.clock
--   uptime()               optional, wall time in seconds. The loading
--                          screen and the fetch use it in place of clock
--   resolve(path)          optional, makes a path absolute
--   home                   optional, the home directory for "~"
--   exists(path)           optional
--   is_dir(path)           optional
--   size(path)             optional, file size in bytes
--   log(text)              optional, keeps the details of an unexpected
--                          error. Returns true, or nil and a reason
--   gpu                    optional, the GPU proxy. Without it, or without
--                          a screen, the page prints as text
--   shell()                optional, runs a nested shell (the `!` key)
--   pull(timeout)          optional, event.pull. The return from the shell
--                          drops the queued events with it
--   getenv(name), setenv(name, value)  optional, os.getenv and os.setenv
--   open_screen(opts)      optional, opens the screen session with the
--                          loading screen (see viewer.open). It takes
--                          no_rescale, status and enter_held. Without it, the viewer
--                          opens after the render, through view. The
--                          session runs the load as a coroutine and reads
--                          the keys itself (see viewer.open)
--   view(lines, opts)      optional, runs the viewer (see viewer.run).
--                          Returns "quit", "interrupted" or an action table
--   on_interrupt(fn)       optional, calls fn on Ctrl+C. Returns a function
--                          that removes the listener
--   internet               optional, the internet card proxy (for a URL)
--   sleep(seconds)         optional, os.sleep. The fetch waits with it
--   cache                  optional, the filesystem links of the disk cache
--                          (get, exists, makeDirectory, remove, rename, list,
--                          open: see lib/html/cache.lua). Without it, the
--                          session caches nothing
-- Returns the exit code.
function M.main(argv, deps)
  -- A nested start inside the tab-out shell (spec/shell.md).
  local getenv = deps.getenv or os.getenv
  if getenv and getenv("HTML_TABOUT") then
    deps.err("html: already open; type exit to return to it")
    return EXIT_ERROR
  end
  local opts, msg = M.parse_args(argv, max_width_of(deps.gpu))
  if not opts then
    deps.err(msg .. " (see html --help)")
    return EXIT_USAGE
  end
  if opts.help then
    deps.out(M.USAGE)
    return 0
  end
  local arg = opts.file
  local target, why, why_code = M.classify(arg, deps)
  if not target then
    deps.err(why)
    return why_code
  end
  -- The loading screen opens before the heavy modules load (see
  -- spec/loading.md). Print mode and the no-screen path load them first.
  local screen_w = not opts.print and (deps.view or deps.open_screen)
    and screen_width(deps.gpu, opts.no_rescale)
  local framed = screen_w and deps.open_screen ~= nil
  -- load_modules can fail while it builds its message (for example out of
  -- memory), so it runs protected and any failure gives one controlled line.
  local function load_all()
    local called, loaded, load_why = pcall(load_modules)
    if not called then
      local built, line = pcall(function()
        return "html: cannot load modules: " .. reason(loaded)
      end)
      loaded = nil
      load_why = built and line or "html: cannot load modules"
    end
    return loaded, load_why
  end
  if not framed then
    local loaded, load_why = load_all()
    if not loaded then
      deps.err(load_why)
      return EXIT_ERROR
    end
  end
  local width = opts.width or deps.width or DEFAULT_WIDTH
  if not opts.print then
    if screen_w then
      width = screen_w
    else
      deps.err("html: no screen found, printing the text")
      opts.print = true
    end
  end

  local ctx = { opts = opts, deps = deps, arg = arg, width = width,
    framed = framed, load_all = load_all }
  target.arg = arg
  local page
  if opts.print then
    page = load_page(target, ctx)
  else
    local ran
    ran, page = pcall(run_session, target, ctx)
    if not ran then
      ctx.raised = page
    end
  end
  -- The screen is restored before any error line prints. The cache folder is
  -- emptied in the same place, on every exit path.
  local restored, restore_err = true, nil
  if ctx.session then
    restored, restore_err = pcall(ctx.session.close)
  end
  if ctx.kept then
    pcall(ctx.kept.close)
  end
  if ctx.cache then
    pcall(ctx.cache.clear)
  end
  if ctx.raised ~= nil then
    error(ctx.raised, 0)
  end

  local code = 0
  if page.quit then
    code = 0
  elseif page.interrupted then
    if page.message then
      deps.err(page.message)
    end
    code = EXIT_INTERRUPTED
  elseif page.error then
    code = EXIT_ERROR
    if page.kind == "controlled" then
      deps.err(page.error)
    else
      report_unexpected(page.error, deps)
    end
  end
  if code == 0 and not restored then
    code = EXIT_ERROR
    report_unexpected(restore_err, deps)
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
  local keyboard = need("keyboard")
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
    shell = function() return shell.execute("sh") end,
    pull = event.pull,
    home = os.getenv("HOME"),
    exists = filesystem.exists,
    is_dir = filesystem.isDirectory,
    size = filesystem.size,
    space = function(path)
      local proxy = filesystem.get(path)
      return proxy.spaceTotal() - proxy.spaceUsed()
    end,
    remove = filesystem.remove,
    rename = filesystem.rename,
    cwd = shell.getWorkingDirectory,
    log = function(text)
      if #text > ERROR_LOG_MAX then
        text = sub(text, -ERROR_LOG_MAX)
      end
      return M.write_text(io.open, ERROR_LOG, text)
    end,
    gpu = gpu,
    internet = internet,
    sleep = os.sleep,
    cache = {
      get = filesystem.get, exists = filesystem.exists,
      makeDirectory = filesystem.makeDirectory, remove = filesystem.remove,
      rename = filesystem.rename, list = filesystem.list, open = io.open,
    },
    open_screen = function(opts)
      local viewer = need("html.viewer")
      return viewer.open({ gpu = gpu, pull = event.pull, term = term,
        control_down = keyboard.isControlDown }, opts)
    end,
    view = function(lines, opts)
      local viewer = need("html.viewer")
      return viewer.run(lines, opts, { gpu = gpu, pull = event.pull,
        term = term, control_down = keyboard.isControlDown })
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
