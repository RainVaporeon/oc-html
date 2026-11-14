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

return T
