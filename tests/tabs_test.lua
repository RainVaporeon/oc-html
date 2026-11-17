-- Tests for lib/html/tabs.lua against spec/tabs.md "Tab state model".

local t = require("test")
local tabs = require("html.tabs")

local T = {}

local function tab(name)
  local x = tabs.new_tab()
  x.name = name
  return x
end

local function names(l)
  local out = {}
  for i, x in ipairs(l.snapshot().list) do
    out[i] = x.name
  end
  return table.concat(out, ",")
end

T["add_after inserts after the active tab and activates it"] = function()
  local l = tabs.new(8)
  l.add_after(tab("a"))
  l.add_after(tab("b"))
  l.prev()
  l.add_after(tab("c"))
  t.eq(names(l), "a,c,b", "order")
  t.eq(l.active().name, "c", "active")
  t.eq(l.index(), 2, "index")
end

T["add_after stops at the limit"] = function()
  local l = tabs.new(2)
  t.eq(l.add_after(tab("a")), true, "first")
  t.eq(l.add_after(tab("b")), true, "second")
  t.eq(l.add_after(tab("c")), false, "third")
  t.eq(l.count(), 2, "count")
end

T["next and prev wrap"] = function()
  local l = tabs.new(8)
  for _, n in ipairs({ "a", "b", "c" }) do l.add_after(tab(n)) end
  t.eq(l.next().name, "a", "next wraps")
  t.eq(l.prev().name, "c", "prev wraps")
  t.eq(l.prev().name, "b", "prev")
end

T["close activates the right tab, else the left"] = function()
  local l = tabs.new(8)
  for _, n in ipairs({ "a", "b", "c" }) do l.add_after(tab(n)) end
  l.prev() -- b
  t.eq(l.close().name, "c", "right tab")
  t.eq(l.close().name, "a", "left tab at the end")
  t.eq(l.close(), nil, "last tab stays")
  t.eq(l.count(), 1, "count")
end

T["snapshot and restore round trip"] = function()
  local l = tabs.new(8)
  for _, n in ipairs({ "a", "b", "c" }) do l.add_after(tab(n)) end
  l.prev()
  local r = tabs.restore(l.snapshot(), 8)
  t.eq(names(r), "a,b,c", "list")
  t.eq(r.index(), 2, "active")
  t.eq(tabs.restore(nil, 8).count(), 0, "bad data gives an empty list")
end

return T
