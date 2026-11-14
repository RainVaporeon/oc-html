-- Tests for lib/html/viewer.lua with a fake GPU and a fake event queue.

local t = require("test")
local viewer = require("html.viewer")
local fake_gpu = require("gpu")
local unicode = require("unicode")

local T = {}

local UP, DOWN, PGUP, PGDN, HOME, END = 200, 208, 201, 209, 199, 207
local NP_HOME, NP_UP, NP_PGUP, NP_END, NP_DOWN, NP_PGDN = 71, 72, 73, 79,
  80, 81

local function key(code, char)
  return { "key_down", "kbd", char or 0, code, "player" }
end

local Q = key(16, 113)
local Y = key(21, 121)
local N = key(49, 110)
local ENTER = key(28, 13)
local ESC = key(1, 0)
local CTRL_C = key(46, 3)
local INTERRUPTED = { "interrupted" }

-- "\1line N" for N = 1 to n.
local function make_lines(n)
  local lines = {}
  for i = 1, n do
    lines[i] = "\1line " .. i
  end
  return lines
end

-- Returns a pull function. A table item is an event. A function item runs
-- at the next blocking pull, so it sees the screen after a draw.
local function queue(items)
  local i = 1
  local pulls = {}
  local function pull(timeout)
    pulls[#pulls + 1] = timeout
    while true do
      local item = items[i]
      if item == nil then
        if timeout == 0 then
          return nil
        end
        error("test: event queue empty", 0)
      end
      if type(item) == "function" then
        if timeout == 0 then
          return nil
        end
        i = i + 1
        item()
      else
        i = i + 1
        return table.unpack(item)
      end
    end
  end
  return pull, pulls
end

local function fake_term()
  local term = { cleared = 0 }
  function term.clear()
    term.cleared = term.cleared + 1
  end
  function term.setCursor(x, y)
    term.cursor = { x, y }
  end
  return term
end

-- Runs the viewer. o: lines, opts, events, gpu (options for the fake GPU).
-- Returns the result, the GPU control, the term and the GPU proxy.
local function run(o)
  local gpu, ctl = fake_gpu.new(o.gpu or { width = 80, height = 25,
    max_width = 80, max_height = 25 })
  local term = fake_term()
  local pull = queue(o.events)
  local result = viewer.run(o.lines, o.opts or {}, {
    gpu = gpu, pull = pull, term = term,
  })
  return result, ctl, term, gpu
end

-- The number of the first line shown on screen, read from row 1.
local function top_line(ctl)
  return tonumber(ctl.row(1):match("^line (%d+)"))
end

-- Runs the events, then records the top line and quits.
local function top_after(events, n, size)
  local top
  local ctl_ref = {}
  local list = {}
  for _, e in ipairs(events) do
    list[#list + 1] = e
  end
  list[#list + 1] = function() top = top_line(ctl_ref.ctl) end
  list[#list + 1] = Q
  list[#list + 1] = Y
  local gpu, ctl = fake_gpu.new(size or { width = 80, height = 25,
    max_width = 80, max_height = 25 })
  ctl_ref.ctl = ctl
  viewer.run(make_lines(n), {}, {
    gpu = gpu, pull = (queue(list)), term = fake_term(),
  })
  return top
end

-- Scroll keys: 80x25 has 24 text rows, a page is 23 lines.

function T.down_and_up_move_one_line()
  t.eq(top_after({ key(DOWN) }, 100), 2)
  t.eq(top_after({ key(DOWN), key(DOWN), key(UP) }, 100), 2)
end

function T.page_keys_move_one_screen_with_overlap()
  t.eq(top_after({ key(PGDN) }, 100), 24)
  t.eq(top_after({ key(PGDN), key(PGDN), key(PGUP) }, 100), 24)
end

function T.home_and_end()
  t.eq(top_after({ key(END) }, 100), 77)
  t.eq(top_after({ key(END), key(HOME) }, 100), 1)
end

function T.clamps_at_start_and_end()
  t.eq(top_after({ key(UP) }, 100), 1)
  t.eq(top_after({ key(PGUP) }, 100), 1)
  t.eq(top_after({ key(END), key(DOWN) }, 100), 77)
  t.eq(top_after({ key(PGDN), key(PGDN), key(PGDN), key(PGDN) }, 100), 77)
  t.eq(top_after({ key(DOWN), key(END) }, 10), 1)
end

-- Each event is pulled alone, so no coalescing changes the clamp.
function T.clamps_with_separate_draws()
  local draws = {}
  for _ = 1, 30 do
    draws[#draws + 1] = key(PGDN)
    draws[#draws + 1] = function() end
  end
  t.eq(top_after(draws, 100), 77)
end

function T.numpad_with_char_0_navigates()
  t.eq(top_after({ key(NP_DOWN) }, 100), 2)
  t.eq(top_after({ key(NP_DOWN), key(NP_DOWN), key(NP_UP) }, 100), 2)
  t.eq(top_after({ key(NP_PGDN) }, 100), 24)
  t.eq(top_after({ key(NP_PGDN), key(NP_PGDN), key(NP_PGUP) }, 100), 24)
  t.eq(top_after({ key(NP_END) }, 100), 77)
  t.eq(top_after({ key(NP_END), key(NP_HOME) }, 100), 1)
end

function T.numpad_with_digit_char_does_not_navigate()
  t.eq(top_after({ key(NP_PGDN, 51) }, 100), 1)
  t.eq(top_after({ key(NP_DOWN, 50) }, 100), 1)
  t.eq(top_after({ key(NP_END, 49) }, 100), 1)
  t.eq(top_after({ key(END), key(NP_PGUP, 57) }, 100), 77)
  t.eq(top_after({ key(END), key(NP_UP, 56) }, 100), 77)
  t.eq(top_after({ key(END), key(NP_HOME, 55) }, 100), 77)
end

function T.coalesces_queued_scroll_events()
  local events = {}
  for _ = 1, 20 do
    events[#events + 1] = key(DOWN)
    events[#events + 1] = { "key_up", "kbd", 0, DOWN, "player" }
  end
  events[#events + 1] = Q
  events[#events + 1] = Y
  local _, ctl = run({
    lines = make_lines(200), events = events,
    gpu = { width = 160, height = 50, max_width = 160, max_height = 50 },
  })
  local copies = ctl.find("copy")
  t.eq(#copies, 1)
  t.eq(copies[1], { "copy", 1, 21, 160, 29, 0, -20 })
end

function T.burst_larger_than_a_screen_redraws_once()
  local events = {}
  for _ = 1, 30 do
    events[#events + 1] = key(DOWN)
  end
  local status_sets
  events[#events + 1] = function() end
  events[#events + 1] = Q
  events[#events + 1] = Y
  local _, ctl = run({ lines = make_lines(200), events = events })
  t.eq(ctl.count("copy"), 0)
  status_sets = 0
  for _, c in ipairs(ctl.find("set")) do
    if c[3] == 25 then
      status_sets = status_sets + 1
    end
  end
  -- Start, one scroll, the quit prompt.
  t.eq(status_sets, 3)
end

-- A copy scroll must give the same screen as a full redraw at that line.
local function styled_lines(n)
  local lines = {}
  for i = 1, n do
    if i % 3 == 0 then
      lines[i] = ""
    else
      lines[i] = "\2head " .. i .. "\1 text \4link\1 end"
    end
  end
  return lines
end

local function screen_with_colors(ctl, rows, w)
  local out = {}
  for y = 1, rows do
    local row = {}
    for x = 1, w do
      local ch, fg, bg = ctl.cell(x, y)
      row[x] = ch .. ":" .. fg .. ":" .. bg
    end
    out[y] = table.concat(row, ",")
  end
  return out
end

local function scrolled_screen(lines, events)
  local snap
  local ctl_ref = {}
  local list = {}
  for _, e in ipairs(events) do
    list[#list + 1] = e
  end
  list[#list + 1] = function() snap = screen_with_colors(ctl_ref.ctl, 24, 80) end
  list[#list + 1] = Q
  list[#list + 1] = Y
  local gpu, ctl = fake_gpu.new({ width = 80, height = 25, max_width = 80,
    max_height = 25 })
  ctl_ref.ctl = ctl
  viewer.run(lines, {}, { gpu = gpu, pull = (queue(list)),
    term = fake_term() })
  return snap, ctl
end

function T.copy_scroll_matches_full_redraw()
  local lines = styled_lines(100)
  for _, case in ipairs({
    { events = { key(DOWN) }, top = 2, copies = 1 },
    { events = { key(DOWN), key(DOWN), key(DOWN) }, top = 4, copies = 1 },
    { events = { key(PGDN) }, top = 24, copies = 1 },
    { events = { key(PGDN), function() end, key(UP) }, top = 23, copies = 2 },
    { events = { key(PGDN), function() end, key(PGUP) }, top = 1, copies = 2 },
  }) do
    local snap, ctl = scrolled_screen(lines, case.events)
    t.eq(ctl.count("copy"), case.copies, "copies to " .. case.top)
    local shifted = {}
    for i = case.top, #lines do
      shifted[#shifted + 1] = lines[i]
    end
    local fresh = scrolled_screen(shifted, {})
    t.eq(snap, fresh, "screen at line " .. case.top)
  end
end

function T.one_line_scroll_draws_only_the_exposed_row()
  local seen
  local gpu, ctl = fake_gpu.new({ width = 80, height = 25, max_width = 80,
    max_height = 25 })
  local events = {
    function() ctl.clear_log() end,
    key(DOWN),
    function()
      seen = {}
      for _, c in ipairs(ctl.find("set")) do
        seen[c[3]] = true
      end
      for _, c in ipairs(ctl.find("fill")) do
        seen[c[3]] = true
      end
    end,
    Q, Y,
  }
  viewer.run(make_lines(100), {}, { gpu = gpu, pull = (queue(events)),
    term = fake_term() })
  t.eq(seen, { [24] = true, [25] = true })
end

function T.exposed_row_has_new_text_after_copy()
  local snap
  local gpu, ctl = fake_gpu.new({ width = 80, height = 25, max_width = 80,
    max_height = 25 })
  local events = {
    key(DOWN),
    function() snap = { ctl.row(1), ctl.row(23), ctl.row(24) } end,
    Q, Y,
  }
  viewer.run(make_lines(100), {}, { gpu = gpu, pull = (queue(events)),
    term = fake_term() })
  t.eq(snap[1]:match("^line %d+"), "line 2")
  t.eq(snap[2]:match("^line %d+"), "line 24")
  t.eq(snap[3]:match("^line %d+"), "line 25")
end

-- Colors.

local function fg_calls(ctl)
  return #ctl.find("setForeground")
end

function T.foreground_changes_only_on_style_change()
  local lines = {
    "\1aaa\1bbb\1ccc",   -- same style: no change
    "\1ddd",             -- same style
    "\2head",            -- change 1
    "\2more",            -- same
    "\1x\4link\1y",      -- changes 2, 3, 4
  }
  local _, ctl = run({ lines = lines, events = { Q, Y } })
  -- Draw: NORMAL first (1), then 4 changes, the status line (1), the quit
  -- prompt keeps the status colors, restore (1).
  t.eq(fg_calls(ctl), 7)
  t.eq(#ctl.find("setBackground"), 3)
end

function T.depth_8_and_4_use_rgb_colors_per_style()
  for _, depth in ipairs({ 8, 4 }) do
    local snap
    local gpu, ctl = fake_gpu.new({ width = 80, height = 25, max_width = 80,
      max_height = 25, depth = depth })
    local lines = { "\1n\2h\3e\4l\5p" }
    viewer.run(lines, {}, { gpu = gpu, term = fake_term(), pull = (queue({
      function()
        snap = {}
        for x = 1, 5 do
          local _, fg, bg = ctl.cell(x, 1)
          snap[x] = { fg, bg }
        end
        local _, sfg, sbg = ctl.cell(1, 25)
        snap.status = { sfg, sbg }
      end, Q, Y })) })
    t.eq(snap, {
      { 0xFFFFFF, 0 }, { 0xFFFF33, 0 }, { 0xFFCC33, 0 }, { 0x6699FF, 0 },
      { 0x33CC33, 0 }, status = { 0x000000, 0xFFFFFF },
    }, "depth " .. depth)
    for _, c in ipairs(ctl.find("setForeground")) do
      t.ok(not c[3], "no palette index")
    end
  end
end

function T.depth_1_is_plain_text()
  local _, ctl = run({
    lines = { "\1n\2h\3e\4l\5p", "\2head" },
    events = { Q, Y },
    gpu = { width = 50, height = 16, max_width = 50, max_height = 16,
      depth = 1 },
  })
  -- One set at start, one restore.
  t.eq(fg_calls(ctl), 2)
  t.eq(#ctl.find("setBackground"), 2)
  t.eq(ctl.find("set")[1], { "set", 1, 1, "n" })
end

function T.sizes_and_depths()
  for _, size in ipairs({ { 160, 50 }, { 80, 25 }, { 50, 16 } }) do
    for _, depth in ipairs({ 8, 4, 1 }) do
      local w, h = size[1], size[2]
      local snap
      local gpu, ctl = fake_gpu.new({ width = w, height = h, max_width = w,
        max_height = h, depth = depth })
      local events = {
        function() snap = ctl.screen() end,
        key(END),
        function()
          t.eq(top_line(ctl), 200 - (h - 1) + 1)
          t.ok(ctl.row(h):find("100%", 1, true), "status at end")
        end,
        Q, Y,
      }
      local result = viewer.run(make_lines(200), { title = "Page" }, {
        gpu = gpu, pull = (queue(events)), term = fake_term() })
      local label = w .. "x" .. h .. " depth " .. depth
      t.eq(result, "quit", label)
      t.eq(#snap, h, label)
      t.eq(snap[1], "line 1" .. string.rep(" ", w - 6), label)
      t.eq(snap[h - 1]:match("^line %d+"), "line " .. (h - 1), label)
      t.ok(snap[h]:find("^ Page "), label)
      t.ok(snap[h]:find("  0%", 1, true), label)
      t.eq(ctl.overflow, false, label)
    end
  end
end

-- Resolution.

function T.rescales_to_max_and_restores()
  local seen
  local gpu, ctl = fake_gpu.new({ width = 120, height = 60, max_width = 160,
    max_height = 50 })
  local events = {
    function() seen = { gpu.getResolution() } end,
    Q, Y,
  }
  viewer.run(make_lines(10), {}, { gpu = gpu, pull = (queue(events)),
    term = fake_term() })
  t.eq(seen, { 160, 50 })
  t.eq({ gpu.getResolution() }, { 120, 60 })
  local res = ctl.find("setResolution")
  t.eq(res, { { "setResolution", 160, 50 }, { "setResolution", 120, 60 } })
end

function T.no_rescale_keeps_resolution()
  local seen
  local gpu, ctl = fake_gpu.new({ width = 120, height = 60, max_width = 160,
    max_height = 50 })
  local events = {
    function() seen = { gpu.getResolution() } end,
    Q, Y,
  }
  viewer.run(make_lines(10), { no_rescale = true }, { gpu = gpu,
    pull = (queue(events)), term = fake_term() })
  t.eq(seen, { 120, 60 })
  t.eq(ctl.count("setResolution"), 0)
end

function T.max_resolution_is_not_set_again()
  local _, ctl = run({ lines = make_lines(10), events = { Q, Y } })
  t.eq(ctl.count("setResolution"), 0)
end

-- Status line.

local function status_after(events, opts, n, size)
  local status
  local w = size and size.width or 80
  local h = size and size.height or 25
  local gpu, ctl = fake_gpu.new(size or { width = w, height = h,
    max_width = w, max_height = h })
  local list = {}
  for _, e in ipairs(events) do
    list[#list + 1] = e
  end
  list[#list + 1] = function() status = ctl.row(h) end
  list[#list + 1] = Q
  list[#list + 1] = Y
  viewer.run(make_lines(n or 100), opts or {}, { gpu = gpu,
    pull = (queue(list)), term = fake_term() })
  return status, ctl
end

function T.status_shows_title_percent_and_hint()
  local s = status_after({}, { title = "My Page" })
  t.eq(unicode.wlen(s), 80)
  t.ok(s:find("^ My Page "), s)
  t.ok(s:find("  0%%  Up Dn PgUp PgDn Home End q:quit $"), s)
end

function T.status_falls_back_to_file_name()
  local s = status_after({}, { file = "index.html" })
  t.ok(s:find("^ index.html "), s)
end

function T.status_percent_top_middle_end()
  -- 124 lines on 24 rows: the last top line is 101, so one line is 1%.
  t.ok(status_after({}, {}, 124):find("  0%", 1, true))
  local events = {}
  for _ = 1, 50 do
    events[#events + 1] = key(DOWN)
  end
  t.ok(status_after(events, {}, 124):find(" 50%", 1, true))
  t.ok(status_after({ key(END) }, {}, 124):find("100%", 1, true))
end

function T.status_short_page_is_100_percent()
  t.ok(status_after({}, {}, 5):find("100%", 1, true))
end

function T.status_truncates_long_title()
  local title = string.rep("abcdefghij", 20)
  local s = status_after({}, { title = title })
  t.eq(#s, 80)
  t.ok(s:find("q:quit $"), s)
  t.ok(s:find("^ abcdefghij"), s)
end

function T.status_uses_short_hint_on_narrow_screen()
  local s = status_after({}, { title = "Title" }, 100, { width = 50,
    height = 16, max_width = 50, max_height = 16 })
  t.eq(#s, 50)
  t.ok(s:find("  0%%  q:quit $"), s)
end

function T.status_wide_title_does_not_overflow()
  -- 中 is 2 columns wide. An odd number of free columns puts the last one
  -- half over the edge.
  local title = string.rep("\xE4\xB8\xAD", 60)
  for _, w in ipairs({ 50, 51, 80, 81 }) do
    local s, ctl = status_after({}, { title = title }, 100, { width = w,
      height = 16, max_width = w, max_height = 16 })
    t.eq(ctl.overflow, false, "width " .. w)
    t.eq(unicode.wlen(s), w, "width " .. w)
    t.ok(s:find("q:quit $"), "width " .. w)
    for _, c in ipairs(ctl.find("set")) do
      t.ok(c[2] + unicode.wlen(c[4]) - 1 <= w, "set inside width " .. w)
    end
  end
end

function T.status_title_control_bytes_become_spaces()
  local s = status_after({}, { title = "a\1b\tc" })
  t.ok(s:find("^ a b c "), s)
end

-- Quit prompt.

function T.quit_prompt_shows_question()
  local s
  local gpu, ctl = fake_gpu.new({ width = 80, height = 25, max_width = 80,
    max_height = 25 })
  viewer.run(make_lines(10), {}, { gpu = gpu, term = fake_term(),
    pull = (queue({ Q, function() s = ctl.row(25) end, Y })) })
  t.eq(s, " Quit? (y/n)" .. string.rep(" ", 68))
end

function T.quit_with_y_and_enter()
  t.eq((run({ lines = make_lines(10), events = { Q, Y } })), "quit")
  t.eq((run({ lines = make_lines(10), events = { Q, key(21, 89) } })), "quit")
  t.eq((run({ lines = make_lines(10), events = { Q, ENTER } })), "quit")
end

function T.cancel_with_n_esc_or_other_key()
  for _, cancel in ipairs({ N, ESC, key(30, 97), key(DOWN) }) do
    local s
    local gpu, ctl = fake_gpu.new({ width = 80, height = 25, max_width = 80,
      max_height = 25 })
    local result = viewer.run(make_lines(100), { title = "T" }, {
      gpu = gpu, term = fake_term(), pull = (queue({
        Q, cancel,
        function() s = { ctl.row(25), top_line(ctl) } end,
        Q, Y,
      })) })
    t.eq(result, "quit")
    t.ok(s[1]:find("^ T "), s[1])
    t.ok(s[1]:find("q:quit $"), s[1])
    -- The cancel key does not scroll.
    t.eq(s[2], 1)
  end
end

function T.prompt_ignores_key_up()
  local result = run({ lines = make_lines(10), events = {
    Q, { "key_up", "kbd", 113, 16, "player" }, Y } })
  t.eq(result, "quit")
end

-- Ctrl+C.

function T.ctrl_c_char_quits_without_prompt()
  local result, ctl = run({ lines = make_lines(10), events = { CTRL_C } })
  t.eq(result, "interrupted")
  for _, c in ipairs(ctl.find("set")) do
    t.ok(not c[4]:find("Quit?", 1, true), "no prompt")
  end
end

function T.interrupted_event_quits()
  t.eq((run({ lines = make_lines(10), events = { INTERRUPTED } })),
    "interrupted")
end

function T.ctrl_c_in_prompt_and_during_coalescing()
  t.eq((run({ lines = make_lines(10), events = { Q, CTRL_C } })),
    "interrupted")
  t.eq((run({ lines = make_lines(10), events = { Q, INTERRUPTED } })),
    "interrupted")
  t.eq((run({ lines = make_lines(100), events = { key(DOWN), key(DOWN),
    CTRL_C } })), "interrupted")
  t.eq((run({ lines = make_lines(100), events = { key(DOWN), INTERRUPTED } })),
    "interrupted")
end

-- Exit.

local function check_restored(gpu, ctl, term, w, h)
  t.eq({ gpu.getResolution() }, { w, h })
  t.eq({ ctl.colors() }, { 0x123456, 0x654321 })
  t.eq(term.cleared, 1)
  t.eq(term.cursor, { 1, 1 })
  for y = 1, h do
    t.eq(ctl.row(y), string.rep(" ", w), "row " .. y)
  end
end

function T.exit_restores_screen()
  for _, events in ipairs({ { Q, Y }, { CTRL_C }, { INTERRUPTED } }) do
    local gpu, ctl = fake_gpu.new({ width = 120, height = 60,
      max_width = 160, max_height = 50 })
    gpu.setForeground(0x123456)
    gpu.setBackground(0x654321)
    local term = fake_term()
    viewer.run(make_lines(100), {}, { gpu = gpu, term = term,
      pull = (queue(events)) })
    check_restored(gpu, ctl, term, 120, 60)
  end
end

function T.error_during_drawing_restores_and_reraises()
  local gpu, ctl = fake_gpu.new({ width = 120, height = 60, max_width = 160,
    max_height = 50 })
  gpu.setForeground(0x123456)
  gpu.setBackground(0x654321)
  local real_set = gpu.set
  local calls = 0
  rawset(gpu, "set", function(...)
    calls = calls + 1
    if calls == 5 then
      error("html: draw failed", 0)
    end
    return real_set(...)
  end)
  local term = fake_term()
  t.raises(function()
    viewer.run(make_lines(100), {}, { gpu = gpu, term = term,
      pull = (queue({ Q, Y })) })
  end, "^html: draw failed$")
  check_restored(gpu, ctl, term, 120, 60)
end

function T.error_from_pull_restores_and_reraises()
  local gpu, ctl = fake_gpu.new({ width = 80, height = 25, max_width = 80,
    max_height = 25 })
  gpu.setForeground(0x123456)
  gpu.setBackground(0x654321)
  local term = fake_term()
  t.raises(function()
    viewer.run(make_lines(100), {}, { gpu = gpu, term = term,
      pull = function() error({ code = 1 }) end })
  end)
  check_restored(gpu, ctl, term, 80, 25)
end

-- Input.

function T.waits_with_a_timeout()
  local gpu = fake_gpu.new({ width = 80, height = 25, max_width = 80,
    max_height = 25 })
  local pull, pulls = queue({ { "touch" }, key(DOWN), Q, Y })
  viewer.run(make_lines(100), {}, { gpu = gpu, term = fake_term(),
    pull = pull })
  for _, timeout in ipairs(pulls) do
    t.eq(type(timeout), "number")
  end
  t.ok(pulls[1] > 0)
end

function T.ignores_other_keys_and_events()
  t.eq(top_after({ key(30, 97), { "touch", "s", 1, 1 }, key(DOWN) }, 100), 2)
end

function T.does_not_change_lines()
  local lines = make_lines(50)
  local copy = {}
  for i, l in ipairs(lines) do
    copy[i] = l
  end
  run({ lines = lines, events = { key(END), key(HOME), Q, Y } })
  t.eq(lines, copy)
end

return T
