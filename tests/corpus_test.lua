-- Renders the saved real pages in tests/real through the tokenizer and the
-- layout at three widths. A page must render without an error, give more
-- than 0 lines and keep every line within the width.

local t = require("test")
local layout = require("html.layout")
local tokenizer = require("html.tokenizer")
local unicode = require("unicode")

local T = {}

local PAGES = { "wiki", "wikipedia", "manual" }
local WIDTHS = { 40, 80, 160 }
local CHUNK = 4096

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("a")
  f:close()
  return s
end

local function render(doc, width)
  local lay = layout.new(width)
  local pos = 1
  local next_token = tokenizer.new(function()
    if pos > #doc then
      return nil
    end
    local piece = doc:sub(pos, pos + CHUNK - 1)
    pos = pos + CHUNK
    return piece
  end, lay.count)
  while true do
    local kind, value, attrs, self_closing = next_token()
    if not kind then
      break
    end
    lay.push(kind, value, attrs, self_closing)
  end
  return lay.finish()
end

for _, name in ipairs(PAGES) do
  for _, width in ipairs(WIDTHS) do
    T["real_" .. name .. "_at_" .. width] = function()
      local doc = read_file("tests/real/" .. name .. ".html")
      local started = os.clock()
      local lines = render(doc, width)
      local seconds = os.clock() - started
      print(string.format("corpus %s width %d: %d lines, %.2f s", name,
        width, #lines, seconds))
      t.ok(#lines > 0, name .. " gave no lines")
      for i, line in ipairs(lines) do
        local text = line:gsub("[\1-\5]", "")
        t.ok(unicode.wlen(text) <= width, string.format(
          "%s width %d line %d is too wide", name, width, i))
      end
    end
  end
end

-- Pages through the fake internet card ---------------------------------------
-- Each case is served in chunks of 1, 7, 4096 and 65536 bytes with "" gaps
-- and rendered by bin/html.lua with --print --width 40. The text must equal
-- the .txt file, as for a local file.

local internet = require("internet")
local computer = require("computer")
local html = t.load_bin("html")({})

local CARD_CHUNKS = { 1, 7, 4096, 65536 }
local URL = "http://example.com/page"

-- Runs main for url with a fake card that serves text in pieces of size.
-- Returns the exit code, the stdout lines, the stderr lines and the card
-- controller.
local function fetch_main(args, text, size)
  local card, ctl = internet.new({ default = {
    headers = { ["Content-Type"] = { "text/html" } },
    body = internet.pieces(text, size, true) } })
  local out, err = {}, {}
  args.n = #args
  local code = html.main(args, {
    out = function(line) out[#out + 1] = line end,
    err = function(line) err[#err + 1] = line end,
    width = 80,
    open = function() error("a URL opens no file") end,
    traceback = function(msg) return msg end,
    clock = os.clock,
    uptime = computer.uptime,
    sleep = os.sleep,
    internet = card,
  })
  return code, out, err, ctl
end

-- The same normalization as the layout case test: no "\r", no trailing
-- spaces, no blank lines at the end.
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

local function closed_once(ctl, what)
  for i, h in ipairs(ctl.handles) do
    t.eq(h.closed, 1, what .. ": handle " .. i .. " closed once")
  end
end

function T.cases_through_the_card_match_expected_text()
  local failures = {}
  for _, name in ipairs(t.list_cases()) do
    local doc = read_file("tests/cases/" .. name .. ".html")
    local expected = normalize(read_file("tests/cases/" .. name .. ".txt"))
    for _, size in ipairs(CARD_CHUNKS) do
      local code, out, err, ctl = fetch_main({ "--width", "40", URL }, doc,
        size)
      local what = name .. " in chunks of " .. size
      closed_once(ctl, what)
      if code ~= 0 or #err > 0 then
        failures[#failures + 1] = what .. ": exit " .. code .. " "
          .. table.concat(err, " | ")
      elseif normalize(table.concat(out, "\n")) ~= expected then
        failures[#failures + 1] = what .. ": text differs"
      end
    end
  end
  t.ok(#failures == 0, "\n" .. table.concat(failures, "\n"))
end

-- Real pages and the large page: no uncontrolled error.
local function through_card(path, size, width)
  local doc = read_file(path)
  local code, out, err, ctl = fetch_main({ "--width", tostring(width), URL },
    doc, size)
  closed_once(ctl, path)
  for _, line in ipairs(err) do
    t.ok(not line:find("unexpected error", 1, true), path .. ": " .. line)
  end
  t.ok(code == 0 or code == 1, path .. ": exit " .. code)
  if code == 0 then
    t.ok(#out > 0, path .. " gave no lines")
  else
    t.ok(err[1] and err[1]:find("^html: "), path .. ": " .. tostring(err[1]))
  end
end

for _, name in ipairs(PAGES) do
  T["real_" .. name .. "_through_the_card"] = function()
    for _, size in ipairs({ 7, 4096 }) do
      through_card("tests/real/" .. name .. ".html", size, 80)
    end
  end
end

function T.large_page_through_the_card()
  local started = os.clock()
  through_card("tests/pages/large.html", 4096, 160)
  print(string.format("large.html through the card: %.2f s",
    os.clock() - started))
end

return T
