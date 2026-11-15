-- Tests for lib/html/viewer.lua against spec/viewer.md, with a fake GPU
-- and a fake event queue.

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

local function key_up(code, char)
  return { "key_up", "kbd", char or 0, code, "player" }
end

local Q = key(16, 113)
local Y = key(21, 121)
local N = key(49, 110)
local ENTER = key(28, 13)
local ESC = key(1, 27)
local CTRL_C = key(46, 3)
local INTERRUPTED = { "interrupted" }
local TOUCH = { "touch", "screen", 1, 1, 0, "player" }

local HINT = "Tab:link Enter:open Bksp:back r:reload ?:keys q:quit"
local SHORT_HINT = "?:keys q:quit"
local TINY_HINT = "q:quit"
local ERROR_TEXT = "html: read error: closed"

-- "\1line N" for N = 1 to n.
local function make_lines(n)
  local lines = {}
  for i = 1, n do
    lines[i] = "\1line " .. i
  end
  return lines
end

local function size(w, h, depth)
  return { width = w, height = h, max_width = w, max_height = h,
    depth = depth }
end

-- Returns a pull function. A table item is an event. A function item runs
-- at the next blocking pull as item(ctl, items), so it sees the screen
-- after a draw and can add more items.
local function queue(items, ctl)
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
        item(ctl, items)
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
  local gpu, ctl = fake_gpu.new(o.gpu or size(80, 25))
  local term = fake_term()
  local list = {}
  for _, e in ipairs(o.events) do
    list[#list + 1] = e
  end
  local result = viewer.run(o.lines, o.opts or {}, {
    gpu = gpu, pull = (queue(list, ctl)), term = term,
    shift_down = o.shift_down,
  })
  return result, ctl, term, gpu
end

-- The number N of a "line N" row, or nil.
local function line_at(ctl, y)
  return tonumber(ctl.row(y):match("^line (%d+)"))
end

-- Keys (spec/viewer.md "Keys", "Drawing"). 80x25 has 24 text rows. One
-- page is h-2 = 23 lines. With 100 lines, the last top line is 77.
-- The input is { n, events [, size] }. The result is the line on the top
-- row and the line on the last row above the status line.
local function keys_row(name, n, events, expected, sz)
  return { name, { n = n, events = events, size = sz }, expected }
end

local PGDN_DRAWS = {}
for _ = 1, 30 do
  PGDN_DRAWS[#PGDN_DRAWS + 1] = key(PGDN)
  PGDN_DRAWS[#PGDN_DRAWS + 1] = function() end
end

local QUEUED_DOWNS = {}
for _ = 1, 20 do
  QUEUED_DOWNS[#QUEUED_DOWNS + 1] = key(DOWN)
  QUEUED_DOWNS[#QUEUED_DOWNS + 1] = key_up(DOWN)
end

local KEYS = {
  keys_row("Down moves one line", 100, { key(DOWN) }, { 2, 25 }),
  keys_row("Up moves one line back", 100,
    { key(DOWN), key(DOWN), key(UP) }, { 2, 25 }),
  keys_row("PgDn moves h-2 lines", 100, { key(PGDN) }, { 24, 47 }),
  keys_row("PgUp moves h-2 lines back", 100,
    { key(PGDN), key(PGDN), key(PGUP) }, { 24, 47 }),
  keys_row("End shows the last line on the last row", 100, { key(END) },
    { 77, 100 }),
  keys_row("Home shows line 1 at the top", 100, { key(END), key(HOME) },
    { 1, 24 }),
  keys_row("End at 50x16", 200, { key(END) }, { 186, 200 }, size(50, 16)),
  keys_row("End at 160x50", 200, { key(END) }, { 152, 200 },
    size(160, 50)),
  keys_row("Up at the start does nothing", 100, { key(UP) }, { 1, 24 }),
  keys_row("PgUp at the start does nothing", 100, { key(PGUP) }, { 1, 24 }),
  keys_row("Home at the start does nothing", 100, { key(HOME) }, { 1, 24 }),
  keys_row("PgUp near the start stops at line 1", 100,
    { key(DOWN), key(DOWN), key(PGUP) }, { 1, 24 }),
  keys_row("Down at the end does nothing", 100, { key(END), key(DOWN) },
    { 77, 100 }),
  keys_row("PgDn past the end stops at the end", 100,
    { key(PGDN), key(PGDN), key(PGDN), key(PGDN) }, { 77, 100 }),
  keys_row("PgDn past the end with a draw after each", 100, PGDN_DRAWS,
    { 77, 100 }),
  keys_row("a short page does not scroll", 10,
    { key(DOWN), key(PGDN), key(END) }, { 1 }),
  keys_row("a page of exactly one screen does not scroll", 24,
    { key(DOWN), key(END) }, { 1, 24 }),
  keys_row("a page one line over a screen scrolls one line", 25,
    { key(END) }, { 2, 25 }),
  keys_row("NumPad Down with char 0", 100, { key(NP_DOWN) }, { 2, 25 }),
  keys_row("NumPad Up with char 0", 100,
    { key(NP_DOWN), key(NP_DOWN), key(NP_UP) }, { 2, 25 }),
  keys_row("NumPad PgDn with char 0", 100, { key(NP_PGDN) }, { 24, 47 }),
  keys_row("NumPad PgUp with char 0", 100,
    { key(NP_PGDN), key(NP_PGDN), key(NP_PGUP) }, { 24, 47 }),
  keys_row("NumPad End with char 0", 100, { key(NP_END) }, { 77, 100 }),
  keys_row("NumPad Home with char 0", 100, { key(NP_END), key(NP_HOME) },
    { 1, 24 }),
  keys_row("NumPad 3 is not PgDn", 100, { key(NP_PGDN, 51) }, { 1, 24 }),
  keys_row("NumPad 2 is not Down", 100, { key(NP_DOWN, 50) }, { 1, 24 }),
  keys_row("NumPad 1 is not End", 100, { key(NP_END, 49) }, { 1, 24 }),
  keys_row("NumPad 9 is not PgUp", 100, { key(END), key(NP_PGUP, 57) },
    { 77, 100 }),
  keys_row("NumPad 8 is not Up", 100, { key(END), key(NP_UP, 56) },
    { 77, 100 }),
  keys_row("NumPad 7 is not Home", 100, { key(END), key(NP_HOME, 55) },
    { 77, 100 }),
  keys_row("other keys and events are ignored", 100,
    { key(30, 97), TOUCH, key_up(DOWN), key(DOWN) }, { 2, 25 }),
  keys_row("queued Down events add up", 200, QUEUED_DOWNS, { 21, 44 }),
  keys_row("queued mixed keys add up", 100,
    { key(DOWN), key(DOWN), key(UP), key(PGDN) }, { 25, 48 }),
}

t.cases(T, "keys", KEYS, function(input)
  local out
  local events = {}
  for _, e in ipairs(input.events) do
    events[#events + 1] = e
  end
  local h = input.size and input.size.height or 25
  events[#events + 1] = function(ctl)
    out = { line_at(ctl, 1), line_at(ctl, h - 1) }
  end
  events[#events + 1] = Q
  events[#events + 1] = Y
  run({ lines = make_lines(input.n), events = events, gpu = input.size })
  return out
end)

-- Quit (spec/viewer.md "Quit"). The result is the viewer result and
-- whether the prompt was drawn.
local function prompt_drawn(ctl)
  for _, c in ipairs(ctl.find("set")) do
    if c[4]:find("Quit?", 1, true) then
      return true
    end
  end
  return false
end

local QUIT = {
  { "q then y quits", { Q, Y }, { "quit", true } },
  { "q then Y quits", { Q, key(21, 89) }, { "quit", true } },
  { "q then Enter quits", { Q, ENTER }, { "quit", true } },
  { "key_up does not answer the prompt",
    { Q, key_up(16, 113), Y }, { "quit", true } },
  { "touch does not answer the prompt", { Q, TOUCH, Y }, { "quit", true } },
  { "q after queued scroll keys opens the prompt",
    { key(DOWN), key(DOWN), Q, Y }, { "quit", true } },
  { "Ctrl+C quits without the prompt", { CTRL_C },
    { "interrupted", false } },
  { "the interrupted event quits", { INTERRUPTED },
    { "interrupted", false } },
  { "Ctrl+C in the prompt quits", { Q, CTRL_C }, { "interrupted", true } },
  { "the interrupted event in the prompt quits", { Q, INTERRUPTED },
    { "interrupted", true } },
  { "Ctrl+C during queued scroll keys quits",
    { key(DOWN), key(DOWN), CTRL_C }, { "interrupted", false } },
  { "the interrupted event during queued scroll keys quits",
    { key(DOWN), INTERRUPTED }, { "interrupted", false } },
}

t.cases(T, "quit", QUIT, function(events)
  local result, ctl = run({ lines = make_lines(100), events = events })
  return { result, prompt_drawn(ctl) }
end)

function T.quit_prompt_shows_question()
  local s
  run({ lines = make_lines(10), events = {
    Q, function(ctl) s = ctl.row(25) end, Y } })
  t.eq(s, " Quit? (y/n)" .. string.rep(" ", 68))
end

-- Any other key cancels the prompt. The result is the top line, whether
-- the status line shows the title again, and whether it shows the prompt.
local CANCEL = {
  { "n cancels", N, { 1, true, false } },
  { "Esc cancels", ESC, { 1, true, false } },
  { "a letter cancels", key(30, 97), { 1, true, false } },
  { "Down cancels and does not scroll", key(DOWN), { 1, true, false } },
}

t.cases(T, "cancel", CANCEL, function(cancel)
  local out
  local result = run({ lines = make_lines(100), opts = { title = "T" },
    events = { Q, cancel, function(ctl)
      local s = ctl.row(25)
      out = { line_at(ctl, 1), s:find("^ T ") ~= nil,
        s:find("Quit?", 1, true) ~= nil }
    end, Q, Y } })
  t.eq(result, "quit")
  return out
end)

-- Status line (spec/viewer.md "Status line"). The input is
-- { opts, n, events, size }. The result is the title, the percent, the
-- hint and the width of the status row.
local function parse_status(s)
  local title, pct, hint = s:match("^ (.-) +(%d+)%%  (.-) $")
  return { title = title, pct = tonumber(pct), hint = hint,
    width = unicode.wlen(s) }
end

local function status_row(name, input, title, pct, hint, width)
  return { name, input,
    { title = title, pct = pct, hint = hint, width = width or 100 } }
end

local function downs(n)
  local list = {}
  for i = 1, n do
    list[i] = key(DOWN)
  end
  return list
end

local LONG_TITLE = string.rep("abcdefghij", 20)

local STATUS = {
  status_row("title, percent and hint", { opts = { title = "My Page" } },
    "My Page", 0, HINT),
  status_row("file name when there is no title",
    { opts = { file = "index.html" } }, "index.html", 0, HINT),
  status_row("the title wins over the file name",
    { opts = { title = "T", file = "f.html" } }, "T", 0, HINT),
  status_row("an HTTP status prefix shows as part of the title",
    { opts = { title = "[HTTP 404] Not Found" } }, "[HTTP 404] Not Found",
    0, HINT),
  status_row("control bytes in the title show as spaces",
    { opts = { title = "a\1b\tc" } }, "a b c", 0, HINT),
  status_row("0 percent at the top", { opts = { title = "T" }, n = 124 },
    "T", 0, HINT),
  status_row("50 percent in the middle",
    { opts = { title = "T" }, n = 124, events = downs(50) }, "T", 50, HINT),
  status_row("100 percent at the end",
    { opts = { title = "T" }, n = 124, events = { key(END) } }, "T", 100,
    HINT),
  status_row("percent rounds down",
    { opts = { title = "T" }, n = 31, events = downs(3) }, "T", 42, HINT),
  status_row("a short page shows 100 percent",
    { opts = { title = "T" }, n = 5 }, "T", 100, HINT),
  status_row("a page of exactly one screen shows 100 percent",
    { opts = { title = "T" }, n = 24 }, "T", 100, HINT),
  status_row("a long title is cut to fit", { opts = { title = LONG_TITLE } },
    string.rep("abcdefghij", 3) .. "abcdefghi", 0, HINT),
  status_row("20 title columns keep the full hint",
    { opts = { title = "Title" }, size = size(81, 16) }, "Title", 0, HINT,
    81),
  status_row("19 title columns use the short hint",
    { opts = { title = "Title" }, size = size(80, 16) }, "Title", 0,
    SHORT_HINT, 80),
  status_row("a screen of 50 columns shows ?:keys",
    { opts = { title = "Title" }, size = size(50, 16) }, "Title", 0,
    SHORT_HINT, 50),
  status_row("a screen of 42 columns still shows ?:keys",
    { opts = { title = "Title" }, size = size(42, 16) }, "Title", 0,
    SHORT_HINT, 42),
  status_row("a narrow screen falls back to q:quit",
    { opts = { title = "Title" }, size = size(41, 16) }, "Title", 0,
    TINY_HINT, 41),
}

t.cases(T, "status", STATUS, function(input)
  local out
  local h = input.size and input.size.height or 25
  local events = {}
  for _, e in ipairs(input.events or {}) do
    events[#events + 1] = e
  end
  events[#events + 1] = function(ctl) out = parse_status(ctl.row(h)) end
  events[#events + 1] = Q
  events[#events + 1] = Y
  run({ lines = make_lines(input.n or 100), opts = input.opts,
    events = events, gpu = input.size or size(100, 25) })
  return out
end)

-- A wide title never goes past the right edge. 中 is 2 columns wide. An
-- odd number of free columns puts the last one half over the edge. The
-- result is the status width, whether a cell was written past the edge
-- and whether every set call stays inside the width.
local WIDE_TITLE = { sizes = { 50, 51, 80, 81 } }

t.cases(T, "status_wide_title", {
  { "wide title", string.rep("\xE4\xB8\xAD", 60), true },
}, function(title, w)
  local s
  local _, ctl = run({ lines = make_lines(100), opts = { title = title },
    gpu = size(w, 16),
    events = { function(c) s = c.row(16) end, Q, Y } })
  local inside = true
  for _, c in ipairs(ctl.find("set")) do
    if c[2] + unicode.wlen(c[4]) - 1 > w then
      inside = false
    end
  end
  return unicode.wlen(s) == w and not ctl.overflow and inside
end, WIDE_TITLE)

-- Colors (spec/viewer.md "Colors"). The result is the foreground and
-- background of the five style cells and of the status line, and whether
-- a palette index was used.
local function color_case(depth, styles, status)
  return { "depth " .. depth, depth, { styles = styles, status = status,
    palette = false } }
end

local BLACK, WHITE = 0x000000, 0xFFFFFF
local RGB = { { 0xFFFFFF, BLACK }, { 0xFFFF33, BLACK }, { 0xFFCC33, BLACK },
  { 0x6699FF, BLACK }, { 0x33CC33, BLACK } }
local MONO = { { WHITE, BLACK }, { WHITE, BLACK }, { WHITE, BLACK },
  { WHITE, BLACK }, { WHITE, BLACK } }

local COLORS = {
  color_case(8, RGB, { BLACK, WHITE }),
  color_case(4, RGB, { BLACK, WHITE }),
  color_case(1, MONO, { BLACK, WHITE }),
}

t.cases(T, "colors", COLORS, function(depth)
  local out
  run({ lines = { "\1n\2h\3e\4l\5p" }, gpu = size(80, 25, depth),
    events = { function(ctl)
      local styles = {}
      for x = 1, 5 do
        local _, fg, bg = ctl.cell(x, 1)
        styles[x] = { fg, bg }
      end
      local _, sfg, sbg = ctl.cell(1, 25)
      local palette = false
      for _, name in ipairs({ "setForeground", "setBackground" }) do
        for _, c in ipairs(ctl.find(name)) do
          palette = palette or c[3] == true
        end
      end
      out = { styles = styles, status = { sfg, sbg }, palette = palette }
    end, Q, Y } })
  return out
end)

-- The viewer sets a color only on a change. The result is the number of
-- setForeground and setBackground calls that repeat the current color,
-- counted until the viewer quits.
local CACHE_LINES = {
  "\1aaa\1bbb\1ccc", "\1ddd", "\2head", "\2more", "\1x\4link\1y", "",
  "\3em\5pre\1n",
}
for i = 8, 60 do
  CACHE_LINES[i] = CACHE_LINES[(i - 1) % 7 + 1]
end

t.cases(T, "color_cache", {
  { "depth 8", 8, { 0, 0 } },
  { "depth 4", 4, { 0, 0 } },
  { "depth 1", 1, { 0, 0 } },
}, function(depth)
  local out
  run({ lines = CACHE_LINES, gpu = size(80, 25, depth), events = {
    key(DOWN), function() end, key(PGDN), function() end, key(END),
    function() end, key(HOME), function() end, Q, N,
    function(ctl)
      out = {}
      for i, name in ipairs({ "setForeground", "setBackground" }) do
        local repeats, last = 0, nil
        for _, c in ipairs(ctl.find(name)) do
          if c[2] == last then
            repeats = repeats + 1
          end
          last = c[2]
        end
        out[i] = repeats
      end
    end, Q, Y } })
  return out
end)

-- Every size and depth: first screen, status line and End.
local SIZES = {}
for _, sz in ipairs({ { 160, 50 }, { 80, 25 }, { 50, 16 } }) do
  for _, depth in ipairs({ 8, 4, 1 }) do
    local w, h = sz[1], sz[2]
    SIZES[#SIZES + 1] = { w .. "x" .. h .. " depth " .. depth,
      { w = w, h = h, depth = depth },
      { result = "quit", rows = h, first = "line 1" .. string.rep(" ", w - 6),
        last = h - 1, title = "Page", pct = 0, end_top = 200 - (h - 1) + 1,
        end_pct = 100, overflow = false } }
  end
end

t.cases(T, "sizes_and_depths", SIZES, function(input)
  local w, h = input.w, input.h
  local out = {}
  local result, ctl = run({ lines = make_lines(200),
    opts = { title = "Page" }, gpu = size(w, h, input.depth), events = {
      function(c)
        local screen = c.screen()
        local status = parse_status(screen[h])
        out.rows = #screen
        out.first = screen[1]
        out.last = line_at(c, h - 1)
        out.title, out.pct = status.title, status.pct
      end,
      key(END),
      function(c)
        out.end_top = line_at(c, 1)
        out.end_pct = parse_status(c.row(h)).pct
      end,
      Q, Y } })
  out.result = result
  out.overflow = ctl.overflow
  return out
end)

-- Resolution (spec/viewer.md "Resolution"). The input is the start size,
-- the max size, opts and events. The result is the size the viewer works
-- in, the size after exit and the setResolution calls.
local function res_row(name, start, max, opts, events, seen, calls)
  return { name, { start = start, max = max, opts = opts, events = events },
    { seen = seen, final = start, calls = calls } }
end

local RESOLUTION = {
  res_row("rescales to the max and restores", { 120, 60 }, { 160, 50 }, {},
    { Q, Y }, { 160, 50 }, { { 160, 50 }, { 120, 60 } }),
  res_row("restores after Ctrl+C", { 120, 60 }, { 160, 50 }, {},
    { CTRL_C }, { 160, 50 }, { { 160, 50 }, { 120, 60 } }),
  res_row("--no-rescale keeps the resolution", { 120, 60 }, { 160, 50 },
    { no_rescale = true }, { Q, Y }, { 120, 60 }, {}),
  res_row("the max resolution is not set again", { 80, 25 }, { 80, 25 }, {},
    { Q, Y }, { 80, 25 }, {}),
}

t.cases(T, "resolution", RESOLUTION, function(input)
  local seen
  local gpu, ctl = fake_gpu.new({ width = input.start[1],
    height = input.start[2], max_width = input.max[1],
    max_height = input.max[2] })
  local events = { function(c)
    -- The status line is on the last row of the size the viewer read.
    local w, h = gpu.getResolution()
    seen = { w, h }
    t.ok(c.row(h):find("100%", 1, true), "status on row " .. h)
  end }
  for _, e in ipairs(input.events) do
    events[#events + 1] = e
  end
  viewer.run(make_lines(10), input.opts, { gpu = gpu,
    pull = (queue(events, ctl)), term = fake_term() })
  local calls = {}
  for i, c in ipairs(ctl.find("setResolution")) do
    calls[i] = { c[2], c[3] }
  end
  return { seen = seen, final = { gpu.getResolution() }, calls = calls }
end)

-- Exit (spec/viewer.md "Exit"). The input is events, opts and a fault:
-- "set" makes the 5th gpu.set raise, "pull" makes pull raise a table. The
-- result is the outcome and whether the screen was restored: the start
-- resolution and colors, term.clear() once, the cursor at 1,1 and a blank
-- screen.
local function restored(gpu, ctl, term)
  local w, h = gpu.getResolution()
  if w ~= 120 or h ~= 60 then
    return "resolution " .. w .. "x" .. h
  end
  local fg, bg = ctl.colors()
  if fg ~= 0x123456 or bg ~= 0x654321 then
    return "colors"
  end
  if term.cleared ~= 1 then
    return "term.clear() calls " .. term.cleared
  end
  if not term.cursor or term.cursor[1] ~= 1 or term.cursor[2] ~= 1 then
    return "cursor"
  end
  for y = 1, h do
    if ctl.row(y) ~= string.rep(" ", w) then
      return "row " .. y
    end
  end
  return true
end

local EXIT = {
  { "quit with q y", { events = { Q, Y } }, { "quit", true } },
  { "Ctrl+C", { events = { CTRL_C } }, { "interrupted", true } },
  { "the interrupted event", { events = { INTERRUPTED } },
    { "interrupted", true } },
  { "quit after the popup closes",
    { events = { ENTER, Q, Y }, opts = { error = ERROR_TEXT } },
    { "quit", true } },
  { "Ctrl+C while the popup shows",
    { events = { CTRL_C }, opts = { error = ERROR_TEXT } },
    { "interrupted", true } },
  { "error in gpu.set", { fault = "set" },
    { "error: html: draw failed", true } },
  { "error value from pull", { fault = "pull" }, { "error: table", true } },
  { "error from pull while the popup shows",
    { fault = "pull", opts = { error = ERROR_TEXT } },
    { "error: table", true } },
}

t.cases(T, "exit", EXIT, function(input)
  local gpu, ctl = fake_gpu.new({ width = 120, height = 60,
    max_width = 160, max_height = 50 })
  gpu.setForeground(0x123456)
  gpu.setBackground(0x654321)
  local term = fake_term()
  local pull = queue(input.events or { Q, Y }, ctl)
  if input.fault == "set" then
    local real_set = gpu.set
    local calls = 0
    rawset(gpu, "set", function(...)
      calls = calls + 1
      if calls == 5 then
        error("html: draw failed", 0)
      end
      return real_set(...)
    end)
  elseif input.fault == "pull" then
    pull = function() error({ code = 1 }) end
  end
  local ok, result = pcall(viewer.run, make_lines(100), input.opts or {},
    { gpu = gpu, term = term, pull = pull })
  if not ok then
    result = "error: " .. (type(result) == "table" and "table"
      or tostring(result))
  end
  return { result, restored(gpu, ctl, term) }
end)

-- Drawing (spec/viewer.md "Drawing" and "Keys": queued events give one
-- redraw).

function T.coalesces_queued_scroll_events()
  local events = { table.unpack(QUEUED_DOWNS) }
  events[#events + 1] = Q
  events[#events + 1] = Y
  local _, ctl = run({ lines = make_lines(200), gpu = size(160, 50),
    events = events })
  local copies = ctl.find("copy")
  t.eq(#copies, 1)
  t.eq(copies[1], { "copy", 1, 21, 160, 29, 0, -20 })
end

-- Lines with three styles and blank lines, for screen comparisons.
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

-- Returns rows 1 to 24 with colors after the events, and the GPU control.
local function scrolled_screen(lines, events, opts)
  local snap
  local list = {}
  for _, e in ipairs(events) do
    list[#list + 1] = e
  end
  list[#list + 1] = function(ctl)
    snap = screen_with_colors(ctl, 24, 80)
    snap.text = ctl.screen()
  end
  list[#list + 1] = Q
  list[#list + 1] = Y
  local _, ctl = run({ lines = lines, events = list, opts = opts })
  return snap, ctl
end

-- A scroll of up to h-2 lines uses copy. A larger jump redraws all rows.
-- Either way the screen equals a fresh draw at the new top line. The input
-- is { n, events }. The result is the top line, the copy count and whether
-- the screen equals a fresh draw.
local NOOP = function() end
local THIRTY_DOWNS = downs(30)
THIRTY_DOWNS[#THIRTY_DOWNS + 1] = NOOP

local SCROLL = {
  { "Down uses copy", { n = 100, events = { key(DOWN) } }, { 2, 1, true } },
  { "three queued Downs use one copy",
    { n = 100, events = { key(DOWN), key(DOWN), key(DOWN) } },
    { 4, 1, true } },
  { "PgDn uses copy", { n = 100, events = { key(PGDN) } }, { 24, 1, true } },
  { "Up after PgDn uses copy",
    { n = 100, events = { key(PGDN), NOOP, key(UP) } }, { 23, 2, true } },
  { "PgUp after PgDn uses copy",
    { n = 100, events = { key(PGDN), NOOP, key(PGUP) } }, { 1, 2, true } },
  { "a short Home jump uses copy",
    { n = 100, events = { key(DOWN), key(DOWN), key(DOWN), NOOP,
      key(HOME) } }, { 1, 2, true } },
  { "a short End jump uses copy", { n = 30, events = { key(END) } },
    { 7, 1, true } },
  { "a long End jump redraws all rows", { n = 100, events = { key(END) } },
    { 77, 0, true } },
  { "a long Home jump redraws all rows",
    { n = 100, events = { key(END), NOOP, key(HOME) } }, { 1, 0, true } },
  { "a queued burst over a screen redraws all rows",
    { n = 100, events = THIRTY_DOWNS }, { 31, 0, true } },
}

t.cases(T, "scroll", SCROLL, function(input)
  local lines = styled_lines(input.n)
  local snap, ctl = scrolled_screen(lines, input.events)
  -- Every third line is blank, so row 1 or row 2 has a line number.
  local n = snap.text[1]:match("^head (%d+)")
  local top = n and tonumber(n)
    or tonumber(snap.text[2]:match("^head (%d+)")) - 1
  local shifted = {}
  for j = top, #lines do
    shifted[#shifted + 1] = lines[j]
  end
  local fresh = scrolled_screen(shifted, {})
  return { top, ctl.count("copy"),
    table.concat(fresh, "\n") == table.concat(snap, "\n") }
end)

-- After a scroll, only the exposed rows and the status line are drawn.
-- The input is events before and after the log is cleared. The result is
-- the sorted list of drawn rows.
local function range(a, b)
  local list = {}
  for y = a, b do
    list[#list + 1] = y
  end
  return list
end

local DRAWN_PGDN = range(2, 24)
DRAWN_PGDN[#DRAWN_PGDN + 1] = 25

local DRAWN = {
  { "Down draws the bottom row", { {}, { key(DOWN) } }, { 24, 25 } },
  { "Up draws the top row", { { key(DOWN) }, { key(UP) } }, { 1, 25 } },
  { "PgDn draws the h-2 exposed rows", { {}, { key(PGDN) } }, DRAWN_PGDN },
  { "a long End jump draws every row", { {}, { key(END) } }, range(1, 25) },
}

t.cases(T, "drawn_rows", DRAWN, function(input)
  local drawn
  local events = {}
  for _, e in ipairs(input[1]) do
    events[#events + 1] = e
  end
  events[#events + 1] = function(ctl) ctl.clear_log() end
  for _, e in ipairs(input[2]) do
    events[#events + 1] = e
  end
  events[#events + 1] = function(ctl)
    local seen = {}
    for _, name in ipairs({ "set", "fill" }) do
      for _, c in ipairs(ctl.find(name)) do
        seen[c[3]] = true
      end
    end
    drawn = {}
    for y = 1, 25 do
      if seen[y] then
        drawn[#drawn + 1] = y
      end
    end
  end
  events[#events + 1] = Q
  events[#events + 1] = Y
  run({ lines = make_lines(100), events = events })
  return drawn
end)

-- Error popup (spec/viewer.md "Error popup"). opts.error shows a popup
-- over the page. PROBE records the state. The result is the viewer result,
-- whether the popup shows, the top line and whether the quit prompt shows.
local PROBE = {}

local function popup_shown(ctl, h)
  for y = 1, h - 1 do
    if ctl.row(y):find(ERROR_TEXT, 1, true) then
      return true
    end
  end
  return false
end

local function popup_row(name, events, result, popup, top, prompt)
  return { name, events,
    { result = result, popup = popup, top = top, prompt = prompt } }
end

local POPUP = {
  popup_row("the popup shows at start", { PROBE }, "quit", true, 1, false),
  popup_row("Enter closes the popup", { ENTER, PROBE }, "quit", false, 1,
    false),
  popup_row("Esc is ignored while the popup shows", { ESC, PROBE }, "quit",
    true, 1, false),
  popup_row("Esc with char 0 is ignored while the popup shows",
    { key(1, 0), PROBE }, "quit", true, 1, false),
  popup_row("Down is ignored while the popup shows", { key(DOWN), PROBE },
    "quit", true, 1, false),
  popup_row("PgDn and End are ignored while the popup shows",
    { key(PGDN), key(END), PROBE }, "quit", true, 1, false),
  popup_row("q is ignored while the popup shows", { Q, PROBE }, "quit", true,
    1, false),
  popup_row("other keys are ignored while the popup shows",
    { N, key(30, 97), Y, PROBE }, "quit", true, 1, false),
  popup_row("key_up of Enter does not close the popup",
    { key_up(28, 13), PROBE }, "quit", true, 1, false),
  popup_row("touch does not close the popup", { TOUCH, PROBE }, "quit",
    true, 1, false),
  popup_row("Down scrolls after the popup closes",
    { ENTER, key(DOWN), PROBE }, "quit", false, 2, false),
  popup_row("q opens the prompt after the popup closes",
    { ENTER, Q, PROBE }, "quit", false, 1, true),
  popup_row("Ctrl+C quits while the popup shows", { CTRL_C }, "interrupted"),
  popup_row("the interrupted event quits while the popup shows",
    { INTERRUPTED }, "interrupted"),
}

t.cases(T, "popup", POPUP, function(events)
  local out = {}
  local list = {}
  for _, e in ipairs(events) do
    if e == PROBE then
      list[#list + 1] = function(ctl, items)
        out.popup = popup_shown(ctl, 25)
        out.top = line_at(ctl, 1)
        out.prompt = ctl.row(25):find("Quit?", 1, true) ~= nil
        if out.prompt then
          items[#items + 1] = Y
        else
          if out.popup then
            items[#items + 1] = ENTER
          end
          items[#items + 1] = Q
          items[#items + 1] = Y
        end
      end
    else
      list[#list + 1] = e
    end
  end
  out.result = run({ lines = make_lines(100), events = list,
    opts = { title = "T", error = ERROR_TEXT } })
  return out
end)

-- The popup covers part of the page. The page and the status line stay
-- visible around it.
function T.popup_shows_over_the_page()
  local rows
  run({ lines = make_lines(100), opts = { title = "T", error = ERROR_TEXT },
    events = { function(ctl) rows = ctl.screen() end, ENTER, Q, Y } })
  t.eq(rows[1]:match("^line %d+"), "line 1")
  t.eq(rows[24]:match("^line %d+"), "line 24")
  t.ok(rows[25]:find("^ T "), rows[25])
  t.ok(popup_shown({ row = function(y) return rows[y] end }, 25))
end

-- The popup shows an [OK] button under the error text and no Enter hint.
function T.popup_shows_an_ok_button()
  local rows
  run({ lines = make_lines(100), opts = { title = "T", error = ERROR_TEXT },
    events = { function(ctl) rows = ctl.screen() end, ENTER, Q, Y } })
  local text_y, ok_y
  for y = 1, 24 do
    if rows[y]:find(ERROR_TEXT, 1, true) then text_y = y end
    if rows[y]:find("[OK]", 1, true) then ok_y = y end
  end
  t.ok(text_y and ok_y and ok_y > text_y, "[OK] below the text")
  t.ok(not table.concat(rows, "\n"):find("Enter: close", 1, true))
end

-- After the popup closes, the screen equals the page without a popup.
function T.popup_close_restores_the_page()
  local lines = styled_lines(100)
  local closed = scrolled_screen(lines, { ENTER },
    { title = "T", error = ERROR_TEXT })
  local plain = scrolled_screen(lines, {}, { title = "T" })
  t.eq(closed, plain)
end

-- A long error wraps inside the screen. Every word shows, no cell is
-- written past the edge and the status line stays.
t.cases(T, "popup_long_error", {
  { "long error", string.rep("html: timed out reading \xE4\xB8\xAD\xE6\x96"
    .. "\x87 ", 12), true, sizes = { 50, 51, 80, 160 } },
}, function(text, w)
  local h = w == 160 and 50 or 16
  local screen
  local _, ctl = run({ lines = make_lines(100),
    opts = { title = "T", error = text }, gpu = size(w, h),
    events = { function(c) screen = c.screen() end, ENTER, Q, Y } })
  local joined = table.concat(screen, "\n", 1, h - 1)
  for word in text:gmatch("%S+") do
    if not joined:find(word, 1, true) then
      return "missing word " .. word
    end
  end
  for _, c in ipairs(ctl.find("set")) do
    if c[2] + unicode.wlen(c[4]) - 1 > w then
      return "set past the edge"
    end
  end
  if ctl.overflow then
    return "overflow"
  end
  return screen[h]:find("^ T ") ~= nil
end)

-- No spec rule. The viewer waits with a timeout in every blocking pull.
function T.waits_with_a_timeout()
  local gpu, ctl = fake_gpu.new(size(80, 25))
  local pull, pulls = queue({ TOUCH, key(DOWN), Q, Y }, ctl)
  viewer.run(make_lines(100), {}, { gpu = gpu, term = fake_term(),
    pull = pull })
  for _, timeout in ipairs(pulls) do
    t.eq(type(timeout), "number")
  end
  t.ok(pulls[1] > 0)
end


-- The screen session (spec/loading.md "Startup", "Content during load",
-- "Keys during load" and "Exit") ---------------------------------------------

local WHITE_BG = 0xFFFFFF

-- Opens a session on a fake GPU. A function item in events ends one poll,
-- and the viewer takes it at its next blocking pull.
local function open_session(events, opts, dims)
  local gpu, ctl = fake_gpu.new(dims or size(80, 10))
  local term = fake_term()
  local pull = queue(events or {}, ctl)
  local s = viewer.open({ gpu = gpu, pull = pull, term = term }, opts)
  return s, ctl, term, gpu
end

-- Ends a poll: the queue gives nil to pull(0) until the viewer pulls.
local function gap() return function() end end

-- The text of the status row, without trailing spaces.
local function status_row(ctl, h)
  return (ctl.row(h or 10):gsub("%s+$", ""))
end

function T.session_open_clears_and_draws_the_status_row()
  local s, ctl = open_session({}, { status = "Loading a.html..." })
  t.eq(s.rows, 9)
  t.eq(status_row(ctl), "Loading a.html...")
  local ch, fg, bg = ctl.cell(1, 10)
  t.eq({ ch, fg, bg }, { "L", 0x000000, WHITE_BG })
  for y = 1, 9 do
    t.eq(ctl.row(y), string.rep(" ", 80), "row " .. y .. " is blank")
  end
  local first = ctl.calls
  t.eq(first[#first][1], "set", "the status row is the last draw")
end

function T.session_open_without_status_draws_nothing()
  local _, ctl = open_session({}, { no_rescale = true })
  t.eq(ctl.count("set") + ctl.count("fill"), 0)
end

function T.session_status_redraws_only_the_status_row()
  local s, ctl = open_session({}, { status = "one" })
  ctl.clear_log()
  s.status("two")
  t.eq(status_row(ctl), "two")
  t.eq(ctl.count("fill"), 0)
  t.eq(ctl.count("copy"), 0)
  for _, c in ipairs(ctl.find("set")) do
    t.eq(c[3], 10, "set on the status row")
  end
end

t.cases(T, "session_draw_lines", {
  { "enough lines: rows 1 to 9, from the live table", { 20, 12 },
    { rows = { "line 1", "line 2", "line 3", "line 4", "line 5", "line 6",
      "line 7", "line 8", "line 9" }, status = "load" } },
  { "more lines than rows: only the first rows draw",
    { 30, 30 }, { rows = { "line 1", "line 2", "line 3", "line 4", "line 5",
      "line 6", "line 7", "line 8", "line 9" }, status = "load" } },
  { "count 0 over a full screen: every row is blank", { 20, 0 },
    { rows = { "", "", "", "", "", "", "", "", "" }, status = "load" } },
  { "fewer lines than rows: the rest is blank", { 3, 3 },
    { rows = { "line 1", "line 2", "line 3", "", "", "", "", "", "" },
      status = "load" } },
}, function(input)
  local s, ctl = open_session({}, { status = "load" })
  -- A full screen first, so a blank row is a redraw.
  s.draw_lines(make_lines(20), 20)
  local lines = make_lines(input[1])
  s.draw_lines(lines, input[2])
  local rows = {}
  for y = 1, 9 do
    rows[y] = (ctl.row(y):gsub("%s+$", ""))
  end
  return { rows = rows, status = status_row(ctl) }
end)

-- poll: "q" shows the quit prompt, y or Enter confirms, other keys cancel,
-- other events and keys are dropped (spec/viewer.md "Quit").
local PROMPT_TEXT = " Quit? (y/n)"

t.cases(T, "session_poll", {
  { "no events", {}, { nil, "load" } },
  { "other keys and events are dropped", { key(DOWN), TOUCH, ESC, N },
    { nil, "load" } },
  { "q shows the prompt", { Q }, { nil, PROMPT_TEXT } },
  { "q then y quits", { Q, Y }, { "quit", PROMPT_TEXT } },
  { "q then Y (upper case) quits", { Q, key(21, 89) },
    { "quit", PROMPT_TEXT } },
  { "q then Enter quits", { Q, ENTER }, { "quit", PROMPT_TEXT } },
  { "q then n cancels: the status comes back", { Q, N }, { nil, "load" } },
  { "q then another key cancels", { Q, key(DOWN) }, { nil, "load" } },
  { "a key_up does not answer the prompt", { Q, key_up(21, 121) },
    { nil, PROMPT_TEXT } },
  { "Ctrl+C", { CTRL_C }, { "interrupted", "load" } },
  { "the interrupted event", { INTERRUPTED }, { "interrupted", "load" } },
  { "Ctrl+C while the prompt shows", { Q, CTRL_C },
    { "interrupted", PROMPT_TEXT } },
  { "q while the prompt shows cancels it", { Q, Q }, { nil, "load" } },
  { "z aborts", { key(44, 122) }, { "abort", "load" } },
  { "Z aborts", { key(44, 90) }, { "abort", "load" } },
  { "z after other keys and events aborts",
    { key(DOWN), TOUCH, key(44, 122) }, { "abort", "load" } },
  { "z while the prompt shows only cancels it", { Q, key(44, 122) },
    { nil, "load" } },
  { "z does not abort when Ctrl+C comes first", { CTRL_C, key(44, 122) },
    { "interrupted", "load" } },
  { "key_up of z does not abort", { key_up(44, 122) }, { nil, "load" } },
}, function(events)
  local s, ctl = open_session(events, { status = "load" })
  local result = s.poll()
  return { result, status_row(ctl) }
end)

function T.session_status_keeps_the_prompt_until_the_user_answers()
  local gpu, ctl = fake_gpu.new(size(80, 10))
  local current = {}
  local function pull()
    local e = table.remove(current, 1)
    if e then
      return table.unpack(e)
    end
  end
  local s = viewer.open({ gpu = gpu, pull = pull, term = fake_term() },
    { status = "load" })
  current = { Q }
  t.eq(s.poll(), nil)
  s.status("load 12 KB")
  t.eq(status_row(ctl), PROMPT_TEXT, "the prompt stays")
  current = { N }
  t.eq(s.poll(), nil)
  t.eq(status_row(ctl), "load 12 KB", "the newest status comes back")
end

function T.session_poll_without_pull_returns_nil()
  local gpu = fake_gpu.new(size(80, 10))
  local s = viewer.open({ gpu = gpu, term = fake_term() }, {})
  t.eq(s.poll(), nil)
end

-- show answers a quit prompt that is still on screen from the load, then
-- works as the interactive loop.
t.cases(T, "session_show_after_a_prompt", {
  { "y: quits at once", { Q, gap(), Y }, "quit" },
  { "n: the page stays, then q and y quit", { Q, gap(), N, Q, Y }, "quit" },
  { "Ctrl+C at the prompt", { Q, gap(), CTRL_C }, "interrupted" },
}, function(events)
  local s, ctl = open_session(events, { status = "load" })
  s.poll()
  local result = s.show(make_lines(30), { title = "T" })
  return result
end)

function T.session_show_without_a_prompt_does_not_ask()
  local s, ctl = open_session({ key(DOWN), Q, Y }, { status = "load" })
  t.eq(s.show(make_lines(30), { title = "T" }), "quit")
  t.eq(line_at(ctl, 1), 2, "scrolled by one line")
end

function T.session_show_shows_the_error_popup()
  local s, ctl = open_session({ ENTER, Q, Y }, { status = "load" })
  t.eq(s.show(make_lines(30), { title = "T", error = ERROR_TEXT }), "quit")
  t.eq(line_at(ctl, 1), 1)
end

t.cases(T, "session_close", {
  { "restores the resolution, colors and cursor once",
    { dims = { width = 80, height = 25, max_width = 160, max_height = 50 },
      closes = 2 },
    { resolutions = { { 160, 50 }, { 80, 25 } }, cleared = 1,
      cursor = { 1, 1 } } },
  { "the same size: no resolution change, one restore",
    { dims = size(80, 25), closes = 1 },
    { resolutions = {}, cleared = 1, cursor = { 1, 1 } } },
  { "no_rescale: no resolution change",
    { dims = { width = 80, height = 25, max_width = 160, max_height = 50 },
      opts = { no_rescale = true }, closes = 1 },
    { resolutions = {}, cleared = 1, cursor = { 1, 1 } } },
}, function(input)
  local s, ctl, term = open_session({}, input.opts or { status = "x" },
    input.dims)
  for _ = 1, input.closes do
    s.close()
  end
  local res = {}
  for i, c in ipairs(ctl.find("setResolution")) do
    res[i] = { c[2], c[3] }
  end
  return { resolutions = res, cleared = term.cleared, cursor = term.cursor }
end)

function T.session_open_error_restores_the_screen()
  local gpu = fake_gpu.new({ width = 80, height = 25, max_width = 160,
    max_height = 50 })
  local broken = {}
  for k, v in pairs(gpu) do
    broken[k] = v
  end
  broken.getDepth = function() error("boom", 0) end
  local term = fake_term()
  t.raises(function()
    viewer.open({ gpu = broken, term = term, pull = function() end },
      { status = "x" })
  end, "boom")
  t.eq(term.cleared, 1)
end

function T.session_show_error_keeps_the_screen_for_close()
  local s, _, term = open_session({}, { status = "x" })
  t.raises(function()
    -- The queue is empty, so the viewer raises at its first blocking pull.
    s.show(make_lines(3), {})
  end, "event queue empty")
  t.eq(term.cleared, 0, "show does not restore")
  s.close()
  t.eq(term.cleared, 1)
end

-- Links, selection and the visible cursor (spec/viewer.md "Link keys",
-- "Visible cursor", "Status line") ------------------------------------------

local TAB = key(15, 9)
local KEY_G = key(34, 103)
local HELP = key(53, 63)
local BS = key(14, 8)
local SELECT_BG = 0x6699FF
local LSHIFT_DOWN, RSHIFT_DOWN = key(42, 0), key(54, 0)
local NOOP2 = function() end

-- A packed link span (spec/layout.md "Links and anchors").
local function span(fl, fc, tl, tc)
  return fl << 32 | fc << 24 | (tl - fl) << 8 | tc
end

-- Five links on "line N" rows: the cells 1 to 4 ("line") of lines 3, 10,
-- 30, 60 and 95.
local function fixture()
  return {
    span = { span(3, 1, 3, 4), span(10, 1, 10, 4), span(30, 1, 30, 4),
      span(60, 1, 60, 4), span(95, 1, 95, 4) },
    href = { "a3.html", "a10.html", "a30.html", "a60.html", "a95.html" },
    count = 5,
  }
end

local function resolve(href)
  if href:find("^mailto:") then
    return nil, "mailto: links are not supported"
  end
  return "R:" .. href
end

-- The highlighted cells of rows 1 to h-1 as "row:first-last" strings.
local function highlights(ctl, w, h, bg)
  local out = {}
  for y = 1, h - 1 do
    local first, last
    for x = 1, w do
      local _, _, b = ctl.cell(x, y)
      if b == bg then
        first = first or x
        last = x
      elseif first then
        out[#out + 1] = y .. ":" .. first .. "-" .. last
        first = nil
      end
    end
    if first then
      out[#out + 1] = y .. ":" .. first .. "-" .. last
    end
  end
  return out
end

-- Runs events on 100 lines with the fixture. The result has the viewer
-- result, and the top line, the highlighted cells and the status title at
-- the end of the events. o: events, opts (added to the defaults), links,
-- shift_down, depth, lines.
local function link_run(o)
  local out = {}
  local events = {}
  for _, e in ipairs(o.events) do
    events[#events + 1] = e
  end
  events[#events + 1] = function(ctl)
    local bg = (o.depth == 1) and WHITE or SELECT_BG
    out.top = line_at(ctl, 1)
    out.hl = highlights(ctl, 80, 25, bg)
    out.title = parse_status(ctl.row(25)).title
  end
  events[#events + 1] = Q
  events[#events + 1] = Y
  local opts = { title = "T", links = o.links or fixture(),
    resolve = resolve }
  for k, v in pairs(o.opts or {}) do
    opts[k] = v
  end
  out.result = run({ lines = o.lines or make_lines(100), opts = opts,
    events = events, shift_down = o.shift_down,
    gpu = size(80, 25, o.depth) })
  return out
end

local function shift_yes() return true end
local function shift_no() return false end

local function sel_row(top, hl, title)
  return { result = "quit", top = top, hl = hl, title = title }
end

-- Selection and scroll rules.
t.cases(T, "links_select", {
  { "no selection at the start", { events = {} }, sel_row(1, {}, "T") },
  { "Tab picks the first link at or after top",
    { events = { TAB } }, sel_row(1, { "3:1-4" }, "-> R:a3.html") },
  { "Tab twice picks the second link",
    { events = { TAB, TAB } }, sel_row(1, { "10:1-4" }, "-> R:a10.html") },
  { "Tab to a link below the screen scrolls the least amount",
    { events = { TAB, TAB, TAB } },
    sel_row(7, { "24:1-4" }, "-> R:a30.html") },
  { "Tab at the last link is the last link before the wrap",
    { events = { TAB, TAB, TAB, TAB, TAB } },
    sel_row(72, { "24:1-4" }, "-> R:a95.html") },
  { "Tab at the last link wraps to the first link and scrolls up to it",
    { events = { TAB, TAB, TAB, TAB, TAB, TAB } },
    sel_row(3, { "1:1-4" }, "-> R:a3.html") },
  { "Tab after the wrap goes to the second link",
    { events = { TAB, TAB, TAB, TAB, TAB, TAB, TAB } },
    sel_row(3, { "8:1-4" }, "-> R:a10.html") },
  { "Tab on the only link keeps it",
    { events = { TAB, TAB }, links = { span = { span(3, 1, 3, 4) },
      href = { "a3.html" }, count = 1 } },
    sel_row(1, { "3:1-4" }, "-> R:a3.html") },
  { "Shift+Tab on the only link keeps it",
    { events = { TAB, LSHIFT_DOWN, TAB }, links = { span = { span(3, 1, 3, 4) },
      href = { "a3.html" }, count = 1 } },
    sel_row(1, { "3:1-4" }, "-> R:a3.html") },
  { "Shift+Tab with no links does nothing",
    { events = { LSHIFT_DOWN, TAB }, links = { span = {}, href = {},
      count = 0 } },
    sel_row(1, {}, "T") },
  { "Tab events with draws in between give the same result",
    { events = { TAB, NOOP2, TAB, NOOP2, TAB } },
    sel_row(7, { "24:1-4" }, "-> R:a30.html") },
  { "Tab with the selection off screen picks the first link at or after top",
    { events = { TAB, NOOP2, key(END), NOOP2, TAB } },
    sel_row(77, { "19:1-4" }, "-> R:a95.html") },
  { "Tab on the last visible link wraps to the first link",
    { events = { key(END), NOOP2, TAB, TAB } },
    sel_row(3, { "1:1-4" }, "-> R:a3.html") },
  { "Tab with no selection and no link below wraps to the first link",
    { events = { key(END), NOOP2, TAB }, links = { span = { span(3, 1, 3, 4) },
      href = { "a3.html" }, count = 1 } },
    sel_row(3, { "1:1-4" }, "-> R:a3.html") },
  { "Tab with no selection and no link below scrolls the least amount",
    { events = { key(END), NOOP2, TAB }, links = { span = { span(60, 1, 60, 4),
      span(70, 1, 70, 4) }, href = { "a60.html", "a70.html" }, count = 2 } },
    sel_row(60, { "1:1-4" }, "-> R:a60.html") },
  { "Tab with no links does nothing",
    { events = { TAB }, links = { span = {}, href = {}, count = 0 } },
    sel_row(1, {}, "T") },
  { "Shift+Tab with no selection picks the last visible link",
    { events = { TAB }, shift_down = shift_yes },
    sel_row(1, { "10:1-4" }, "-> R:a10.html") },
  { "the dep false: Tab stays Tab",
    { events = { LSHIFT_DOWN, TAB }, shift_down = shift_no },
    sel_row(1, { "3:1-4" }, "-> R:a3.html") },
  { "Shift+Tab with a selection picks the previous link",
    { events = { TAB, TAB, NOOP2, LSHIFT_DOWN, TAB } },
    sel_row(1, { "3:1-4" }, "-> R:a3.html") },
  { "Shift+Tab scrolls the least amount up",
    { events = { LSHIFT_DOWN, key(END), NOOP2, TAB, TAB } },
    sel_row(60, { "1:1-4" }, "-> R:a60.html") },
  { "Shift+Tab at the first link wraps to the last link and scrolls to it",
    { events = { TAB, LSHIFT_DOWN, TAB } },
    sel_row(72, { "24:1-4" }, "-> R:a95.html") },
  { "Shift+Tab after the wrap goes to the link before the last",
    { events = { TAB, LSHIFT_DOWN, TAB, TAB } },
    sel_row(60, { "1:1-4" }, "-> R:a60.html") },
  { "Shift+Tab with no link at or before the bottom wraps to the last link",
    { events = { LSHIFT_DOWN, TAB }, links = { span = { span(40, 1, 40, 4) },
      href = { "x" }, count = 1 } },
    sel_row(17, { "24:1-4" }, "-> R:x") },
  { "Shift+Tab with no link at or above the bottom picks the last link",
    { events = { LSHIFT_DOWN, TAB }, links = { span = { span(40, 1, 40, 4),
      span(50, 1, 50, 4) }, href = { "a40.html", "a50.html" }, count = 2 } },
    sel_row(27, { "24:1-4" }, "-> R:a50.html") },
  { "Shift by the left Shift key tracking",
    { events = { LSHIFT_DOWN, TAB, key_up(42, 0), TAB } },
    sel_row(7, { "24:1-4" }, "-> R:a30.html") },
  { "Shift by the right Shift key tracking",
    { events = { RSHIFT_DOWN, TAB, key_up(54, 0), TAB } },
    sel_row(7, { "24:1-4" }, "-> R:a30.html") },
  { "Shift tracking: key_up of one Shift keeps the other",
    { events = { LSHIFT_DOWN, RSHIFT_DOWN, key_up(42, 0), TAB } },
    sel_row(1, { "10:1-4" }, "-> R:a10.html") },
  { "the dep wins over the key tracking",
    { events = { RSHIFT_DOWN, TAB }, shift_down = shift_no },
    sel_row(1, { "3:1-4" }, "-> R:a3.html") },
  { "scrolling keeps the selection and moves its highlight",
    { events = { TAB, key(DOWN) } },
    sel_row(2, { "2:1-4" }, "-> R:a3.html") },
  { "a selection off screen shows no highlight and the title",
    { events = { TAB, key(PGDN) } }, sel_row(24, {}, "T") },
  { "the highlight is back when the link scrolls back",
    { events = { TAB, NOOP2, key(PGDN), NOOP2, key(PGUP) } },
    sel_row(1, { "3:1-4" }, "-> R:a3.html") },
  { "Tab and scroll keys in one burst add up",
    { events = { TAB, TAB, TAB, key(DOWN), key(DOWN) } },
    sel_row(9, { "22:1-4" }, "-> R:a30.html") },
  { "depth 4 shows the same highlight",
    { events = { TAB }, depth = 4 },
    sel_row(1, { "3:1-4" }, "-> R:a3.html") },
  { "depth 1 shows the highlight on white",
    { events = { TAB }, depth = 1 },
    sel_row(1, { "3:1-4" }, "-> R:a3.html") },
}, function(input)
  local out = link_run(input)
  return { result = out.result, top = out.top, hl = out.hl,
    title = out.title }
end)

-- Three queued Tab events give one redraw.
function T.links_tab_burst_gives_one_redraw()
  local _, ctl = run({ lines = make_lines(100), opts = { links = fixture() },
    events = { TAB, TAB, TAB, Q, Y } })
  t.eq(ctl.find("copy"), { { "copy", 1, 7, 80, 18, 0, -6 } })
end

-- The highlight colors. The result is the foreground and background of the
-- cell before the link, its first cell, its last cell and the cell after.
local STYLED = { "\1ab \4link text\1 end", "second line" }
local STYLED_LINKS = { span = { span(1, 4, 1, 12) }, href = { "x.html" },
  count = 1 }
local LIGHT_ON_BLACK = { 0xFFFFFF, 0 }

t.cases(T, "links_highlight_colors", {
  { "depth 8", 8, { LIGHT_ON_BLACK, { 0, SELECT_BG }, { 0, SELECT_BG },
    LIGHT_ON_BLACK } },
  { "depth 4", 4, { LIGHT_ON_BLACK, { 0, SELECT_BG }, { 0, SELECT_BG },
    LIGHT_ON_BLACK } },
  { "depth 1", 1, { LIGHT_ON_BLACK, { 0, WHITE }, { 0, WHITE },
    LIGHT_ON_BLACK } },
}, function(depth)
  local out
  run({ lines = STYLED, opts = { links = STYLED_LINKS },
    gpu = size(80, 25, depth), events = { TAB, function(ctl)
      out = {}
      for _, x in ipairs({ 3, 4, 12, 13 }) do
        local _, fg, bg = ctl.cell(x, 1)
        out[#out + 1] = { fg, bg }
      end
    end, Q, Y } })
  return out
end)

function T.links_highlight_keeps_the_text()
  local text
  run({ lines = STYLED, opts = { links = STYLED_LINKS },
    events = { TAB, function(ctl) text = ctl.row(1) end, Q, Y } })
  t.eq(text, "ab link text end" .. string.rep(" ", 64))
end

-- A link over several lines, and wide characters. The result is the
-- highlighted cells. A continuation line starts at its first non-blank cell.
local SHAPE_LINES = { "x \4two\1", "\4words\1 more",
  "\4\xE4\xB8\xAD\xE6\x96\x87\1 x", "  \4cont", "  \4more\1 tail" }

t.cases(T, "links_highlight_shapes", {
  { "a link over two lines", { span(1, 3, 2, 5) }, { "1:3-5", "2:1-5" } },
  { "a link over three lines skips the leading spaces",
    { span(3, 1, 5, 6) }, { "3:1-6", "4:3-6", "5:3-6" } },
  { "a wide character is kept whole", { span(3, 1, 3, 4) }, { "3:1-4" } },
  { "the end inside a wide character keeps it whole",
    { span(3, 1, 3, 3) }, { "3:1-4" } },
  { "the start inside a wide character keeps it whole",
    { span(3, 2, 3, 4) }, { "3:1-4" } },
  { "a link on one line", { span(1, 3, 1, 5) }, { "1:3-5" } },
}, function(sp)
  local out
  run({ lines = SHAPE_LINES, opts = { links = { span = { sp[1] },
    href = { "x" }, count = 1 } }, events = { TAB, function(ctl)
      out = highlights(ctl, 80, 25, SELECT_BG)
    end, Q, Y } })
  return out
end)

-- The cut helper: the text of the cell columns a to b and the column of its
-- first cell.
t.cases(T, "links_cut", {
  { "plain text", { "abcdef", 2, 4 }, { "bcd", 2 } },
  { "style bytes do not count", { "\1ab\2cd\4ef", 2, 5 }, { "bcde", 2 } },
  { "a wide character inside", { "\xE4\xB8\xAD\xE6\x96\x87x", 1, 4 },
    { "\xE4\xB8\xAD\xE6\x96\x87", 1 } },
  { "a wide character cut at its second cell",
    { "a\xE4\xB8\xAD" .. "b", 3, 3 }, { "\xE4\xB8\xAD", 2 } },
  { "a wide character cut at its first cell",
    { "a\xE4\xB8\xAD" .. "b", 1, 2 }, { "a\xE4\xB8\xAD", 1 } },
  { "past the end", { "abc", 5, 9 }, { "" } },
  { "to the end", { "abc", 2, math.maxinteger }, { "bc", 2 } },
  { "an empty line", { "", 1, 5 }, { "" } },
}, function(input)
  local text, col = viewer._cut(input[1], input[2], input[3])
  return { text, col }
end)

-- The old and the new selection rows are drawn again, and the status row.
function T.links_redraw_old_and_new_rows()
  local drawn
  run({ lines = make_lines(100), opts = { links = fixture() }, events = {
    TAB, function(ctl) ctl.clear_log() end, TAB, function(ctl)
      local seen = {}
      for _, name in ipairs({ "set", "fill" }) do
        for _, c in ipairs(ctl.find(name)) do
          seen[c[3]] = true
        end
      end
      drawn = {}
      for y = 1, 25 do
        if seen[y] then
          drawn[#drawn + 1] = y
        end
      end
    end, Q, Y } })
  t.eq(drawn, { 3, 10, 25 })
end

-- Spans that start past the last line are ignored. The page has 10 lines.
local PAST_LINKS = { span = { span(5, 1, 5, 4), span(11, 1, 11, 4),
  span(40, 1, 40, 4) }, href = { "a5.html", "a11.html", "a40.html" },
  count = 3 }
local ONLY_PAST = { span = { span(11, 1, 11, 4) }, href = { "x" }, count = 1 }

t.cases(T, "links_past_the_end", {
  { "Tab skips them", { events = { TAB, TAB, TAB, ENTER } },
    { kind = "link", href = "a5.html", text = "R:a5.html", top = 1,
      sel = 1 } },
  { "Shift+Tab skips them",
    { events = { TAB, ENTER }, shift_down = shift_yes },
    { kind = "link", href = "a5.html", text = "R:a5.html", top = 1,
      sel = 1 } },
  { "a page with only such spans has no selection",
    { events = { TAB, ENTER, Q, Y }, links = ONLY_PAST }, "quit" },
  { "a restored sel on such a span moves to the last valid link",
    { events = { key(203, 0) }, opts = { sel = 3 } },
    { kind = "back", top = 1, sel = 1 } },
}, function(input)
  return (run({ lines = make_lines(10), opts = { title = "T",
    links = input.links or PAST_LINKS, resolve = resolve,
    sel = (input.opts or {}).sel }, events = input.events,
    shift_down = input.shift_down }))
end)

-- opts.top and opts.sel restore the position, clamped.
t.cases(T, "links_restore", {
  { "top", { top = 5 }, { top = 5, hl = {}, title = "T" } },
  { "top clamped to the last top line", { top = 500 },
    { top = 77, hl = {}, title = "T" } },
  { "top below 1 clamped to 1", { top = 0 },
    { top = 1, hl = {}, title = "T" } },
  { "sel with its link on screen", { top = 7, sel = 3 },
    { top = 7, hl = { "24:1-4" }, title = "-> R:a30.html" } },
  { "sel off screen shows no highlight", { sel = 3 },
    { top = 1, hl = {}, title = "T" } },
  { "sel past the count is clamped to the last link",
    { top = 77, sel = 99 },
    { top = 77, hl = { "19:1-4" }, title = "-> R:a95.html" } },
  { "sel 0 is clamped to the first link", { sel = 0 },
    { top = 1, hl = { "3:1-4" }, title = "-> R:a3.html" } },
  { "the restored position is in the action",
    { top = 7, sel = 3, action = key(203, 0) },
    { kind = "back", top = 7, sel = 3 } },
  { "a clamped position is in the action",
    { top = 500, sel = 99, action = key(203, 0) },
    { kind = "back", top = 77, sel = 5 } },
  { "sel with no links is dropped",
    { sel = 2, nolinks = true, action = key(203, 0) },
    { kind = "back", top = 1 } },
}, function(input)
  local links
  if input.nolinks then
    links = { span = {}, href = {}, count = 0 }
  end
  if input.action then
    return (link_run({ events = { input.action }, links = links,
      opts = { top = input.top, sel = input.sel } }).result)
  end
  local out = link_run({ events = {}, opts = { top = input.top,
    sel = input.sel } })
  return { top = out.top, hl = out.hl, title = out.title }
end)

-- The status row text: the title part, or the whole text of a notice.
local function status_text(ctl)
  local s = ctl.row(25)
  return parse_status(s).title or (s:match("^ (.-)%s*$"))
end

-- Status line texts (spec/viewer.md "Status line").
t.cases(T, "links_status", {
  { "the target of the selected link", { events = { TAB } },
    "-> R:a3.html" },
  { "the HTTP prefix stays", { events = { TAB },
    opts = { title = "[HTTP 404] Not Found" } }, "[HTTP 404] -> R:a3.html" },
  { "the HTTP prefix without a phrase stays", { events = { TAB },
    opts = { title = "[HTTP 500]" } }, "[HTTP 500] -> R:a3.html" },
  { "a title that only looks like a prefix is replaced",
    { events = { TAB }, opts = { title = "[x] page" } }, "-> R:a3.html" },
  { "the HTTP prefix stays only with a selection",
    { events = {}, opts = { title = "[HTTP 404] Not Found" } },
    "[HTTP 404] Not Found" },
  { "no resolve: the raw href", { events = { TAB },
    opts = { resolve = false } }, "-> a3.html" },
  { "the title returns when the link scrolls away",
    { events = { TAB, NOOP2, key(PGDN) } }, "T" },
  { "an href that is false", { events = { TAB },
    links = { span = { span(3, 1, 3, 4) }, href = { false }, count = 1 } },
    "-> (link too long)" },
}, function(input)
  return (link_run(input).title)
end)

-- A long target is cut inside the width, with the short hint on 50 columns.
function T.links_status_stays_inside_the_width()
  local href = "http://example.com/" .. string.rep("long/", 40)
  local _, ctl = run({ lines = make_lines(100), opts = { title = "T",
    links = { span = { span(3, 1, 3, 4) }, href = { href }, count = 1 },
    resolve = resolve }, gpu = size(50, 16), events = { TAB, function(c)
      local s = c.row(16)
      t.eq(unicode.wlen(s), 50)
      t.ok(s:find("^ %-> R:http://example%.com/"), s)
      t.ok(s:find("q:quit $"), s)
    end, Q, Y } })
  t.ok(not ctl.overflow)
end

-- Enter (spec/viewer.md "Link keys"). The result is the viewer result.
t.cases(T, "links_enter", {
  { "Enter follows the visible selected link", { events = { TAB, ENTER } },
    { kind = "link", href = "a3.html", text = "R:a3.html", top = 1,
      sel = 1 } },
  { "the action has the top and the selection",
    { events = { TAB, TAB, TAB, ENTER } },
    { kind = "link", href = "a30.html", text = "R:a30.html", top = 7,
      sel = 3 } },
  { "Enter with the key code only", { events = { TAB, key(28, 0) } },
    { kind = "link", href = "a3.html", text = "R:a3.html", top = 1,
      sel = 1 } },
  { "Enter with no selection does nothing", { events = { ENTER, Q, Y } },
    "quit" },
  { "Enter with the selection off screen does nothing",
    { events = { TAB, key(PGDN), ENTER, Q, Y } }, "quit" },
  { "Enter works again when the link scrolls back",
    { events = { TAB, key(PGDN), NOOP2, key(PGUP), NOOP2, ENTER } },
    { kind = "link", href = "a3.html", text = "R:a3.html", top = 1,
      sel = 1 } },
  { "Enter without a resolve gives the raw href",
    { events = { TAB, ENTER }, opts = { resolve = false } },
    { kind = "link", href = "a3.html", top = 1, sel = 1 } },
  { "Enter after a burst of Tab events", { events = { TAB, TAB, ENTER } },
    { kind = "link", href = "a10.html", text = "R:a10.html", top = 1,
      sel = 2 } },
}, function(input)
  return (link_run(input).result)
end)

-- Enter on a link that cannot be followed. The result is the status title
-- after Enter and after the next key (Down).
t.cases(T, "links_enter_notice", {
  { "an href that is false", false,
    { "link too long", "-> (link too long)" } },
  { "an unsupported scheme", "mailto:a@b.c",
    { "mailto: links are not supported", "-> mailto:a@b.c" } },
}, function(href)
  local out = {}
  local result = run({ lines = make_lines(100), opts = { title = "T",
    links = { span = { span(3, 1, 3, 4) }, href = { href }, count = 1 },
    resolve = resolve }, events = { TAB, ENTER, function(ctl)
      out[1] = status_text(ctl)
    end, key(DOWN), function(ctl)
      out[2] = parse_status(ctl.row(25)).title
    end, Q, Y } })
  t.eq(result, "quit")
  return out
end)

-- The notice stays until a key_down. A key_up and a touch do not clear it.
function T.links_notice_stays_until_the_next_key()
  local seen = {}
  local function probe()
    return function(ctl)
      seen[#seen + 1] = status_text(ctl)
    end
  end
  run({ lines = make_lines(100), opts = { title = "T",
    links = { span = { span(3, 1, 3, 4) }, href = { "mailto:x" },
      count = 1 }, resolve = resolve },
    events = { TAB, ENTER, key_up(28, 13), probe(), TOUCH, probe(),
      key(30, 97), probe(), Q, Y } })
  t.eq(seen, { "mailto: links are not supported",
    "mailto: links are not supported", "-> mailto:x" })
end

-- A held Enter does not follow a link after a popup closed on Enter, until
-- the key_up of code 28.
local LINK_A3 = { kind = "link", href = "a3.html", text = "R:a3.html", top = 1,
  sel = 1 }

t.cases(T, "links_held_enter", {
  { "after the error popup",
    { events = { ENTER, TAB, ENTER, Q, Y }, opts = { error = ERROR_TEXT } },
    "quit" },
  { "after the error popup, with the key_up",
    { events = { ENTER, TAB, ENTER, key_up(28, 13), ENTER },
      opts = { error = ERROR_TEXT } }, LINK_A3 },
  { "after the help popup", { events = { TAB, HELP, ENTER, ENTER, Q, Y } },
    "quit" },
  { "after the help popup, with the key_up",
    { events = { TAB, HELP, ENTER, key_up(28, 13), ENTER } }, LINK_A3 },
  { "an unrelated key_up does not clear it",
    { events = { TAB, HELP, ENTER, key_up(30, 97), ENTER, Q, Y } }, "quit" },
  { "after the go prompt closes on Enter in the same show",
    { events = { TAB, KEY_G, ENTER, TAB, ENTER, Q, Y } }, "quit" },
  { "no popup: Enter acts at once", { events = { TAB, ENTER } }, LINK_A3 },
}, function(input)
  return (link_run(input).result)
end)

-- The held Enter rule holds across the shows of one session: the go prompt
-- closes on Enter in the first show.
t.cases(T, "links_held_enter_after_the_prompt", {
  { "no key_up", { TAB, ENTER, Q, Y }, "quit" },
  { "with the key_up", { key_up(28, 13), TAB, ENTER }, LINK_A3 },
}, function(events)
  local list = { KEY_G, key(30, 120), ENTER }
  for _, e in ipairs(events) do
    list[#list + 1] = e
  end
  local s = open_session(list, { no_rescale = true }, size(80, 25))
  t.eq(s.show(make_lines(100), { links = fixture(), resolve = resolve }),
    { kind = "go", text = "x", top = 1 })
  return s.show(make_lines(100), { links = fixture(), resolve = resolve })
end)

-- Back, Forward, reload and the other keys.
t.cases(T, "navigation_keys", {
  { "Left", { key(203, 0) }, { kind = "back", top = 1 } },
  { "Left with a char", { key(203, 52) }, { kind = "back", top = 1 } },
  { "NumPad 4 (code 75) with char 0", { key(75, 0) },
    { kind = "back", top = 1 } },
  { "NumPad 4 (code 75) with a digit char", { key(75, 52), Q, Y }, "quit" },
  { "Right", { key(205, 0) }, { kind = "forward", top = 1 } },
  { "NumPad 6 (code 77) with char 0", { key(77, 0) },
    { kind = "forward", top = 1 } },
  { "NumPad 6 (code 77) with a digit char", { key(77, 54), Q, Y }, "quit" },
  { "Backspace", { key(14, 8) }, { kind = "back", top = 1 } },
  { "Backspace with char 0", { key(14, 0) }, { kind = "back", top = 1 } },
  { "r", { key(19, 114) }, { kind = "reload", top = 1 } },
  { "R", { key(19, 82) }, { kind = "reload", top = 1 } },
  { "F5 does nothing", { key(63, 0), Q, Y }, "quit" },
  { "z does nothing in the page", { key(44, 122), Q, Y }, "quit" },
  { "other keys do nothing", { key(30, 97), TOUCH, Q, Y }, "quit" },
  { "the top is in the action", { key(DOWN), key(DOWN), key(203, 0) },
    { kind = "back", top = 3 } },
  { "the selection is in the action", { TAB, TAB, key(205, 0) },
    { kind = "forward", top = 1, sel = 2 } },
  { "a burst of Tab and Left: the Tab events apply first",
    { TAB, TAB, key(203, 0) }, { kind = "back", top = 1, sel = 2 } },
  { "a burst of Down and r: the scroll applies first",
    { key(DOWN), key(DOWN), key(19, 114) }, { kind = "reload", top = 3 } },
  { "Ctrl+C in a burst after Tab", { TAB, CTRL_C }, "interrupted" },
  { "the quit prompt works with links", { TAB, Q, Y }, "quit" },
  { "any other key cancels the quit prompt",
    { Q, key(203, 0), Q, Y }, "quit" },
}, function(events)
  return (link_run({ events = events }).result)
end)

-- The go prompt (spec/navigation.md "Go prompt"). The result has the viewer
-- result, whether the prompt shows, its text, the column of the input
-- cursor (the first cell with a black background on the status row) and
-- the top line.
local function chars(text)
  local list = {}
  for i = 1, #text do
    list[i] = key(30, text:byte(i))
  end
  return list
end

local function cat(...)
  local list = {}
  for _, part in ipairs({ ... }) do
    for _, e in ipairs(part) do
      list[#list + 1] = e
    end
  end
  return list
end

local function go_run(events, after, opts)
  local out = {}
  local list = {}
  for _, e in ipairs(events) do
    list[#list + 1] = e
  end
  list[#list + 1] = function(ctl)
    local row = (ctl.row(25):gsub("%s+$", ""))
    out.prompt = row:find("^ Go to:") ~= nil
    out.text = out.prompt and row:match("^ Go to: ?(.*)$") or nil
    for x = 1, 80 do
      local _, _, bg = ctl.cell(x, 25)
      if bg == 0 then
        out.cursor = out.cursor or x
      end
    end
    out.top = line_at(ctl, 1)
  end
  for _, e in ipairs(after) do
    list[#list + 1] = e
  end
  local o = { title = "T", links = fixture(), resolve = resolve }
  for k, v in pairs(opts or {}) do
    o[k] = v
  end
  out.result = run({ lines = make_lines(100), opts = o, events = list })
  return out
end

local CANCEL_END = { ESC, Q, Y }
local CLOSED = { result = "quit", prompt = false, top = 1 }

local function open_row(text, cursor, top)
  return { result = "quit", prompt = true, text = text, cursor = cursor,
    top = top or 1 }
end

t.cases(T, "go_prompt", {
  { "an empty prompt with the input cursor",
    { events = cat({ KEY_G }), after = CANCEL_END }, open_row("", 9) },
  { "typing shows the text",
    { events = cat({ KEY_G }, chars("a/b.html")), after = CANCEL_END },
    open_row("a/b.html", 17) },
  { "Backspace deletes the last character",
    { events = cat({ KEY_G }, chars("abc"), { BS }), after = CANCEL_END },
    open_row("ab", 11) },
  { "Backspace with the code only",
    { events = cat({ KEY_G }, chars("abc"), { key(14, 0) }),
      after = CANCEL_END }, open_row("ab", 11) },
  { "Backspace on an empty prompt does nothing",
    { events = cat({ KEY_G, BS, BS }, chars("a")), after = CANCEL_END },
    open_row("a", 10) },
  { "a space is appended, control characters are not",
    { events = cat({ KEY_G }, chars("a b"), { key(30, 127), key(30, 1) }),
      after = CANCEL_END }, open_row("a b", 12) },
  { "a space is the first character of the text",
    { events = cat({ KEY_G, key(57, 32) }, chars("a")),
      after = CANCEL_END }, open_row(" a", 11) },
  { "a space submits as part of the text",
    { events = cat({ KEY_G }, chars("my dir/a.html"), { ENTER }), after = {} },
    { result = { kind = "go", text = "my dir/a.html", top = 1 } } },
  { "0x21 and 0x7E are appended",
    { events = { KEY_G, key(2, 33), key(41, 126) }, after = CANCEL_END },
    open_row("!~", 11) },
  { "scroll keys do nothing in the prompt",
    { events = cat({ KEY_G, key(DOWN), key(END) }, chars("a")),
      after = CANCEL_END }, open_row("a", 10) },
  { "q is text in the prompt, not quit",
    { events = { KEY_G, Q }, after = CANCEL_END }, open_row("q", 10) },
  { "g is text in the prompt", { events = { KEY_G, KEY_G },
    after = CANCEL_END }, open_row("g", 10) },
  { "a clipboard event appends",
    { events = cat({ KEY_G }, chars("x"),
      { { "clipboard", "kbd", "y.org/z\n", "player" } }),
      after = CANCEL_END }, open_row("xy.org/z", 17) },
  { "a clipboard event with other text and spaces",
    { events = { KEY_G, { "clipboard", "kbd", "  a b \xE4\xB8\xAD\n c", "p" } },
      after = CANCEL_END }, open_row("a b", 12) },
  { "Esc cancels and the status comes back",
    { events = cat({ KEY_G }, chars("abc"), { ESC }), after = { Q, Y } },
    CLOSED },
  { "Esc with char 0 cancels",
    { events = cat({ KEY_G }, chars("abc"), { key(1, 0) }),
      after = { Q, Y } }, CLOSED },
  { "an empty Enter cancels", { events = { KEY_G, ENTER }, after = { Q, Y } },
    CLOSED },
  { "Enter submits the text",
    { events = cat({ KEY_G }, chars("a/b.html"), { ENTER }), after = {} },
    { result = { kind = "go", text = "a/b.html", top = 1 } } },
  { "Enter with the code only submits",
    { events = cat({ KEY_G }, chars("a"), { key(28, 0) }), after = {} },
    { result = { kind = "go", text = "a", top = 1 } } },
  { "the action has the top and the selection",
    { events = { key(DOWN), TAB, KEY_G, key(30, 117), ENTER }, after = {} },
    { result = { kind = "go", text = "u", top = 2, sel = 1 } } },
  { "a clipboard text submits",
    { events = { KEY_G, { "clipboard", "kbd", "http://x.org/", "p" }, ENTER },
      after = {} }, { result = { kind = "go", text = "http://x.org/",
      top = 1 } } },
  { "Ctrl+C quits", { events = cat({ KEY_G }, chars("a"), { CTRL_C }),
    after = {} }, { result = "interrupted" } },
  { "the interrupted event quits",
    { events = cat({ KEY_G }, chars("a"), { INTERRUPTED }), after = {} },
    { result = "interrupted" } },
}, function(input)
  local out = go_run(input.events, input.after)
  if #input.after == 0 then
    return { result = out.result }
  end
  return out
end)

-- A text longer than the row shows its end, with the cursor inside.
function T.go_prompt_long_text_stays_inside_the_row()
  local text = string.rep("abcdefghij", 10)
  local out, ctl_after
  local _, ctl = run({ lines = make_lines(100), opts = { title = "T" },
    events = cat({ KEY_G }, chars(text), { function(c)
      out = (c.row(25):gsub("%s+$", ""))
      ctl_after = c.cell(80, 25)
    end, ESC, Q, Y }) })
  t.ok(not ctl.overflow)
  t.eq(#out, 79)
  t.ok(out:find("^ Go to: ") and out:sub(-5) == "fghij", out)
end

-- The key list popup (spec/viewer.md "Navigation keys").
local function help_state(ctl, h)
  local joined = table.concat(ctl.screen(), "\n", 1, h - 1)
  local shown = {}
  for _, word in ipairs({ "Tab", "Shift+Tab", "Enter", "Left", "Backspace",
      "Right", "r: reload", "g: go", "Up, Down, PgUp, PgDn, Home, End",
      "q: quit", "?: this list", "[OK]" }) do
    shown[#shown + 1] = joined:find(word, 1, true) ~= nil
  end
  return shown
end

local ALL_SHOWN = {}
local NONE_SHOWN = {}
for i = 1, 12 do
  ALL_SHOWN[i] = true
  NONE_SHOWN[i] = false
end

t.cases(T, "help_popup", {
  { "? lists the keys", { HELP }, ALL_SHOWN },
  { "Esc does not close it", { HELP, ESC }, ALL_SHOWN },
  { "scroll keys, q and other keys are ignored",
    { HELP, key(DOWN), key(END), Q, key(30, 97), Y, key(203, 0) },
    ALL_SHOWN },
  { "key_up of Enter does not close it", { HELP, key_up(28, 13) },
    ALL_SHOWN },
  { "touch does not close it", { HELP, TOUCH }, ALL_SHOWN },
  { "Enter closes it", { HELP, ENTER }, NONE_SHOWN },
  { "it can open again", { HELP, ENTER, key_up(28, 13), HELP }, ALL_SHOWN },
}, function(events, size_h)
  local out
  local list = {}
  for _, e in ipairs(events) do
    list[#list + 1] = e
  end
  list[#list + 1] = function(ctl) out = help_state(ctl, 25) end
  list[#list + 1] = ENTER
  list[#list + 1] = Q
  list[#list + 1] = Y
  run({ lines = make_lines(100), opts = { title = "T" }, events = list })
  return out
end)

function T.help_popup_fits_a_small_screen()
  local out, ctl_out
  local _, ctl = run({ lines = make_lines(100), opts = { title = "T" },
    gpu = size(50, 16), events = { HELP, function(c)
      out = help_state(c, 16)
    end, ENTER, Q, Y } })
  t.eq(out, ALL_SHOWN)
  t.ok(not ctl.overflow)
end

function T.help_popup_ctrl_c_quits()
  t.eq((run({ lines = make_lines(100), events = { HELP, CTRL_C } })),
    "interrupted")
end

function T.help_popup_close_restores_the_page()
  local lines = make_lines(100)
  local closed = scrolled_screen(lines, { HELP, ENTER }, { title = "T" })
  local plain = scrolled_screen(lines, {}, { title = "T" })
  t.eq(closed, plain)
end

return T
