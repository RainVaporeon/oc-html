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
M.VERSION = "0.5.0a"
M.sizes["bin/html.lua"] = 48516
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
-- Seconds between two key polls and two byte counts while loading. An event
-- pull costs about 15 ms in game, so this is about 6% of the time.
local LOAD_TICK = 0.25
-- Exit codes.
local EXIT_ERROR = 1
-- The second line of the popup of a broken page.
local RELOAD_LINE = "Reload to try again."
local EXIT_USAGE = 2
local EXIT_INTERRUPTED = 130
local INTERRUPTED = "html: interrupted"
-- The largest --width with no GPU or no screen (the tier 3 maximum).
local NO_SCREEN_MAX_WIDTH = 160

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
  --help              show this help
Viewer keys: Up Down PgUp PgDn Home End scroll, Tab Shift+Tab Enter links,
Left or Bksp back, Right forward, g go to, r reload, z abort a load,
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
-- count) is optional. It runs
-- before each read, with the live lines table and the number of finished
-- lines.
function M.render(read, width, before_read)
  local loaded, why = load_modules()
  if not loaded then
    error(why, 0)
  end
  local lay = layout.new(width)
  if before_read then
    local inner = read
    read = function()
      before_read(lay.lines, lay.count())
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
-- called when the render ends. ui is optional, for the loading screen:
-- before_read(lines, count).
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
-- target), width, framed (the loading screen opens inside the load),
-- load_all() (loads the modules, returns true or nil and a message), nav
-- (true for a load after the first one), on_commit() (optional, called after
-- phase 1 and before the size check: the point where the old page goes).
-- The screen session opens here when framed, and is stored in ctx.session.
-- A later load uses it. The caller closes it. The listener and the file are
-- closed before this returns.
-- Returns one of:
--   { ok = true, lines =, title =, page =, location = absolute path or final
--     URL, show = { file =, error = popup text or nil } (nil in print mode) }
--   { failed = true, committed = bool, text = popup text, reload = bool,
--     name = text }  an error that keeps the session (spec/navigation.md
--     "Two phases of a load"). committed is false for a phase 1 failure
--   { aborted = true, committed = bool, name = text }  the user pressed z
--   { error = text, reload = bool, kind = "controlled" or "unexpected" }
--   { interrupted = true, message = text or nil }
--   { quit = true }
local function load_page(target, ctx)
  local opts, deps, arg = ctx.opts, ctx.deps, ctx.arg
  local width, framed = ctx.width, ctx.framed
  local load_all = ctx.load_all
  local url, path, guessed = target.url, target.path, target.guessed
  local f
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
      if ctx.session or ctx.nav then
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

  -- Ctrl+C or a confirmed quit during load: the flags are set by the
  -- listener or by the screen poll, and the next guard.tick raises
  -- INTERRUPTED. A confirmed quit exits with code 0 and no message.
  -- z (abort) stops the load in the same way (spec/navigation.md "Abort").
  local interrupted, quit_requested, remove = false, false, nil
  local abort_requested, committed = false, false
  if deps.on_interrupt then
    remove = deps.on_interrupt(function() interrupted = true end)
  end
  -- The key listener of the session feeds the intents. Each check takes them,
  -- so a key counts at the next guard tick or fetch wait. poll_keys is set
  -- below.
  local poll_keys
  local function stop_flag()
    if ctx.session then
      poll_keys()
    end
    return interrupted or quit_requested or abort_requested
  end
  -- The guard loads with the other modules, so a framed run arms it later.
  local function arm_guard()
    guard.set_interrupt_check(stop_flag)
  end
  if not framed then
    arm_guard()
  end
  local function stop_listening()
    if guard then
      guard.set_interrupt_check(nil)
    end
    if ctx.session then
      pcall(ctx.session.unlisten)
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

  -- The loading screen. The status line shows the phase (see
  -- spec/loading.md). The status text is drawn only when it changes, and the
  -- byte count at most once per LOAD_TICK. The keys are polled at every tick.
  local session = ctx.session
  local name, total, bytes = arg, nil, 0
  if entry then
    name = entry.final_url or url
  end
  local in_body, phase_text, shown = false, "", nil
  local last_tick, first_drawn = 0, false
  local now = deps.uptime or deps.clock
  local function load_text()
    local text = "Loading " .. name .. "..."
    if bytes > 0 then
      text = text .. " " .. kb(bytes)
      if type(total) == "number" then
        text = text .. " of " .. kb(math.max(total, bytes))
      end
    end
    return text
  end
  local function draw_status()
    local text = in_body and load_text() or phase_text
    if text ~= shown then
      shown = text
      session.status(text)
    end
  end
  local function set_phase(text)
    in_body, phase_text = false, text
    draw_status()
  end
  function poll_keys()
    local key = session.poll()
    if key == "interrupted" then
      interrupted = true
    elseif key == "abort" then
      abort_requested = true
    elseif key == "quit" then
      quit_requested = true
    end
  end
  local function tick_load()
    poll_keys()
    local t = now()
    if t - last_tick < LOAD_TICK then
      return
    end
    last_tick = t
    draw_status()
  end
  -- The phases of the fetch (see fetch.open).
  local function progress(phase, u)
    if phase == "connect" then
      set_phase("Connecting to " .. u.host .. "...")
    elseif phase == "response" then
      set_phase("Waiting for response...")
    elseif phase == "redirect" then
      set_phase("Redirect to " .. u.url .. "...")
    else
      tick_load()
    end
  end
  -- The first screen draws as soon as the lines fill it. After that only
  -- the status line changes until the end of the input.
  local ui = {
    before_read = function(lines, count)
      if not first_drawn and count >= session.rows then
        first_drawn = true
        session.draw_lines(lines, count)
      end
      tick_load()
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
    resp, why, retry = fetch.open(url, { internet = deps.internet,
      clock = fetch_clock, sleep = deps.sleep or os.sleep,
      interrupted = stop_flag, progress = session and progress or nil },
      info)
    if not resp then
      fetch_error(why, retry)
    end
    open_file = resp
    name, total = resp.final_url, resp.length
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
    if session then
      -- A later load: the session and the modules are there. The old page
      -- stays on screen until the commit.
      shown = "Loading " .. name .. "..."
      session.status(shown)
      last_tick = now()
      session.listen()
      arm_guard()
    elseif framed then
      session = deps.open_screen({ no_rescale = opts.no_rescale,
        status = "Loading " .. name .. "..." })
      ctx.session = session
      session.listen()
      shown = "Loading " .. name .. "..."
      last_tick = now()
      set_phase("Loading modules...")
      local loaded, why = load_all()
      if not loaded then
        error(why, 0)
      end
      arm_guard()
    end
    local source = open_source()
    -- stop_flag takes the keys that came while the response opened, so they
    -- still count for phase 1.
    if stop_flag() then
      error(INTERRUPTED, 0)
    end
    -- The commit: phase 1 is over. The caller releases the old page here,
    -- before the size check measures the free memory. The old page leaves the
    -- screen, and the status line keeps the loading text.
    committed = true
    if ctx.on_commit then
      ctx.on_commit()
    end
    if session then
      session.draw_lines({}, 0)
    end
    active = source
    in_body = true
    if session then
      draw_status()
    end
    return run(source, opts, deps, width, function()
      close_file()
      if stop_flag() then
        error(INTERRUPTED, 0)
      end
      if writer and resp then
        local w = writer
        writer = nil
        w.commit_complete({ final_url = resp.final_url, status = resp.status,
          content_type = resp.content_type, is_error = false })
      end
      -- The viewer handles Ctrl+C itself. Print mode keeps the check for
      -- the output loop.
      if not opts.print then
        stop_listening()
      end
      if session then
        draw_status()
      end
    end, session and ui or nil)
  end, handler)
  -- An error that keeps the session: a fetch error, a file read error or a
  -- memory stop after the frame opened. The caller shows a popup (over the
  -- old page after a phase 1 failure, else over an empty page). A broken
  -- page is not rendered: the lines so far are dropped. Quit then gives
  -- code 0.
  local failed
  if not ok and (session or ctx.nav) and not opts.print
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
  -- Each step runs alone, so a failure in one does not skip the other.
  pcall(stop_listening)
  pcall(close_file)
  -- A load that did not complete leaves no cache entry.
  if writer then
    pcall(writer.abort)
  end

  if not ok and result == "interrupted" then
    -- A bare "interrupted" error is Ctrl+C from the event system.
    result = INTERRUPTED
  end
  if not ok and result == INTERRUPTED and not interrupted then
    if quit_requested then
      -- The user confirmed the quit prompt during load.
      ok, result = true, "quit"
    elseif abort_requested then
      return { aborted = true, committed = committed, name = name }
    end
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
  elseif result == "quit" then
    return { quit = true }
  end
  return { ok = true, lines = lines, title = title, page = page,
    location = resp and resp.final_url or entry and name or path,
    show = shown_info }
end

M.load_page = load_page

-- The session loop ----------------------------------------------------------
-- See spec/navigation.md.

local HISTORY_CAP = 32

