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

  -- Ctrl+C or a confirmed quit during load: the flags are set by the
  -- listener or by the screen poll, and the next guard.tick raises
  -- INTERRUPTED. A confirmed quit exits with code 0 and no message.
  -- z (abort) stops the load in the same way (spec/navigation.md "Abort").
  local interrupted, quit_requested, remove = false, false, nil
  local abort_requested, committed = false, false
  if deps.on_interrupt then
    remove = deps.on_interrupt(function() interrupted = true end)
  end
  local function stop_flag()
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
  -- byte count at most once per LOAD_TICK. The same tick polls the keys.
  local session = ctx.session
  local name, total, bytes = arg, nil, 0
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
  local function poll_keys()
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
    local t = now()
    if t - last_tick < LOAD_TICK then
      return
    end
    last_tick = t
    poll_keys()
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

  -- Returns the source for run: the file, or the response of url.
  local function open_source()
    if not url then
      name, total = arg, file_size(f, path, deps)
      return {
        read = function()
          local chunk, why = f:read(CHUNK)
          -- A plain nil is the end of the input. A nil with a message is an
          -- error.
          if chunk == nil and why then
            kept_error = "html: read error: " .. reason(why)
            offer_reload = true
            error(kept_error, 0)
          end
          if chunk then
            bytes = bytes + #chunk
          end
          return chunk
        end,
        size = total, kind = "file", name = arg,
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
      arm_guard()
    elseif framed then
      session = deps.open_screen({ no_rescale = opts.no_rescale,
        status = "Loading " .. name .. "..." })
      ctx.session = session
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
    -- A key that came while the response opened still counts for phase 1.
    -- The poll has no LOAD_TICK gate.
    if session then
      poll_keys()
    end
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
    location = resp and resp.final_url or path, show = shown_info }
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
    local res = load_page(spec, ctx)
    ctx.on_commit = nil
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
--   view(lines, opts)      optional, runs the viewer (see viewer.run).
--                          Returns "quit", "interrupted" or an action table
--   on_interrupt(fn)       optional, calls fn on Ctrl+C. Returns a function
--                          that removes the listener
--   internet               optional, the internet card proxy (for a URL)
--   sleep(seconds)         optional, os.sleep. The fetch waits with it
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
    page = run_session(target, ctx)
  end
  -- The screen is restored before any error line prints.
  local restored, restore_err = true, nil
  if ctx.session then
    restored, restore_err = pcall(ctx.session.close)
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
    open_screen = function(opts)
      local viewer = need("html.viewer")
      return viewer.open({ gpu = gpu, pull = event.pull, term = term }, opts)
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
