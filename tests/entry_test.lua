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
  { "print, broken body: no stdout, one stderr line, exit 1",
    { args = { "--print", URL }, card = { default = PART } },
    { code = 1, err = { READ_ERROR }, out = 0, clean = true } },
  { "viewer without a frame, broken body: one stderr line, exit 1",
    { args = { URL }, card = { default = PART } },
    { code = 1, err = { READ_ERROR }, views = 0, clean = true } },
  { "broken body, guessed URL: the line names the argument",
    { args = { "--print", "example.com" }, deps = no_local,
      card = { default = PART } },
    { code = 1, err = { READ_ERROR .. SUFFIX }, out = 0 } },
  { "print, status from a connect failure: the short page, then one line",
    { args = { "--print", URL }, card = { default = { connect_error =
      internet.reason_404(URL) } } },
    { code = 0, err = { "html: HTTP 404 Not Found: " .. URL }, out = 3,
      events = { "out", "out", "out", "err" }, clean = true } },
  { "print, unknown status: no phrase",
    { args = { "--print", URL }, card = { default = { connect_error =
      internet.reason_status(418, URL) } } },
    { code = 0, err = { "html: HTTP 418: " .. URL }, out = 3, clean = true } },
  { "no screen, status from a connect failure: the same line, exit 0",
    { args = { URL }, gpu = false, card = { default = { connect_error =
      internet.reason_status(500, URL) } } },
    { code = 0, err = { NO_GPU_LINE, "html: HTTP 500 Internal Server Error: "
      .. URL }, out = 3, views = 0 } },
  { "viewer without a frame: the popup text is two lines",
    { args = { URL }, card = { default = { connect_error =
      internet.reason_404(URL) } } },
    { code = 0, err = {}, views = 1, error_opt = "[HTTP 404] Not Found\n" .. URL,
      clean = true } },
  { "print, connection error: stderr and exit 1 as before",
    { args = { "--print", URL }, card = { default = { connect_error =
      "Connection reset" } } },
    { code = 1, err = { "html: cannot connect: " .. URL
      .. ": Connection reset" }, out = 0, clean = true } },
  { "no screen, broken body: no stdout, only the error line",
    { args = { URL }, gpu = false, card = { default = PART } },
    { code = 1, err = { NO_GPU_LINE, READ_ERROR }, out = 0, views = 0 } },
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


-- The loading screen (spec/loading.md) ---------------------------------------
-- These runs use the real viewer session over the fake GPU. The screen is 80
-- columns by 10 rows: 9 line rows and the status row. A fake event queue
-- gives each key poll its events (ticks). The clock moves by step seconds at
-- each read, so each read can cause a poll.

local viewer = require("html.viewer")
local fake_screen = require("gpu")

local ROWS, STATUS_ROW = 9, 10
local BIG = "<title>Big</title>" .. LONG
local KEY_Q = { "key_down", "kbd", 113, 16, "player" }
local KEY_Y = { "key_down", "kbd", 121, 21, "player" }
local KEY_N = { "key_down", "kbd", 110, 49, "player" }
local KEY_ENTER = { "key_down", "kbd", 13, 28, "player" }
local KEY_DOWN = { "key_down", "kbd", 0, 208, "player" }
local KEY_CTRL_C = { "key_down", "kbd", 3, 46, "player" }
local EV_INTERRUPTED = { "interrupted" }
local QUIT_PROMPT = "Quit? (y/n)"

