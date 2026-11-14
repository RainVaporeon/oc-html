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
local POPUP_BUTTON = "[OK]"

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

local function is_enter(char, code)
  return char == CHAR_ENTER or code == CODE_ENTER
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
      local cut = head:match("^(.*[^ ]) ")
      if cut then
        head = cut
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

  local function draw_row(y)
    draw_line(gpu, screen, color, w, lines[top + y - 1] or "", y)
  end

  local function draw_rows(from, to)
    for y = from, to do
      draw_row(y)
    end
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
    screen.status(left .. rep(" ", w - #right - wlen(left)) .. right)
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
    screen.status(PROMPT)
    while true do
      local name, _, char, code = pull(IDLE_TIMEOUT)
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
  -- "interrupted" on Ctrl+C, else nil.
  local function show_popup(text)
    local first, last = screen.popup(text .. "\n\n" .. POPUP_BUTTON)
    while true do
      local name, _, char, code = pull(IDLE_TIMEOUT)
      if name == "interrupted" then
        return "interrupted"
      end
      if name == "key_down" then
        if char == CHAR_CTRL_C then
          return "interrupted"
        end
        if is_enter(char, code) then
          draw_rows(first, last)
          return nil
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

-- Opens a screen session: saves the GPU state, sets the resolution (unless
-- opts.no_rescale) and reads the size. With opts.status it also clears the
-- screen and draws that text on the status row. Returns a session:
--   rows                     the number of line rows (the height minus 1)
--   status(text)             redraws the status row only
--   draw_lines(lines, count) draws the first screen from lines, which can
--                            still grow. It reads lines[1] to lines[rows]
--   poll()                   takes the queued events without waiting. Returns
--                            "interrupted", "quit" (the user confirmed the
--                            quit prompt) or nil. "q" shows the quit prompt
--                            and the status row keeps it until the user
--                            answers. Other keys are dropped
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
    base = { w = w, h = h, screen = new_screen(gpu, w, h),
      color = gpu.getDepth() > 1 and COLORS or PLAIN }
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

  function s.poll()
    if not pull then
      return nil
    end
    while true do
      local name, _, char, code = pull(0)
      if name == nil then
        return nil
      end
      if name == "interrupted"
          or (name == "key_down" and char == CHAR_CTRL_C) then
        return "interrupted"
      end
      if prompt then
        if name == "key_down" then
          if char == CHAR_Y or char == CHAR_UPPER_Y or is_enter(char, code) then
            return "quit"
          end
          prompt = false
          base.screen.status(text)
        end
      elseif classify(name, char, code) == "quit" then
        prompt = true
        base.screen.status(PROMPT)
      end
    end
  end

  function s.show(lines, o)
    return view(lines, o or {}, gpu, pull, base, prompt)
  end

  function s.close()
    if not closed then
      closed = true
      restore()
    end
  end

  return s
end

-- Shows lines until the user quits. Returns "quit" or "interrupted".
-- opts: title, file (shown when there is no title), no_rescale, error.
-- opts.error is a text shown in a popup over the first screen. Only Enter
-- closes it, then the user browses as usual.
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
  return { gpu = component.gpu, pull = event.pull, term = term }
end

return M
