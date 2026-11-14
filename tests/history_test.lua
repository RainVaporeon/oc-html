-- Tests for lib/html/history.lua against spec/navigation.md "History".

local t = require("test")
local history = require("html.history")

local T = {}

local function e(target, top, sel)
  return { target = target, top = top or 1, sel = sel }
end

-- Runs steps on a new history. A step is a string (push), or { "op", ... }.
-- The result is { current target, size, can_back, can_forward }.
local function run(steps)
  local h = history.new()
  for _, step in ipairs(steps) do
    if type(step) == "string" then
      h.push(step)
    else
      h[step[1]](table.unpack(step, 2))
    end
  end
  local cur = h.current()
  return { cur and cur.target or false, h.size(), h.can_back(), h.can_forward() }
end

local FLOW = {
  { "empty", {}, { false, 0, false, false } },
  { "push one", { "a" }, { "a", 1, false, false } },
  { "push two", { "a", "b" }, { "b", 2, true, false } },
  { "back", { "a", "b", { "back" } }, { "a", 2, false, true } },
  { "back then forward", { "a", "b", { "back" }, { "forward" } },
    { "b", 2, true, false } },
  { "back at the start does nothing", { "a", { "back" } },
    { "a", 1, false, false } },
  { "back on empty does nothing", { { "back" } }, { false, 0, false, false } },
  { "forward at the end does nothing", { "a", "b", { "forward" } },
    { "b", 2, true, false } },
  { "push cuts the forward entries",
    { "a", "b", "c", { "back" }, { "back" }, "d" },
    { "d", 2, true, false } },
  { "forward after the cut does nothing",
    { "a", "b", "c", { "back" }, "d", { "forward" } },
    { "d", 3, true, false } },
  { "drop the last entry", { "a", "b", { "drop_current" } },
    { "a", 1, false, false } },
  { "drop the only entry", { "a", { "drop_current" } },
    { false, 0, false, false } },
  { "drop the first entry keeps the next",
    { "a", "b", { "back" }, { "drop_current" } },
    { "b", 1, false, false } },
  { "replace keeps the size", { "a", "b", { "replace", e("c") } },
    { "c", 2, true, false } },
  { "replace on empty does nothing", { { "replace", e("c") } },
    { false, 0, false, false } },
}

t.cases(T, "flow", FLOW, run)

local CAP = {
  { "32 entries fit", 32, { 32, "e1", "e32" } },
  { "the 33rd entry drops the oldest", 33, { 32, "e2", "e33" } },
  { "many pushes keep 32", 100, { 32, "e69", "e100" } },
}

t.cases(T, "cap of 32", CAP, function(count)
  local h = history.new()
  for i = 1, count do
    h.push("e" .. i)
  end
  local last = h.current().target
  local first = last
  while h.can_back() do
    first = h.back().target
  end
  return { h.size(), first, last }
end)

t.cases(T, "custom cap", {
  { "cap 3", { "a", "b", "c", "d" }, { 3, "b" } },
}, function(targets)
  local h = history.new(3)
  for _, v in ipairs(targets) do
    h.push(v)
  end
  while h.can_back() do
    h.back()
  end
  return { h.size(), h.current().target }
end)

local ENTRIES = {
  { "a new entry starts at line 1",
    function(h) h.push("a") return h.current() end, e("a", 1) },
  { "set_pos stores top and sel",
    function(h) h.push("a") h.set_pos(7, 2) return h.current() end,
    e("a", 7, 2) },
  { "set_pos with no sel clears it",
    function(h) h.push("a") h.set_pos(7, 2) h.set_pos(8) return h.current() end,
    e("a", 8) },
  { "set_pos on empty does nothing",
    function(h) h.set_pos(7, 2) return h.current() end, nil },
  { "back returns the stored position",
    function(h)
      h.push("a") h.set_pos(5, 1) h.push("b") h.set_pos(9, 3)
      return h.back()
    end, e("a", 5, 1) },
  { "forward returns the stored position",
    function(h)
      h.push("a") h.push("b") h.set_pos(9, 3) h.back()
      return h.forward()
    end, e("b", 9, 3) },
  { "back at the start returns nil",
    function(h) h.push("a") return h.back() end, nil },
  { "forward at the end returns nil",
    function(h) h.push("a") return h.forward() end, nil },
  { "replace swaps the whole entry",
    function(h)
      h.push("a") h.set_pos(5, 1) h.replace(e("a", 2))
      return h.current()
    end, e("a", 2) },
  { "replace does not touch other entries",
    function(h)
      h.push("a") h.set_pos(5, 1) h.push("b") h.replace(e("c", 4, 2))
      return h.back()
    end, e("a", 5, 1) },
  { "drop_current returns the previous entry",
    function(h)
      h.push("a") h.set_pos(5, 1) h.push("b")
      return h.drop_current()
    end, e("a", 5, 1) },
  { "drop_current on empty returns nil",
    function(h) return h.drop_current() end, nil },
  { "a returned entry is a copy",
    function(h)
      h.push("a")
      local c = h.current()
      c.top = 99
      return h.current()
    end, e("a", 1) },
}

t.cases(T, "entries", ENTRIES, function(fn) return fn(history.new()) end)

T["two instances do not share state"] = function()
  local a, b = history.new(), history.new()
  a.push("x")
  a.push("y")
  a.set_pos(4, 1)
  t.eq(b.size(), 0, "b is empty")
  t.eq(b.current(), nil, "b has no current entry")
  b.push("z")
  t.eq(a.current(), e("y", 4, 1), "a keeps its entry")
  t.eq(a.size(), 2, "a keeps its size")
end

return T
