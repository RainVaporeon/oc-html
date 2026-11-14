-- Test replacement for a GPU component proxy.
-- Values follow docs/probe/FACTS.md ("GPU"). M.new returns a proxy and a
-- control table. The proxy records every call and keeps a cell buffer.

local unicode = require("unicode")

local M = {}

local CHAR_PATTERN = "[%z\1-\x7F\xC2-\xFD][\x80-\xBF]*"

-- opts: width, height (current resolution), max_width, max_height, depth.
function M.new(opts)
  opts = opts or {}
  local max_w = opts.max_width or 160
  local max_h = opts.max_height or 50
  local w = opts.width or max_w
  local h = opts.height or max_h
  local depth = opts.depth or 8
  local fg, bg = 0xFFFFFF, 0x000000
  local calls = {}
  local ctl = { calls = calls, overflow = false }
  local cells

  local function blank()
    cells = {}
    for y = 1, h do
      local row = {}
      for x = 1, w do
        row[x] = { " ", fg, bg }
      end
      cells[y] = row
    end
  end
  blank()

  local function log(name, ...)
    calls[#calls + 1] = { name, ... }
  end

  local function put(x, y, ch)
    if y < 1 or y > h then
      return
    end
    if x < 1 or x > w then
      ctl.overflow = true
      return
    end
    cells[y][x] = { ch, fg, bg }
  end

  local gpu = {}

  function gpu.getResolution()
    log("getResolution")
    return w, h
  end

  function gpu.maxResolution()
    log("maxResolution")
    return max_w, max_h
  end

  function gpu.setResolution(nw, nh)
    log("setResolution", nw, nh)
    -- Measured: 120x60 works with a 160x50 maximum. The cell count is the
    -- limit.
    if nw < 1 or nh < 1 or nw > max_w or nw * nh > max_w * max_h then
      error("unsupported resolution", 2)
    end
    local changed = nw ~= w or nh ~= h
    w, h = nw, nh
    blank()
    return changed
  end

  function gpu.getDepth()
    log("getDepth")
    return depth
  end

  -- Like the measured GPU: returns the old color, also for the same color.
  function gpu.setForeground(c, palette)
    log("setForeground", c, palette)
    local old = fg
    fg = c
    return old, false
  end

  function gpu.setBackground(c, palette)
    log("setBackground", c, palette)
    local old = bg
    bg = c
    return old, false
  end

  function gpu.getForeground()
    log("getForeground")
    return fg, false
  end

  function gpu.getBackground()
    log("getBackground")
    return bg, false
  end

  -- A wide character takes two cells. The second one holds "", and get()
  -- returns a space for it (measured).
  function gpu.set(x, y, s)
    log("set", x, y, s)
    for ch in s:gmatch(CHAR_PATTERN) do
      put(x, y, ch)
      if unicode.charWidth(ch) > 1 then
        put(x + 1, y, "")
        x = x + 2
      else
        x = x + 1
      end
    end
    return true
  end

  function gpu.fill(x, y, fw, fh, ch)
    log("fill", x, y, fw, fh, ch)
    for yy = y, y + fh - 1 do
      for xx = x, x + fw - 1 do
        if yy >= 1 and yy <= h and xx >= 1 and xx <= w then
          cells[yy][xx] = { ch, fg, bg }
        end
      end
    end
    return true
  end

  -- Copies a snapshot of the source. The source cells stay as they were.
  function gpu.copy(x, y, cw, ch, tx, ty)
    log("copy", x, y, cw, ch, tx, ty)
    local snap = {}
    for yy = y, y + ch - 1 do
      for xx = x, x + cw - 1 do
        if yy >= 1 and yy <= h and xx >= 1 and xx <= w then
          snap[#snap + 1] = { xx + tx, yy + ty, cells[yy][xx] }
        end
      end
    end
    for _, s in ipairs(snap) do
      local dx, dy = s[1], s[2]
      if dy >= 1 and dy <= h and dx >= 1 and dx <= w then
        cells[dy][dx] = s[3]
      end
    end
    return true
  end

  function gpu.get(x, y)
    log("get", x, y)
    local c = cells[y][x]
    if c[1] == "" then
      return " ", c[2], c[3]
    end
    return c[1], c[2], c[3]
  end

  -- The text of row y. A wide character counts once.
  function ctl.row(y)
    local out = {}
    for x = 1, w do
      out[x] = cells[y][x][1]
    end
    return table.concat(out)
  end

  -- The character, foreground and background of a cell.
  function ctl.cell(x, y)
    local c = cells[y][x]
    return c[1], c[2], c[3]
  end

  -- The text of every row.
  function ctl.screen()
    local out = {}
    for y = 1, h do
      out[y] = ctl.row(y)
    end
    return out
  end

  -- The number of calls with this name.
  function ctl.count(name)
    local n = 0
    for _, c in ipairs(calls) do
      if c[1] == name then
        n = n + 1
      end
    end
    return n
  end

  -- The calls with this name, in order.
  function ctl.find(name)
    local out = {}
    for _, c in ipairs(calls) do
      if c[1] == name then
        out[#out + 1] = c
      end
    end
    return out
  end

  function ctl.clear_log()
    for i = #calls, 1, -1 do
      calls[i] = nil
    end
  end

  function ctl.colors()
    return fg, bg
  end

  return gpu, ctl
end

M.test = {}

function M.test.reset()
end

return M
