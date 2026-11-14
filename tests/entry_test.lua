-- Tests for the entry point in bin/html.lua: modes, the output width, file
-- checks, URL errors, error status, Ctrl+C and unexpected errors. Each table
-- row is one scenario. spec/cli.md, spec/errors.md and spec/fetch.md give
-- the expected values.

local t = require("test")

local T = {}

local html = t.load_bin("html")({})
local guard = require("html.guard")
local internet = require("internet")
local computer = require("computer")

local PAGE = "<html><head><title>My Page</title></head><body>"
  .. "<h1>Head</h1><p>Some text in a paragraph.</p></body></html>"

-- A page with many tokens, so the guard ticks after the second read.
local LONG = string.rep("<p>word word word word word</p>\n", 1000)

local URL = "http://example.com/"

local function no() return false end
local function yes() return true end

-- A fake file over text. state counts the reads and records the close.
-- on_read(n) is called before the nth read.
local function fake_file(text, on_read)
  local state = { reads = 0, closed = false }
  local pos = 1
  local f = {}
  function f.read(_, n)
    state.reads = state.reads + 1
    if on_read then
      on_read(state.reads)
    end
    if pos > #text then
      return nil
    end
    local chunk = text:sub(pos, pos + n - 1)
    pos = pos + n
    return chunk
  end
  function f.seek(_, whence, offset)
    if whence == "end" then
      return #text
    end
    pos = (offset or 0) + 1
    return pos - 1
  end
  function f.close()
    state.closed = true
    return true
  end
  return f, state
end

-- A fake GPU with a screen. max and cur are { w, h }.
local function fake_gpu(max, cur, screen)
  return {
    getScreen = function() return screen end,
    maxResolution = function() return max[1], max[2] end,
    getResolution = function() return cur[1], cur[2] end,
  }
end

-- The record of the run in progress, so the hooks in a row reach the
-- listener and the output counters.
local last

