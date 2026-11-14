-- Tests for the entry point in bin/html.lua: modes, file checks, Ctrl+C,
-- exit codes and the cleanup on every exit path.

local t = require("test")

local T = {}

local html = t.load_bin("html")({})
local guard = require("html.guard")

local PAGE = "<html><head><title>My Page</title></head><body>"
  .. "<h1>Head</h1><p>Some text in a paragraph.</p></body></html>"

-- A page with many tokens, so the guard ticks after the second read.
local LONG = string.rep("<p>word word word word word</p>\n", 1000)

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

-- Runs main with a fake file and fake viewer deps. extra replaces deps.
-- Returns the exit code and a record: out, err, events (in order), views
-- (the lines and opts of each viewer call), the file state and the
-- listener counts.
local function run(args, text, extra)
  local rec = { out = {}, err = {}, events = {}, views = {}, listens = 0,
    removes = 0 }
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

-- Checks that the listener is gone and the guard has no interrupt check.
local function check_clean(rec)
  t.eq(rec.removes, rec.listens, "listener removed")
  local ok = pcall(guard.tick)
  t.ok(ok, "guard has no interrupt check")
  t.ok(rec.file.closed or rec.file.reads == 0, "file closed")
end

local function max_width(lines)
  local wlen = require("unicode").wlen
  local w = 0
  for _, line in ipairs(lines) do
    w = math.max(w, wlen((line:gsub("[\1-\5]", ""))))
  end
  return w
