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
M.VERSION = "0.0.3a"
M.sizes["bin/html.lua"] = 11934
M.files["bin/html.lua"] = [=[
-- html: renders a local HTML file as text.
-- Run as a program: html [options] <file>
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

local guard = require("html.guard")
local tokenizer = require("html.tokenizer")
local layout = require("html.layout")

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

M.USAGE = [[
Usage: html [options] <file>
Renders a local HTML file as text.
Options:
  --width <n>         wrap lines at n columns (default: screen width)
  --stats             print file size, line count, render time and memory
  --stats-out <path>  also write the stats lines to a file (sets --stats)
  --help              show this help]]

-- Returns an options table, or nil and a controlled error message.
function M.parse_args(argv)
  local opts = {}
  local i, count = 1, argv.n or #argv
  while i <= count do
    local a = tostring(argv[i])
    if a == "--help" or a == "-h" then
      opts.help = true
    elseif a == "--stats" then
      opts.stats = true
    elseif a == "--stats-out" then
      i = i + 1
      local p = argv[i]
      if type(p) ~= "string" or p == "" then
        return nil, "html: --stats-out needs a file path"
      end
      opts.stats = true
      opts.stats_out = p
    elseif a == "--width" then
      i = i + 1
      local w = math.tointeger(tonumber(argv[i]))
      if not w or w < 1 then
        return nil, "html: --width needs a positive whole number"
      end
      opts.width = w
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

local function is_controlled(e)
  return type(e) == "string" and sub(e, 1, 6) == "html: "
end

-- Removes the style bytes.
local function plain(line)
  if find(line, "[\1-\5]") then
    return (gsub(line, "[\1-\5]", ""))
  end
  return line
end

-- Runs the tokenizer and layout over a reader. Returns the lines.
function M.render(read, width)
  local lay = layout.new(width)
  local next_token = tokenizer.new(read, lay.count)
  local push = lay.push
  while true do
    local kind, value, attrs, self_closing = next_token()
    if not kind then
      break
    end
    push(kind, value, attrs, self_closing)
  end
  return lay.finish()
end

-- Renders the file and prints the lines. Fills st with the stats values as
-- it goes, so a render that stops still has the values up to that point.
local function run(f, opts, deps, st)
  if opts.stats then
    st.free_before = guard.settled_free()
  end
  -- The lowest free reading starts here, after the settled reading.
  guard.reset()
  local clock0, wall0 = deps.clock(), deps.uptime and deps.uptime()
  local lines = M.render(function() return f:read(CHUNK) end, st.width)
  st.cpu = deps.clock() - clock0
  if wall0 then
    st.wall = deps.uptime() - wall0
  end
  st.lines = #lines
  if opts.stats then
    st.free_after = guard.settled_free()
  end
  local out = deps.out
  for i = 1, #lines do
    guard.tick()
    out(plain(lines[i]))
  end
end

local function per_line(bytes, lines)
  if lines then
    return string.format(" (%.1f per line)", bytes / math.max(1, lines))
  end
  return ""
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

-- A missing value prints as "n/a", so a stats report never fails.
local function bytes_text(v)
  if is_num(v) then
    return int_text(v) .. " bytes"
  end
  return NA
end

local function seconds_text(fmt, v)
  if is_num(v) then
    return string.format(fmt, v) .. " s"
  end
  return NA
end

-- Returns the stats lines for the values in st. lowest is the lowest free
-- memory reading of the guard, or nil. trace is the memory trace text of the
-- guard, or nil.
function M.stats_lines(st, lowest, trace)
  local s = {}
  local function add(line)
    s[#s + 1] = "stats: " .. line
  end
  add("file=" .. bytes_text(st.size))
  add("width=" .. int_text(st.width))
  local lines = is_num(st.lines) and st.lines or nil
  if st.lines ~= nil then
    add("lines=" .. int_text(st.lines))
    add("cpu=" .. seconds_text("%.3f", st.cpu))
    if st.wall ~= nil then
      add("wall=" .. seconds_text("%.2f", st.wall))
    end
  end
  if st.free_before ~= nil then
    local before = st.free_before
    add("free_before=" .. bytes_text(before))
    if st.free_after ~= nil then
      add("free_after=" .. bytes_text(st.free_after))
      if is_num(before) and is_num(st.free_after) then
        local delta = before - st.free_after
        add("delta=" .. bytes_text(delta) .. per_line(delta, lines))
      else
        add("delta=" .. NA)
      end
    end
    if not is_num(lowest) then
      lowest = is_num(st.free_after) and st.free_after or before
    end
    add("lowest_free=" .. bytes_text(lowest))
    if is_num(before) and is_num(lowest) then
      local peak = before - lowest
      add("peak_used=" .. bytes_text(peak) .. per_line(peak, lines))
    else
      add("peak_used=" .. NA)
    end
  end
  if type(trace) == "string" and trace ~= "" then
    add("trace=" .. trace)
  else
    add("trace=" .. NA)
  end
  if st.stopped ~= nil then
    add("stopped=" .. tostring(st.stopped))
  end
  return s
end

-- Calls a guard function by name. Returns nil when the function is missing
-- or fails, for example with a guard module from an older version.
local function guard_value(name)
  local fn = type(guard) == "table" and guard[name]
  if type(fn) ~= "function" then
    return nil
  end
  local ok, value = pcall(fn)
  if ok then
    return value
  end
  return nil
end

-- Prints the stats lines to stderr and writes them to opts.stats_out.
-- Returns false when the file write fails.
local function report_stats(st, opts, deps)
  local lines = M.stats_lines(st, st.free_before and guard_value("lowest_free"),
    guard_value("trace_text"))
  for i = 1, #lines do
    deps.err(lines[i])
  end
  if not opts.stats_out then
    return true
  end
  local path = deps.resolve and deps.resolve(opts.stats_out) or opts.stats_out
  local ok, done, why = false, nil, "no file access"
  if deps.write_file then
    ok, done, why = pcall(deps.write_file, path,
      table.concat(lines, "\n") .. "\n")
  end
  if ok and done then
    return true
  end
  if not ok then
    why = done
  end
  why = tostring(why or "unknown reason"):match("^[^\n]*")
  deps.err("html: cannot write stats file: " .. opts.stats_out .. " ("
    .. why .. ")")
  return false
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

-- argv: the program arguments (a table, n is optional).
-- deps: the machine links:
--   out(line), err(line)   print to stdout and stderr
--   width                  default wrap width
--   open(path, mode)       io.open
--   traceback(msg)         debug.traceback, or a fake in the tests
--   clock()                os.clock
--   uptime()               optional, wall time in seconds
--   resolve(path)          optional, makes a path absolute
--   is_dir(path)           optional
--   size(path)             optional, file size in bytes
--   log(text)              optional, keeps the details of an unexpected error
--   write_file(path, text) optional, for --stats-out. Returns true, or nil
--                          and a reason
-- Returns the exit code.
function M.main(argv, deps)
  local opts, msg = M.parse_args(argv)
  if not opts then
    deps.err(msg .. " (see html --help)")
    return 2
  end
  if opts.help then
    deps.out(M.USAGE)
    return 0
  end
  local path = deps.resolve and deps.resolve(opts.file) or opts.file
  if deps.is_dir and deps.is_dir(path) then
    deps.err("html: not a file: " .. opts.file)
    return 1
  end
  local f = deps.open(path, "rb")
  if not f then
    deps.err("html: cannot open file: " .. opts.file)
    return 1
  end
  local traceback = deps.traceback
  local function handler(e)
    if is_controlled(e) then
      return e
    end
    return traceback(tostring(e), 2)
  end
  local st = { width = opts.width or deps.width or DEFAULT_WIDTH }
  local ok, result = xpcall(function()
    st.size = file_size(f, path, deps)
    run(f, opts, deps, st)
  end, handler)
  f:close()
  local code = 0
  if not ok then
    code = 1
    if is_controlled(result) then
      deps.err(result)
      st.stopped = result
    else
      result = tostring(result)
      local first = result:match("^[^\n]*")
      if deps.log then
        deps.log(result)
        deps.err("html: unexpected error: " .. first .. " (details in "
          .. ERROR_LOG .. ")")
      else
        deps.err("html: unexpected error: " .. first)
      end
      st.stopped = "html: unexpected error: " .. first
    end
  end
  if opts.stats and not report_stats(st, opts, deps) then
    code = 1
  end
  return code
end

-- The links to OpenOS. Loaded only when the chunk runs as a program.
function M.game_deps()
  local computer = require("computer")
  local filesystem = require("filesystem")
  local shell = require("shell")
  local term = require("term")
  local width = DEFAULT_WIDTH
  local ok, w = pcall(term.getViewport)
  if ok and math.tointeger(w) and w > 0 then
    width = w
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
    is_dir = filesystem.isDirectory,
    size = filesystem.size,
    log = function(text)
      if #text > ERROR_LOG_MAX then
        text = sub(text, -ERROR_LOG_MAX)
      end
      local f = io.open(ERROR_LOG, "w")
      if f then
        f:write(text)
        f:close()
      end
    end,
    write_file = function(path, text)
      local f, why = io.open(path, "w")
      if not f then
        return nil, why
      end
      local done, werr = f:write(text)
      f:close()
      if not done then
        return nil, werr
      end
      return true
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
M.sizes["lib/html/entities.lua"] = 5706
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
M.sizes["lib/html/guard.lua"] = 3343
M.files["lib/html/guard.lua"] = [[
local computer = require("computer")

local M = {}

-- OpenOS kills a program that runs for 5 s without yielding.
local YIELD_INTERVAL = 1
local MEMORY_RESERVE = 128 * 1024
-- freeMemory() can read up to about 200 KB low until garbage is collected.
local SETTLE_TRIES = 3
-- The stats trace line must stay short: 64 samples are under 1000 chars.
local TRACE_MAX = 64

local last_yield = os.clock()
-- The lowest freeMemory() reading since the last reset. It includes garbage
-- that is not collected yet, so it is a lower bound of the real free memory.
local lowest

-- The memory trace: line count and freeMemory() reading of every
-- trace_every-th tick. When it is full, every second sample is dropped and
-- trace_every doubles, so the samples spread across the whole run.
local trace_lines, trace_free = {}, {}
local trace_every, trace_ticks = 1, 0
local last_lines = 0

local function trace_add(free)
  local n = #trace_lines
  if n >= TRACE_MAX then
    local j = 0
    for i = 2, n, 2 do
      j = j + 1
      trace_lines[j], trace_free[j] = trace_lines[i], trace_free[i]
    end
    for i = n, j + 1, -1 do
      trace_lines[i], trace_free[i] = nil, nil
    end
    trace_every = trace_every * 2
    n = j
  end
  trace_lines[n + 1], trace_free[n + 1] = last_lines, free
end

local function yield()
  os.sleep(0)
  last_yield = os.clock()
end

local function read_free()
  local free = computer.freeMemory()
  if not lowest or free < lowest then
    lowest = free
  end
  return free
end

local function settled_free()
  local best = read_free()
  for _ = 1, SETTLE_TRIES do
    yield()
    best = math.max(best, read_free())
  end
  return best
end

-- The highest free memory reading over a few yields. The stats output
-- uses it, because a single reading can be about 200 KB too low.
M.settled_free = settled_free

-- The lowest reading seen by tick() and settled_free() since the last
-- reset, or nil when there was no reading.
function M.lowest_free()
  return lowest
end

-- The memory trace as "<line>:<free>,<line>:<free>,...", oldest first, or
-- "" when there is no sample. <line> is the last line count given to tick().
function M.trace_text()
  local parts = {}
  for i = 1, #trace_lines do
    parts[i] = trace_lines[i] .. ":" .. trace_free[i]
  end
  return table.concat(parts, ",")
end

-- Starts the yield timer again and clears the lowest reading and the trace.
-- Tests call this after they set the clock.
function M.reset()
  last_yield = os.clock()
  lowest = nil
  trace_lines, trace_free = {}, {}
  trace_every, trace_ticks = 1, 0
  last_lines = 0
end

-- lines is optional. It is the progress value in the memory error message.
function M.tick(lines)
  if os.clock() - last_yield > YIELD_INTERVAL then
    yield()
  end
  if lines then
    last_lines = lines
  end
  local free = read_free()
  trace_ticks = trace_ticks + 1
  if trace_ticks % trace_every == 0 then
    trace_add(free)
  end
  if free < MEMORY_RESERVE and settled_free() < MEMORY_RESERVE then
    -- The reading that stops the render is always the last sample.
    if trace_ticks % trace_every ~= 0 then
      trace_add(free)
    end
    local progress = ""
    if lines then
      progress = " (rendered " .. lines .. " lines before stopping)"
    end
    error("html: page too large for available memory" .. progress, 0)
  end
end

return M
]]
M.sizes["lib/html/layout.lua"] = 6031
M.files["lib/html/layout.lua"] = [[
-- Turns tokens into wrapped lines. There is no DOM tree.
-- A line is one string. A non-empty line starts with a style byte (see
-- M.NORMAL and the others). A style lasts until the next style byte.
-- An empty line is "".

local guard = require("html.guard")
local unicode = require("unicode")

local M = {}

local byte, find, sub, rep = string.byte, string.find, string.sub,
  string.rep
local concat = table.concat

M.NORMAL = "\1"
M.HEADING = "\2"
M.EMPHASIS = "\3"
M.LINK = "\4"
M.PRE = "\5"

local function set(...)
  local s = {}
  for _, k in ipairs({ ... }) do
    s[k] = true
  end
  return s
end

-- Dropped with all content. head is here until title goes to the status
-- line.
local DROP = set("script", "style", "template", "svg", "math", "iframe",
  "object", "noscript", "head")

local BLOCK = set("p", "div", "section", "article", "main", "header",
  "footer", "nav", "aside", "blockquote", "pre", "li", "table", "tr", "td",
  "th", "ul", "ol", "dl", "form", "input", "button", "select", "textarea")

local HEADING = set("h1", "h2", "h3", "h4", "h5", "h6")

local SPACE = "[ \t\n]"
local NOT_SPACE = "[^ \t\n]"

-- Returns a layout object for lines of at most width columns:
--   push(kind, value, attrs, self_closing)   one token from the tokenizer
--   count()                                  number of finished lines
--   finish()                                 ends the input, returns lines
-- lines holds the finished lines while push runs.
function M.new(width)
  if width < 1 then
    width = 1
  end
  local lines, n = {}, 0
  -- Pieces of the current line.
  local parts, np, cur_w = {}, 0, 0
  local line_style = M.NORMAL
  -- Pieces of a word that is not placed yet. A word can span text tokens.
  local word, nw = {}, 0
  -- True when white space came after the last placed word.
  local space = false
  -- True when the current line has a word. A prefix such as "- " is not a
  -- word, so white space after it is not kept.
  local has_word = false
  local drop, dropping = {}, 0
  local style = M.NORMAL

  local function emit(line)
    n = n + 1
    lines[n] = line
    guard.tick(n)
  end

  local function end_line()
    if np > 0 then
      emit(line_style .. concat(parts, "", 1, np))
    else
      emit("")
    end
    np, cur_w = 0, 0
    has_word = false
  end

  local function place(s, w)
    if np == 0 then
      line_style = style
    end
    np = np + 1
    parts[np] = s
    cur_w = cur_w + w
  end

  -- Places a word wider than the line, split at characters.
  local function place_long(s)
    local i, len, from, w = 1, #s, 1, 0
    while i <= len do
      guard.tick(n)
      local b = byte(s, i)
      local size = b < 0x80 and 1 or b >= 0xF0 and 4 or b >= 0xE0 and 3 or 2
      local cw = unicode.wlen(sub(s, i, i + size - 1))
      if cur_w + w + cw > width and cur_w + w > 0 then
        if i > from then
          place(sub(s, from, i - 1), w)
        end
        end_line()
        from, w = i, 0
      end
      w = w + cw
      i = i + size
    end
    if from <= len then
      place(sub(s, from), w)
    end
  end

  local function commit()
    if nw == 0 then
      return
    end
    local s = nw == 1 and word[1] or concat(word, "", 1, nw)
    nw = 0
    local w = unicode.wlen(s)
    local gap = (space and has_word) and 1 or 0
    space = false
    if cur_w + gap + w <= width then
      if gap == 1 then
        place(" ", 1)
      end
      place(s, w)
    else
      if np > 0 then
        end_line()
      end
      if w <= width then
        place(s, w)
      else
        place_long(s)
      end
    end
    has_word = true
  end

  local function add_text(s)
    local i, len = 1, #s
    while i <= len do
      guard.tick(n)
      local ws = find(s, SPACE, i)
      if not ws then
        nw = nw + 1
        word[nw] = i == 1 and s or sub(s, i)
        return
      end
      if ws > i then
        nw = nw + 1
        word[nw] = sub(s, i, ws - 1)
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

  local function start_tag(name, self_closing)
    if DROP[name] then
      if not self_closing then
        drop[name] = (drop[name] or 0) + 1
        dropping = dropping + 1
      end
    elseif name == "body" then
      -- An unclosed head ends at body.
      dropping = dropping - (drop.head or 0)
      drop.head = 0
    elseif dropping > 0 then
      return
    elseif HEADING[name] then
      block()
      blank()
      style = M.HEADING
    elseif name == "br" then
      commit()
      space = false
      end_line()
    elseif name == "hr" then
      block()
      emit(M.NORMAL .. rep("─", width))
    elseif name == "li" then
      block()
      place("- ", 2)
    elseif BLOCK[name] then
      block()
    end
  end

  local function end_tag(name)
    if DROP[name] then
      local open = drop[name] or 0
      if open > 0 then
        drop[name] = open - 1
        dropping = dropping - 1
      end
    elseif dropping > 0 then
      return
    elseif HEADING[name] then
      block()
      style = M.NORMAL
      blank()
    elseif BLOCK[name] then
      block()
    end
  end

  local self = { lines = lines }

  function self.push(kind, value, _, self_closing)
    if kind == "text" then
      if dropping == 0 then
        add_text(value)
      end
    elseif kind == "start" then
      start_tag(value, self_closing)
    elseif kind == "end" then
      end_tag(value)
    end
  end

  function self.count()
    return n
  end

  function self.finish()
    block()
    while n > 0 and lines[n] == "" do
      lines[n] = nil
      n = n - 1
    end
    return lines
  end

  return self
end

return M
]]
M.sizes["lib/html/text.lua"] = 4127
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

-- True for C1 controls (U+0080..U+009F), the soft hyphen (U+00AD) and
-- zero-width or invisible characters (U+200B..U+200F, U+FEFF).
-- unicode.wlen counts U+200B as width 2.
local function removed(s, i, len)
  local b1, b2, b3 = byte(s, i, i + 2)
  if len == 2 then
    return b1 == 0xC2 and (b2 <= 0x9F or b2 == 0xAD)
  end
  if len == 3 then
    return (b1 == 0xE2 and b2 == 0x80 and b3 >= 0x8B and b3 <= 0x8F)
      or (b1 == 0xEF and b2 == 0xBB and b3 == 0xBF)
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

-- Splits s into head and tail. The tail is a trailing piece that the next
-- chunk may complete: a partial UTF-8 sequence or a partial entity. A
-- streaming caller cleans the head and puts the tail before the next chunk.
-- At the end of a text run the caller passes the whole rest, not split.
function M.split_tail(s)
  local len = #s
  local cut = len + 1
  -- Partial UTF-8: a lead byte in the last 3 bytes with too few followers.
  for k = len, math.max(1, len - 2), -1 do
    local b = byte(s, k)
    if b < 0x80 or b >= 0xC0 then
      local need = b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC2 and 2 or 1
      if len - k + 1 < need then
        cut = k
      end
      break
    end
  end
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
  return sub(s, 1, cut - 1), sub(s, cut)
end

return M
]]
M.sizes["lib/html/tokenizer.lua"] = 6229
M.files["lib/html/tokenizer.lua"] = [[
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
-- Names are lowercase. attrs is nil in this version.
-- Comments, doctype, CDATA and processing instructions are skipped.
-- The content of script and style is skipped up to the matching end tag.

local guard = require("html.guard")
local text = require("html.text")
local entities = require("html.entities")

local M = {}

local byte, find, sub, lower = string.byte, string.find, string.sub,
  string.lower
local max = math.max
local clean, split_tail, decode = text.clean, text.split_tail,
  entities.decode

-- A "<" with no ">" within this many bytes is text. This bounds the buffer.
M.MAX_TAG = 16384

-- Raw text elements. Their content is never markup.
local RAW = { script = true, style = true }

local function is_letter(b)
  return b ~= nil and ((b >= 65 and b <= 90) or (b >= 97 and b <= 122))
end

local function is_alnum(b)
  return is_letter(b) or (b ~= nil and b >= 48 and b <= 57)
end

-- read() returns the next chunk, or nil at the end of input.
-- progress() is optional. Its result is the line count in a memory error.
-- Returns a function that returns the next token.
function M.new(read, progress)
  local buf, pos, eof = "", 1, false
  -- Terminator of a skipped comment or bogus tag.
  local skip_to
  -- Name of the raw text element whose content is skipped.
  local raw

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
      buf = chunk
    else
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

  local function text_token(s)
    return "text", decode(clean(s))
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

  -- Skips raw text up to "</name" followed by a non-alphanumeric byte.
  local function skip_raw()
    local k = find(buf, "</", pos, true)
    if not k then
      -- Keep a last "<".
      pos = max(pos, #buf)
      if not fill() then
        pos = #buf + 1
        raw = nil
      end
      return
    end
    pos = k
    if not want(#raw + 3) then
      -- Too short for an end tag. Unclosed raw text ends with the input.
      pos = #buf + 1
      raw = nil
      return
    end
    if lower(sub(buf, pos + 2, pos + 1 + #raw)) == raw
        and not is_alnum(byte(buf, pos + 2 + #raw)) then
      raw = nil
    else
      pos = pos + 2
    end
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
      if want(4) and sub(buf, pos, pos + 3) == "<!--" then
        skip_to, pos = "-->", pos + 4
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
        skip_to, pos = ">", pos + 2
        return nil
      end
      pos = pos + 1
      return "text", "<"
    end
    local gt = find(buf, ">", pos + rel, true)
    while not gt do
      local scanned = #buf - pos + 1
      if scanned > M.MAX_TAG then
        pos = pos + 1
        return "text", "<"
      end
      tick()
      if not fill() then
        -- A tag cut by the end of input is dropped.
        pos = #buf + 1
        return nil
      end
      gt = find(buf, ">", pos + scanned, true)
    end
    local start = pos + rel
    local _, e = find(buf, "^[^%s/>]+", start)
    local name = lower(sub(buf, start, e))
    local self_closing = byte(buf, gt - 1) == 47 and gt - 1 > e
    pos = gt + 1
    if closing then
      return "end", name
    end
    if RAW[name] then
      raw = name
    end
    return "start", name, nil, self_closing
  end

  return function()
    while true do
      tick()
      if skip_to then
        skip()
      elseif raw then
        skip_raw()
      else
        if pos > #buf and not fill() then
          return nil
        end
        local lt = find(buf, "<", pos, true)
        if not lt then
          if eof then
            local s = sub(buf, pos)
            pos = #buf + 1
            return text_token(s)
          end
          -- A UTF-8 sequence or entity cut by the chunk end waits for the
          -- next chunk.
          local head, tail = split_tail(sub(buf, pos))
          buf, pos = tail, 1
          fill()
          if head ~= "" then
            return text_token(head)
          end
        elseif lt > pos then
          local s = sub(buf, pos, lt - 1)
          pos = lt
          return text_token(s)
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
]]

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
-- copy with the embedded content. Returns the temporary paths written.
local function write_temps(plan, deps)
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
    end
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

local function install(opts, deps)
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
  local written, why = write_temps(plan, deps)
  if why then
    for _, temp in ipairs(written) do
      call(deps, "remove", temp)
    end
    fail(why .. "; old files kept")
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
  local ok, e = pcall(install, opts, deps)
  if ok then
    return 0
  end
  if type(e) == "string" and e:sub(1, 14) == "html-install: " then
    deps.err(e)
  else
    deps.err("html-install: unexpected error: "
      .. tostring(e):match("^[^\n]*"))
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
      f:close()
      if not done then
        return nil, werr
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
