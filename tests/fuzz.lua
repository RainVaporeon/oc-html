-- Fuzz generator for the tokenizer and layout pipeline.
-- Run inside the container: lua5.3 tests/fuzz.lua <n> [seed] [index]
--   n      number of documents
--   seed   run seed (default: os.time(), printed at start)
--   index  run only this document of the seed run
--
-- Two parts share this file:
-- * The driver runs when the file is a program. It runs outside the sandbox
--   env and keeps the only write access: it saves failures under
--   tests/fuzz-failures/. It loads this file again inside a sandbox env
--   (the rules of SPEC.md "Sandbox") to get the module part.
-- * The module part runs when the first argument is a table. It returns M.
--   It generates the documents, runs the pipeline and checks the oracles.
--   tests/fuzz_test.lua loads it in the test runner env.
--
-- Random numbers come from an own 64-bit LCG, so a seed gives the same
-- documents on every Lua 5.3 build. Each document has its own generator,
-- seeded from the run seed and the document index.

local ARGS = table.pack(...)

-- Driver ------------------------------------------------------------------

local function driver(argv)
  local real_open = io.open
  local real_loadfile = loadfile
  local real_load = load
  local FAILURE_DIR = "tests/fuzz-failures/"
  local TIME_LIMIT = 30

  local function usage()
    print("usage: lua5.3 tests/fuzz.lua <n> [seed] [index]")
    return 2
  end

  local n = math.tointeger(tonumber(argv[1]))
  if not n or n < 1 then
    return usage()
  end
  local seed = os.time()
  if argv[2] ~= nil then
    local given = math.tointeger(tonumber(argv[2]))
    if not given or given < 0 then
      return usage()
    end
    seed = given
  end
  local only
  if argv[3] ~= nil then
    only = math.tointeger(tonumber(argv[3]))
    if not only or only < 1 or only > n then
      return usage()
    end
  end

  local function list_html(dir)
    local pipe = assert(io.popen("ls -1 " .. dir, "r"))
    local files = {}
    for name in pipe:lines() do
      if name:match("^[%w_%-]+%.html$") then
        files[#files + 1] = dir .. "/" .. name
      end
    end
    pipe:close()
    table.sort(files)
    return files
  end

  local corpus = list_html("tests/cases")
  for _, path in ipairs(list_html("tests/fuzz-corpus")) do
    corpus[#corpus + 1] = path
  end

  -- The env follows tests/run.lua: read-only io.open under tests/, text
  -- chunks only, no os.execute, io.popen, os.remove, os.exit or debug.
  local function safe_open(path, mode)
    mode = mode or "r"
    if mode ~= "r" and mode ~= "rb" then
      return nil, tostring(path) .. ": sandbox allows read mode only"
    end
    if type(path) ~= "string" or path:sub(1, 6) ~= "tests/"
        or path:find("..", 1, true) or path:find("\\", 1, true)
        or path:find("%z") then
      return nil, tostring(path) .. ": sandbox allows only paths under tests/"
    end
    return real_open(path, mode)
  end

  local function copy(t, except)
    local c = {}
    for k, v in pairs(t) do
      if not (except and except[k]) then
        c[k] = v
      end
    end
    return c
  end

  local env = {
    _VERSION = _VERSION,
    assert = assert, error = error, ipairs = ipairs, next = next,
    pairs = pairs, pcall = pcall, print = print, rawequal = rawequal,
    rawget = rawget, rawlen = rawlen, rawset = rawset, select = select,
    setmetatable = setmetatable, getmetatable = getmetatable,
    tonumber = tonumber, tostring = tostring, type = type, xpcall = xpcall,
    coroutine = copy(coroutine),
    math = copy(math),
    string = copy(string, { dump = true }),
    table = copy(table),
    utf8 = copy(utf8),
    os = {
      clock = os.clock, date = os.date, difftime = os.difftime,
      time = os.time,
    },
    io = { open = safe_open },
  }
  env._G = env
  env.load = function(chunk, name, _, chunk_env)
    return real_load(chunk, name, "t", chunk_env == nil and env or chunk_env)
  end
  local loaded = {}
  function env.require(name)
    if loaded[name] ~= nil then
      return loaded[name]
    end
    local path
    local sub = type(name) == "string" and name:match("^html%.([%w_]+)$")
    if sub then
      path = "lib/html/" .. sub .. ".lua"
    elseif type(name) == "string" and name:match("^[%w_]+$") then
      path = "tests/shim/" .. name .. ".lua"
    end
    local chunk = path and real_loadfile(path, "t", env)
    if not chunk then
      error("module '" .. tostring(name) .. "' not found in the fuzz sandbox",
        2)
    end
    local result = chunk(name)
    if result == nil then
      result = true
    end
    loaded[name] = result
    return result
  end
  function env.os.sleep(seconds)
    env.require("computer").test.sleep(seconds or 0)
  end

  local chunk = assert(real_loadfile("tests/fuzz.lua", "t", env))
  local M = chunk({})

  -- The only write: the input and a text file per failure. The names are
  -- built from integers, so the paths stay in FAILURE_DIR.
  local function write(path, data)
    local f, err = real_open(path, "wb")
    if not f then
      return nil, err
    end
    local ok, werr = f:write(data)
    local closed, cerr = f:close()
    if not ok then
      return nil, werr
    end
    if not closed then
      return nil, cerr
    end
    return true
  end

  local function save(failure)
    local base = FAILURE_DIR .. string.format("%d-%d", failure.seed,
      failure.index)
    local ok, err = write(base .. ".html", failure.input)
    if ok then
      ok, err = write(base .. ".txt", M.failure_text(failure))
    end
    if not ok then
      print("fuzz: cannot save " .. base .. ": " .. tostring(err))
    end
    return base
  end

  -- A backstop for a loop that never returns a token: the hook raises an
  -- error when one document runs longer than TIME_LIMIT seconds.
  local deadline = math.huge
  debug.sethook(function()
    if os.clock() > deadline then
      deadline = math.huge
      error("fuzz: time limit of " .. TIME_LIMIT .. " s exceeded", 0)
    end
  end, "", 1000000)

  print(string.format("fuzz: seed=%d documents=%d%s", seed, n,
    only and (" only=" .. only) or ""))
  local clock0 = os.clock()
  local summary = M.run({
    n = n,
    seed = seed,
    only = only,
    corpus = corpus,
    large = "tests/pages/large.html",
    traceback = debug.traceback,
    on_document = function()
      deadline = os.clock() + TIME_LIMIT
    end,
    on_failure = function(failure)
      local base = save(failure)
      print(string.format("FAIL %d (%s, width=%d, chunk=%d, %d bytes): %s"
        .. " -> %s.html", failure.index, failure.generator, failure.width,
        failure.chunk, #failure.input, failure.message:match("^[^\n]*"),
        base))
    end,
  })
  debug.sethook()
  print(string.format("fuzz: seed=%d documents=%d bytes=%d controlled=%d"
    .. " card=%d card_controlled=%d failures=%d time=%.1f s", seed,
    summary.documents, summary.bytes, summary.controlled, summary.card,
    summary.card_controlled, summary.failures, os.clock() - clock0))
  local gens = {}
  for name, count in pairs(summary.by_generator) do
    gens[#gens + 1] = name .. "=" .. count
  end
  table.sort(gens)
  print("fuzz: generators " .. table.concat(gens, " "))
  return summary.failures == 0 and 0 or 1
end

if type(ARGS[1]) ~= "table" then
  os.exit(driver(ARGS))
end

-- Module ------------------------------------------------------------------

local guard = require("html.guard")
local tokenizer = require("html.tokenizer")
local layout = require("html.layout")
local unicode = require("unicode")

local M = {}

local byte, char, find, gsub, sub, rep = string.byte, string.char,
  string.find, string.gsub, string.sub, string.rep
local concat = table.concat

local MIN_SIZE, MAX_SIZE = 4, 65536
local MIN_WIDTH, MAX_WIDTH = 10, 160
local MAX_CHUNK = 16

-- A 64-bit LCG (Knuth MMIX constants). Integer math wraps at 2^64 in Lua
-- 5.3, so the sequence is the same everywhere. The high 31 bits are used.
function M.rng(seed)
  local s = seed
  local r = {}
  local function next31()
    s = s * 6364136223846793005 + 1442695040888963407
    return (s >> 33) & 0x7FFFFFFF
  end
  for _ = 1, 4 do
    next31()
  end
  -- A whole number from a to b.
  function r.int(a, b)
    return a + next31() % (b - a + 1)
  end
  -- True with probability p.
  function r.chance(p)
    return next31() < p * 0x80000000
  end
  -- A number in [0, 1).
  function r.float()
    return next31() / 0x80000000
  end
  function r.pick(t)
    return t[next31() % #t + 1]
  end
  return r
end

-- The generator of one document.
function M.doc_rng(seed, index)
  return M.rng(seed * 1000003 + index)
end

-- A size from MIN_SIZE to MAX_SIZE, log-uniform, so small documents are
-- frequent and large ones still occur.
local function random_size(r)
  return math.floor(MIN_SIZE * (MAX_SIZE / MIN_SIZE) ^ r.float())
end

-- Generator 1: tag soup -----------------------------------------------------

local KNOWN_TAGS = {
  "html", "head", "body", "title", "meta", "link", "script", "style",
  "template", "svg", "math", "iframe", "object", "noscript", "h1", "h2",
  "h3", "h4", "h5", "h6", "p", "div", "section", "article", "main",
  "header", "footer", "nav", "aside", "blockquote", "br", "hr", "b",
  "strong", "i", "em", "u", "mark", "a", "pre", "code", "img", "li", "ul",
  "ol", "dl", "dt", "dd", "table", "tr", "td", "th", "form", "input",
  "button", "select", "option", "textarea", "span", "font", "center",
}

local RAW_TAGS = { "script", "style", "title", "textarea" }

local ATTR_NAMES = {
  "href", "alt", "src", "class", "id", "style", "title", "onclick",
  "data-x", "HREF", "Alt", "x:y", "a_b", "",
}

local ENTITIES = {
  -- Valid named, with and without ";".
  "&amp;", "&lt;", "&gt;", "&quot;", "&apos;", "&nbsp;", "&copy;", "&reg;",
  "&mdash;", "&ndash;", "&hellip;", "&eacute;", "&Eacute;", "&yuml;",
  "&amp", "&lt", "&copy", "&nbsp", "&ampx", "&amp=", "&amp1", "&AMP;",
  -- Invalid.
  "&", "&;", "&foo;", "&#;", "&#x;", "&#xg;", "&# 65;", "&&", "&am",
  "&notanentity", "&lt;&gt", "&#-1;",
  -- Numeric edge cases.
  "&#0;", "&#x0;", "&#65;", "&#65", "&#x41;", "&#X41;", "&#x41",
  "&#127;", "&#128;", "&#129;", "&#141;", "&#150;", "&#159;", "&#x9F;",
  "&#160;", "&#173;", "&#8203;", "&#x200B;", "&#xFE0F;", "&#xFEFF;",
  "&#55296;", "&#xD800;", "&#xDFFF;", "&#x10FFFF;", "&#x110000;",
  "&#1114112;", "&#99999999999999999999999;", "&#x7FFFFFFFFFFFFFFFF;",
  "&#00000065;", "&#x0000041;", "&#9;", "&#10;", "&#13;", "&#1;", "&#5;",
  "&#x1F600;", "&#x4E2D;", "&#12288;",
}

local TEXT_PIECES = {
  "hello", "world", "a", "the quick brown fox", "  ", " ", "\n", "\t",
  "\r\n", "\r", "x\ty", "  \t \n ", "中文", "日本語のテキスト", "😀",
  "e\204\129", "\226\128\139", "\239\184\143", "\194\173", "\239\187\191",
  "<", ">", "<<", ">>", "< b", "a<b", "a>b", "1 < 2 > 0", "<3", "</",
  "</ x>", "</>", "<!", "<?", "<!-", "=", "\"", "'", "`", "&", ";", "/",
  "verylongwordwithoutanyspacesthatmustbesplitbythelayoutatsomepoint",
  "\1", "\2", "\3", "\4", "\5", "\0", "\127", "\194\128", "\194\159",
  "\237\160\128", "\192\175", "\255", "\128", "\228\184",
}

local function random_name(r)
  local first = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
  local rest = first .. "0123456789-_:."
  local n = r.int(1, 10)
  local out = { sub(first, r.int(1, #first), r.int(1, #first)) }
  out[1] = sub(out[1], 1, 1)
  for i = 2, n do
    local k = r.int(1, #rest)
    out[i] = sub(rest, k, k)
  end
  return concat(out)
end

local function mixed_case(r, s)
  if not r.chance(0.2) then
    return s
  end
  return (gsub(s, "%a", function(c)
    if r.chance(0.5) then
      return c:upper()
    end
    return c
  end))
end

local function tag_name(r)
  if r.chance(0.75) then
    return mixed_case(r, r.pick(KNOWN_TAGS))
  end
  return random_name(r)
end

local function random_text(r, max)
  local out = {}
  for i = 1, r.int(1, max) do
    if r.chance(0.15) then
      out[i] = r.pick(ENTITIES)
    else
      out[i] = r.pick(TEXT_PIECES)
    end
  end
  return concat(out)
end

local function attr_value(r)
  local v = random_text(r, 3)
  local k = r.int(1, 10)
  if k == 1 then
    return "=" .. (gsub(v, "[%s>\"']", ""))
  elseif k == 2 then
    return "='" .. v .. "'"
  elseif k == 3 then
    return '="' .. v .. '"'
  elseif k == 4 then
    return " = \"" .. v .. "\""
  elseif k == 5 then
    -- An unclosed quote.
    return '="' .. v
  elseif k == 6 then
    return "='" .. v
  elseif k == 7 then
    -- A value with ">" and then "</".
    return '="x>' .. v .. '</a>'
  elseif k == 8 then
    return "="
  elseif k == 9 then
    return '=""'
  end
  return ""
end

local function attributes(r)
  local out = {}
  for i = 1, r.int(0, 4) do
    local name
    local k = r.int(1, 12)
    if k == 1 then
      name = "\"x"
    elseif k == 2 then
      name = "=a"
    elseif k == 3 then
      name = "<b"
    elseif k == 4 then
      name = random_name(r)
    else
      name = mixed_case(r, r.pick(ATTR_NAMES))
    end
    out[i] = r.pick({ " ", "  ", "\n", "\t", "/" }) .. name .. attr_value(r)
  end
  return concat(out)
end

local function start_tag(r, name)
  local close = r.pick({ ">", ">", ">", "/>", " />", " >", "", "\n>" })
  return "<" .. name .. attributes(r) .. close
end

local function end_tag(r, name)
  local k = r.int(1, 8)
  if k == 1 then
    return "</" .. name .. " junk=\"1\">"
  elseif k == 2 then
    return "</" .. name
  elseif k == 3 then
    return "</ " .. name .. ">"
  end
  return "</" .. name .. ">"
end

local function raw_element(r)
  local name = r.pick(RAW_TAGS)
  local body = { random_text(r, 5) }
  local k = r.int(1, 6)
  if k == 1 then
    body[2] = "</" .. name:sub(1, r.int(1, #name))
  elseif k == 2 then
    body[2] = "</" .. name:upper() .. " x>"
  elseif k == 3 then
    body[2] = "<!-- </" .. name .. "> -->"
  elseif k == 4 then
    body[2] = "if (a < b && c > d) { x = '</div>'; }"
  end
  local tail = r.pick({ "</" .. name .. ">", "</" .. name .. " >",
    "</" .. name, "" })
  return start_tag(r, mixed_case(r, name)) .. concat(body) .. tail
end

local SPECIAL = {
  function(r) return "<!--" .. random_text(r, 4) .. "-->" end,
  function() return "<!---->" end,
  function() return "<!-->" end,
  function() return "<!--->" end,
  function(r) return "<!--" .. random_text(r, 4) .. "--!>" end,
  function(r) return "<!--" .. random_text(r, 4) end,
  function(r) return "<![CDATA[" .. random_text(r, 4) .. "]]>" end,
  function(r) return "<![CDATA[" .. random_text(r, 4) end,
  function() return "<!DOCTYPE html>" end,
  function() return "<!doctype html public \"-//W3C//DTD\">" end,
  function() return "<!DOCTYPE" end,
  function() return "<?xml version=\"1.0\"?>" end,
  function(r) return "<?" .. random_text(r, 2) end,
  function(r) return "<!" .. random_text(r, 2) .. ">" end,
  function(r) return "</" .. random_text(r, 2) .. ">" end,
  function() return "</>" end,
  function(r) return "<" .. tag_name(r) .. " attr=\"never closed" end,
  function(r) return "<" .. tag_name(r) end,
  function(r) return "<pre>" .. random_text(r, 6) .. "</pre>" end,
  function(r) return "<img alt=\"" .. random_text(r, 2) .. "\">" end,
  function(r)
    -- A tag or value longer than MAX_TAG.
    return "<a href=\"" .. rep("x", r.int(16000, 17000))
      .. r.pick({ "\">", ">", "" })
  end,
}

function M.tag_soup(r, size)
  local out, len, stack = {}, 0, {}
  while len < size do
    local piece
    local k = r.int(1, 100)
    if k <= 30 then
      piece = random_text(r, 6)
    elseif k <= 50 then
      local name = tag_name(r)
      piece = start_tag(r, name)
      stack[#stack + 1] = name
    elseif k <= 65 then
      local name
      if #stack > 0 and r.chance(0.7) then
        name = stack[#stack]
        stack[#stack] = nil
      else
        name = tag_name(r)
      end
      piece = end_tag(r, name)
    elseif k <= 75 then
      piece = r.pick(ENTITIES)
    elseif k <= 82 then
      piece = raw_element(r)
    else
      local special = r.pick(SPECIAL)
      -- The long tag only when the size leaves room for it.
      if special == SPECIAL[#SPECIAL] and size < 20000 then
        special = SPECIAL[1]
      end
      piece = special(r)
    end
    out[#out + 1] = piece
    len = len + #piece
  end
  return concat(out)
end

-- Generator 2: random bytes -------------------------------------------------

local MARKUP_BYTES = "<>&;#=\"'/!-?[] \n\tx"

function M.random_bytes(r, size)
  local mode = r.int(1, 4)
  local out = {}
  local i = 0
  while i < size do
    local k = r.int(1, 100)
    local piece
    if mode == 1 or k <= 25 then
      -- Any byte.
      piece = char(r.int(0, 255))
    elseif k <= 45 then
      local m = r.int(1, #MARKUP_BYTES)
      piece = sub(MARKUP_BYTES, m, m)
    elseif k <= 55 then
      -- Control and style bytes.
      piece = char(r.int(0, 31))
    elseif k <= 70 then
      -- A lead byte with a random number of continuation bytes.
      local t = { char(r.int(0xC0, 0xFF)) }
      for j = 2, r.int(1, 4) do
        t[j] = char(r.int(0x80, 0xBF))
      end
      piece = concat(t)
    elseif k <= 80 then
      piece = utf8.char(r.pick({ r.int(0x80, 0x7FF), r.int(0x800, 0xFFFF),
        r.int(0x10000, 0x10FFFF), r.int(0x4E00, 0x9FFF) }))
    elseif k <= 90 then
      piece = char(r.int(0x61, 0x7A))
    else
      piece = r.pick(ENTITIES)
    end
    out[#out + 1] = piece
    i = i + #piece
  end
  return concat(out)
end

-- Generator 3: corpus mutations ---------------------------------------------

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("a")
  f:close()
  return s
end

-- A random range [i, j] of s, at most max bytes long. s is not empty.
local function range(r, s, max)
  local i = r.int(1, #s)
  local j = math.min(#s, i + r.int(0, max) - 1)
  return i, j
end

local MUTATIONS = {
  -- Cut: keep a part.
  function(r, s)
    local i, j = range(r, s, #s)
    return sub(s, i, j)
  end,
  -- Duplicate a range.
  function(r, s)
    local i, j = range(r, s, 4096)
    local part = sub(s, i, j)
    return sub(s, 1, j) .. rep(part, r.int(1, 3)) .. sub(s, j + 1)
  end,
  -- Insert random bytes.
  function(r, s)
    local at = r.int(0, #s)
    return sub(s, 1, at) .. M.random_bytes(r, r.int(1, 64)) .. sub(s, at + 1)
  end,
  -- Delete a range.
  function(r, s)
    local i, j = range(r, s, 4096)
    return sub(s, 1, i - 1) .. sub(s, j + 1)
  end,
  -- Swap two ranges.
  function(r, s)
    local a, b = range(r, s, 2048)
    local c, d = range(r, s, 2048)
    if c < a then
      a, b, c, d = c, d, a, b
    end
    if c <= b then
      return s
    end
    return sub(s, 1, a - 1) .. sub(s, c, d) .. sub(s, b + 1, c - 1)
      .. sub(s, a, b) .. sub(s, d + 1)
  end,
  -- Overwrite single bytes.
  function(r, s)
    local out = s
    for _ = 1, r.int(1, 8) do
      local at = r.int(1, #out)
      out = sub(out, 1, at - 1) .. char(r.int(0, 255)) .. sub(out, at + 1)
    end
    return out
  end,
}

-- sources: { files = { {name, content}, ... }, large = content or nil }
function M.mutation(r, size, sources)
  local base, name
  if sources.large and (#sources.files == 0 or r.chance(0.5)) then
    local i = r.int(1, math.max(1, #sources.large - size + 1))
    base = sub(sources.large, i, i + size - 1)
    name = "large.html@" .. i
  elseif #sources.files > 0 then
    local f = r.pick(sources.files)
    base, name = f[2], f[1]
  else
    return M.tag_soup(r, size), "tag_soup"
  end
  local ops = {}
  for k = 1, r.int(1, 8) do
    if #base == 0 then
      break
    end
    local op = r.int(1, #MUTATIONS)
    ops[k] = op
    base = MUTATIONS[op](r, base)
    if #base > MAX_SIZE then
      base = sub(base, 1, MAX_SIZE)
    end
  end
  return base, name .. " ops=" .. concat(ops, ",")
end

-- Pipeline and oracles -------------------------------------------------------

local function chunk_reader(s, size)
  local i = 1
  return function()
    if i > #s then
      return nil
    end
    local piece = sub(s, i, i + size - 1)
    i = i + size
    return piece
  end
end

-- Runs the tokenizer and layout like M.render in bin/html.lua, with a token
-- limit. Returns true and the lines, or false and the error.
local function render(input, width, chunk, traceback)
  local limit = 10 * #input + 1000
  local function handler(e)
    if type(e) == "string" and sub(e, 1, 6) == "html: " then
      return e
    end
    if traceback then
      return traceback(tostring(e), 2)
    end
    return tostring(e)
  end
  guard.reset()
  return xpcall(function()
    local lay = layout.new(width)
    local next_token = tokenizer.new(chunk_reader(input, chunk), lay.count)
    local push = lay.push
    local tokens = 0
    while true do
      local kind, value, attrs, self_closing = next_token()
      if not kind then
        break
      end
      tokens = tokens + 1
      if tokens > limit then
        error("fuzz: token limit " .. limit .. " exceeded", 0)
      end
      push(kind, value, attrs, self_closing)
    end
    return lay.finish()
  end, handler)
end

local function is_controlled(e)
  return type(e) == "string" and sub(e, 1, 6) == "html: "
end

-- Returns the position of the first invalid UTF-8 byte in s, or nil.
-- Overlong forms, surrogates and values above U+10FFFF are invalid.
function M.utf8_error(s)
  local i, n = 1, #s
  while true do
    local at = find(s, "[\128-\255]", i)
    if not at then
      return nil
    end
    i = at
    local b = byte(s, i)
    local need, min
    if b >= 0xC2 and b <= 0xDF then
      need, min = 1, 0x80
    elseif b >= 0xE0 and b <= 0xEF then
      need, min = 2, 0x800
    elseif b >= 0xF0 and b <= 0xF4 then
      need, min = 3, 0x10000
    else
      return i
    end
    if i + need > n then
      return i
    end
    local cp = b & (0x3F >> need)
    for k = 1, need do
      local c = byte(s, i + k)
      if c < 0x80 or c > 0xBF then
        return i
      end
      cp = (cp << 6) | (c & 0x3F)
    end
    if cp < min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
      return i
    end
    i = i + need + 1
  end
end

local function show(s)
  return '"' .. gsub(s, "[^\32-\126]", function(c)
    return string.format("\\x%02X", byte(c))
  end) .. '"'
end

-- Returns nil when the lines pass every line oracle, or a message.
function M.check_lines(lines, width)
  if type(lines) ~= "table" then
    return "result is " .. type(lines) .. ", not a table of lines"
  end
  for i = 1, #lines do
    local line = lines[i]
    if type(line) ~= "string" then
      return "line " .. i .. " is " .. type(line)
    end
    if line ~= "" then
      local b = byte(line, 1)
      if b < 1 or b > 5 then
        return "line " .. i .. " does not start with a style byte: "
          .. show(sub(line, 1, 40))
      end
      local bad = M.utf8_error(line)
      if bad then
        return "line " .. i .. " has invalid UTF-8 at byte " .. bad .. ": "
          .. show(sub(line, math.max(1, bad - 10), bad + 10))
      end
      local ctl = find(line, "[%z\6-\31]")
      if ctl then
        return "line " .. i .. " has control byte "
          .. string.format("0x%02X", byte(line, ctl)) .. " at " .. ctl
          .. ": " .. show(sub(line, math.max(1, ctl - 10), ctl + 10))
      end
      local w = unicode.wlen((gsub(line, "[\1-\5]", "")))
      if w > width then
        return "line " .. i .. " has width " .. w .. " > " .. width .. ": "
          .. show(sub(line, 1, 200))
      end
    end
  end
  return nil
end

local function same_lines(a, b)
  if #a ~= #b then
    return false, "line count " .. #a .. " (chunked) ~= " .. #b
      .. " (single)"
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false, "line " .. i .. " differs: chunked " .. show(a[i])
        .. ", single " .. show(b[i])
    end
  end
  return true
end

-- Runs one input through both pipelines and the oracles. Returns nil, nil
-- and the lines, or "controlled" for an allowed controlled error, or "fail"
-- and a message.
function M.check(input, width, chunk, traceback)
  local ok1, r1 = render(input, width, chunk, traceback)
  local ok2, r2 = render(input, width, #input + 1, traceback)
  if not ok1 and not is_controlled(r1) then
    return "fail", "chunked run: " .. tostring(r1)
  end
  if not ok2 and not is_controlled(r2) then
    return "fail", "single run: " .. tostring(r2)
  end
  if ok1 ~= ok2 then
    return "fail", "outcome differs: chunked " .. tostring(ok1 or r1)
      .. ", single " .. tostring(ok2 or r2)
  end
  if not ok1 then
    -- Both stopped with a controlled error.
    return "controlled"
  end
  local same, why = same_lines(r1, r2)
  if not same then
    return "fail", "chunked and single output differ: " .. why
  end
  local bad = M.check_lines(r2, width)
  if bad then
    return "fail", bad
  end
  return nil, nil, r2
end

-- Card runs -------------------------------------------------------------------
-- A share of the documents also goes through the fake internet card and
-- fetch.lua, with random chunk sizes, "" gaps, headers and errors.

local fetch = require("html.fetch")
local internet = require("internet")
local computer = require("computer")

local CARD_SHARE = 0.3
local CARD_URL = "http://fuzz.example/doc"

local CARD_STATUS = { 200, 200, 200, 200, 201, 204, 404, 500, 503, 302 }
local CARD_TYPES = { false, "text/html", "text/plain",
  "application/xhtml+xml", "image/png", "application/json",
  "text/html; charset=windows-1252", "text/html; charset=ISO-8859-1",
  "text/html; charset=latin1", "text/html; charset=utf-8",
  "text/html; charset=koi8-r", "text/html;charset=\"windows-1252\"" }

-- The media type of a Content-Type value, in lower case.
local function lower_media(ctype)
  return (ctype:match("^[^;]*"):lower():match("^%s*(.-)%s*$"))
end

-- The card run of a document has its own generator, so the documents of a
-- seed stay the same as before the card runs existed.
function M.card_rng(seed, index)
  return M.rng((seed * 1000003 + index) ~ 0x5DEECE66D)
end

-- Builds a card script for input. Returns the script, a short description
-- and true when the body is served unchanged (the output must then equal
-- the output of a plain run).
function M.card_script(r, input)
  local script = { headers = {}, code = r.pick(CARD_STATUS),
    message = r.pick({ "OK", "", "Not Found", "<b>&" }) }
  local ctype = r.pick(CARD_TYPES)
  if ctype then
    script.headers["Content-Type"] = { ctype }
  end
  local encoded = r.chance(0.05)
  if encoded then
    script.headers["Content-Encoding"] = { "gzip" }
  end
  local k = r.int(1, 5)
  if k == 1 then
    script.headers["Content-Length"] = { tostring(#input) }
  elseif k == 2 then
    script.headers["Content-Length"] = { tostring(r.int(0, 2 * #input)) }
  elseif k == 3 then
    script.headers["content-length"] = r.pick({ "x", "-1", " 12 ", "" })
  end
  if script.code == 302 and r.chance(0.5) then
    script.headers.Location = { r.pick({ "/doc", "//x", "ftp://x",
      "http://fuzz.example/doc", "x y" }) }
  end
  local size = r.pick({ 1, 2, 3, 7, 16, 100, 4096, 5000, 65536,
    r.int(1, 9000) })
  local gaps = r.float() * 0.5
  local body = {}
  for i = 1, #input, size do
    body[#body + 1] = sub(input, i, i + size - 1)
    while r.chance(gaps) do
      body[#body + 1] = ""
    end
  end
  local cut = r.int(1, 12)
  if cut == 1 then
    -- A mid-stream error after a random part of the body.
    script.read_error = "reset"
    for i = r.int(1, #body + 1), #body do
      body[i] = nil
    end
  elseif cut == 2 then
    script.read_raise = "broken pipe"
  elseif cut == 3 then
    script.endless = true
  end
  script.body = body
  script.connect_polls = r.int(0, 3)
  script.response_polls = r.int(0, 3)
  if r.chance(0.03) then
    script.connect_error = "unknown host"
  end
  local media = ctype and lower_media(ctype) or ""
  local same = cut > 3 and not encoded and script.code >= 200
    and script.code <= 299 and (media == "" or media == "text/html"
    or media == "text/plain" or media == "application/xhtml+xml")
    and not (ctype and find(ctype:lower(), "1252", 1, true))
    and not (ctype and find(ctype:lower(), "latin1", 1, true))
    and not (ctype and find(ctype:lower(), "8859", 1, true))
    and not script.connect_error
  local desc = string.format("code=%d type=%s size=%d gaps=%.2f cut=%d"
    .. " encoded=%s", script.code, tostring(ctype), size, gaps, cut,
    tostring(encoded))
  return script, desc, same
end

-- Runs input through the fake card and the pipeline. Returns nil, or
-- "controlled", or "fail" and a message. plain is the result of the plain
-- run (the lines) when it ended without an error.
function M.check_card(input, width, r, plain, traceback)
  local script, desc, same = M.card_script(r, input)
  local card, ctl = internet.new({ default = script })
  local interrupt_after = r.chance(0.05) and r.int(0, 3) or nil
  local waits = 0
  local links = {
    internet = card,
    clock = computer.uptime,
    sleep = os.sleep,
    interrupted = function()
      waits = waits + 1
      return interrupt_after ~= nil and waits > interrupt_after
    end,
  }
  local resp
  local ok, result = xpcall(function()
    local why
    resp, why = fetch.open(CARD_URL, links, {})
    if not resp then
      error(why, 0)
    end
    local read = function()
      local s, err = resp.read()
      if s == nil and err then
        error(err, 0)
      end
      return s
    end
    guard.reset()
    local lay = layout.new(width)
    local next_token = tokenizer.new(read, lay.count)
    local limit = 20 * #input + 1000
    local tokens = 0
    while true do
      local kind, value, attrs, self_closing = next_token()
      if not kind then
        break
      end
      tokens = tokens + 1
      if tokens > limit then
        error("fuzz: token limit " .. limit .. " exceeded", 0)
      end
      lay.push(kind, value, attrs, self_closing)
    end
    return lay.finish()
  end, function(e)
    if type(e) == "string" and sub(e, 1, 6) == "html: " then
      return e
    end
    return traceback and traceback(tostring(e), 2) or tostring(e)
  end)
  if resp then
    resp.close()
  end
  local prefix = "card run (" .. desc .. "): "
  for i, h in ipairs(ctl.handles) do
    if h.closed ~= 1 then
      return "fail", prefix .. "handle " .. i .. " closed " .. h.closed
        .. " times"
    end
  end
  if ctl.open ~= 0 then
    return "fail", prefix .. ctl.open .. " connections left open"
  end
  if not ok then
    if is_controlled(result) then
      return "controlled"
    end
    return "fail", prefix .. tostring(result)
  end
  local bad = M.check_lines(result, width)
  if bad then
    return "fail", prefix .. bad
  end
  if same and plain and interrupt_after == nil then
    local equal, why = same_lines(result, plain)
    if not equal then
      return "fail", prefix .. "card and plain output differ: " .. why
    end
  end
  return nil
end

local GENERATORS = { "tag_soup", "random_bytes", "mutation" }

-- Builds document index of the seed run. Returns the input, a record of
-- the choices, and the generator.
function M.document(seed, index, sources)
  local r = M.doc_rng(seed, index)
  local width = r.int(MIN_WIDTH, MAX_WIDTH)
  local chunk = r.int(1, MAX_CHUNK)
  local size = random_size(r)
  local generator = GENERATORS[r.int(1, #GENERATORS)]
  local input, detail
  if generator == "tag_soup" then
    input = M.tag_soup(r, size)
  elseif generator == "random_bytes" then
    input = M.random_bytes(r, size)
  else
    input, detail = M.mutation(r, size, sources)
  end
  return input, {
    seed = seed, index = index, width = width, chunk = chunk,
    generator = generator, detail = detail,
  }
end

function M.failure_text(f)
  return concat({
    "seed=" .. f.seed,
    "index=" .. f.index,
    "generator=" .. f.generator .. (f.detail and (" " .. f.detail) or ""),
    "size=" .. #f.input,
    "width=" .. f.width,
    "chunk=" .. f.chunk,
    "reproduce=lua5.3 tests/fuzz.lua " .. f.index .. " " .. f.seed .. " "
      .. f.index,
    "message=" .. f.message,
  }, "\n") .. "\n"
end

-- opts:
--   n, seed        number of documents and run seed
--   only           optional, run only this document index
--   corpus         list of HTML file paths to mutate
--   large          optional path of a large page to take slices from
--   traceback      optional, debug.traceback for uncontrolled errors
--   on_document()  optional, called before each document
--   on_failure(f)  called for each failure with seed, index, generator,
--                  detail, width, chunk, input and message
-- Returns a summary: documents, bytes, controlled, failures, by_generator.
function M.run(opts)
  local sources = { files = {} }
  for _, path in ipairs(opts.corpus or {}) do
    local s = read_file(path)
    if s and #s > 0 then
      sources.files[#sources.files + 1] = { path, s }
    end
  end
  if opts.large then
    sources.large = read_file(opts.large)
  end
  local summary = { documents = 0, bytes = 0, controlled = 0, failures = 0,
    by_generator = {}, card = 0, card_controlled = 0 }
  for index = opts.only or 1, opts.only or opts.n do
    if opts.on_document then
      opts.on_document(index)
    end
    local input, info = M.document(opts.seed, index, sources)
    summary.documents = summary.documents + 1
    summary.bytes = summary.bytes + #input
    summary.by_generator[info.generator] =
      (summary.by_generator[info.generator] or 0) + 1
    local result, message, plain = M.check(input, info.width, info.chunk,
      opts.traceback)
    if result ~= "fail" then
      local r = M.card_rng(opts.seed, index)
      if r.chance(CARD_SHARE) then
        summary.card = summary.card + 1
        local card_result, card_message = M.check_card(input, info.width, r,
          plain, opts.traceback)
        if card_result == "fail" then
          result, message = card_result, card_message
        elseif card_result == "controlled" then
          summary.card_controlled = summary.card_controlled + 1
        end
      end
    end
    if result == "controlled" then
      summary.controlled = summary.controlled + 1
    elseif result == "fail" then
      summary.failures = summary.failures + 1
      info.input, info.message = input, message
      opts.on_failure(info)
    end
  end
  return summary
end

return M
