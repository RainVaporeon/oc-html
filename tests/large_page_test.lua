-- Renders tests/pages/large.html (about 1 MB, made by tools/genpage.lua)
-- through bin/html.lua at width 160 and prints its stats.

local t = require("test")

local T = {}

local html = t.load_bin("html")({})

function T.large_page_renders_without_uncontrolled_error()
  local lines, err = 0, {}
  local code = html.main({ "--stats", "--width", "160",
    "tests/pages/large.html", n = 4 }, {
      out = function() lines = lines + 1 end,
      err = function(line) err[#err + 1] = line end,
      open = io.open,
      traceback = function(msg) return msg end,
      clock = os.clock,
    })
  for _, line in ipairs(err) do
    t.ok(line:find("^stats: ") or line:find("^html: page too large"), line)
  end
  local stats = {}
  for _, line in ipairs(err) do
    local key, value = line:match("^stats: ([%w_]+)=(.*)$")
    if key then
      stats[key] = value
    end
  end
  t.ok(code == 0 or stats.stopped, "exit code " .. code)
  print(string.format("large.html: %s, lines=%s, cpu=%s", stats.file,
    stats.lines or stats.stopped, stats.cpu or "-"))
  if code == 0 then
    t.eq(stats.lines, tostring(lines))
    t.ok(lines > 10000, "line count " .. lines)
  end
end

return T
