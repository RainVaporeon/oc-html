-- The tab list of one session (spec/tabs.md "Tab state model").
-- A pure module: it holds tab records and the active index, no page content.
--
--   local l = tabs.new(cap)   cap defaults to 8
--   l.add_after(tab)     insert tab after the active tab and make it active;
--                        returns false (and adds nothing) at the cap
--   l.close()            remove the active tab; the right tab becomes active,
--                        else the left one; returns the new active tab, or
--                        nil (and removes nothing) when only one tab is left
--   l.next(), l.prev()   move the active index with wrap; return the active tab
--   l.active()           the active tab record, or nil when empty
--   l.index()            the active index
--   l.count()            number of tabs
--   l.snapshot()         { v = 1, active = <int>, list = { tab, ... } }
--   tabs.restore(data, cap)   new list from a snapshot; bad data gives an
--                        empty list
--
-- A tab record: { entries, pos, guesses, shown, pending, job } (the job field
-- is reserved and stays nil). tabs.new_tab(hist_export) makes one.

local M = {}

local DEFAULT_CAP = 8

function M.new_tab(exported)
  exported = exported or { entries = {}, pos = 0 }
  return {
    entries = exported.entries,
    pos = exported.pos,
    guesses = {},
    shown = nil,
    pending = nil,
    job = nil,
  }
end

function M.new(cap)
  cap = cap or DEFAULT_CAP
  local list = {}
  local cur = 0
  local l = {}

  function l.add_after(tab)
    if #list >= cap then
      return false
    end
    table.insert(list, cur + 1, tab)
    cur = cur + 1
    return true
  end

  function l.close()
    if #list <= 1 then
      return nil
    end
    table.remove(list, cur)
    if cur > #list then
      cur = #list
    end
    return list[cur]
  end

  function l.next()
    if #list > 0 then
      cur = cur % #list + 1
    end
    return list[cur]
  end

  function l.prev()
    if #list > 0 then
      cur = (cur - 2) % #list + 1
    end
    return list[cur]
  end

  function l.active()
    return list[cur]
  end

  function l.index()
    return cur
  end

  function l.count()
    return #list
  end

  function l.snapshot()
    local out = {}
    for i, tab in ipairs(list) do
      out[i] = tab
    end
    return { v = 1, active = cur, list = out }
  end

  function l.load(data)
    list = {}
    for i, tab in ipairs(data.list) do
      if #list < cap and type(tab) == "table" then
        list[#list + 1] = tab
      end
    end
    local at = math.tointeger(data.active) or 1
    cur = #list == 0 and 0 or math.max(1, math.min(at, #list))
  end

  return l
end

function M.restore(data, cap)
  local l = M.new(cap)
  if type(data) == "table" and data.v == 1 and type(data.list) == "table" then
    l.load(data)
  end
  return l
end

return M