-- The status texts so far that are not a byte count or the prompt, without
-- repeats.
local function phases(statuses)
  local out = {}
  for _, s in ipairs(statuses) do
    if not s:find(" KB", 1, true) and not s:find(QUIT_PROMPT, 1, true)
        and out[#out] ~= s then
      out[#out + 1] = s
    end
  end
  return out
end

local function index_of(list, value)
  for i, v in ipairs(list) do
    if v == value then
      return i
    end
  end
  return nil
end

local function is_plain(line)
  return (line:gsub("[\1-\5]", ""):gsub("%s+$", ""))
end

-- Runs a fresh main (so the module upvalues start empty) with the real
-- session. o: args, text (a local page), card (card options, for a URL),
-- step (clock seconds per read), ticks (events for each key poll), show
-- (events for the interactive loop, default q then y), on_read(n), deps.
-- Returns the record.
local function framed(o)
  computer.test.reset()
  local rec = { trace = {}, statuses = {}, err = {} }
  local polls = 0
  local function trace(x)
    rec.trace[#rec.trace + 1] = x
  end
  local function advance()
    if o.step then
      computer.test.advance(o.step)
    end
  end
  local gpu, gctl = fake_screen.new({ width = 80, height = STATUS_ROW,
    max_width = 80, max_height = STATUS_ROW })
  rec.gctl = gctl
  local set = gpu.set
  gpu.set = function(x, y, s)
    if y == STATUS_ROW then
      local text = s:gsub("%s+$", "")
      trace("status")
      if not rec.shown then
        rec.statuses[#rec.statuses + 1] = text
        if rec.body_started and (text:find("^Connecting")
            or text:find("^Waiting") or text:find("^Redirect")) then
          rec.late_phase = true
        end
      end
    else
      trace("row")
    end
    return set(x, y, s)
  end
  local term = { clear = function() trace("restore") end,
    setCursor = function() end }

  -- The queue: each poll (pull(0) until nil) gets o.ticks[n].
  local batch, at = nil, 1
  local show_events = o.show or { KEY_Q, KEY_Y }
  local show_at = 1
  local function pull(timeout)
    if timeout ~= 0 then
      local e = show_events[show_at]
      show_at = show_at + 1
      if not e then
        error("test: no event for the viewer", 0)
      end
      return table.unpack(e)
    end
    if not batch then
      polls = polls + 1
      batch, at = (o.ticks or {})[polls] or {}, 1
    end
    local e = batch[at]
    at = at + 1
    if e then
      return table.unpack(e)
    end
    batch = nil
    return nil
  end

  local file, state = fake_file(o.text or PAGE, function(n)
    advance()
    if o.on_read then
      o.on_read(n)
    end
  end)
  rec.file = state
  local file_read = file.read
  file.read = function(self, n)
    local chunk = file_read(self, n)
    if chunk == nil then
      trace("eof")
    end
    return chunk
  end

  local deps = {
    out = function() end,
    err = function(line)
      trace("err")
      rec.err[#rec.err + 1] = without_position(line)
    end,
    width = 50, open = function() return file end,
    traceback = function(msg) return msg .. "\nstack traceback: (fake)" end,
    clock = os.clock, uptime = computer.uptime, sleep = os.sleep,
    gpu = gpu,
    open_screen = function(so)
      local s = viewer.open({ gpu = gpu, pull = pull, term = term }, so)
      local show = s.show
      s.show = function(lines, opts)
        trace("show")
        if not rec.shown then
          -- The screen the load left, before the viewer draws.
          rec.screen = gctl.screen()
          rec.shown = { lines = lines, opts = opts }
        end
        return show(lines, opts)
      end
      return s
    end,
  }
  if o.card then
    local card, ctl = internet.new(o.card)
    rec.ctl = ctl
    local request = card.request
    card.request = function(...)
      trace("request")
      local h, why = request(...)
      if h then
        local read = h.read
        h.read = function(...)
          advance()
          local s, e = read(...)
          if s == nil and e == nil then
            trace("eof")
          elseif s ~= nil and not rec.body_started then
            rec.body_started = true
            trace("body")
          end
          return s, e
        end
      end
      return h, why
    end
    deps.internet = card
  end
  for k, v in pairs(o.deps or {}) do
    deps[k] = v
  end

  local chunk = t.load_bin("html")({})
  local real_require = _G.require
  rec.required = {}
  _G.require = function(name)
    if type(name) == "string" and name:sub(1, 5) == "html." then
      rec.required[#rec.required + 1] = name
    end
    if name == "html.tokenizer" then
      trace("require")
    end
    return real_require(name)
  end
  local args = {}
  for i, a in ipairs(o.args or { "page.html" }) do
    args[i] = a
  end
  args.n = #args
  local ok, code = pcall(chunk.main, args, deps)
  _G.require = real_require
  if not ok then
    error(code, 0)
  end
  rec.code = code
  rec.duration = computer.uptime()
  return rec
end

-- The markers of the exit: the screen restore and the stderr lines.
local function exit_marks(rec)
  local out = {}
  for _, x in ipairs(rec.trace) do
    if x == "restore" or x == "err" then
      out[#out + 1] = x
    end
  end
  return out
end

-- The KB numbers of the byte-count statuses, and the last such status.
local function counts(rec)
  local nums, latest = {}, nil
  for _, s in ipairs(rec.statuses) do
    local n = s:match("(%d+) KB")
    if n then
      nums[#nums + 1] = tonumber(n)
      latest = s
    end
  end
  return nums, latest
end

-- The non-empty lines of the first viewer call, without style bytes.
local function page_lines(rec)
  local out = {}
  for _, line in ipairs(rec.shown and rec.shown.lines or {}) do
    local text = is_plain(line)
    if text ~= "" then
      out[#out + 1] = text
    end
  end
  return out
end

-- The values that a row can name, from one run.
local function observe(rec)
  local nums, last_status = counts(rec)
  local rising = #nums > 1
  for i = 2, #nums do
    if nums[i] < nums[i - 1] then
      rising = false
    end
  end
  local request_at = index_of(rec.trace, "request")
  local require_at = index_of(rec.trace, "require")
  local status_at = index_of(rec.trace, "status")
  local first_row = index_of(rec.trace, "row")
  local eof_at = index_of(rec.trace, "eof")
  local show_at = index_of(rec.trace, "show")
  local rows_equal = true
  if rec.screen then
    for y = 1, ROWS do
      if is_plain(rec.screen[y]) ~= is_plain(rec.shown.lines[y] or "") then
        rows_equal = false
      end
    end
  end
  local before_show = 0
  for i, x in ipairs(rec.trace) do
    if show_at and i >= show_at then
      break
    end
    if x == "row" then
      before_show = before_show + 1
    end
  end
  local closed = true
  for _, h in ipairs(rec.ctl and rec.ctl.handles or {}) do
    if h.closed ~= 1 then
      closed = false
    end
  end
  return {
    code = rec.code,
    err = rec.err,
    phases = phases(rec.statuses),
    first_status = rec.statuses[1],
    status_first = status_at ~= nil
      and (not require_at or status_at < require_at)
      and (not request_at or status_at < request_at),
    marks = exit_marks(rec),
    early_draw = before_show > 0 and (eof_at == nil or first_row < eof_at),
    early_rows_equal = rows_equal,
    row_draws_before_show = before_show,
    shown = rec.shown ~= nil,
    title = rec.shown and rec.shown.opts.title or false,
    popup = rec.shown and rec.shown.opts.error or false,
    popup_memory = rec.shown ~= nil and (rec.shown.opts.error or ""):find(
      "^html: page too large for available memory") ~= nil,
    shown_lines = rec.shown and #rec.shown.lines or false,
    popup_reload = rec.shown ~= nil and (rec.shown.opts.error or ""):find(
      "\nReload to try again%.$") ~= nil,
    popup_last = rec.shown and (rec.shown.opts.error or ""):match(
      "([^\n]*)$") or false,
    page_lines = page_lines(rec),
    last_kb = last_status,
    kb_rising = rising,
    updates = #nums,
    within_rate = #nums - 1 <= rec.duration / 0.25 + 1,
    phases_before_body = not rec.late_phase,
    handles_closed = closed,
    sleeps = computer.test.sleeps(),
    reads = rec.file.reads,
  }
end

-- Registers T[name], a table test over framed runs. Each row compares only
-- the fields that its expected table names.
local function framed_cases(name, rows)
  for _, row in ipairs(rows) do
    local keys = {}
    for k in pairs(row[3]) do
      keys[#keys + 1] = k
    end
    row[2].keys = keys
  end
  t.cases(T, name, rows, function(input)
    local obs, out = observe(framed(input)), {}
    for _, k in ipairs(input.keys) do
      out[k] = obs[k]
    end
    return out
  end)
end

-- A page script served in pieces of size bytes. extra replaces fields.
local function served(body, size, extra)
  local s = { headers = { ["Content-Type"] = { "text/html" } },
    body = internet.pieces(body, size, false) }
  for k, v in pairs(extra or {}) do
    s[k] = v
  end
  return s
end

local function with_length(body, size)
  return served(body, size, { headers = { ["Content-Type"] = { "text/html" },
    ["Content-Length"] = { tostring(#body) } } })
end

-- "Startup" rule 3: the status line draws before the modules load and before
-- the request. "Status line during load": the phases.
local URL_FIRST = "Loading " .. URL .. "..."
framed_cases("loading_startup_order_and_phases", {
  { "local file: status first, then modules, then the page",
    { text = PAGE },
    { code = 0, status_first = true, first_status = "Loading page.html...",
      phases = { "Loading page.html...", "Loading modules...",
        "Loading page.html..." } } },
  { "URL: status first, before the request and the modules",
    { args = { URL }, card = { default = served(PAGE, 10) } },
    { code = 0, status_first = true, first_status = URL_FIRST,
      phases = { URL_FIRST, "Loading modules...",
        "Connecting to example.com...", "Waiting for response...",
        URL_FIRST } } },
  { "URL: the phases come before the body, also on a slow server",
    { args = { URL }, step = 0.1, card = { default = served(PAGE, 10,
      { connect_polls = 3, response_polls = 3 }) } },
    { code = 0, phases_before_body = true,
      phases = { URL_FIRST, "Loading modules...",
        "Connecting to example.com...", "Waiting for response...",
        URL_FIRST } } },
  { "redirect: its target shows before the body",
    { args = { URL }, card = { routes = {
        [URL] = { code = 302, headers = { Location = { "/next" } } },
        ["http://example.com/next"] = served(PAGE, 10),
      } } },
    { code = 0, phases_before_body = true,
      phases = { URL_FIRST, "Loading modules...",
        "Connecting to example.com...", "Waiting for response...",
        "Redirect to http://example.com/next...",
        "Waiting for response...", "Loading http://example.com/next..." } } },
  { "guessed URL: the frame shows the argument",
    { args = { "example.com" }, deps = { exists = no },
      card = { routes = { ["http://example.com"] = served(PAGE, 10) } } },
    { code = 0, status_first = true, first_status = "Loading example.com..." } },
})

-- "Status line during load": byte counts, with the size from the file or from
-- Content-Length, and the rate limit of one update each 0.25 s. The last
-- update is not limited: it shows the total.
local KB = #BIG // 1024 + 1
local OF = " " .. KB .. " KB of " .. KB .. " KB"
framed_cases("loading_byte_counts", {
  { "file: the size is known, the last count is the size",
    { text = BIG, step = 0.1 },
    { code = 0, kb_rising = true, within_rate = true,
      last_kb = "Loading page.html..." .. OF } },
  { "page with Content-Length: the last count is the size",
    { args = { URL }, step = 0.1, card = { default = with_length(BIG, 1000) } },
    { code = 0, kb_rising = true, within_rate = true,
      last_kb = "Loading " .. URL .. "..." .. OF } },
  { "page without Content-Length: a count and no total",
    { args = { URL }, step = 0.1, card = { default = served(BIG, 1000) } },
    { code = 0, kb_rising = true, within_rate = true,
      last_kb = "Loading " .. URL .. "... " .. KB .. " KB" } },
  { "a fast read: the counts do not run faster than the limit",
    { text = BIG, step = 0.01 },
    { code = 0, within_rate = true, updates = 1 } },
  { "a small page: one update, at the end",
    { text = PAGE, step = 0.01 },
    { code = 0, updates = 1 } },
})

-- "Content during load": the first screen draws when the lines fill it, and
-- not before. A page with fewer lines than rows draws once, at the end.
framed_cases("loading_first_screen", {
  { "file: draws before the end of input, rows equal the final rows",
    { text = BIG, step = 0.01 },
    { code = 0, early_draw = true, early_rows_equal = true, shown = true,
      title = "Big" } },
  { "large page in small pieces: draws before the end of input",
    { args = { URL }, step = 0.01, card = { default = served(BIG, 100) } },
    { code = 0, early_draw = true, early_rows_equal = true, shown = true } },
  { "small page: no draw before the viewer",
    { text = PAGE },
    { code = 0, early_draw = false, row_draws_before_show = 0,
      shown = true } },
  { "a page that does not fill the screen: no draw before the viewer",
    { text = string.rep("<p>x</p>", 4), step = 0.01 },
    { code = 0, early_draw = false, row_draws_before_show = 0 } },
})

-- "Keys during load": Ctrl+C exits at once with code 130. The screen is
-- restored before the stderr line (spec "Exit").
local INTERRUPT_EXIT = { code = 130, err = { "html: interrupted" },
  marks = { "restore", "err" }, shown = false, handles_closed = true }
framed_cases("loading_ctrl_c", {
  { "during connect: key_down char 3",
    { args = { URL }, card = { default = { connect_polls = 1000 } },
      ticks = { { KEY_CTRL_C } } }, INTERRUPT_EXIT },
  { "during the wait for the response: the interrupted event",
    { args = { URL }, card = { default = { response_polls = 1000 } },
      ticks = { { EV_INTERRUPTED } } }, INTERRUPT_EXIT },
  { "during the body",
    { args = { URL }, step = 0.1, card = { default = served(BIG, 500) },
      ticks = { {}, { KEY_CTRL_C } } }, INTERRUPT_EXIT },
  { "during the render of a file",
    { text = BIG, step = 0.3, ticks = { { EV_INTERRUPTED } } },
    INTERRUPT_EXIT },
  { "while the quit prompt shows",
    { text = BIG, step = 0.3, ticks = { { KEY_Q }, { KEY_CTRL_C } } },
    INTERRUPT_EXIT },
})

-- "Keys during load": q shows the prompt and loading goes on. y or Enter stops
-- loading with code 0. Any other key cancels and loading goes on. Other keys
-- are dropped.
framed_cases("loading_quit_prompt", {
  { "q then y: loading stops, exit 0, no error line",
    { text = BIG, step = 0.3, ticks = { { KEY_Q }, { KEY_Y } } },
    { code = 0, err = {}, marks = { "restore" }, shown = false,
      reads = 3 } },
  { "q then Enter: loading stops",
    { text = BIG, step = 0.3, ticks = { { KEY_Q }, { KEY_ENTER } } },
    { code = 0, err = {}, marks = { "restore" }, shown = false } },
  { "q and y in one poll: loading stops",
    { text = BIG, step = 0.3, ticks = { { KEY_Q, KEY_Y } } },
    { code = 0, shown = false } },
  { "q then n: loading goes on and the page shows",
    { text = BIG, step = 0.3, ticks = { { KEY_Q }, { KEY_N } } },
    { code = 0, err = {}, shown = true, title = "Big",
      marks = { "restore" }, reads = 9 } },
  { "q then another key cancels",
    { text = BIG, step = 0.3, ticks = { { KEY_Q }, { KEY_DOWN } } },
    { code = 0, shown = true, title = "Big" } },
  { "other keys alone are dropped, no prompt",
    { text = BIG, step = 0.3, ticks = { { KEY_DOWN, KEY_N } } },
    { code = 0, shown = true, title = "Big" } },
  { "the prompt is still open at the end of the load: the viewer asks",
    { text = PAGE, step = 0.3, ticks = { { KEY_Q } }, show = { KEY_Y } },
    { code = 0, shown = true, marks = { "restore" } } },
  { "the prompt at the end of the load, cancelled: the page shows",
    { text = PAGE, step = 0.3, ticks = { { KEY_Q } },
      show = { KEY_N, KEY_Q, KEY_Y } },
    { code = 0, shown = true, marks = { "restore" } } },
  { "q then y during a download: the handle closes",
    { args = { URL }, step = 0.1, card = { default = served(BIG, 500) },
      ticks = { { KEY_Q }, { KEY_Y } } },
    { code = 0, shown = false, handles_closed = true } },
})

-- "Exit": the screen is restored before the error line on the error paths
-- that end the session (the unexpected error).
framed_cases("loading_error_exits", {
  { "unexpected error in the render: restore, then one line",
    { text = BIG, step = 0.01,
      on_read = function(n)
        if n == 3 then
          error("boom", 0)
        end
      end },
    { code = 1, marks = { "restore", "err" },
      err = { "html: unexpected error: boom" } } },
})

-- "Errors after the frame": a fetch error or a memory stop does not end the
-- session. The viewer shows a popup over an empty page: a broken page is not
-- rendered, so no line of it shows (spec/loading.md). After OK, q and y quit
-- with code 0. No stderr line.
local OK_QUIT = { KEY_ENTER, KEY_Q, KEY_Y }
local function kept(url, text, extra)
  local e = { code = 0, err = {}, marks = { "restore" }, shown = true,
    popup = text, title = "[error] " .. url, shown_lines = 0,
    handles_closed = true }
  for k, v in pairs(extra or {}) do
    e[k] = v
  end
  return e
end
local RELOAD = "\nReload to try again."
local CONNECT_ERR ="html: cannot connect: " .. URL .. ": "
framed_cases("loading_errors_keep_the_session", {
  { "cannot connect",
    { args = { URL }, show = OK_QUIT,
      card = { default = { connect_error = "refused" } } },
    kept(URL, CONNECT_ERR .. "refused" .. RELOAD,
      { first_status = URL_FIRST, popup_reload = true }) },
  { "unknown host (measured text)",
    { args = { URL }, show = OK_QUIT, card = { default = { connect_error =
      "unknown host: example.com: Name or service not known" } } },
    kept(URL, CONNECT_ERR .. "unknown host: example.com: Name or service "
      .. "not known" .. RELOAD) },
  { "timeout while connecting",
    { args = { URL }, show = OK_QUIT, step = 0.05,
      card = { default = { connect_polls = 1e6 } } },
    kept(URL, "html: timed out connecting to " .. URL .. RELOAD) },
  { "read error in a 200 body",
    { args = { URL }, show = OK_QUIT,
      card = { default = served(PAGE, 10, { read_error = "reset" }) } },
    kept(URL, "html: read error: reset" .. RELOAD,
      { popup_last = "Reload to try again." }) },
  { "read error in a 200 body, a guessed URL: the popup names the argument",
    { args = { "example.com" }, show = OK_QUIT, deps = { exists = no },
      card = { default = served(PAGE, 10, { read_error = "reset" }) } },
    kept("http://example.com", "html: read error: reset (no local file named "
      .. "example.com)" .. RELOAD) },
  { "timeout in the body: an empty page and the popup",
    { args = { URL }, show = OK_QUIT, step = 0.5,
      card = { default = served(PAGE, 10, { endless = true }) } },
    { code = 0, err = {}, shown = true, shown_lines = 0,
      title = "[error] " .. URL, popup_last = "Reload to try again.",
      handles_closed = true } },
  { "read error of a local file after the frame: a popup, exit 0",
    { text = BIG, show = OK_QUIT, deps = { open = function()
        local f = fake_file(BIG)
        f.read = function() return nil, "disk gone" end
        return f
      end } },
    { code = 0, err = {}, marks = { "restore" }, shown = true,
      shown_lines = 0, popup = "html: read error: disk gone" .. RELOAD,
      title = "[error] page.html" } },
  { "too many open connections",
    { args = { URL }, show = OK_QUIT, card = { limit = 0,
      default = served(PAGE, 10) } },
    kept(URL, "html: cannot fetch " .. URL .. ": too many open connections"
      .. RELOAD) },
  { "not text/html",
    { args = { URL }, show = OK_QUIT, card = { default = { headers =
      { ["Content-Type"] = { "application/pdf" } } } } },
    kept(URL, "html: not an HTML page: application/pdf",
      { popup_reload = false }) },
  { "no internet card",
    { args = { URL }, show = OK_QUIT, deps = { internet = false } },
    kept(URL, "html: no internet card found (needed for " .. URL .. ")",
      { handles_closed = true, popup_reload = false }) },
  { "too large for the memory, known size: an empty page",
    { args = { URL }, show = OK_QUIT, card = { default = served(PAGE, 10,
      { headers = { ["Content-Type"] = { "text/html" },
        ["Content-Length"] = { "99999999" } } }) } },
    { code = 0, err = {}, shown = true, popup_memory = true,
      title = "[error] " .. URL, shown_lines = 0, handles_closed = true,
      popup_reload = false } },
  { "too large for the memory, known file size: no reload line",
    { text = BIG, show = OK_QUIT, deps = { size = function()
        return 99999999
      end } },
    { code = 0, err = {}, shown = true, popup_reload = false } },
  { "HTTP disabled: no reload line",
    { args = { URL }, show = OK_QUIT, card = { http = false,
      default = served(PAGE, 10) } },
    kept(URL, "html: HTTP requests are disabled on this server",
      { popup_reload = false }) },
  { "response timeout: reload line",
    { args = { URL }, show = OK_QUIT, step = 0.05,
      card = { default = { response_polls = 1e6 } } },
    kept(URL, "html: timed out connecting to " .. URL .. RELOAD,
      { popup_reload = true }) },
  { "a guessed URL names the argument in the popup",
    { args = { "example.com" }, show = OK_QUIT, deps = { exists = no },
      card = { default = { connect_error = "refused" } } },
    kept("example.com", "html: cannot connect: http://example.com: refused "
      .. "(no local file named example.com)" .. RELOAD) },
  { "memory stop after the first screen: an empty page and a popup",
    { text = BIG, step = 0.01, show = OK_QUIT,
      on_read = function(n)
        if n == 4 then
          computer.test.set_free(100 * 1024)
        end
      end },
    { code = 0, err = {}, marks = { "restore" }, early_draw = true,
      shown = true, popup_memory = true, title = "[error] page.html",
      shown_lines = 0, popup_last = "Reload to try again." } },
  { "Ctrl+C in the popup exits with 130",
    { args = { URL }, show = { KEY_CTRL_C },
      card = { default = { connect_error = "refused" } } },
    { code = 130, handles_closed = true } },
  { "the interrupted event in the popup exits with 130",
    { args = { URL }, show = { EV_INTERRUPTED },
      card = { default = { connect_error = "refused" } } },
    { code = 130 } },
  { "other keys do not close the popup",
    { args = { URL }, show = { KEY_Q, KEY_Y, KEY_ENTER, KEY_Q, KEY_Y },
      card = { default = { connect_error = "refused" } } },
    { code = 0, err = {}, shown = true } },
})

-- "HTTP error status": the card reports it as a connect failure. The short
-- page shows with a popup of two lines: "[HTTP <code>] <phrase>" and the URL.
-- The status line holds the code once.
local function http_row(name, reason, code_text, popup, extra)
  local e = { code = 0, err = {}, shown = true, popup = popup,
    title = "[HTTP " .. code_text .. "] " .. (extra and extra.phrase or URL),
    popup_last = URL,
    handles_closed = true }
  return { name, { args = { URL }, show = OK_QUIT,
    card = { default = { connect_error = reason } } }, e }
end
framed_cases("loading_http_status_popup", {
  http_row("404: the reason is the URL", internet.reason_404(URL), "404",
    "[HTTP 404] Not Found\n" .. URL, { phrase = "Not Found" }),
  http_row("500: the Java message", internet.reason_status(500, URL), "500",
    "[HTTP 500] Internal Server Error\n" .. URL, { phrase = "Internal Server Error" }),
  http_row("unknown code: no phrase", internet.reason_status(418, URL), "418",
    "[HTTP 418]\n" .. URL),
  { "the short page shows the URL",
    { args = { URL }, show = OK_QUIT,
      card = { default = { connect_error = internet.reason_404(URL) } } },
    { page_lines = { "HTTP 404 Not Found", URL } } },
  { "a connection error is not a status",
    { args = { URL }, show = OK_QUIT, card = { default = { connect_error =
      "Connection reset" } } },
    kept(URL, CONNECT_ERR .. "Connection reset" .. RELOAD) },
})

-- "Startup" rule 1: an invalid URL is a usage error of the argument checks.
-- The screen does not open and only html.url loads.
local function url_check_run(args)
  local rec = framed({ args = args, card = { default = served(PAGE, 10) } })
  local draws = 0
  for _, name in ipairs({ "set", "fill", "copy", "setResolution",
    "setForeground", "setBackground" }) do
    draws = draws + rec.gctl.count(name)
  end
  local heavy = false
  for _, name in ipairs(rec.required) do
    if name ~= "html.url" then
      heavy = true
    end
  end
  return { code = rec.code, err = rec.err, draws = draws, heavy = heavy,
    requests = rec.ctl and #rec.ctl.requests or 0 }
end

t.cases(T, "invalid_url_fails_before_the_screen", {
  { "empty host", { "http://" },
    { code = 2, err = { "html: invalid URL: http://" }, draws = 0,
      heavy = false, requests = 0 } },
  { "space in the URL", { "http://exa mple.com/" },
    { code = 2, err = { "html: invalid URL: http://exa mple.com/" },
      draws = 0, heavy = false, requests = 0 } },
  { "unsupported scheme", { "ftp://example.com/" },
    { code = 2, err = { "html: unsupported URL scheme: ftp" }, draws = 0,
      heavy = false, requests = 0 } },
  { "too long", { "http://example.com/" .. string.rep("a", 2100) },
    { code = 2, err = { "html: invalid URL: too long" }, draws = 0,
      heavy = false, requests = 0 } },
}, url_check_run)

-- "Startup": print mode and the no-screen path do not open the screen.
local function print_run(args, no_gpu)
  local gpu, gctl = fake_screen.new({ width = 80, height = STATUS_ROW })
  local opened = false
  local code, rec = run(args, nil, {
    gpu = (not no_gpu) and gpu or false,
    open_screen = function() opened = true end,
  })
  local draws = 0
  for _, name in ipairs({ "set", "fill", "copy", "setResolution",
    "setForeground", "setBackground" }) do
    draws = draws + gctl.count(name)
  end
  return { code = code, calls = draws, opened = opened,
    views = #rec.views, text = #rec.out > 0 }
end

local NO_DRAW = { code = 0, calls = 0, opened = false, views = 0, text = true }

t.cases(T, "loading_print_draws_nothing", {
  { "--print", { "--print", "page.html" }, NO_DRAW },
  { "--width turns on --print", { "--width", "20", "page.html" }, NO_DRAW },
}, function(args) return print_run(args, false) end)

t.cases(T, "loading_no_screen_draws_nothing", {
  { "no GPU: the text prints", { "page.html" }, NO_DRAW },
}, function(args) return print_run(args, true) end)

-- spec/guard.md "Size check before reading": with no known size there is no
-- check before reading, so no settle (each settle sleeps).
framed_cases("loading_settle_only_with_a_known_size", {
  { "page without Content-Length: no settle sleeps",
    { args = { URL }, card = { default = served(PAGE, 100) } },
    { code = 0, sleeps = 0 } },
  { "page with Content-Length: the settle sleeps",
    { args = { URL }, card = { default = with_length(PAGE, 100) } },
    { code = 0, sleeps = 11 } },
})

return T