end

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
  t.ok(#v.lines > 0)
  t.ok(rec.file.closed, "file closed before the viewer")
  check_clean(rec)
end

function T.viewer_lines_keep_style_bytes()
  local _, rec = run({ "page.html" })
  t.ok(rec.views[1].lines[1]:find("[\1-\5]"), "style bytes kept")
end

function T.viewer_width_is_the_max_resolution()
  local _, rec = run({ "page.html" }, LONG)
  t.eq(max_width(rec.views[1].lines) <= 60, true)
  local _, wide = run({ "page.html" }, string.rep("word ", 200))
  t.eq(max_width(wide.views[1].lines), 59, "wraps at 60 columns")
end

function T.no_rescale_uses_the_current_resolution()
  local code, rec = run({ "--no-rescale", "page.html" },
    string.rep("word ", 200))
  t.eq(code, 0)
  t.eq(rec.views[1].opts.no_rescale, true)
  t.eq(max_width(rec.views[1].lines), 39, "wraps at 40 columns")
end

function T.page_without_title_shows_the_file_name()
  local _, rec = run({ "page.html" }, "<p>x</p>")
  t.eq(rec.views[1].opts.title, nil)
  t.eq(rec.views[1].opts.file, "page.html")
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
  t.ok(max_width(rec.out) <= 50, "term width")
  check_clean(rec)
end

function T.width_sets_print()
  local code, rec = run({ "--width", "20", "page.html" },
    string.rep("word ", 50))
  t.eq(code, 0)
  t.eq(#rec.views, 0)
  t.eq(max_width(rec.out), 19)
end

function T.no_gpu_or_screen_falls_back_to_print()
  for _, gpu in ipairs({ false, fake_gpu({ 60, 20 }, { 40, 10 }, nil),
      { getScreen = function() error("no gpu") end } }) do
    local code, rec = run({ "page.html" }, nil, { gpu = gpu })
    t.eq(code, 0)
    t.eq(#rec.views, 0)
    t.eq(rec.err, { "html: no screen found, printing the text" })
    t.ok(#rec.out > 0)
    check_clean(rec)
  end
end

function T.stats_print_after_the_viewer_returns()
  local code, rec = run({ "--stats", "page.html" })
  t.eq(code, 0)
  t.eq(rec.events[1], "view")
  t.ok(#rec.err > 0)
  for i = 2, #rec.events do
    t.eq(rec.events[i], "err")
  end
  t.ok(rec.err[1]:find("^stats: file="), rec.err[1])
  t.eq(rec.err[2], "stats: width=60")
end

function T.stats_out_in_viewer_mode()
  local written
  local code, rec = run({ "--stats-out", "s.txt", "page.html" }, nil, {
    write_file = function(_, text) written = text return true end,
  })
  t.eq(code, 0)
  t.eq(written, table.concat(rec.err, "\n") .. "\n")
end

function T.missing_file_gives_one_line()
  local opened = false
  local code, rec = run({ "nope.html" }, nil, {
    exists = function() return false end,
    open = function() opened = true end,
  })
  t.eq(code, 1)
  t.eq(rec.err, { "html: file not found: nope.html" })
  t.eq(opened, false)
  t.eq(rec.listens, 0)
end

function T.directory_gives_one_line()
  local code, rec = run({ "dir" }, nil, {
    exists = function() return true end,
    is_dir = function() return true end,
  })
  t.eq(code, 1)
  t.eq(rec.err, { "html: not a file: dir" })
  t.eq(#rec.views, 0)
end

function T.empty_file_shows_an_empty_page()
  local code, rec = run({ "empty.html" }, "")
  t.eq(code, 0)
  t.eq(rec.err, {})
  t.eq(#rec.views, 1)
  t.eq(rec.views[1].lines, {})
  t.eq(rec.views[1].opts.file, "empty.html")
  code, rec = run({ "--print", "empty.html" }, "")
  t.eq(code, 0)
  t.eq(rec.out, {})
  t.eq(rec.err, {})
end

function T.oversized_file_stops_before_reading()
  -- The shim gives 1800000 free. 0.5 units per byte cannot fit 4000000.
  local code, rec = run({ "--stats", "big.html" }, nil, {
    size = function() return 4000000 end,
  })
  t.eq(code, 1)
  t.eq(rec.err[1], "html: file too large for available memory "
    .. "(4000000 bytes, 1800000 free)")
  t.eq(rec.file.reads, 0)
  t.eq(#rec.views, 0)
  t.eq(rec.err[#rec.err], "stats: stopped=" .. rec.err[1])
  check_clean(rec)
end

function T.file_just_under_the_size_limit_renders()
  local code, rec = run({ "page.html" }, nil, {
    size = function() return 3600000 end,
  })
  t.eq(code, 0)
  t.eq(#rec.views, 1)
end

-- The run helper returns rec only at the end, so the hooks reach the
-- listener through this upvalue.
---@class Listener
---@field interrupt function
---@field removes integer
---@field count integer?

---@type Listener
local current = { interrupt = function() end, removes = 0 }

local function capture_listener(fn)
  current = { interrupt = fn, removes = 0 }
  return function() current.removes = current.removes + 1 end
end

function T.ctrl_c_during_the_render_stops_with_130()
  local code, rec = run({ "page.html" }, LONG, {
    on_read = function(n)
      if n == 2 then
        current.interrupt("interrupted")
      end
    end,
    on_interrupt = capture_listener,
  })
  t.eq(code, 130)
  t.eq(rec.err, { "html: interrupted" })
  t.eq(#rec.views, 0)
  t.ok(rec.file.reads < 5, "stopped early: " .. rec.file.reads .. " reads")
  t.eq(current.removes, 1)
  check_clean(rec)
end

function T.ctrl_c_at_the_last_read_stops_before_the_viewer()
  local code, rec = run({ "--stats", "page.html" }, PAGE, {
    on_read = function(n)
      if n == 2 then
        current.interrupt()
      end
    end,
    on_interrupt = capture_listener,
  })
  t.eq(code, 130)
  t.eq(rec.err[1], "html: interrupted")
  t.eq(rec.err[#rec.err], "stats: stopped=html: interrupted")
  t.eq(#rec.views, 0)
  t.eq(current.removes, 1)
end

function T.ctrl_c_during_print_output_stops_with_130()
  local code, rec = run({ "--print", "page.html" }, LONG, {
    out = function()
      current.count = (current.count or 0) + 1
      current.interrupt()
    end,
    on_interrupt = capture_listener,
  })
  t.eq(code, 130)
  t.eq(rec.err, { "html: interrupted" })
  t.eq(current.count, 1)
  t.eq(current.removes, 1)
end

function T.listener_removed_before_the_viewer()
  local code = run({ "page.html" }, nil, {
    on_interrupt = capture_listener,
    view = function()
      t.eq(current.removes, 1)
      current.interrupt()
      return "quit"
    end,
  })
  t.eq(code, 0, "a late flag does not change a normal quit")
end

function T.ctrl_c_in_the_viewer_exits_with_130()
  local code, rec = run({ "page.html" }, nil, {
    view = function() return "interrupted" end,
  })
  t.eq(code, 130)
  t.eq(rec.err, {})
  check_clean(rec)
end

function T.viewer_error_gives_one_line_log_and_exit_1()
  local logged
  local code, rec = run({ "--stats", "page.html" }, nil, {
    view = function() error("boom\nmore") end,
    log = function(text) logged = text return true end,
  })
  t.eq(code, 1)
  t.ok(rec.err[1]:find("^html: unexpected error: .*boom %(details in "
    .. "/tmp/html%-error%.log%)$"), rec.err[1])
  t.ok(logged:find("stack traceback"), "traceback logged")
  t.ok(rec.err[#rec.err]:find("^stats: stopped=html: unexpected error: "),
    rec.err[#rec.err])
  check_clean(rec)
end

function T.viewer_controlled_error_prints_as_it_is()
  local code, rec = run({ "page.html" }, nil, {
    view = function() error("html: screen lost", 0) end,
  })
  t.eq(code, 1)
  t.eq(rec.err, { "html: screen lost" })
end

function T.render_error_removes_the_listener()
  local code, rec = run({ "page.html" }, nil, {
    open = function()
      return { read = function() error("disk") end,
        seek = function() return 10 end, close = function() end }
    end,
  })
  t.eq(code, 1)
  t.ok(rec.err[1]:find("^html: unexpected error: .*disk"), rec.err[1])
  t.eq(rec.removes, 1)
  t.ok(pcall(guard.tick), "guard has no interrupt check")
end

function T.usage_lists_every_option()
  for _, flag in ipairs({ "--print", "--width", "--stats", "--stats-out",
      "--no-rescale", "--help" }) do
    t.ok(html.USAGE:find(flag, 1, true), flag)
  end
end

function T.parse_args_modes()
  t.eq(html.parse_args({ "a", n = 1 }).print, nil)
  t.eq(html.parse_args({ "--print", "a", n = 2 }).print, true)
  local o = html.parse_args({ "--width", "30", "a", n = 3 })
  t.eq(o.print, true)
  t.eq(o.width, 30)
  t.eq(html.parse_args({ "--no-rescale", "a", n = 2 }).no_rescale, true)
end

-- URL arguments -------------------------------------------------------------

local internet = require("internet")
local computer = require("computer")

local URL = "http://example.com/"

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

local function url_clean(rec)
  check_clean(rec)
  for i, h in ipairs(rec.ctl.handles) do
    t.eq(h.closed, 1, "handle " .. i .. " closed once")
  end
end

-- The stats line that starts with prefix, or nil.
local function stats_line(rec, prefix)
  for _, line in ipairs(rec.err) do
    if line:sub(1, #prefix) == prefix then
      return line
    end
  end
  return nil
end

function T.url_opens_the_viewer()
  local code, rec = run_url({ URL }, { default = page_script() })
  t.eq(code, 0)
  t.eq(rec.err, {})
  t.eq(#rec.views, 1)
  t.eq(rec.views[1].opts.title, "My Page")
  t.eq(rec.views[1].opts.file, URL)
  t.eq(rec.ctl.requests, { URL })
  url_clean(rec)
end

function T.url_without_title_shows_the_url()
  local _, rec = run_url({ "https://x.org/a#f" },
    { default = page_script("<p>x</p>") })
  t.eq(rec.views[1].opts.title, nil)
  t.eq(rec.views[1].opts.file, "https://x.org/a")
end

function T.url_title_shows_the_final_url_after_a_redirect()
  local _, rec = run_url({ URL }, { routes = {
    [URL] = { code = 301, headers = { Location = { "/new" } } },
    ["http://example.com/new"] = page_script("<p>x</p>") } })
  t.eq(rec.views[1].opts.file, "http://example.com/new")
  url_clean(rec)
end

function T.url_with_print_width_and_stats()
  local code, rec = run_url({ "--print", "--width", "30", "--stats", URL },
    { default = page_script() })
  t.eq(code, 0)
  t.eq(#rec.views, 0)
  t.ok(#rec.out > 0)
  t.ok(max_width(rec.out) <= 30)
  t.eq(rec.err[1], "stats: file=" .. #PAGE .. " bytes")
  t.eq(rec.err[2], "stats: url=" .. URL)
  t.ok(rec.err[3]:find("^stats: http=200 redirects=0 fetch=%d+%.%d%d s$"),
    rec.err[3])
  t.eq(rec.err[4], "stats: width=30")
  url_clean(rec)
end

function T.url_with_stats_out_and_no_rescale()
  local written
  local code, rec = run_url({ "--no-rescale", "--stats-out", "s.txt", URL },
    { default = page_script() }, {
      write_file = function(_, text) written = text return true end,
    })
  t.eq(code, 0)
  t.eq(rec.views[1].opts.no_rescale, true)
  t.eq(written, table.concat(rec.err, "\n") .. "\n")
  t.ok(written:find("stats: url=" .. URL, 1, true))
end

function T.url_usage_errors_exit_2()
  local long = "http://example.com/" .. string.rep("a", 2048)
  local cases = {
    { "ftp://example.com", "html: unsupported URL scheme: ftp" },
    { "http://exa mple.com", "html: invalid URL: http://exa mple.com" },
    { "http://", "html: invalid URL: http://" },
    { long, "html: invalid URL: too long" },
  }
  for _, c in ipairs(cases) do
    local code, rec = run_url({ c[1] }, {})
    t.eq(code, 2, c[1])
    t.eq(rec.err, { c[2] }, c[1])
    t.eq(#rec.ctl.requests, 0)
  end
end

function T.url_without_a_card()
  local code, rec = run_url({ URL }, {}, { internet = false })
  t.eq(code, 1)
  t.eq(rec.err, { "html: no internet card found (needed for " .. URL .. ")" })
  t.eq(#rec.views, 0)
  check_clean(rec)
end

function T.url_with_http_disabled()
  local code, rec = run_url({ URL }, { http = false })
  t.eq(code, 1)
  t.eq(rec.err, { "html: HTTP requests are disabled on this server" })
end

function T.url_size_check_with_content_length()
  local code, rec = run_url({ "--stats", URL }, { default = page_script(nil,
    { headers = { ["Content-Length"] = { "4000000" } } }) })
  t.eq(code, 1)
  t.eq(rec.err[1], "html: page too large for available memory "
    .. "(4000000 bytes, 1800000 free)")
  t.eq(rec.ctl.handles[1].reads, 0)
  t.eq(rec.err[#rec.err], "stats: stopped=" .. rec.err[1])
  t.eq(stats_line(rec, "stats: file="), "stats: file=0 bytes")
  url_clean(rec)
end

function T.url_fetch_error_with_stats()
  local code, rec = run_url({ "--stats", URL },
    { default = { connect_error = "unknown host" } })
  t.eq(code, 1)
  local msg = "html: cannot connect: " .. URL .. ": unknown host"
  t.eq(rec.err[1], msg)
  t.eq(stats_line(rec, "stats: url="), "stats: url=" .. URL)
  t.ok(stats_line(rec, "stats: http="):find("^stats: http=n/a redirects=0 "
    .. "fetch="), stats_line(rec, "stats: http="))
  t.eq(rec.err[#rec.err], "stats: stopped=" .. msg)
  url_clean(rec)
end

function T.url_read_error_exit_1()
  local code, rec = run_url({ "--print", URL }, { default =
    page_script(PAGE, { read_error = "reset" }) })
  t.eq(code, 1)
  t.eq(rec.err, { "html: read error: reset" })
  url_clean(rec)
end

function T.url_content_type_error()
  local code, rec = run_url({ URL }, { default = { headers =
    { ["Content-Type"] = { "application/pdf" } } } })
  t.eq(code, 1)
  t.eq(rec.err, { "html: not an HTML page: application/pdf" })
  url_clean(rec)
end

function T.url_ctrl_c_during_connect()
  local code, rec = run_url({ URL }, { default = { connect_polls = 100 } }, {
    on_interrupt = capture_listener,
    sleep = function(s) current.interrupt() os.sleep(s) end,
  })
  t.eq(code, 130)
  t.eq(rec.err, { "html: interrupted" })
  t.eq(current.removes, 1)
  url_clean(rec)
end

function T.url_ctrl_c_during_the_body()
  local body = { "<p>a</p>" }
  for _ = 1, 20 do
    body[#body + 1] = ""
  end
  local code, rec = run_url({ "--stats", URL }, { default = { body = body,
    endless = true } }, {
    on_interrupt = capture_listener,
    sleep = function(s) current.interrupt() os.sleep(s) end,
  })
  t.eq(code, 130)
  t.eq(rec.err[1], "html: interrupted")
  t.eq(rec.err[#rec.err], "stats: stopped=html: interrupted")
  url_clean(rec)
end

function T.url_event_interrupt_error_closes_the_handle()
  local code, rec = run_url({ URL }, { default = { connect_polls = 5 } }, {
    sleep = function() error("interrupted", 0) end,
  })
  t.eq(code, 130)
  t.eq(rec.err, { "html: interrupted" })
  url_clean(rec)
end

-- Error status --------------------------------------------------------------

function T.error_status_in_the_viewer()
  local code, rec = run_url({ URL }, { default = page_script(
    "<title>Oops</title><p>gone</p>", { code = 404, message = "Not Found" }) })
  t.eq(code, 0)
  t.eq(rec.err, {})
  t.eq(rec.views[1].opts.title, "[HTTP 404] Oops")
  url_clean(rec)
  code, rec = run_url({ URL }, { default = page_script("<p>gone</p>",
    { code = 500 }) })
  t.eq(code, 0)
  t.eq(rec.views[1].opts.title, "[HTTP 500] " .. URL)
end

function T.error_status_in_print_mode()
  local code, rec = run_url({ "--print", "--stats", URL }, { default =
    page_script("<p>gone</p>", { code = 404, message = "Not Found" }) })
  t.eq(code, 0)
  t.eq(rec.err[1], "html: HTTP 404 Not Found: " .. URL)
  t.eq(rec.events[1], "err")
  t.eq(rec.events[2], "out")
  t.eq(rec.out, { "gone" })
  t.ok(stats_line(rec, "stats: http=404 redirects=0 fetch="))
  t.eq(stats_line(rec, "stats: stopped="), nil)
end

function T.error_status_short_page_in_print_mode()
  local code, rec = run_url({ "--print", URL }, { default = { code = 503,
    message = "Unavailable", body = {} } })
  t.eq(code, 0)
  t.eq(rec.err, { "html: HTTP 503 Unavailable: " .. URL })
  t.eq(rec.out, { "HTTP 503 Unavailable", "", URL })
end

function T.error_status_read_error_after_the_text()
  local code, rec = run_url({ "--print", URL }, { default = page_script(
    "<p>part</p>", { code = 500, message = "Err", read_error = "reset" }) })
  t.eq(code, 0)
  t.eq(rec.err, { "html: HTTP 500 Err: " .. URL, "html: read error: reset" })
  t.eq(rec.events[#rec.events], "err")
  t.eq(rec.out, { "part" })
  code, rec = run_url({ URL }, { default = page_script("<p>part</p>",
    { code = 500, read_error = "reset" }) })
  t.eq(code, 0)
  t.eq(rec.events, { "view", "err" })
  t.eq(rec.err, { "html: read error: reset" })
end

-- Arguments without a scheme ------------------------------------------------

-- Runs one argument with a fake exists. Returns "local", "url <requested>",
-- or the error line, and the exit code.
local function classify(arg, exists)
  local code, rec = run_url({ arg }, { default = page_script() }, {
    exists = function() return exists end,
  })
  if #rec.ctl.requests > 0 then
    return "url " .. rec.ctl.requests[1], code
  end
  if code == 0 and #rec.views == 1 then
    return "local", code
  end
  return rec.err[1], code
end

function T.arguments_without_a_scheme()
  local nf = "html: file not found: "
  local cases = {
    { "./x.html", true, "local" },
    { "./x.html", false, nf .. "./x.html" },
    { "x.html", true, "local" },
    { "x.html", false, nf .. "x.html" },
    { "dir/x.html", false, nf .. "dir/x.html" },
    { "dir/example.com", false, nf .. "dir/example.com" },
    { "example.com", true, "local" },
    { "example.com", false, "url http://example.com" },
    { "EXAMPLE.COM", false, "url http://EXAMPLE.COM" },
    { "example.com/path", false, "url http://example.com/path" },
    { "example.com/", false, "url http://example.com/" },
    { "example.com:8080/a?b=1", false, "url http://example.com:8080/a?b=1" },
    { "example.com#top", false, "url http://example.com" },
    { "localhost", false, "url http://localhost" },
    { "localhost:8080", false, "url http://localhost:8080" },
    { "192.168.0.1", false, "url http://192.168.0.1" },
    { "foo", false, nf .. "foo" },
    { "foo:8080", false, nf .. "foo:8080" },
    { "example..com", false, nf .. "example..com" },
    { "a.-b.com", false, nf .. "a.-b.com" },
    { "example.com:", false, nf .. "example.com:" },
    { "example.com:0", false, nf .. "example.com:0" },
    { "example.com:99999", false, nf .. "example.com:99999" },
    { "exa mple.com", false, nf .. "exa mple.com" },
    { "ex\195\164mple.com", false, nf .. "ex\195\164mple.com" },
    { "~/example.com", false, nf .. "~/example.com" },
  }
  for _, c in ipairs(cases) do
    local got, code = classify(c[1], c[2])
    t.eq(got, c[3], c[1] .. " exists=" .. tostring(c[2]))
    t.eq(code, got:sub(1, 6) == "html: " and 1 or 0, c[1])
  end
  local code, rec = run_url({ "ftp://example.com" }, {}, {
    exists = function() error("not checked") end,
  })
  t.eq(code, 2)
  t.eq(rec.err, { "html: unsupported URL scheme: ftp" })
end

function T.guessed_url_errors_name_the_argument()
  local suffix = " (no local file named example.com)"
  local code, rec = run_url({ "example.com" }, { default =
    { connect_error = "refused" } }, { exists = function() return false end })
  t.eq(code, 1)
  t.eq(rec.err, { "html: cannot connect: http://example.com: refused"
    .. suffix })
  code, rec = run_url({ "--print", "example.com" }, { default =
    page_script(PAGE, { read_error = "reset" }) },
    { exists = function() return false end })
  t.eq(rec.err, { "html: read error: reset" .. suffix })
  code, rec = run_url({ "example.com" }, {}, { internet = false,
    exists = function() return false end })
  t.eq(rec.err, { "html: no internet card found (needed for "
    .. "http://example.com)" .. suffix })
end

function T.usage_lists_the_url_forms()
  t.ok(html.USAGE:find("http://", 1, true))
  t.ok(html.USAGE:find("https://", 1, true))
end

-- A fake package.loaded with html modules and one other module.
local function fake_loaded()
  return { ["html.guard"] = {}, ["html.viewer"] = {}, computer = {} }
end

function T.module_cache_cleared_on_every_path()
  local cases = {
    { args = { "page.html" }, code = 0 },
    { args = { "page.html" }, code = 130,
      view = function() return "interrupted" end },
    { args = { "page.html" }, code = 1, view = function() error("boom") end },
    { args = { "nope.html" }, code = 1, exists = function() return false end },
    { args = { "--bad" }, code = 2 },
  }
  for i, c in ipairs(cases) do
    local loaded = fake_loaded()
    local file = fake_file(PAGE)
    local code = html.run_program(c.args, function()
      return {
        out = function() end, err = function() end, width = 50,
        open = function() return file end,
        traceback = function(msg) return msg end, clock = os.clock,
        gpu = fake_gpu({ 60, 20 }, { 40, 10 }, "screen"),
        view = c.view or function() return "quit" end,
        exists = c.exists,
        on_interrupt = function() return function() end end,
      }
    end, loaded)
    t.eq(code, c.code, "case " .. i)
    t.eq(loaded["html.guard"], nil, "case " .. i)
    t.eq(loaded["html.viewer"], nil, "case " .. i)
    t.ok(loaded.computer, "case " .. i)
  end
end

return T
