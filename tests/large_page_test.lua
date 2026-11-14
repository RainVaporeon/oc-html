-- Renders tests/pages/large.html (about 1 MB, made by tools/genpage.lua)
-- through bin/html.lua in print mode at width 160. The page renders or stops
-- with the controlled memory message (spec/testing.md "Success criteria").

local t = require("test")
local computer = require("computer")

local T = {}

local html = t.load_bin("html")({})

-- Returns the exit code, the number of lines written and the stderr lines.
local function render_large()
  local lines, err = 0, {}
  local started = os.clock()
  local code = html.main({ "--print", "--width", "160",
    "tests/pages/large.html", n = 4 }, {
      out = function() lines = lines + 1 end,
      err = function(line) err[#err + 1] = line end,
      open = io.open,
      traceback = function(msg) return msg end,
      clock = os.clock,
    })
  print(string.format("large.html: exit %d, lines=%d, %.2f s", code, lines,
    os.clock() - started))
  return code, lines, err
end

function T.large_page_renders_or_stops_with_the_memory_message()
  local code, lines, err = render_large()
  if code == 0 then
    t.eq(err, {})
    t.ok(lines > 10000, "line count " .. lines)
  else
    t.eq(code, 1)
    t.eq(#err, 1)
    t.ok(err[1]:find("^html: page too large for available memory"), err[1])
  end
end

function T.large_page_stops_with_the_memory_message_at_low_memory()
  computer.test.set_free(100 * 1024)
  local code, lines, err = render_large()
  t.eq(code, 1)
  t.eq(lines, 0)
  t.eq(#err, 1)
  t.ok(err[1]:find("^html: file too large for available memory"), err[1])
end

return T
