-- The case files and the saved real pages through bin/html.lua, from a local
-- file and through the fake internet card. Spec: spec/testing.md "Success
-- criteria", spec/fetch.md "Stream into the pipeline" and "HTTP status and
-- content type".

local t = require("test")
local unicode = require("unicode")
local internet = require("internet")
local computer = require("computer")

local T = {}

local html = t.load_bin("html")({})

local URL = "http://example.com/page"

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("a")
  f:close()
  return s
end

-- Removes "\r", trailing spaces and tabs, and blank lines at the end.
local function normalize(s)
  local out = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line:gsub("\r", ""):gsub("[ \t]+$", "")
  end
  while #out > 0 and out[#out] == "" do
    out[#out] = nil
  end
  return table.concat(out, "\n")
end

-- A file that gives at most size bytes per read.
local function chunked_file(text, size)
  local pos = 1
  local state = { closed = 0 }
  local f = {}
  function f.read()
    if pos > #text then
      return nil
    end
    local chunk = text:sub(pos, pos + size - 1)
    pos = pos + size
    return chunk
  end
  function f.seek(_, whence)
    if whence == "end" then
      return #text
    end
    return 0
  end
  function f.close()
    state.closed = state.closed + 1
  end
  return f, state
end

local function gpu(width)
  return {
    getScreen = function() return "screen" end,
    maxResolution = function() return width, 25 end,
    getResolution = function() return width, 25 end,
  }
end

-- Runs one document through main. mode is "local" (a file in pieces), "card"
-- (the fake card, print mode), "card404" (the card with a 404 status) or
-- "viewer" (the card, viewer mode with the lines captured). width is the
-- output width. Returns the exit code, the stderr lines, the text and
-- whether every file and card handle closed once.
local function run_doc(doc, mode, size, width)
  local out, err, viewed = {}, {}, nil
  local args = { "--width", tostring(width), URL }
  local deps = {
    out = function(line) out[#out + 1] = line end,
    err = function(line) err[#err + 1] = line end,
    width = 80,
    traceback = function(msg) return msg end,
    clock = os.clock,
    uptime = computer.uptime,
    sleep = os.sleep,
  }
  local handles = {}
  if mode == "local" then
    args = { "--width", tostring(width), "page.html" }
    local file, state = chunked_file(doc, size)
    handles[1] = state
    deps.open = function() return file end
  else
    local script = { headers = { ["Content-Type"] = { "text/html" } },
      body = internet.pieces(doc, size, true) }
    if mode == "card404" then
      script.code, script.message = 404, "Not Found"
    end
    local card, ctl = internet.new({ default = script })
    handles = ctl.handles
    deps.internet = card
    deps.open = function() error("a URL opens no file") end
  end
  if mode == "viewer" then
    args = { URL }
    deps.gpu = gpu(width)
    deps.view = function(lines)
      viewed = {}
      for i, line in ipairs(lines) do
        viewed[i] = line:gsub("[\1-\5]", "")
      end
      return "quit"
    end
  end
  args.n = #args
  local code = html.main(args, deps)
  local closed = true
  for _, h in ipairs(handles) do
    if h.closed ~= 1 then
      closed = false
    end
  end
  return code, err, normalize(table.concat(viewed or out, "\n")), closed
end

-- C1: every case file, in every mode and chunk size ----------------------------
-- The case files hold the text for the layout width 40, so --width 41 (the
-- widest line is the width minus 1).

local CHUNKS = { 1, 2, 3, 7, 4096, 65536 }
local NOTICE = "html: HTTP 404 Not Found: " .. URL

local case_rows = {}
for _, name in ipairs(t.list_cases()) do
  local doc = read_file("tests/cases/" .. name .. ".html")
  local text = normalize(read_file("tests/cases/" .. name .. ".txt"))
  for _, mode in ipairs({ "local", "card", "card404", "viewer" }) do
    case_rows[#case_rows + 1] = { name .. " " .. mode,
      { doc = doc, mode = mode },
      { code = 0, err = mode == "card404" and { NOTICE } or {}, text = text,
        closed = true } }
  end
end

t.cases(T, "cases_match_expected_text", case_rows, function(input, size)
  local code, err, text, closed = run_doc(input.doc, input.mode, size, 41)
  return { code = code, err = err, text = text, closed = closed }
end, { sizes = CHUNKS })

-- RP1: the saved real pages and the large page ---------------------------------
-- A page renders, gives lines, keeps every line within the width minus 1 and
-- gives no unexpected error.

local function check_page(input)
  local doc = read_file(input.path)
  local started = os.clock()
  local code, err, text, closed = run_doc(doc, input.mode, 4096, input.width)
  local seconds = os.clock() - started
  local too_wide, unexpected = 0, 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if unicode.wlen(line) > input.width - 1 then
      too_wide = too_wide + 1
    end
  end
  for _, line in ipairs(err) do
    if line:find("unexpected error", 1, true) then
      unexpected = unexpected + 1
    end
  end
  print(string.format("corpus %s %s width %d: %d lines, %.2f s", input.path,
    input.mode, input.width, select(2, text:gsub("\n", "")) + 1, seconds))
  return { code = code, has_lines = #text > 0, too_wide = too_wide,
    unexpected = unexpected, closed = closed }
end

local OK = { code = 0, has_lines = true, too_wide = 0, unexpected = 0,
  closed = true }

local page_rows = {}
for _, name in ipairs({ "wiki", "wikipedia", "manual" }) do
  for _, width in ipairs({ 40, 80, 160 }) do
    for _, mode in ipairs({ "local", "card" }) do
      page_rows[#page_rows + 1] = { name .. " " .. mode .. " width " .. width,
        { path = "tests/real/" .. name .. ".html", mode = mode,
          width = width }, OK }
    end
  end
end
page_rows[#page_rows + 1] = { "large page through the card",
  { path = "tests/pages/large.html", mode = "card", width = 160 }, OK }

t.cases(T, "real_pages_render", page_rows, check_page)


-- C2: the loading screen does not change the page (spec/loading.md "Content
-- during load"). A viewer run with the screen session gives the same lines
-- and title as a run that opens the viewer after the render, from a file and
-- from the card.

-- Runs a document in viewer mode. framed: the screen session opens before the
-- render, and the session stub keeps the final lines. Returns the plain text,
-- the title and the exit code.
local function run_view(doc, framed, size, source)
  local got = {}
  local deps = {
    out = function() end,
    err = function(line) got.err = line end,
    width = 80,
    traceback = function(msg) return msg end,
    clock = os.clock, uptime = computer.uptime, sleep = os.sleep,
    gpu = gpu(41),
  }
  local function keep(lines, opts)
    got.lines, got.title = lines, opts.title
    return "quit"
  end
  if framed then
    deps.open_screen = function()
      return { rows = 24, status = function() end,
        draw_lines = function() end, poll = function() end, show = keep,
        close = function() end }
    end
  else
    deps.view = keep
  end
  local args
  if source == "local" then
    args = { "page.html" }
    deps.open = function() return (chunked_file(doc, size)) end
  else
    args = { URL }
    deps.internet = internet.new({ default = { headers = {
      ["Content-Type"] = { "text/html" } },
      body = internet.pieces(doc, size, true) } })
    deps.open = function() error("a URL opens no file") end
  end
  args.n = #args
  local code = html.main(args, deps)
  local text = {}
  for i, line in ipairs(got.lines or {}) do
    text[i] = line:gsub("[\1-\5]", "")
  end
  return table.concat(text, "\n"), got.title, code
end

local framed_rows = {}
for _, name in ipairs(t.list_cases()) do
  framed_rows[#framed_rows + 1] = { name .. " (expected text)",
    { doc = read_file("tests/cases/" .. name .. ".html"),
      expected = normalize(read_file("tests/cases/" .. name .. ".txt")) },
    { same = true, matches = true } }
end
for _, name in ipairs({ "wiki", "wikipedia", "manual" }) do
  framed_rows[#framed_rows + 1] = { name .. " (real page)",
    { doc = read_file("tests/real/" .. name .. ".html") },
    { same = true, matches = true } }
end

t.cases(T, "framed_run_gives_the_same_page", framed_rows,
  function(input, size)
    local same, matches = true, true
    for _, source in ipairs({ "local", "card" }) do
      local text, title, code = run_view(input.doc, true, size, source)
      local old_text, old_title, old_code = run_view(input.doc, false, size,
        source)
      if text ~= old_text or title ~= old_title or code ~= old_code
          or code ~= 0 then
        same = false
      end
      if input.expected and normalize(text) ~= input.expected then
        matches = false
      end
    end
    return { same = same, matches = matches }
  end, { sizes = { 1, 4096 } })

return T