-- Runs main with a fake file and fake viewer deps. extra replaces deps.
-- Returns the exit code and a record: out, err, events (in order), views
-- (the lines and opts of each viewer call), the file state and the
-- listener counts.
local function run(args, text, extra)
  local rec = { out = {}, err = {}, events = {}, views = {}, listens = 0,
    removes = 0 }
  last = rec
  local file, state = fake_file(text or PAGE, extra and extra.on_read)
  rec.file = state
  local deps = {
    out = function(line)
      rec.out[#rec.out + 1] = line
      rec.events[#rec.events + 1] = "out"
    end,
    err = function(line)
      rec.err[#rec.err + 1] = line
      rec.events[#rec.events + 1] = "err"
    end,
    width = 50,
    open = function() return file end,
    traceback = function(msg) return msg .. "\nstack traceback: (fake)" end,
    clock = os.clock,
    gpu = fake_gpu({ 60, 20 }, { 40, 10 }, "screen"),
    view = function(lines, opts)
      rec.views[#rec.views + 1] = { lines = lines, opts = opts }
      rec.events[#rec.events + 1] = "view"
      return "quit"
    end,
    on_interrupt = function(fn)
      rec.listens = rec.listens + 1
      rec.interrupt = fn
      return function() rec.removes = rec.removes + 1 end
    end,
  }
  for k, v in pairs(extra or {}) do
    if k ~= "on_read" then
      deps[k] = v
    end
  end
  args.n = #args
  local code = html.main(args, deps)
  return code, rec
end

-- Runs main with a fake card. card_opts go to internet.new. extra replaces
-- deps. rec.ctl is the card controller.
local function run_url(args, card_opts, extra)
  local card, ctl = internet.new(card_opts)
  extra = extra or {}
  local deps = { internet = card, uptime = computer.uptime, sleep = os.sleep }
  for k, v in pairs(extra) do
    deps[k] = v
  end
  local code, rec = run(args, nil, deps)
  rec.ctl = ctl
  return code, rec
end

local function page_script(body, extra)
  local s = { headers = { ["Content-Type"] = { "text/html" } },
    body = internet.pieces(body or PAGE, 10, true) }
  for k, v in pairs(extra or {}) do
    s[k] = v
  end
  return s
end

local function max_width(lines)
  local wlen = require("unicode").wlen
  local w = 0
  for _, line in ipairs(lines) do
    w = math.max(w, wlen((line:gsub("[\1-\5]", ""))))
  end
  return w
end

-- True when the listener is gone, the guard has no interrupt check and
-- every file and card handle is closed.
local function is_clean(rec)
  if rec.removes ~= rec.listens then
    return false
  end
  if not pcall(guard.tick) then
    return false
  end
  if not (rec.file.closed or rec.file.reads == 0) then
    return false
  end
  for _, h in ipairs(rec.ctl and rec.ctl.handles or {}) do
    if h.closed ~= 1 then
      return false
    end
  end
  return true
end

-- Removes the file position the Lua error adds to a message.
local function without_position(line)
  return (line:gsub("[%w_/%.]+%.lua:%d+: ", ""))
end

-- Runs one scenario and returns what it did. input fields: args, text (the
-- page), card (card options, makes it a URL run), deps (extra deps), gpu.
local function scenario(input)
  local extra = {}
  for k, v in pairs(input.deps or {}) do
    extra[k] = v
  end
  if input.gpu ~= nil then
    extra.gpu = input.gpu
  end
  local code, rec
  if input.card then
    code, rec = run_url(input.args, input.card, extra)
  else
    code, rec = run(input.args, input.text, extra)
  end
  local view = rec.views[1]
  local lines = view and view.lines or rec.out
  local err = {}
  for i, line in ipairs(rec.err) do
    err[i] = without_position(line)
  end
  local reads = rec.file.reads
  if rec.ctl and rec.ctl.handles[1] then
    reads = rec.ctl.handles[1].reads
  end
  return {
    code = code,
    err = err,
    out = #rec.out,
    views = #rec.views,
    mode = view and "viewer" or (#rec.out > 0 and "print" or "none"),
    width = max_width(lines),
    lines = #lines,
    title = view and (view.opts.title or false),
    file = view and (view.opts.file or false),
    no_rescale = view and (view.opts.no_rescale or false),
    error_opt = view and (view.opts.error or false),
    events = rec.events,
    reads = reads,
    listens = rec.listens,
    removes = rec.removes,
    outs = rec.outs,
    logged = rec.logged and (rec.logged:find("stack traceback", 1, true)
      and "traceback" or rec.logged) or false,
    removed_at_view = rec.removed_at_view,
    requests = rec.ctl and #rec.ctl.requests,
    clean = is_clean(rec),
  }
end

-- Registers T[name], a table test over scenario rows. Each row compares only
-- the fields that its expected table names.
local function scenarios(name, rows)
  for _, row in ipairs(rows) do
    local keys = {}
    for k in pairs(row[3]) do
      keys[#keys + 1] = k
    end
    row[2].keys = keys
  end
  t.cases(T, name, rows, function(input)
    local obs, out = scenario(input), {}
    for _, k in ipairs(input.keys) do
      out[k] = obs[k]
    end
    return out
  end)
end

-- The default viewer and print modes -----------------------------------------

function T.default_mode_opens_the_viewer_with_the_title()
  local code, rec = run({ "page.html" })
  t.eq(code, 0)
  t.eq(rec.out, {})
  t.eq(rec.err, {})
  t.eq(#rec.views, 1)
  local v = rec.views[1]
  t.eq(v.opts.title, "My Page")
  t.eq(v.opts.file, "page.html")
  t.eq(v.opts.no_rescale, nil)
  t.eq(v.opts.error, nil)
  t.ok(#v.lines > 0)
  t.ok(v.lines[1]:find("[\1-\5]"), "style bytes kept")
  t.ok(rec.file.closed, "file closed before the viewer")
  t.ok(is_clean(rec))
end

function T.print_writes_plain_text_without_the_viewer()
  local code, rec = run({ "--print", "page.html" })
  t.eq(code, 0)
  t.eq(#rec.views, 0)
  t.eq(rec.err, {})
  t.ok(#rec.out > 0)
  for _, line in ipairs(rec.out) do
    t.ok(not line:find("[\1-\5]"), "no style bytes")
  end
  t.ok(is_clean(rec))
end

function T.url_opens_the_viewer()
  local code, rec = run_url({ URL }, { default = page_script() })
  t.eq(code, 0)
  t.eq(rec.err, {})
  t.eq(#rec.views, 1)
  t.eq(rec.views[1].opts.title, "My Page")
  t.eq(rec.views[1].opts.file, URL)
  t.eq(rec.ctl.requests, { URL })
  t.ok(is_clean(rec))
end

-- Width and mode (spec/cli.md "Output width", "Local files") ------------------
-- The gpu of run() has the maximum 60 and the current resolution 40. The
-- terminal width is 50. The widest line is the width minus 1.

-- One long word, so the widest line is the layout width.
local WORDS = string.rep("x", 500)
local NO_GPU_LINE = "html: no screen found, printing the text"
local WIDTH_ERROR = " (see html --help)"
local E60 = "html: --width needs a whole number from 2 to 60" .. WIDTH_ERROR
local E160 = "html: --width needs a whole number from 2 to 160" .. WIDTH_ERROR

scenarios("width_and_mode", {
  { "viewer: the maximum resolution",
    { args = { "page.html" }, text = WORDS },
    { code = 0, mode = "viewer", width = 59, no_rescale = false, err = {} } },
  { "viewer with --no-rescale: the current resolution",
    { args = { "--no-rescale", "page.html" }, text = WORDS },
    { code = 0, mode = "viewer", width = 39, no_rescale = true, err = {} } },
  { "--print: the terminal width",
    { args = { "--print", "page.html" }, text = WORDS },
    { code = 0, mode = "print", width = 49, err = {} } },
  { "--width turns on --print",
    { args = { "--width", "20", "page.html" }, text = WORDS },
    { code = 0, mode = "print", width = 19, err = {} } },
  { "--width at the maximum",
    { args = { "--width", "60", "page.html" }, text = WORDS },
    { code = 0, mode = "print", width = 59, err = {} } },
  { "--width 2 gives lines of 1 column",
    { args = { "--width", "2", "page.html" }, text = WORDS },
    { code = 0, mode = "print", width = 1, err = {} } },
  { "--width 1 is a usage error",
    { args = { "--width", "1", "page.html" }, text = WORDS },
    { code = 2, mode = "none", width = 0, err = { E60 } } },
  { "--width 0 is a usage error",
    { args = { "--width", "0", "page.html" }, text = WORDS },
    { code = 2, mode = "none", width = 0, err = { E60 } } },
  { "--width above the maximum",
    { args = { "--width", "61", "page.html" }, text = WORDS },
    { code = 2, mode = "none", width = 0, err = { E60 } } },
  { "--width far above the maximum",
    { args = { "--width", "9223372036854775807", "page.html" }, text = WORDS },
    { code = 2, mode = "none", width = 0, err = { E60 } } },
  { "no GPU: print mode and one line",
    { args = { "page.html" }, text = WORDS, gpu = false },
    { code = 0, mode = "print", width = 49, err = { NO_GPU_LINE } } },
  { "no screen on the GPU: print mode and one line",
    { args = { "page.html" }, text = WORDS,
      gpu = fake_gpu({ 60, 20 }, { 40, 10 }, nil) },
    { code = 0, mode = "print", width = 49, err = { NO_GPU_LINE } } },
  { "GPU call fails: print mode and one line",
    { args = { "page.html" }, text = WORDS,
      gpu = { getScreen = function() error("no gpu") end } },
    { code = 0, mode = "print", width = 49, err = { NO_GPU_LINE } } },
  { "no GPU: the maximum --width is 160",
    { args = { "--width", "160", "page.html" }, text = WORDS,
      gpu = false },
    { code = 0, mode = "print", width = 159, err = {} } },
  { "no GPU: --width 161 is a usage error",
    { args = { "--width", "161", "page.html" }, gpu = false },
    { code = 2, mode = "none", width = 0, err = { E160 } } },
  { "URL with --print --width",
    { args = { "--print", "--width", "30", URL },
      card = { default = page_script(WORDS) } },
    { code = 0, mode = "print", width = 29, err = {} } },
  { "URL with --no-rescale",
    { args = { "--no-rescale", URL }, card = { default = page_script(WORDS) } },
    { code = 0, mode = "viewer", width = 39, no_rescale = true, err = {} } },
})

-- The viewer title and file name (spec/viewer.md, spec/fetch.md) ---------------

local gone = { code = 404, message = "Not Found" }

scenarios("viewer_title", {
  { "file with a title",
    { args = { "page.html" } },
    { title = "My Page", file = "page.html" } },
  { "file without a title shows the file name",
    { args = { "page.html" }, text = "<p>x</p>" },
    { title = false, file = "page.html" } },
  { "URL with a title",
    { args = { URL }, card = { default = page_script() } },
    { title = "My Page", file = URL } },
  { "URL without a title shows the URL without the fragment",
    { args = { "https://x.org/a#f" },
      card = { default = page_script("<p>x</p>") } },
    { title = false, file = "https://x.org/a" } },
  { "the final URL after a redirect",
    { args = { URL }, card = { routes = {
      [URL] = { code = 301, headers = { Location = { "/new" } } },
      ["http://example.com/new"] = page_script("<p>x</p>") } } },
    { title = false, file = "http://example.com/new" } },
  { "error status with a title",
    { args = { URL }, card = { default = page_script(
      "<title>Oops</title><p>gone</p>", gone) } },
    { title = "[HTTP 404] Oops", file = URL } },
  { "error status without a title",
    { args = { URL }, card = { default = page_script("<p>gone</p>",
      { code = 500 }) } },
    { title = "[HTTP 500] " .. URL, file = URL } },
})

-- File checks (spec/cli.md "Local files", spec/guard.md) -----------------------

local function failing_open() error("the file must not open") end

local function reader_file(chunks)
  local f = {}
  local n = 0
  function f.read()
    n = n + 1
    return table.unpack(chunks[n] or {})
  end
  function f.seek() return 10 end
  function f.close() end
  return f
end

scenarios("file_checks", {
  { "missing file: one line and no listener",
    { args = { "nope.html" },
      deps = { exists = no, open = failing_open } },
    { code = 1, err = { "html: file not found: nope.html" }, views = 0,
      listens = 0 } },
  { "directory",
    { args = { "dir" }, deps = { exists = yes, is_dir = yes } },
    { code = 1, err = { "html: not a file: dir" }, views = 0, listens = 0 } },
  { "open fails on a missing file (no exists check)",
    { args = { "page.html" }, deps = { open = function()
      return nil, "page.html: No such file or directory" end } },
    { code = 1, err = { "html: file not found: page.html" }, views = 0 } },
  { "open fails on an existing file",
    { args = { "page.html" }, deps = { exists = yes, open = function()
      return nil, "denied" end } },
    { code = 1, err = { "html: read error: denied" }, views = 0 } },
  { "read error in a local file",
    { args = { "page.html" }, deps = { open = function()
      return reader_file({ { "<p>hello" }, { nil, "io error" } }) end } },
    { code = 1, err = { "html: read error: io error" }, views = 0,
      clean = true } },
  { "empty file in the viewer",
    { args = { "empty.html" }, text = "" },
    { code = 0, err = {}, views = 1, lines = 0, file = "empty.html" } },
  { "empty file in print mode writes nothing",
    { args = { "--print", "empty.html" }, text = "" },
    { code = 0, err = {}, views = 0, out = 0 } },
  { "local file too large: stops before the first read",
    { args = { "big.html" }, deps = { size = function() return 4000000 end } },
    { code = 1, err = { "html: file too large for available memory "
      .. "(4000000 bytes, 1800000 free)" }, views = 0, reads = 0,
      clean = true } },
  { "local file just under the size limit",
    { args = { "page.html" }, deps = { size = function() return 3600000 end } },
    { code = 0, views = 1 } },
  { "remote page too large by Content-Length: stops before the first read",
    { args = { URL }, card = { default = page_script(nil,
      { headers = { ["Content-Length"] = { "4000000" } } }) } },
    { code = 1, err = { "html: page too large for available memory "
      .. "(4000000 bytes, 1800000 free)" }, views = 0, reads = 0,
      clean = true } },
})

-- Ctrl+C (spec/errors.md "Ctrl+C", spec/loading.md, spec/viewer.md) ------------

local function interrupt_now() last.interrupt("interrupted") end

local function interrupt_in_sleep(s)
  last.interrupt()
  os.sleep(s)
end

local INTERRUPTED = { "html: interrupted" }

scenarios("interrupts", {
  { "during the render",
    { args = { "page.html" }, text = LONG, deps = { on_read = function(n)
      if n == 2 then
        interrupt_now()
      end
    end } },
    { code = 130, err = INTERRUPTED, views = 0, removes = 1, clean = true } },
  { "at the last read, before the viewer",
    { args = { "page.html" }, deps = { on_read = function(n)
      if n == 2 then
        interrupt_now()
      end
    end } },
    { code = 130, err = INTERRUPTED, views = 0, removes = 1, clean = true } },
  { "during the print output",
    { args = { "--print", "page.html" }, text = LONG, deps = { out = function()
      last.outs = (last.outs or 0) + 1
      interrupt_now()
    end } },
    { code = 130, err = INTERRUPTED, outs = 1, removes = 1 } },
  { "the listener is gone before the viewer; a late flag keeps exit 0",
    { args = { "page.html" }, deps = { view = function()
      last.removed_at_view = last.removes
      interrupt_now()
      return "quit"
    end } },
    { code = 0, err = {}, removed_at_view = 1, removes = 1 } },
  { "the viewer returns interrupted",
    { args = { "page.html" }, deps = { view = function()
      return "interrupted"
    end } },
    { code = 130, err = {}, clean = true } },
  { "the viewer raises a bare interrupted error",
    { args = { "page.html" }, deps = { view = function()
      error("interrupted", 0)
    end, log = function(text) last.logged = text return true end } },
    { code = 130, err = INTERRUPTED, logged = false, clean = true } },
  { "during the connect",
    { args = { URL }, card = { default = { connect_polls = 100 } },
      deps = { sleep = interrupt_in_sleep } },
    { code = 130, err = INTERRUPTED, removes = 1, clean = true } },
  { "during the body",
    { args = { URL }, card = { default = { endless = true,
      body = { "<p>a</p>", "", "", "", "", "", "", "", "", "" } } },
      deps = { sleep = interrupt_in_sleep } },
    { code = 130, err = INTERRUPTED, removes = 1, clean = true } },
  { "an interrupted event raised by the sleep",
    { args = { URL }, card = { default = { connect_polls = 5 } },
      deps = { sleep = function() error("interrupted", 0) end } },
    { code = 130, err = INTERRUPTED, clean = true } },
})

-- Errors (spec/errors.md "Controlled and unexpected errors") -------------------

local function keep_log(text)
  last.logged = text
  return true
end

local function broken_file(message)
  return function()
    return { read = function() error(message) end,
      seek = function() return 10 end, close = function() end }
  end
end

local UNEXPECTED = "html: unexpected error: "

scenarios("errors", {
  { "unexpected error in the viewer: one line, log, exit 1",
    { args = { "page.html" }, deps = { log = keep_log, view = function()
      error("boom\nmore")
    end } },
    { code = 1, err = { UNEXPECTED
      .. "boom (details in /tmp/html-error.log)" }, logged = "traceback",
      clean = true } },
  { "unexpected error in the render in print mode",
    { args = { "--print", "page.html" }, deps = { log = keep_log,
      open = broken_file("disk") } },
    { code = 1, err = { UNEXPECTED
      .. "disk (details in /tmp/html-error.log)" }, out = 0,
      logged = "traceback", removes = 1 } },
  { "a controlled error from the viewer prints as it is",
    { args = { "page.html" }, deps = { view = function()
      error("html: screen lost", 0)
    end } },
    { code = 1, err = { "html: screen lost" } } },
  { "the log fails with a reason",
    { args = { "page.html" }, deps = { open = broken_file("boom"),
      log = function() return nil, "not enough space" end } },
    { code = 1, err = { UNEXPECTED
      .. "boom (cannot write /tmp/html-error.log: not enough space)" } } },
  { "the log raises",
    { args = { "page.html" }, deps = { open = broken_file("boom"),
      log = function() error("log boom\nsecond line") end } },
    { code = 1, err = { UNEXPECTED
      .. "boom (cannot write /tmp/html-error.log: log boom)" } } },
  { "no log function",
    { args = { "page.html" }, deps = { open = broken_file("boom") } },
    { code = 1, err = { UNEXPECTED .. "boom" } } },
  { "a failing close still removes the listener",
    { args = { "page.html" }, deps = { open = function()
      local f = fake_file(PAGE)
      f.close = function() error("close boom", 0) end
      return f
    end } },
    { code = 1, err = { UNEXPECTED .. "close boom" }, listens = 1,
      removes = 1 } },
})

-- URL errors (spec/fetch.md "Errors", spec/url.md) -----------------------------

local LONG_URL = URL .. string.rep("a", 2048)
local no_local = { exists = no }
local SUFFIX = " (no local file named example.com)"

scenarios("url_errors", {
  { "unsupported scheme",
    { args = { "ftp://example.com" }, card = {} },
    { code = 2, err = { "html: unsupported URL scheme: ftp" },
      requests = 0 } },
  { "a space in the host",
    { args = { "http://exa mple.com" }, card = {} },
    { code = 2, err = { "html: invalid URL: http://exa mple.com" },
      requests = 0 } },
  { "no host",
    { args = { "http://" }, card = {} },
    { code = 2, err = { "html: invalid URL: http://" }, requests = 0 } },
  { "URL too long",
    { args = { LONG_URL }, card = {} },
    { code = 2, err = { "html: invalid URL: too long" }, requests = 0 } },
  { "a scheme is never a local path",
    { args = { "ftp://example.com" }, card = {},
      deps = { exists = function() error("not checked") end } },
    { code = 2, err = { "html: unsupported URL scheme: ftp" } } },
  { "no internet card",
    { args = { URL }, card = {}, deps = { internet = false } },
    { code = 1, err = { "html: no internet card found (needed for " .. URL
      .. ")" }, views = 0, clean = true } },
  { "HTTP disabled",
    { args = { URL }, card = { http = false } },
    { code = 1, err = { "html: HTTP requests are disabled on this server" } } },
  { "connect fails",
    { args = { URL }, card = { default = { connect_error = "unknown host" } } },
    { code = 1, err = { "html: cannot connect: " .. URL .. ": unknown host" },
      clean = true } },
  { "read error with a 2xx status",
    { args = { "--print", URL }, card = { default = page_script(PAGE,
      { read_error = "reset" }) } },
    { code = 1, err = { "html: read error: reset" }, clean = true } },
  { "content type that is not a page",
    { args = { URL }, card = { default = { headers =
      { ["Content-Type"] = { "application/pdf" } } } } },
    { code = 1, err = { "html: not an HTML page: application/pdf" },
      clean = true } },
  { "guessed URL: connect error names the argument",
    { args = { "example.com" }, deps = no_local,
      card = { default = { connect_error = "refused" } } },
    { code = 1, err = { "html: cannot connect: http://example.com: refused"
      .. SUFFIX } } },
  { "guessed URL: read error names the argument",
    { args = { "--print", "example.com" }, deps = no_local,
      card = { default = page_script(PAGE, { read_error = "reset" }) } },
    { code = 1, err = { "html: read error: reset" .. SUFFIX } } },
  { "guessed URL: no card names the argument",
    { args = { "example.com" }, card = {},
      deps = { exists = no, internet = false } },
    { code = 1, err = { "html: no internet card found (needed for "
      .. "http://example.com)" .. SUFFIX } } },
})

-- Error status (spec/fetch.md "HTTP status and content type") ------------------

local PART = page_script("<p>part</p>", { code = 500, message = "Err",
  read_error = "reset" })
local NOTICE = "html: HTTP 500 Err: " .. URL
local READ_ERROR = "html: read error: reset"

scenarios("error_status", {
  { "viewer: the body renders, no stderr, exit 0, no popup",
    { args = { URL }, card = { default = page_script("<p>gone</p>", gone) } },
    { code = 0, err = {}, views = 1, error_opt = false, clean = true } },
  { "print: the notice comes first, then the text",
    { args = { "--print", URL }, card = { default = page_script("<p>gone</p>",
      gone) } },
    { code = 0, err = { "html: HTTP 404 Not Found: " .. URL }, out = 1,
      events = { "err", "out" }, clean = true } },
  { "print: an empty body gives the short page",
    { args = { "--print", URL }, card = { default = { code = 503,
      message = "Unavailable", body = {} } } },
    { code = 0, err = { "html: HTTP 503 Unavailable: " .. URL }, out = 3 } },
  { "print, partial body: the text, then the error line, exit 0",
    { args = { "--print", URL }, card = { default = PART } },
    { code = 0, err = { NOTICE, READ_ERROR }, out = 1,
      events = { "err", "out", "err" }, clean = true } },
  { "viewer, partial body: the error goes to the popup, not to stderr",
    { args = { URL }, card = { default = PART } },
    { code = 0, err = {}, views = 1, error_opt = READ_ERROR,
      events = { "view" }, clean = true } },
  { "viewer, partial body, guessed URL: the popup line names the argument",
    { args = { "example.com" }, deps = no_local, card = { default = PART } },
    { code = 0, err = {}, views = 1, error_opt = READ_ERROR .. SUFFIX } },
  { "no screen, partial body: print the text, then the error line",
    { args = { URL }, gpu = false, card = { default = PART } },
    { code = 0, err = { NO_GPU_LINE, NOTICE, READ_ERROR }, out = 1, views = 0,
      events = { "err", "err", "out", "err" } } },
})

-- Arguments without a scheme (spec/url.md) -------------------------------------

local nf = "html: file not found: "

-- Runs one argument with a fake exists. Returns "local", "url <requested>",
-- or the error line, and the exit code.
local function classify(input)
  local code, rec = run_url({ input[1] }, { default = page_script() }, {
    exists = function() return input[2] end,
  })
  if #rec.ctl.requests > 0 then
    return { "url " .. rec.ctl.requests[1], code }
  end
  if code == 0 and #rec.views == 1 then
    return { "local", code }
  end
  return { rec.err[1], code }
end

t.cases(T, "arguments_without_a_scheme", {
  { "./x.html exists", { "./x.html", true }, { "local", 0 } },
  { "./x.html missing", { "./x.html", false }, { nf .. "./x.html", 1 } },
  { "x.html exists", { "x.html", true }, { "local", 0 } },
  { "x.html missing", { "x.html", false }, { nf .. "x.html", 1 } },
  { "dir/x.html missing", { "dir/x.html", false },
    { nf .. "dir/x.html", 1 } },
  { "dir/example.com missing", { "dir/example.com", false },
    { nf .. "dir/example.com", 1 } },
  { "example.com exists", { "example.com", true }, { "local", 0 } },
  { "example.com missing", { "example.com", false },
    { "url http://example.com", 0 } },
  { "EXAMPLE.COM", { "EXAMPLE.COM", false },
    { "url http://EXAMPLE.COM", 0 } },
  { "example.com/path", { "example.com/path", false },
    { "url http://example.com/path", 0 } },
  { "example.com/", { "example.com/", false },
    { "url http://example.com/", 0 } },
  { "example.com:8080/a?b=1", { "example.com:8080/a?b=1", false },
    { "url http://example.com:8080/a?b=1", 0 } },
  { "example.com#top", { "example.com#top", false },
    { "url http://example.com", 0 } },
  { "localhost", { "localhost", false }, { "url http://localhost", 0 } },
  { "localhost:8080", { "localhost:8080", false },
    { "url http://localhost:8080", 0 } },
  { "192.168.0.1", { "192.168.0.1", false },
    { "url http://192.168.0.1", 0 } },
  { "foo", { "foo", false }, { nf .. "foo", 1 } },
  { "foo:8080", { "foo:8080", false }, { nf .. "foo:8080", 1 } },
  { "example..com", { "example..com", false }, { nf .. "example..com", 1 } },
  { "a.-b.com", { "a.-b.com", false }, { nf .. "a.-b.com", 1 } },
  { "example.com:", { "example.com:", false }, { nf .. "example.com:", 1 } },
  { "example.com:0", { "example.com:0", false },
    { nf .. "example.com:0", 1 } },
  { "example.com:99999", { "example.com:99999", false },
    { nf .. "example.com:99999", 1 } },
  { "a space", { "exa mple.com", false }, { nf .. "exa mple.com", 1 } },
  { "non-ASCII", { "ex\195\164mple.com", false },
    { nf .. "ex\195\164mple.com", 1 } },
  { "~/example.com", { "~/example.com", false },
    { nf .. "~/example.com", 1 } },
}, classify)

return T
