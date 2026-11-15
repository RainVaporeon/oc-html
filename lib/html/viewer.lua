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
  "Up, Down, PgUp, PgDn, Home, End: scroll",
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
        if SCROLL_KEYS[a] then
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