-- Loads html.history. Returns true, or nil and a controlled message.
local history
local function load_history()
  if history then
    return true
  end
  local ok, mod = pcall(require, "html.history")
  if not ok then
    return nil, "html: cannot load html.history: " .. reason(mod)
  end
  history = mod
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
  -- The disk cache of the session. The program clears it on every exit (see
  -- main). Without deps.cache, or without the module, nothing is cached.
  if deps.cache then
    local cache_ok, cache_mod = pcall(require, "html.cache")
    if cache_ok then
      ctx.cache = cache_mod.new(nil, deps.cache)
    end
  end
  local hist = history.new(HISTORY_CAP)
  local guesses = {}
  -- The page on screen: { lines, title, name, page, location, base, resolve,
  -- broken } or nil. The commit of a load drops it.
  local held
  -- The target of the page on screen.
  local cur
  local top, sel = 1, nil
  -- The text of a popup for the next show.
  local popup
  -- The next load: { spec, mode = "first" | "link" | "go" | "back" |
  -- "forward" | "reload" | "prev", top, sel, fragment }.
  local req = { spec = target, mode = "first", fragment = target.fragment }
  if target.guessed then
    guesses[key_of(target)] = target.arg
  end

  -- An empty page with a title: a broken or an aborted load.
  local function empty_page(title, name)
    return { lines = {}, title = title, name = name, broken = true }
  end

  -- The resolver of the viewer for the page h: the text of the status line,
  -- or nil and a notice. A link that cannot resolve gives its href, so that
  -- Enter reaches the loop and the popup shows the reason.
  local function make_resolve(h)
    return function(href)
      local r = urlmod.resolve(h.base, href)
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
      return h.base .. frag
    end
  end

  -- Runs one load of r. Sets held, cur, top, sel, popup and req. Returns a
  -- final result, or nil to show.
  local function load(r)
    local spec = r.spec
    local had = held ~= nil
    ctx.arg = spec.arg or key_of(spec)
    ctx.nav = r.mode ~= "first"
    ctx.on_commit = function()
      held = nil
      if r.mode == "link" or r.mode == "go" or hist.size() == 0 then
        hist.push(key_of(spec))
      elseif r.mode == "reload" then
        hist.replace({ target = key_of(spec), top = r.top, sel = r.sel })
      end
    end
    -- Back, forward and the load of the previous page use the cached copy.
    -- Reload, link and go fetch.
    ctx.replay = r.mode == "back" or r.mode == "forward" or r.mode == "prev"
    local res = load_page(spec, ctx)
    ctx.on_commit = nil
    ctx.replay = nil
    if res.quit or res.interrupted or res.error then
      return res
    end
    if res.ok then
      cur = spec
      local h = { lines = res.lines, title = res.title, name = res.show.file,
        page = res.page, location = res.location }
      h.base = page_base(res.location, res.page.base)
      h.resolve = make_resolve(h)
      held = h
      popup = res.show.error
      if r.mode == "first" or r.mode == "link" or r.mode == "go" then
        top, sel = anchor_line(h.page, r.fragment) or 1, nil
      else
        top, sel = r.top, r.sel
      end
      return nil
    end
    -- A phase 1 failure or an abort before the commit leaves the old page.
    -- A back or forward move of the history goes back.
    local function undo()
      if r.mode == "back" then
        hist.forward()
      elseif r.mode == "forward" then
        hist.back()
      end
    end
    if res.failed then
      popup = res.text
      if res.committed or not had then
        cur = spec
        held = empty_page("[error] " .. res.name, res.name)
        top, sel = 1, nil
      else
        undo()
      end
    elseif not res.committed then
      if had then
        undo()
      else
        cur = spec
        held = empty_page("[aborted] " .. res.name, res.name)
        top, sel = 1, nil
      end
    elseif (r.mode == "link" or r.mode == "go") and hist.can_back() then
      -- The old page is gone: load the previous page again. The entry of the
      -- aborted new target goes. An abort of a reload, back or forward keeps
      -- its entry and shows the empty page, so r loads it again.
      local prev = hist.drop_current()
      req = { spec = spec_of(prev.target, guesses), mode = "prev",
        top = prev.top, sel = prev.sel }
    else
      cur = spec
      held = empty_page("[aborted] " .. res.name, res.name)
      top, sel = 1, nil
    end
    return nil
  end

  -- Shows the page. Returns ok and the result of the viewer.
  local function present()
    local h = held
    local o = { title = h.title, file = h.name, no_rescale = opts.no_rescale,
      error = popup, top = top, sel = sel }
    if h.page then
      o.links = h.page.links
      o.resolve = h.resolve
    end
    popup = nil
    local session = ctx.session
    return xpcall(session and session.show or deps.view, handler, h.lines, o)
  end

  -- A same-document link: a new history entry and a jump to the anchor.
  local function jump(fragment)
    top = anchor_line(held.page, fragment) or top
    hist.push(key_of(cur))
    hist.set_pos(top, sel)
  end

  while true do
    if req then
      local r = req
      req = nil
      local final = load(r)
      if final then
        return final
      end
    end
    if not req then
      local ok, out = present()
      if not ok then
        if out == "interrupted" or out == INTERRUPTED then
          return { interrupted = true, message = INTERRUPTED }
        end
        return { error = out, reload = false,
          kind = is_controlled(out) and "controlled" or "unexpected" }
      elseif out == "quit" then
        return { quit = true }
      elseif out == "interrupted" then
        return { interrupted = true }
      end
      -- An action: store the position before the page goes.
      top, sel = out.top, out.sel
      hist.set_pos(top, sel)
      local kind = out.kind
      if kind == "link" then
        local r, why_not = urlmod.resolve(held.base, out.href)
        if not r then
          popup = why_not
        elseif r.kind == "same" then
          jump(r.fragment)
        elseif r.kind ~= "unsupported" then
          local key = r.url or r.path
          if key == key_of(cur) or key == held.location then
            jump(r.fragment)
          else
            req = { spec = spec_of(key, guesses), mode = "link",
              fragment = r.fragment }
          end
        end
      elseif kind == "back" or kind == "forward" then
        local entry
        if kind == "back" then
          entry = hist.back()
        else
          entry = hist.forward()
        end
        if entry then
          if not held.broken and entry.target == key_of(cur) then
            top, sel = entry.top, entry.sel
          else
            req = { spec = spec_of(entry.target, guesses), mode = kind,
              top = entry.top, sel = entry.sel }
          end
        end
      elseif kind == "reload" then
        req = { spec = cur, mode = "reload", top = top, sel = sel }
        if held.broken then
          req.top, req.sel = 1, nil
        end
      elseif kind == "go" then
        local spec, msg = M.classify(out.text, deps)
        if not spec then
          popup = msg
        else
          spec.arg = out.text
          if spec.guessed then
            guesses[key_of(spec)] = out.text
          end
          req = { spec = spec, mode = "go", fragment = spec.fragment }
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
--   open_screen(opts)      optional, opens the screen session with the
--                          loading screen (see viewer.open). It takes
--                          no_rescale and status. Without it, the viewer
--                          opens after the render, through view
--                          The viewer session takes deps.on_key from the
--                          caller (see viewer.open), so a test passes a
--                          viewer built on its own deps
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
  -- Calls fn(name, char, code) for each key event until the returned function
  -- runs. The listeners see the keys that os.sleep takes from the queue.
  local function on_key(fn)
    local function down(_, _, char, code)
      fn("key_down", char, code)
    end
    local function up(_, _, char, code)
      fn("key_up", char, code)
    end
    event.listen("key_down", down)
    event.listen("key_up", up)
    return function()
      event.ignore("key_down", down)
      event.ignore("key_up", up)
    end
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
        on_key = on_key }, opts)
    end,
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
M.sizes["lib/html/cache.lua"] = 8493
M.files["lib/html/cache.lua"] = [[
-- Disk page cache of one browsing session (spec/cache.md).
-- The module keeps an index only. The page bytes live in files.
-- Nothing is called at load time. Every filesystem call comes from deps.
--
--   local c = cache.new(opts, deps)
--     opts.dir          folder, default "/home/.cache/html"
--     opts.max_bytes    limit of the byte cap, default 2 MiB
--     opts.fraction     share of the free space, default 0.25
--     opts.max_entries  default 16
--     opts.reserve      free bytes the cache never uses, default 64 KB
--     deps.get(dir)         returns proxy (spaceTotal, spaceUsed, isReadOnly)
--     deps.exists(path), deps.makeDirectory(path), deps.remove(path),
--     deps.rename(from, to), deps.list(dir) (iterator or table of names),
--     deps.open(path, mode) returns a file handle or nil, err
--   c.key(url)             key of a URL: the URL without its fragment
--   c.enabled()            false after the cache turned itself off
--   c.budget()             bytes_cap, entries_cap
--   c.begin(key)           writer, or nil when the cache is off or key is not
--                          an http(s) URL
--     w.write(chunk)       true, or false when the writer stopped
--     w.commit_complete(meta)  rename the part file in; meta is
--                          { final_url, status, content_type, is_error }
--     w.abort()            delete the part file
--   c.get(key)             entry { key, file, bytes, final_url, status,
--                          content_type, is_error, last_used, open }, or nil
--     entry.open()         file handle for reading, or nil, err
--   c.drop(key)            remove one entry (the caller saw a read error)
--   c.clear()              delete the content of the folder, empty the index
--   c.stats()              { entries, bytes }

local M = {}

local DEFAULT_DIR = "/home/.cache/html"
local MAX_BYTES = 2 * 1024 * 1024
local FRACTION = 0.25
local MAX_ENTRIES = 16
local RESERVE = 64 * 1024

local function join(dir, name)
  return (dir:gsub("/+$", "")) .. "/" .. name
end

-- True when a pcall of a handle call failed. A raised error fails. So does
-- (nil|false, reason). A bare nil or no values is success: OpenOS close()
-- returns nothing on success (docs/probe/FACTS.md).
local function failed(ok, res, reason)
  return not ok or ((res == nil or res == false) and reason ~= nil)
end

-- Returns the names in a folder as a list. Never raises.
local function names(deps, dir)
  local ok, res = pcall(deps.list, dir)
  local out = {}
  if not ok or not res then
    return out
  end
  if type(res) == "function" then
    for name in res do
      out[#out + 1] = name
    end
  else
    for _, name in ipairs(res) do
      out[#out + 1] = name
    end
  end
  return out
end

function M.new(opts, deps)
  opts = opts or {}
  local dir = opts.dir or DEFAULT_DIR
  local max_entries = opts.max_entries or MAX_ENTRIES
  local reserve = opts.reserve or RESERVE
  local cap = 0
  local on = true
  local index = {}
  local total = 0
  local count = 0
  local tick = 0
  local serial = 0
  local writers = {}

  local self = {}

  local function remove(path)
    pcall(deps.remove, path)
  end

  local function forget(key)
    local e = index[key]
    if e then
      index[key] = nil
      total = total - e.bytes
      count = count - 1
      remove(e.file)
    end
  end

  -- Deletes the content of the folder. Errors are ignored.
  local function wipe()
    for _, name in ipairs(names(deps, dir)) do
      remove(join(dir, (name:gsub("/+$", ""))))
    end
    index = {}
    total = 0
    count = 0
  end

  local function turn_off()
    if on then
      on = false
      wipe()
    end
  end

  local function evict_oldest()
    local oldest
    for key, e in pairs(index) do
      if not oldest or e.last_used < index[oldest].last_used then
        oldest = key
      end
    end
    if not oldest then
      return false
    end
    forget(oldest)
    return true
  end

  function self.key(url)
    return (tostring(url):gsub("#.*$", ""))
  end

  function self.enabled()
    return on
  end

  function self.budget()
    return cap, max_entries
  end

  function self.stats()
    return { entries = count, bytes = total }
  end

  function self.clear()
    -- Writers in flight lose their part files and stop at the next call.
    for w in pairs(writers) do
      w.stopped = true
    end
    wipe()
  end

  function self.get(key)
    if not on then
      return nil
    end
    key = self.key(key)
    local e = index[key]
    if not e then
      return nil
    end
    local ok, h = pcall(deps.open, e.file, "rb")
    if not ok or not h then
      forget(key)
      return nil
    end
    pcall(h.close, h)
    tick = tick + 1
    e.last_used = tick
    local entry = {}
    for k, v in pairs(e) do
      entry[k] = v
    end
    entry.open = function()
      local ok2, h2, err = pcall(deps.open, e.file, "rb")
      if not ok2 or not h2 then
        forget(key)
        return nil, ok2 and err or h2
      end
      return h2
    end
    return entry
  end

  function self.drop(key)
    forget(self.key(key))
  end

  function self.begin(key)
    if not on or type(key) ~= "string" then
      return nil
    end
    key = self.key(key)
    if not key:lower():match("^https?://") then
      return nil
    end
    forget(key)
    while count >= max_entries do
      if not evict_oldest() then
        break
      end
    end
    serial = serial + 1
    local path = join(dir, tostring(serial))
    local part = path .. ".part"
    local ok, h = pcall(deps.open, part, "wb")
    if not ok or not h then
      turn_off()
      return nil
    end

    local w = { stopped = false }
    local written = 0
    local writer = {}

    local function finish()
      writers[w] = nil
      w.stopped = true
      pcall(h.close, h)
      remove(part)
    end

    function writer.abort()
      if writers[w] then
        finish()
      end
    end

    function writer.write(chunk)
      if w.stopped or not on then
        writer.abort()
        return false
      end
      written = written + #chunk
      -- A page over the cap stops this writer. The cache stays on.
      if written > cap then
        finish()
        return false
      end
      while total + written > cap do
        if not evict_oldest() then
          break
        end
      end
      if failed(pcall(h.write, h, chunk)) then
        finish()
        turn_off()
        return false
      end
      return true
    end

    function writer.commit_complete(meta)
      if w.stopped or not on then
        writer.abort()
        return false
      end
      meta = meta or {}
      local cclosed = failed(pcall(h.close, h))
      writers[w] = nil
      w.stopped = true
      if cclosed then
        remove(part)
        turn_off()
        return false
      end
      local rok, rres = pcall(deps.rename, part, path)
      if not rok or not rres then
        remove(part)
        turn_off()
        return false
      end
      while count >= max_entries or total + written > cap do
        if not evict_oldest() then
          break
        end
      end
      tick = tick + 1
      index[key] = {
        key = key,
        file = path,
        bytes = written,
        final_url = meta.final_url,
        status = meta.status,
        content_type = meta.content_type,
        is_error = meta.is_error and true or false,
        last_used = tick,
      }
      total = total + written
      count = count + 1
      return true
    end

    writers[w] = true
    return writer
  end

  -- Session start: make the folder, check the disk, drop leftovers, and
  -- read the free space.
  local function setup()
    local ok = pcall(function()
      if not deps.exists(dir) and not deps.makeDirectory(dir) then
        error("no folder")
      end
    end)
    if not ok then
      on = false
      return
    end
    local sok, proxy = pcall(deps.get, dir)
    if not sok or not proxy then
      on = false
      return
    end
    local rok, read_only = pcall(proxy.isReadOnly)
    if not rok or read_only then
      on = false
      return
    end
    wipe()
    local fok, free = pcall(function()
      return proxy.spaceTotal() - proxy.spaceUsed()
    end)
    if not fok then
      on = false
      return
    end
    cap = math.min(math.floor(free * (opts.fraction or FRACTION)),
      opts.max_bytes or MAX_BYTES, free - reserve)
    if cap < 1 then
      cap = 0
      on = false
    end
  end

  setup()
  return self
end

return M
]]
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
M.sizes["lib/html/fetch.lua"] = 14221
M.files["lib/html/fetch.lua"] = [[
-- Fetches a page with the internet card and streams its body. The card
-- proxy, the clock, the sleep function and the interrupt check come from the
-- caller (links), so this module never loads component.

local M = {}
local find, lower, sub = string.find, string.lower, string.sub

-- The URL rules live in html.url, so the program can check an argument
-- before this module loads. The names stay here for the callers.
local urlmod = require("html.url")
M.scheme, M.parse_url, M.looks_like_host = urlmod.scheme, urlmod.parse_url,
  urlmod.looks_like_host

-- Request and body ----------------------------------------------------------

-- The release version. It goes into the User-Agent header.
M.VERSION = "0.5.0a"

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

-- Any text/* type renders, as does XHTML. Images, archives and other
-- application types do not.
local function accepted(media)
  return media == "" or media == "application/xhtml+xml"
    or sub(media, 1, 5) == "text/"
end

local LATIN_CHARSETS = { ["iso-8859-1"] = true, latin1 = true,
  ["windows-1252"] = true }

-- The first line of a reason from the card. It can be any value.
local function why_text(v)
  if v == nil then
    v = "unknown reason"
  end
  return (tostring(v):match("^[^\n]*"))
end

-- The reason phrases of the common error codes. The card gives no phrase for
-- an error status, so the program adds its own. A code that is not here has
-- no phrase.
M.PHRASES = {
  [400] = "Bad Request", [401] = "Unauthorized", [403] = "Forbidden",
  [404] = "Not Found", [405] = "Method Not Allowed",
  [408] = "Request Timeout", [410] = "Gone", [429] = "Too Many Requests",
  [500] = "Internal Server Error", [501] = "Not Implemented",
  [502] = "Bad Gateway", [503] = "Service Unavailable",
  [504] = "Gateway Timeout",
}

local STATUS_REASON = "^Server returned HTTP response code: (%d+) for URL: "

-- Maps a finishConnect failure back to an HTTP error status (measured in
-- game, see spec/fetch.md "HTTP error statuses"). The card gives no status
-- for 4xx and 5xx: finishConnect returns nil and a reason. h.response is
-- tried first, because the card may give a code after a failure. The reason
-- text is the main path: the exact URL means 404, and the Java message of
-- the other codes holds the number. Returns the code, or nil when the
-- failure is a connection error.
local function status_of(h, reason, url)
  local ok, code = pcall(h.response)
  if ok and type(code) == "number" then
    code = math.tointeger(code)
    if code and code >= 400 and code <= 599 then
      return code
    end
  end
  reason = tostring(reason)
  if reason == url then
    return 404
  end
  code = math.tointeger(tonumber(reason:match(STATUS_REASON) or ""))
  if code and code >= 400 and code <= 599 then
    return code
  end
  return nil
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
-- The title is the phrase only: the status line has the code already.
local function short_page(code, message, url)
  local head = escape("HTTP " .. code .. (message ~= "" and (" " .. message)
    or ""))
  local title = message ~= "" and ("<title>" .. escape(message) .. "</title>")
    or ""
  return title .. "<h1>" .. head .. "</h1><p>" .. escape(url) .. "</p>"
end

-- Waits for the connection and the status line. Returns true, code, message
-- and headers, or false, a controlled message, the HTTP error status that the
-- failure maps to (or nil) and retry (true when trying again may work).
local function wait_response(h, url, links)
  local clock, interrupted = links.clock, links.interrupted
  local t0 = clock()
  local function wait()
    if interrupted() then
      return INTERRUPTED
    end
    if clock() - t0 > CONNECT_TIMEOUT then
      return "html: timed out connecting to " .. url, true
    end
    if links.progress then
      links.progress("wait")
    end
    links.sleep(WAIT_STEP)
    return nil
  end
  while true do
    local ok, done, why = pcall(h.finishConnect)
    if not ok or done == nil then
      local reason = ok and why or done
      return false, "html: cannot connect: " .. url .. ": "
        .. why_text(reason), status_of(h, reason, url), true
    end
    if done then
      break
    end
    local stop, retry = wait()
    if stop then
      return false, stop, nil, retry
    end
  end
  if links.progress then
    links.progress("response")
  end
  while true do
    local ok, code, message, headers = pcall(h.response)
    if not ok then
      return false, "html: cannot connect: " .. url .. ": " .. why_text(code),
        nil, true
    end
    if code ~= nil then
      return true, code, message, headers
    end
    local stop, retry = wait()
    if stop then
      return false, stop, nil, retry
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
-- bodyless is true for a status that came from a connect failure: there is
-- no body to read, so the short page shows.
local function make_response(h, u, code, message, headers, links, info,
                             bodyless)
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
  if not is_error and not accepted(media) then
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
      if links.progress then
        links.progress("wait")
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
  if bodyless or not accepted(media) or not plain then
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
    end
    return s, why
  end
  return resp
end

-- Opens url with the card in links.internet and follows redirects.
-- links: internet (the card proxy), clock() (wall time in seconds),
-- sleep(seconds), interrupted() (true after Ctrl+C), and an optional
-- progress(phase, u): "connect" (u is the parsed URL), "redirect" (u is the
-- parsed target), "response" (the connection is up) and "wait" (a wait loop
-- is about to sleep). It does not stop the fetch: use interrupted() for that.
-- info is filled as the request goes: url, redirects, status, started and
-- ended (clock values).
-- Returns a response (status, message, is_error, length, content_type,
-- final_url, redirects, bytes, read(), close(), fetch_time()),
-- or nil, a controlled message and retry (true when trying again may work:
-- a connect or timeout failure). A 4xx or 5xx status that the card reports
-- as a connect failure returns a response too: its body is the short page,
-- and it has notice (the print mode line) and popup (the viewer text).
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
    if links.progress then
      links.progress(info.redirects == 0 and "connect" or "redirect", u)
    end
    local ok, h, reason = pcall(card.request, u.url, nil, HEADERS)
    if not ok or not h then
      return nil, "html: cannot fetch " .. u.url .. ": "
        .. why_text(ok and reason or h), true
    end
    local called, got, code, message, headers = pcall(wait_response, h,
      u.url, links)
    if not called then
      -- A raised sleep (for example Ctrl+C) still closes the handle.
      pcall(h.close)
      error(got, 0)
    end
    if not got then
      -- On a failure, code is the message, message is the status of the
      -- failure (nil for a connection error) and headers is retry.
      local status = message
      if status then
        info.status = status
        local phrase = M.PHRASES[status] or ""
        local tail = phrase ~= "" and (" " .. phrase) or ""
        local resp = make_response(h, u, status, phrase, {}, links, info,
          true)
        resp.popup = "[HTTP " .. status .. "]" .. tail .. "\n" .. u.url
        resp.notice = "html: HTTP " .. status .. tail .. ": " .. u.url
        return resp
      end
      pcall(h.close)
      return nil, code, headers == true
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
M.sizes["lib/html/guard.lua"] = 10879
M.files["lib/html/guard.lua"] = [[
local computer = require("computer")

local M = {}

-- CPU seconds between yields. OpenOS kills a program that runs for 5 s
-- without yielding, and a short interval lets Ctrl+C and q respond fast
-- during load.
local YIELD_INTERVAL = 0.25
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
-- two >= the line count, at least TABLE_SLOTS_MIN. The link and anchor
-- arrays of the layout double the same way. The layout reports their
-- capacity with note_tables(), and c is the larger of the two capacities.
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
-- A function fn(seconds) that replaces os.sleep in every yield and settle, or
-- nil for os.sleep. reset() keeps it, because the loader sets it once per
-- session and tests reset the guard between pages.
local yield_fn
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
local tables = TABLE_SLOTS_MIN
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
  (yield_fn or os.sleep)(0)
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
  slots, tables = TABLE_SLOTS_MIN, TABLE_SLOTS_MIN
  reserve = math.max(MEMORY_RESERVE, SLOT_DOUBLING * slots)
end

-- Sets the function that tick() calls to check for Ctrl+C. When it returns
-- true, tick() raises "html: interrupted". nil removes the check.
function M.set_interrupt_check(fn)
  interrupted = fn
end

-- Sets the function fn(seconds) that every guard yield and settle calls in
-- place of os.sleep. An error raised by fn propagates out of tick(). nil
-- restores os.sleep. reset() keeps it.
function M.set_yield(fn)
  yield_fn = fn
end

-- The layout calls this when its link or anchor arrays pass a power of
-- two. count is the larger of 2 * link count and anchor count, or their
-- capacity. The guard rounds it up to a power of two, at least 1024.
function M.note_tables(count)
  local c = TABLE_SLOTS_MIN
  while c < count do
    c = c * 2
  end
  if c > tables then
    tables = c
    reserve = math.max(MEMORY_RESERVE, SLOT_DOUBLING * math.max(slots, tables))
  end
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
      reserve = math.max(MEMORY_RESERVE,
        SLOT_DOUBLING * math.max(slots, tables))
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
M.sizes["lib/html/history.lua"] = 2655
M.files["lib/html/history.lua"] = [[
-- History of one browsing session (spec/navigation.md "History").
-- A pure module: it holds entries { target, top, sel } and no page content.
--
--   local h = history.new(cap)   cap defaults to 32
--   h.push(target)       cut the forward entries, append { target, top = 1 },
--                        drop the oldest entry at the cap; returns the entry
--   h.current()          copy of the current entry, or nil when empty
--   h.back()             move one entry back; returns the entry, or nil at the start
--   h.forward()          move one entry forward; returns the entry, or nil at the end
--   h.can_back()         true when back() would move
--   h.can_forward()      true when forward() would move
--   h.set_pos(top, sel)  store top and sel in the current entry (sel may be nil)
--   h.replace(entry)     the current entry becomes a copy of entry (reload)
--   h.drop_current()     remove the current entry (abort after the commit);
--                        the previous entry becomes current and is returned,
--                        or nil when no entry is left
--   h.size()             number of entries

local M = {}

local DEFAULT_CAP = 32

local function copy(entry)
  return { target = entry.target, top = entry.top, sel = entry.sel }
end

function M.new(cap)
  cap = cap or DEFAULT_CAP
  local entries = {}
  local pos = 0
  local h = {}

  function h.push(target)
    for i = #entries, pos + 1, -1 do
      entries[i] = nil
    end
    entries[#entries + 1] = { target = target, top = 1 }
    if #entries > cap then
      table.remove(entries, 1)
    end
    pos = #entries
    return copy(entries[pos])
  end

  function h.current()
    return entries[pos] and copy(entries[pos]) or nil
  end

  function h.can_back()
    return pos > 1
  end

  function h.can_forward()
    return pos < #entries
  end

  function h.back()
    if pos <= 1 then
      return nil
    end
    pos = pos - 1
    return copy(entries[pos])
  end

  function h.forward()
    if pos >= #entries then
      return nil
    end
    pos = pos + 1
    return copy(entries[pos])
  end

  function h.set_pos(top, sel)
    local entry = entries[pos]
    if entry then
      entry.top = top
      entry.sel = sel
    end
  end

  function h.replace(entry)
    if entries[pos] then
      entries[pos] = copy(entry)
    end
  end

  function h.drop_current()
    if pos == 0 then
      return nil
    end
    table.remove(entries, pos)
    -- The first entry has no previous one: the next entry takes its place.
    if pos > 1 then
      pos = pos - 1
    end
    return h.current()
  end

  function h.size()
    return #entries
  end

  return h
end

return M
]]
M.sizes["lib/html/layout.lua"] = 22122
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
local note_tables = guard.note_tables

M.NORMAL = "\1"
M.HEADING = "\2"
M.EMPHASIS = "\3"
M.LINK = "\4"
M.PRE = "\5"

-- Link and anchor limits (spec/layout.md "Links and anchors").
local HREF_MAX = 2048
local ID_MAX = 256
local DELTA_MAX = 65535
local COL_MAX = 255
local TABLES_MIN = 1024

-- FNV-1a over the bytes, masked to 40 bits. The 64-bit product wraps, and
-- the low 40 bits do not depend on the higher bits.
function M.hash40(s)
  local h = 0xcbf29ce484222325
  for i = 1, #s do
    h = (h ~ byte(s, i)) * 0x100000001b3
  end
  return h & 0xFFFFFFFFFF
end
local hash40 = M.hash40

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
  "ol", "dl", "dt", "dd", "form", "input", "button", "select", "option",
  "textarea", "pre", "li")

local HEADING = set("h1", "h2", "h3", "h4", "h5", "h6")

local EMPHASIS = set("b", "strong", "i", "em", "u", "mark")

-- Elements without content. They never go on the stack.
local VOID = set("area", "base", "br", "col", "embed", "hr", "img", "input",
  "keygen", "link", "meta", "param", "source", "track", "wbr")

-- A start tag of one of these closes an open p (the HTML standard list).
local CLOSES_P = set("address", "article", "aside", "blockquote", "center",
  "details", "dialog", "dir", "div", "dl", "dd", "dt", "fieldset",
  "figcaption", "figure", "footer", "form", "header", "hgroup", "hr", "li",
  "listing", "main", "menu", "nav", "ol", "p", "plaintext", "pre", "search",
  "section", "summary", "table", "ul", "xmp", "h1", "h2", "h3", "h4", "h5",
  "h6")

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
--   links()                                  link spans, hrefs, link count
--   anchors()                                anchor entries, anchor count
--   base()                                   the raw <base href>, or nil
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
  -- The link key of each pending piece (0: no link), the key in effect for
  -- new text (see sokey) and the key of the last placed word.
  local wkey, ckey, lastkey = {}, 0, 0
  -- Links: one packed span and one href per entry. ent[key] holds the href
  -- (or false) until the first piece of the link is placed, then the index
  -- of its entry. nkey counts the keys.
  local spans, hrefs, nl, ent, nkey = {}, {}, 0, {}, 0
  -- Anchors, and the table capacity last reported to the guard.
  local anc, na, tcap = {}, 0, TABLES_MIN
  local base_href
  -- True when white space came after the last placed word.
  local space = false
  -- True when the pending word continues a word that was placed early
  -- because it was wider than the width.
  local cont = false
  -- True when the current line has a word. A prefix such as "- " is not a
  -- word, so white space after it is not kept.
  local has_word = false
  -- The open elements: name, style inside, pre flag inside, and the style
  -- the element sets itself (false when it takes the style of its parent).
  local sname, sstyle, spre, sown, sd = {}, {}, {}, {}, 0
  -- Per open element: the link key it starts (0 when none) and the key in
  -- effect inside it.
  local sokey, skey = {}, {}
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

  -- Tells the guard when a table passes a power of two.
  local function grow(count)
    if count > tcap then
      repeat
        tcap = tcap * 2
      until tcap >= count
      note_tables(tcap)
    end
  end

  -- Adds columns c1 to c2 of the current line to the link of key.
  local function link_piece(key, c1, c2)
    if c2 > COL_MAX then
      c2 = COL_MAX
      if c1 > COL_MAX then
        c1 = COL_MAX
      end
    end
    local line = n + 1
    local e = ent[key]
    if type(e) ~= "number" then
      nl = nl + 1
      spans[nl] = (line << 32) | (c1 << 24) | c2
      hrefs[nl] = e
      ent[key] = nl
      grow(2 * nl)
      return
    end
    local span = spans[e]
    local delta = line - (span >> 32)
    if delta <= DELTA_MAX then
      spans[e] = (span & ~0xFFFFFF) | (delta << 8) | c2
    end
  end

  -- Adds s (not empty) of w columns in style st to the current line. key is
  -- the link key of s, or 0.
  local function place(s, st, w, key)
    if key ~= 0 then
      link_piece(key, cur_w + 1, cur_w + w)
    end
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
  local function split(s, st, key)
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
        place(sub(s, i, j), st, j - i + 1, key)
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
          place(sub(s, from, i - 1), st, w, key)
        end
        end_line()
        from, w = i, 0
      end
      w = w + cw
      i = i + size
    end
    if from <= len then
      place(sub(s, from), st, w, key)
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
    -- The gap space is part of a link only when both sides are.
    local gkey = wkey[1]
    if gkey ~= lastkey then
      gkey = 0
    end
    space = false
    if cur_w + gap + ww > width and has_word and not cont then
      end_line()
      gap = 0
    end
    if cur_w + gap + ww <= width then
      if gap == 1 then
        place(" ", lstyle, 1, gkey)
      end
      for i = 1, nw do
        place(word[i], wst[i], wwd[i], wkey[i])
      end
    else
      for i = 1, nw do
        if cur_w + wwd[i] <= width then
          place(word[i], wst[i], wwd[i], wkey[i])
        else
          split(word[i], wst[i], wkey[i])
        end
      end
    end
    lastkey = wkey[nw]
    nw, ww = 0, 0
    has_word = true
    cont = partial or false
  end

  local function add_piece(s, ascii)
    local w = ascii and #s or unicode.wlen(s)
    nw = nw + 1
    word[nw], wst[nw], wwd[nw], wkey[nw] = s, style, w, ckey
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
        split(sub(s, i, stop), style, ckey)
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
        place(rep(" ", sp), style, sp, ckey)
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
    if title_at == 0 or title_bytes >= TITLE_BUF then
      return
    end
    -- Small chunks give many small pieces. Join them to keep the list short.
    if title_len >= 64 then
      title_buf[1] = concat(title_buf, "", 1, title_len)
      for k = 2, title_len do
        title_buf[k] = nil
      end
      title_len = 1
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
    sname[sd], sstyle[sd], spre[sd], sown[sd] = nil, nil, nil, nil
    sokey[sd], skey[sd] = nil, nil
    sd = sd - 1
    if sd > 0 then
      style, in_pre, ckey = sstyle[sd], spre[sd], skey[sd]
    else
      style, in_pre, ckey = M.NORMAL, false, 0
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
  local function push_open(name, st, pre, own, okey)
    if sd >= M.MAX_DEPTH then
      if drop_at > 0 or not DROP[name] then
        return false
      end
      close_top()
    end
    sd = sd + 1
    sname[sd], sstyle[sd], spre[sd], sown[sd] = name, st, pre, own or false
    if okey then
      ckey = okey
    end
    sokey[sd], skey[sd] = okey or 0, ckey
    style, in_pre = st, pre
    return true
  end

  -- Removes the inline element at index i (below the top) from the stack.
  -- The elements above it stay open and take their styles again from their
  -- new parents, as browsers do for a misnested inline end tag.
  local function remove_at(i)
    for k = i, sd - 1 do
      sname[k], sown[k], sokey[k] = sname[k + 1], sown[k + 1], sokey[k + 1]
    end
    sname[sd], sstyle[sd], spre[sd], sown[sd] = nil, nil, nil, nil
    sokey[sd], skey[sd] = nil, nil
    sd = sd - 1
    for k = i, sd do
      local pst, ppre, pkey = M.NORMAL, false, 0
      if k > 1 then
        pst, ppre, pkey = sstyle[k - 1], spre[k - 1], skey[k - 1]
      end
      sstyle[k] = sown[k] or pst
      spre[k] = ppre or sname[k] == "pre"
      skey[k] = sokey[k] ~= 0 and sokey[k] or pkey
    end
    style, in_pre, ckey = sstyle[sd], spre[sd], skey[sd]
  end

  -- Makes a fresh link key for an href. The href is trimmed of ASCII white
  -- space. One over HREF_MAX bytes is stored as false.
  local function new_link(href)
    if type(href) ~= "string" then
      href = ""
    end
    local b, e = find(href, "[^ \t\n\r\f\v]"), #href
    if not b then
      href = ""
    else
      while find(sub(href, e, e), "[ \t\n\r\f\v]") do
        e = e - 1
      end
      if b > 1 or e < #href then
        href = sub(href, b, e)
      end
    end
    nkey = nkey + 1
    ent[nkey] = #href <= HREF_MAX and href or false
    return nkey
  end

  -- Records the id of an element, and the name of an a, as anchors at the
  -- first line of the element.
  local function note_anchors(name, attrs)
    local id, nm = attrs.id, name == "a" and attrs.name
    if not id and not nm then
      return
    end
    local line = n + 1
    if line > 0xFFFFFF then
      line = 0xFFFFFF
    end
    for k = 1, 2 do
      local v = id
      if k == 2 then
        v = nm
      end
      if type(v) == "string" and v ~= "" and #v <= ID_MAX then
        na = na + 1
        anc[na] = (hash40(v) << 24) | line
        grow(na)
      end
    end
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
      if name == "base" and not base_href and attrs
          and sname[drop_at] == "head" and type(attrs.href) == "string" then
        base_href = attrs.href
      end
      -- A title in head is the document title. A title in svg is not.
      if not void and push_open(name, style, in_pre) and name == "title"
          and sname[drop_at] == "head" and title_buf and title_at == 0 then
        title_at = sd
      end
      return
    end
    -- The first base with an href counts, in head or anywhere else outside
    -- a dropped part.
    if name == "base" and not base_href and attrs
        and type(attrs.href) == "string" then
      base_href = attrs.href
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
    ---@type string|false
    local own = false
    local pre = in_pre
    local okey
    if HEADING[name] then
      block()
      blank()
      own = M.HEADING
    elseif EMPHASIS[name] then
      own = M.EMPHASIS
    elseif name == "a" then
      if attrs and attrs.href then
        own = M.LINK
        okey = new_link(attrs.href)
      end
    elseif name == "br" then
      commit()
      space = false
      -- A br before any content gives no blank first line.
      if n > 0 or np > 0 then
        end_line()
      end
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
        place("- ", style, 2, 0)
      end
    elseif name == "pre" then
      block()
      own, pre = M.PRE, true
    elseif BLOCK[name] then
      block()
    end
    if attrs then
      note_anchors(name, attrs)
    end
    if not void then
      push_open(name, own or style, pre, own, okey)
      if name == "pre" then
        pre_first = true
      end
    end
  end

  -- An end tag closes the innermost open element of its name. An inline
  -- element closes alone, so the elements open inside it stay open. A block,
  -- heading or dropped element, and any element around a dropped part,
  -- closes the elements inside it too.
  local function end_tag(name)
    pre_first = false
    for i = sd, 1, -1 do
      if sname[i] == name then
        if i < sd and drop_at == 0 and not (BLOCK[name] or HEADING[name]
            or DROP[name]) then
          remove_at(i)
        else
          close_to(i)
        end
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

  -- The link spans, their hrefs and the number of links.
  function self.links()
    return spans, hrefs, nl
  end

  -- The anchor entries and their number.
  function self.anchors()
    return anc, na
  end

  -- The first <base href> outside a dropped part, raw, or nil.
  function self.base()
    return base_href
  end

  function self.finish()
    close_to(1)
    block()
    while n > 0 and lines[n] == "" do
      lines[n] = nil
      n = n - 1
    end
    -- An anchor on an element at the end can point past the last line. Its
    -- line is the last line then. Entries are in line order.
    local last = n > 0 and n or 1
    for i = na, 1, -1 do
      local a = anc[i]
      if (a & 0xFFFFFF) <= last then
        break
      end
      anc[i] = (a & ~0xFFFFFF) | last
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
M.sizes["lib/html/tokenizer.lua"] = 15152
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
--   A "<" with no ">" within MAX_TAG bytes or before the end of input is
--   text.
--   A broken quoted value ends the tag at the first ">" in the value. The
--   value's attribute is dropped. A quoted value is broken when it does not
--   close within MAX_TAG bytes of "<" or before the end of input, or when
--   it holds a ">" and then "</" (as in <a href="x>text</a>).
--   A tag that does not end within MAX_TAG bytes for another reason ends at
--   the first ">" after its "<", with no attributes.
--   An attribute name with a quote or "<", or one that starts with "=", is
--   dropped. For a duplicate name, the first value is kept.
--   An end tag ends at the first ">" after its "<", also inside quotes.
--   An unclosed comment, bogus comment, CDATA, script or style ends with
--   the input and gives no text. Unclosed title or textarea content is text.

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
  -- and the self-closing flag.
  -- A quoted value is broken when it does not close within MAX_TAG bytes of
  -- "<" or before the end of input, or when it holds a ">" and then "</"
  -- (as in <a href="x>text</a>).
  local function attributes(i, gt)
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
          if not bad then
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
            if not bad then
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
          if not bad then
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
          if not bad then
            attrs = add(attrs, name, "")
          end
          break
        elseif not WS[b] then
          state, vs = UNQUOTED, i
        end
        i = i + 1
      elseif state == UNQUOTED then
        if WS[b] or b == 62 then
          if not bad then
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
        pos = pos + 1
        return "text", "<"
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
    if closing then
      pos = gt + 1
      return "end", name
    end
    local attrs, self_closing
    local nb = byte(buf, e + 1)
    if nb == 62 then
      pos, self_closing = e + 2, false
    elseif nb == 47 and byte(buf, e + 2) == 62 then
      pos, self_closing = e + 3, true
    else
      attrs, self_closing = attributes(e + 1, gt)
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
M.sizes["lib/html/url.lua"] = 7676
M.files["lib/html/url.lua"] = [[
-- Parses URL arguments. The program loads this small module while it checks
-- the arguments, so a bad URL is found before the TUI opens and before the
-- heavy modules load. It has no dependencies.

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
-- See spec/url.md "Arguments without a scheme".
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

-- Link resolution -----------------------------------------------------------
-- See spec/url.md "Link resolution".

-- Returns the scheme of s in lower case when s starts with
-- "<letter>[letters, digits, + . -]:" (RFC 3986), or nil.
function M.ref_scheme(s)
  local scheme = type(s) == "string" and s:match("^(%a[%w+.-]*):")
  return scheme and lower(scheme) or nil
end

-- Removes the "." and ".." segments of an absolute path (RFC 3986 5.2.4).
local function remove_dots(path)
  if sub(path, 1, 1) ~= "/" then
    return path
  end
  local segs = {}
  for seg in (sub(path, 2) .. "/"):gmatch("([^/]*)/") do
    segs[#segs + 1] = seg
  end
  local out = {}
  for i, seg in ipairs(segs) do
    local last = i == #segs
    if seg == "." then
      if last then
        out[#out + 1] = ""
      end
    elseif seg == ".." then
      out[#out] = nil
      if last then
        out[#out + 1] = ""
      end
    else
      out[#out + 1] = seg
    end
  end
  return "/" .. table.concat(out, "/")
end

-- Splits "path?query#fragment". The query and the fragment are nil when the
-- text has no "?" or "#".
local function split_ref(s)
  local fragment
  local hash = find(s, "#", 1, true)
  if hash then
    fragment = sub(s, hash + 1)
    s = sub(s, 1, hash - 1)
  end
  local mark = find(s, "?", 1, true)
  if mark then
    return sub(s, 1, mark - 1), sub(s, mark + 1), fragment
  end
  return s, nil, fragment
end

-- Resolves a link of a local page. base is the absolute path of the page.
local function resolve_local(base, ref, scheme)
  if scheme == "file" then
    local rest = ref:match("^[^:]*:///(.*)$")
    if not rest then
      return nil, "html: invalid URL: " .. ref
    end
    ref = "/" .. rest
  elseif ref == "" or sub(ref, 1, 1) == "#" then
    return { kind = "same", fragment = select(3, split_ref(ref)) }
  end
  local path, _, fragment = split_ref(ref)
  path = path:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end)
  if path == "" then
    path = base
  elseif sub(path, 1, 1) ~= "/" then
    path = (base:match("^(.*/)") or "/") .. path
  end
  return { kind = "file", path = remove_dots(path), fragment = fragment }
end

-- Resolves a link against a base. base is an http(s) URL (a remote page) or
-- an absolute path (a local page). Returns one of
-- { kind = "http", url, fragment }, { kind = "file", path, fragment },
-- { kind = "same", fragment } and { kind = "unsupported", scheme },
-- or nil and a controlled message.
function M.resolve(base, ref)
  ref = ref:match("^%s*(.-)%s*$")
  local remote = M.scheme(base) ~= nil
  local scheme = M.ref_scheme(ref)
  if scheme == "file" and remote then
    return nil, "html: unsupported URL scheme: file"
  end
  if scheme == "file" or (not scheme and not remote) then
    return resolve_local(base, ref, scheme)
  end
  if scheme and scheme ~= "http" and scheme ~= "https" then
    return { kind = "unsupported", scheme = scheme }
  end
  ref = ref:gsub("[%z\1-\32\127-\255]", function(c)
    return string.format("%%%02X", byte(c))
  end)
  local target, fragment
  if scheme then
    local head, rest = ref:match("^(%a[%w+.-]*://[^/?#]*)(.*)$")
    if not head then
      return nil, "html: invalid URL: " .. ref
    end
    local path, query
    path, query, fragment = split_ref(rest)
    target = head .. remove_dots(path) .. (query and "?" .. query or "")
  else
    local u, why = M.parse_url(base)
    if not u then
      return nil, why
    end
    local path, query
    path, query, fragment = split_ref(ref)
    if path == "" and not query then
      return { kind = "same", fragment = fragment }
    end
    local tail = query and "?" .. query or ""
    local bpath = u.path:match("^[^?]*")
    if bpath == "" then
      bpath = "/"
    end
    if sub(path, 1, 2) == "//" then
      local auth = path:match("^//([^/]*)")
      target = u.scheme .. "://" .. auth
        .. remove_dots(sub(path, 3 + #auth)) .. tail
    elseif path == "" then
      target = u.origin .. bpath .. tail
    elseif sub(path, 1, 1) == "/" then
      target = u.origin .. remove_dots(path) .. tail
    else
      target = u.origin .. remove_dots(bpath:match("^(.*/)") .. path) .. tail
    end
  end
  local parsed, why = M.parse_url(target)
  if not parsed then
    return nil, why
  end
  return { kind = "http", url = parsed.url, fragment = fragment }
end

return M
]]
M.sizes["lib/html/viewer.lua"] = 31989
M.files["lib/html/viewer.lua"] = [=[
-- Full-screen viewer for laid-out lines (see lib/html/layout.lua).
-- Rows 1 to h-1 show lines. Row h is the status line.
-- All screen and input access goes through deps, so tests can fake it:
--   deps.gpu    a GPU component proxy
--   deps.pull   event.pull: pull(timeout) returns name, ... or nil
--   deps.term   a table with clear() and setCursor(x, y)
--   deps.on_key on_key(fn) calls fn(name, char, code) for each key_down and
--               key_up event and returns a function that stops it. A session
--               uses it during a load

local unicode = require("unicode")

local M = {}

local byte, find, sub, rep, format = string.byte, string.find, string.sub,
  string.rep, string.format
local wlen, wtrunc, usub = unicode.wlen, unicode.wtrunc, unicode.sub

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
-- The status line and the popup are black on white at every depth.
local BAR_FG, BAR_BG = BLACK, WHITE

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
-- Other standard codes. NumPad Left and Right need char 0 like the scroll
-- keys.
local CODE_LEFT, CODE_RIGHT, NUMPAD_LEFT, NUMPAD_RIGHT = 203, 205, 75, 77
local CODE_TAB, CODE_BACKSPACE, CODE_ESC = 15, 14, 1
local CODE_LSHIFT, CODE_RSHIFT = 42, 54
local CHAR_CTRL_C = 3
local CHAR_BACKSPACE, CHAR_TAB, CHAR_ESC = 8, 9, 27
local CHAR_ENTER = 13
local CODE_ENTER = 28
local CHAR_Q, CHAR_UPPER_Q = 113, 81
local CHAR_Y, CHAR_UPPER_Y = 121, 89
local CHAR_Z, CHAR_UPPER_Z = 122, 90
local CHAR_R, CHAR_UPPER_R, CHAR_G, CHAR_HELP = 114, 82, 103, 63

-- event.pull with a timeout, so the program yields while it waits.
local IDLE_TIMEOUT = 1
-- The most intents that wait for a poll.
local INTENT_MAX = 32

local HINT = "Tab:link Enter:open Bksp:back r:reload ?:keys q:quit"
local SHORT_HINT = "?:keys q:quit"
local TINY_HINT = "q:quit"
-- The full hint is used only when the title keeps this many columns.
local TITLE_MIN = 20
local PROMPT = " Quit? (y/n)"
local GO_PROMPT = " Go to: "
local GO_MAX = 2048
local POPUP_BUTTON = "[OK]"
local HELP_TEXT = table.concat({
  "Tab, Shift+Tab: next, previous link",
  "Enter: open the selected link",
  "Left, Backspace: back",
  "Right: forward",
  "r: reload",
  "g: go to a URL or a file",
  "Up, Down: move between links",
  "PgUp, PgDn, Home, End: scroll",
  "q: quit",
  "?: this list",
}, "\n")

-- Reverse video of a selected link: black on the link color. Depth 1 has
-- white.
local SELECT_BG = 0x6699FF

local SCROLL_KEYS = {
  up = true, down = true, pgup = true, pgdn = true, home = true,
  ["end"] = true,
}

-- Returns "interrupted", "quit", a scroll name ("up" ... "end"), "tab",
-- "shift_tab", "enter", "back", "forward", "backspace", "reload", "go",
-- "help", or nil for other events. shifted() tells whether Shift is down.
local function classify(name, char, code, shifted)
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
  if code == CODE_LEFT or (char == 0 and code == NUMPAD_LEFT) then
    return "back"
  end
  if code == CODE_RIGHT or (char == 0 and code == NUMPAD_RIGHT) then
    return "forward"
  end
  if code == CODE_TAB or char == CHAR_TAB then
    return shifted and shifted() and "shift_tab" or "tab"
  end
  if code == CODE_BACKSPACE or char == CHAR_BACKSPACE then
    return "backspace"
  end
  if code == CODE_ENTER or char == CHAR_ENTER then
    return "enter"
  end
  if char == CHAR_Q or char == CHAR_UPPER_Q then
    return "quit"
  end
  if char == CHAR_R or char == CHAR_UPPER_R then
    return "reload"
  end
  if char == CHAR_G then
    return "go"
  end
  if char == CHAR_HELP then
    return "help"
  end
  return nil
end

local function is_enter(char, code)
  return char == CHAR_ENTER or code == CODE_ENTER
end

-- Cuts a line to the cell columns a to b. Style bytes do not count. A wide
-- character is kept whole when one of its cells is inside. Returns the text
-- and the column of its first cell, or "" and nil.
local CHAR_PATTERN = "[\0\6-\x7F\xC2-\xFD][\x80-\xBF]*"
local function cut(line, a, b)
  local col, first = 1, nil
  local parts = {}
  for ch in line:gmatch(CHAR_PATTERN) do
    local next_col = col + unicode.charWidth(ch)
    if next_col - 1 >= a and col <= b then
      first = first or col
      parts[#parts + 1] = ch
    end
    col = next_col
    if col > b then
      break
    end
  end
  return table.concat(parts), first
end
M._cut = cut

-- Unpacks a link span (spec/layout.md "Links and anchors").
local function unpack_span(s)
  return s >> 32, (s >> 24) & 0xFF, (s >> 32) + ((s >> 8) & 0xFFFF), s & 0xFF
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

-- Splits text at newlines and wraps each part to at most width columns.
-- A line breaks at its last space that fits, else inside the word. Control
-- bytes show as spaces.
local function wrap(text, width)
  local out = {}
  for part in (text .. "\n"):gmatch("([^\n]*)\n") do
    part = part:gsub("%c", " ")
    while wlen(part) > width do
      local head = fit(part, width)
      local trimmed = head:match("^(.*[^ ]) ")
      if trimmed then
        head = trimmed
      elseif head == "" then
        head = usub(part, 1, 1)
      end
      out[#out + 1] = head
      part = sub(part, #head + 1):gsub("^ +", "")
    end
    out[#out + 1] = part
  end
  return out
end

-- Drawing shared by the page view and the popup: the cached colors, the
-- status row and the popup box. The loading screen draws with it too.
local function new_screen(gpu, w, h)
  local s = {}

  -- The colors are unknown at start, so the first set always happens.
  local cur_fg, cur_bg
  function s.fg(c)
    if c ~= cur_fg then
      gpu.setForeground(c)
      cur_fg = c
    end
  end
  function s.bg(c)
    if c ~= cur_bg then
      gpu.setBackground(c)
      cur_bg = c
    end
  end

  -- Fills row h with text in the status colors.
  function s.status(text)
    s.fg(BAR_FG)
    s.bg(BAR_BG)
    text = fit(text, w)
    gpu.set(1, h, text .. rep(" ", w - wlen(text)))
  end

  -- Draws text in a box centred over rows 1 to h-1, one column of padding
  -- on each side and one row above and below. Returns the first and last
  -- row it covers.
  function s.popup(text)
    local rows = h - 1
    local inner = math.max(1, w - 4)
    local list = wrap(text, inner)
    local width = 0
    for i = 1, #list do
      width = math.max(width, wlen(list[i]))
    end
    while #list > math.max(1, rows - 2) do
      list[#list] = nil
    end
    local bw = math.min(w, width + 2)
    local bh = math.min(rows, #list + 2)
    local x0 = (w - bw) // 2 + 1
    local y0 = (rows - bh) // 2 + 1
    s.fg(BAR_FG)
    s.bg(BAR_BG)
    gpu.fill(x0, y0, bw, bh, " ")
    for i = 1, #list do
      local y = y0 + i
      if y < y0 + bh then
        gpu.set(x0 + 1, y, fit(list[i], bw - 2))
      end
    end
    return y0, y0 + bh - 1
  end

  return s
end

-- Draws one line on row y: style pieces, then blanks to the right edge.
local function draw_line(gpu, screen, color, w, line, y)
  screen.bg(BLACK)
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
      screen.fg(color[style])
      gpu.set(x, y, text)
      x = x + wlen(text)
      pos = last + 1
    end
  end
  if x <= w then
    gpu.fill(x, y, w - x + 1, 1, " ")
  end
end

-- base: w, h, color and screen of the session (see M.open). start_prompt is
-- true when the quit prompt is still on screen from the load.
-- opts: title, file, error, links, resolve, top, sel (see M.run).
-- Returns "quit", "interrupted" or an action table (see M.run).
local function view(lines, opts, gpu, pull, base, start_prompt)
  local w, h = base.w, base.h
  local rows = h - 1
  local count = #lines
  local max_top = math.max(1, count - rows + 1)
  -- One page is h-2 lines, the largest scroll that still uses copy.
  local page = math.max(1, rows - 1)
  local top = 1

  local color = base.color
  local screen = base.screen

  local title = opts.title or opts.file or ""
  title = title:gsub("%c", " ")
  -- The status keeps an "[HTTP ...]" prefix before a link target.
  local http_prefix = title:match("^(%[HTTP [^%]]*%])")

  -- Links: the start and end of each span, and the list of the links that
  -- start inside the page, in order. A span that starts past the last line
  -- is ignored.
  local links = opts.links
  local from_line, from_col, to_line, to_col = {}, {}, {}, {}
  local valid, pos = {}, {}
  if links and links.span then
    for i = 1, links.count or #links.span do
      local span = links.span[i]
      if span then
        local fl, fc, tl, tc = unpack_span(span)
        from_line[i], from_col[i], to_line[i], to_col[i] = fl, fc, tl, tc
        if fl >= 1 and fl <= count then
          valid[#valid + 1] = i
          pos[i] = #valid
        end
      end
    end
  end

  -- The selected link index, or nil.
  local sel
  local notice
  local notice_dirty = false
  -- A later input field sets this. Backspace then deletes, not Back.
  local input_focus = false

  local function clamp_top(n)
    return math.max(1, math.min(max_top, n))
  end

  top = clamp_top(math.floor(tonumber(opts.top) or 1))
  if opts.sel and #valid > 0 then
    local n = math.max(1, math.min(links.count or #links.span,
      math.floor(tonumber(opts.sel) or 1)))
    while n >= 1 and not pos[n] do
      n = n - 1
    end
    if n >= 1 then
      sel = n
    else
      sel = valid[1]
    end
  end

  local function visible(t, i)
    return from_line[i] >= t and from_line[i] <= t + rows - 1
  end

  -- Draws the selected part of line n on row y, in reverse video.
  local function draw_selection(n, y)
    local line = lines[n]
    if not line then
      return
    end
    local a = n == from_line[sel] and from_col[sel] or 1
    local b = n == to_line[sel] and to_col[sel] or math.maxinteger
    local text, col = cut(line, a, b)
    if not col then
      return
    end
    if n ~= from_line[sel] then
      local lead = #text:match("^ *")
      text, col = text:sub(lead + 1), col + lead
    end
    if n ~= to_line[sel] then
      text = text:gsub(" +$", "")
    end
    if text == "" or col > w then
      return
    end
    screen.fg(BLACK)
    screen.bg(base.select_bg)
    gpu.set(col, y, fit(text, w - col + 1))
  end

  local function draw_row(y)
    local n = top + y - 1
    draw_line(gpu, screen, color, w, lines[n] or "", y)
    if sel and n >= from_line[sel] and n <= to_line[sel] then
      draw_selection(n, y)
    end
  end

  local function draw_rows(from, to)
    for y = from, to do
      draw_row(y)
    end
  end

  -- The label of the selected link: the resolved text, else the raw href.
  local label_for, label
  local function sel_label()
    if label_for ~= sel then
      label_for = sel
      local href = links.href and links.href[sel]
      if not href then
        label = "(link too long)"
      else
        label = opts.resolve and opts.resolve(href) or href
      end
      label = tostring(label):gsub("%c", " ")
    end
    return label
  end

  local function draw_status()
    local pct = 100
    if max_top > 1 then
      pct = (top - 1) * 100 // (max_top - 1)
    end
    local right = format(" %3d%%  %s ", pct, HINT)
    if w - 1 - #right < TITLE_MIN then
      right = format(" %3d%%  %s ", pct, SHORT_HINT)
      if w - 1 - #right < TITLE_MIN then
        right = format(" %3d%%  %s ", pct, TINY_HINT)
      end
    end
    if notice then
      -- A notice takes the whole row, with no percent and no hint.
      screen.status(" " .. notice)
      return
    end
    local text = title
    if sel and visible(top, sel) then
      text = (http_prefix and http_prefix .. " " or "") .. "-> " .. sel_label()
    end
    local left = " " .. fit(text, w - 1 - #right)
    screen.status(left .. rep(" ", w - #right - wlen(left)) .. right)
  end

  local function set_notice(text)
    notice = text
    draw_status()
  end

  -- Takes the next event. A key clears a notice, and the loop redraws the
  -- status once.
  local function pull_ev(timeout)
    local name, a, b, c = pull(timeout)
    base.track(name, b, c)
    if name == "key_down" and notice then
      notice = nil
      notice_dirty = true
    end
    return name, a, b, c
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
    return clamp_top(target)
  end

  -- One Tab (dir 1) or Shift+Tab (dir -1) from the state t (top), s (sel).
  -- Returns the new top and selection.
  local function step(t, s, dir)
    local pick
    if s and visible(t, s) then
      -- The order wraps: after the last entry comes the first.
      pick = valid[(pos[s] - 1 + dir) % #valid + 1]
    elseif dir > 0 then
      for _, i in ipairs(valid) do
        if from_line[i] >= t then
          pick = i
          break
        end
      end
      -- No link at or below the top: wrap to the first link.
      pick = pick or valid[1]
    else
      for k = #valid, 1, -1 do
        if from_line[valid[k]] <= t + rows - 1 then
          pick = valid[k]
          break
        end
      end
      -- No link at or above the bottom: wrap to the last link.
      pick = pick or valid[#valid]
    end
    if not pick then
      return t, s
    end
    if from_line[pick] < t then
      t = from_line[pick]
    elseif from_line[pick] > t + rows - 1 then
      t = from_line[pick] - rows + 1
    end
    return clamp_top(t), pick
  end

  -- One Down (dir 1) or Up (dir -1) from the state t (top), s (sel). It
  -- selects the next (previous) link in document order when its start line
  -- is on screen, also on the same line as the selection. With no visible
  -- selection, Down starts at the top and Up at the bottom of the screen.
  -- With no such link on screen it scrolls one page and selects the first
  -- (last for Up) link that starts in the new rows. At the end of the page
  -- it does nothing. Returns the new top and selection.
  local function link_move(t, s, dir)
    local bottom = t + rows - 1
    local pick
    if s and visible(t, s) then
      local n = valid[pos[s] + dir]
      if n and visible(t, n) then
        pick = n
      end
    else
      for _, i in ipairs(valid) do
        if visible(t, i) then
          pick = i
          if dir > 0 then
            break
          end
        end
      end
    end
    if pick then
      return t, pick
    end
    local nt = clamp_top(t + dir * page)
    if nt == t then
      return t, s
    end
    -- The rows that the scroll shows.
    local lo, hi = nt, nt + rows - 1
    if dir > 0 then
      lo = bottom + 1
    else
      hi = t - 1
    end
    for _, i in ipairs(valid) do
      local n = from_line[i]
      if n >= lo and n <= hi then
        pick = i
        if dir > 0 then
          break
        end
      end
    end
    return nt, pick or s
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
  end

  -- Moves to a new top and selection. The rows of the old and of the new
  -- selection are drawn again.
  local function apply(target, new_sel)
    local old_sel, old_top = sel, top
    sel = new_sel
    scroll_to(target)
    if sel ~= old_sel then
      local done = {}
      for _, i in ipairs({ old_sel or 0, sel or 0 }) do
        if from_line[i] then
          local first = math.max(from_line[i], top)
          local last = math.min(to_line[i], top + rows - 1)
          for n = first, last do
            if not done[n] then
              done[n] = true
              draw_row(n - top + 1)
            end
          end
        end
      end
    end
    if top ~= old_top or sel ~= old_sel then
      draw_status()
    end
  end

  -- The action table for the session loop.
  local function act(kind, extra)
    local a = extra or {}
    a.kind, a.top, a.sel = kind, top, sel
    return a
  end

  -- Returns "quit", "interrupted", or nil when the user cancels.
  local function confirm_quit()
    screen.status(PROMPT)
    while true do
      local name, _, char, code = pull_ev(IDLE_TIMEOUT)
      if name == "interrupted" then
        return "interrupted"
      end
      if name == "key_down" then
        if char == CHAR_CTRL_C then
          return "interrupted"
        end
        if char == CHAR_Y or char == CHAR_UPPER_Y or is_enter(char, code) then
          return "quit"
        end
        draw_status()
        return nil
      end
    end
  end

  -- Shows the popup until Enter. Other keys are ignored. Returns
  -- "interrupted" on Ctrl+C, else nil. Enter closes it, so a held Enter must
  -- not act until its key_up.
  local function show_popup(text)
    local first, last = screen.popup(text .. "\n\n" .. POPUP_BUTTON)
    while true do
      local name, _, char, code = pull_ev(IDLE_TIMEOUT)
      if name == "interrupted" then
        return "interrupted"
      end
      if name == "key_down" then
        if char == CHAR_CTRL_C then
          return "interrupted"
        end
        if is_enter(char, code) then
          base.enter_held = true
          draw_rows(first, last)
          return nil
        end
      end
    end
  end

  -- The go prompt on the status row. Returns "interrupted", the typed text,
  -- or nil when the user cancels.
  local function go_prompt()
    local text = ""
    local function draw()
      local avail = math.max(0, w - #GO_PROMPT - 1)
      local shown = text
      if #shown > avail then
        shown = avail > 0 and sub(shown, -avail) or ""
      end
      screen.status(GO_PROMPT .. shown)
      local x = #GO_PROMPT + #shown + 1
      if x <= w then
        -- The input cursor is a reverse-video cell.
        screen.fg(BAR_BG)
        screen.bg(BAR_FG)
        gpu.set(x, h, " ")
      end
    end
    draw()
    while true do
      local name, _, b, c = pull_ev(IDLE_TIMEOUT)
      if name == "interrupted" then
        return "interrupted"
      elseif name == "clipboard" and type(b) == "string" then
        local clip = b:match("^%s*([^\r\n]*)"):gsub("[^\32-\126]", "")
        text = sub(text .. clip:gsub("%s+$", ""), 1, GO_MAX)
        draw()
      elseif name == "key_down" then
        local char, code = b, c
        if char == CHAR_CTRL_C then
          return "interrupted"
        elseif is_enter(char, code) then
          base.enter_held = true
          draw_status()
          if text == "" then
            return nil
          end
          return text
        elseif code == CODE_ESC or char == CHAR_ESC then
          draw_status()
          return nil
        elseif char == CHAR_BACKSPACE or code == CODE_BACKSPACE then
          text = sub(text, 1, -2)
          draw()
        elseif char >= 0x20 and char <= 0x7E and #text < GO_MAX then
          text = text .. string.char(char)
          draw()
        end
      end
    end
  end

  draw_rows(1, rows)
  draw_status()
  if opts.error and show_popup(opts.error) then
    return "interrupted"
  end
  if start_prompt then
    local result = confirm_quit()
    if result then
      return result
    end
  end

  local pending
  while true do
    local action
    if pending then
      action, pending = pending, nil
    else
      local name, _, char, code = pull_ev(IDLE_TIMEOUT)
      action = classify(name, char, code, base.shifted)
    end
    if action == "backspace" then
      if input_focus then
        -- Input fields (later) delete a character here.
        action = nil
      else
        action = "back"
      end
    end
    if action == "interrupted" then
      return "interrupted"
    elseif action == "quit" then
      local result = confirm_quit()
      if result then
        return result
      end
    elseif SCROLL_KEYS[action] or action == "tab" or action == "shift_tab" then
      -- Takes all queued events, so a burst of key repeat gives one redraw.
      -- Tab and Shift+Tab are moves too.
      local target, target_sel = top, sel
      local function take(a)
        if a == "up" or a == "down" then
          target, target_sel = link_move(target, target_sel,
            a == "down" and 1 or -1)
        elseif SCROLL_KEYS[a] then
          target = move(target, a)
        else
          target, target_sel = step(target, target_sel,
            a == "tab" and 1 or -1)
        end
      end
      take(action)
      while true do
        local name, _, char, code = pull_ev(0)
        if name == nil then
          break
        end
        local next_action = classify(name, char, code, base.shifted)
        if SCROLL_KEYS[next_action] or next_action == "tab"
            or next_action == "shift_tab" then
          take(next_action)
        elseif next_action then
          pending = next_action
          break
        end
      end
      apply(target, target_sel)
    elseif action == "enter" then
      if not base.enter_held and sel and visible(top, sel) then
        local href = links.href and links.href[sel]
        if not href then
          set_notice("link too long")
        elseif opts.resolve then
          local text, why = opts.resolve(href)
          if text then
            return act("link", { href = href, text = text })
          end
          set_notice(why or "link not supported")
        else
          return act("link", { href = href })
        end
      end
    elseif action == "back" or action == "forward" or action == "reload" then
      return act(action)
    elseif action == "go" then
      local text = go_prompt()
      if text == "interrupted" then
        return "interrupted"
      elseif text then
        return act("go", { text = text })
      end
    elseif action == "help" then
      if show_popup(HELP_TEXT) then
        return "interrupted"
      end
    end
    if notice_dirty then
      notice_dirty = false
      draw_status()
    end
  end
end

-- Opens a screen session: saves the GPU state, sets the resolution (unless
-- opts.no_rescale) and reads the size. With opts.status it also clears the
-- screen and draws that text on the status row. Returns a session:
--   rows                     the number of line rows (the height minus 1)
--   status(text)             redraws the status row only
--   draw_lines(lines, count) draws the first screen from lines, which can
--                            still grow. It reads lines[1] to lines[rows].
--                            With count 0 it blanks the line rows
--   listen()                 starts the key listener (deps.on_key) and drops
--                            the old intents. A load calls it at its start
--   unlisten()               stops the listener. close calls it too
--   poll()                   takes the intents of the listener without
--                            waiting and never reads events. Returns
--                            "interrupted" (Ctrl+C), "quit" (the user
--                            confirmed the quit prompt), "abort" (z, Z,
--                            Backspace or Left) or nil. "q" shows the quit
--                            prompt and the status row keeps it until the
--                            user answers. Other keys are dropped
--   show(lines, opts)        the interactive loop (see M.run). A quit prompt
--                            still on screen is answered first
--   close()                  restores the screen. A second call does nothing
-- An error inside open restores the screen and is raised again.
function M.open(deps, opts)
  opts = opts or {}
  local gpu, term, pull = deps.gpu, deps.term, deps.pull
  local old_w, old_h = gpu.getResolution()
  local old_fg, old_fg_palette = gpu.getForeground()
  local old_bg, old_bg_palette = gpu.getBackground()
  local rescaled, closed = false, false

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

  local base, s
  local prompt, text = false, ""
  local ok, err = pcall(function()
    if not opts.no_rescale then
      local max_w, max_h = gpu.maxResolution()
      if max_w ~= old_w or max_h ~= old_h then
        rescaled = true
        gpu.setResolution(max_w, max_h)
      end
    end
    local w, h = gpu.getResolution()
    local depth = gpu.getDepth()
    base = { w = w, h = h, screen = new_screen(gpu, w, h),
      color = depth > 1 and COLORS or PLAIN }
    base.select_bg = depth > 1 and SELECT_BG or WHITE
    -- Shift comes from deps.shift_down. Without it the viewer tracks the
    -- Shift keys. enter_held is true from an Enter that closed a popup or a
    -- prompt until the key_up of Enter.
    base.shift_down = deps.shift_down
    base.enter_held = false
    local shift_l, shift_r = false, false
    function base.track(name, _, code)
      if name == "key_down" then
        if code == CODE_LSHIFT then
          shift_l = true
        elseif code == CODE_RSHIFT then
          shift_r = true
        end
      elseif name == "key_up" then
        if code == CODE_LSHIFT then
          shift_l = false
        elseif code == CODE_RSHIFT then
          shift_r = false
        elseif code == CODE_ENTER then
          base.enter_held = false
        end
      end
    end
    function base.shifted()
      if base.shift_down then
        return base.shift_down() and true or false
      end
      return shift_l or shift_r
    end
    s = { rows = h - 1 }

    function s.status(t)
      text = t
      if not prompt then
        base.screen.status(t)
      end
    end

    if opts.status then
      base.screen.fg(WHITE)
      base.screen.bg(BLACK)
      gpu.fill(1, 1, w, h, " ")
      s.status(opts.status)
    end
  end)
  if not ok then
    pcall(restore)
    error(err, 0)
  end

  function s.draw_lines(lines, count)
    for y = 1, s.rows do
      draw_line(gpu, base.screen, base.color, base.w,
        y <= count and lines[y] or "", y)
    end
  end

  -- The key listener of a load (see listen). It turns each key into an
  -- intent: "interrupted" (Ctrl+C), "abort" (z, Backspace, Left), "quit" (q),
  -- "yes" (y or Enter) or "other". Repeats of "other" in a row count once.
  local on_key, remove_key = deps.on_key, nil
  local intents = {}

  local function intent_of(char, code)
    if char == CHAR_CTRL_C then
      return "interrupted"
    end
    if char == CHAR_Z or char == CHAR_UPPER_Z or code == CODE_BACKSPACE
        or char == CHAR_BACKSPACE or code == CODE_LEFT
        or (char == 0 and code == NUMPAD_LEFT) then
      return "abort"
    end
    if char == CHAR_Q or char == CHAR_UPPER_Q then
      return "quit"
    end
    if char == CHAR_Y or char == CHAR_UPPER_Y or is_enter(char, code) then
      return "yes"
    end
    return "other"
  end

  local function on_event(name, char, code)
    base.track(name, char, code)
    if name ~= "key_down" then
      return
    end
    local intent = intent_of(char, code)
    local n = #intents
    if n < INTENT_MAX and not (intent == "other" and intents[n] == intent) then
      intents[n + 1] = intent
    end
  end

  -- Starts the key listener and drops the old intents. A second call restarts
  -- it. Without deps.on_key nothing listens.
  function s.listen()
    s.unlisten()
    if on_key then
      remove_key = on_key(on_event)
    end
  end

  -- Stops the listener and drops the intents. A second call does nothing.
  function s.unlisten()
    local remove = remove_key
    remove_key = nil
    intents = {}
    if remove then
      remove()
    end
  end

  function s.poll()
    while #intents > 0 do
      local intent = table.remove(intents, 1)
      if intent == "interrupted" then
        return "interrupted"
      end
      if prompt then
        if intent == "yes" then
          return "quit"
        end
        prompt = false
        base.screen.status(text)
      elseif intent == "quit" then
        prompt = true
        base.screen.status(PROMPT)
      elseif intent == "abort" then
        return "abort"
      end
    end
    return nil
  end

  function s.show(lines, o)
    return view(lines, o or {}, gpu, pull, base, prompt)
  end

  function s.close()
    if not closed then
      closed = true
      pcall(s.unlisten)
      restore()
    end
  end

  return s
end

-- Shows lines until the user quits or asks for a navigation. Returns "quit",
-- "interrupted" or an action table:
--   { kind = "link", href = <raw href>, text = <resolved text or nil> }
--   { kind = "back" } { kind = "forward" } { kind = "reload" }
--   { kind = "go", text = <typed text> }
-- Every action table has top (the first shown line) and sel (the selected
-- link index or nil), for the history.
-- opts: title, file (shown when there is no title), no_rescale, error, and
--   links   { span = {...}, href = {...}, count = n } from the layout
--   resolve resolve(href) returns the text for the status line, or nil and
--           a notice that the status line shows until the next key
--   top, sel  the position to restore. Both are clamped
-- opts.error is a text shown in a popup over the first screen. Only Enter
-- closes it, then the user browses as usual.
-- deps.shift_down (optional) tells whether Shift is down.
-- An error inside restores the screen and is raised again.
function M.run(lines, opts, deps)
  opts = opts or {}
  local session = M.open(deps, { no_rescale = opts.no_rescale })
  local ok, result = pcall(session.show, lines, opts)
  local restored, restore_err = pcall(session.close)
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
  local ok, keyboard = pcall(require, "keyboard")
  return { gpu = component.gpu, pull = event.pull, term = term,
    shift_down = ok and keyboard.isShiftDown or nil }
end

return M
]=]

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
