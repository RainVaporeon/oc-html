-- History of one browsing session (spec/navigation.md "History").
-- A pure module: it holds entries { target, top, sel } and no page content.
--
--   local h = history.new(cap)   cap defaults to 32
--   h.push(target)       cut the forward entries, append { target, top = 1 },
--                        drop the oldest entry at the cap; returns the entry
--   h.current()          copy of the current entry, or nil when empty
--   h.back()             move one entry back; returns the entry, or nil at the start
--   h.forward()          move one entry forward; returns the entry, or nil at the end
--   h.can_back()         true when back() would move
--   h.can_forward()      true when forward() would move
--   h.set_pos(top, sel)  store top and sel in the current entry (sel may be nil)
--   h.replace(entry)     the current entry becomes a copy of entry (reload)
--   h.drop_current()     remove the current entry (abort after the commit);
--                        the previous entry becomes current and is returned,
--                        or nil when no entry is left
--   h.size()             number of entries

local M = {}

local DEFAULT_CAP = 32

local function copy(entry)
  return { target = entry.target, top = entry.top, sel = entry.sel }
end

function M.new(cap)
  cap = cap or DEFAULT_CAP
  local entries = {}
  local pos = 0
  local h = {}

  function h.push(target)
    for i = #entries, pos + 1, -1 do
      entries[i] = nil
    end
    entries[#entries + 1] = { target = target, top = 1 }
    if #entries > cap then
      table.remove(entries, 1)
    end
    pos = #entries
    return copy(entries[pos])
  end

  function h.current()
    return entries[pos] and copy(entries[pos]) or nil
  end

  function h.can_back()
    return pos > 1
  end

  function h.can_forward()
    return pos < #entries
  end

  function h.back()
    if pos <= 1 then
      return nil
    end
    pos = pos - 1
    return copy(entries[pos])
  end

  function h.forward()
    if pos >= #entries then
      return nil
    end
    pos = pos + 1
    return copy(entries[pos])
  end

  function h.set_pos(top, sel)
    local entry = entries[pos]
    if entry then
      entry.top = top
      entry.sel = sel
    end
  end

  function h.replace(entry)
    if entries[pos] then
      entries[pos] = copy(entry)
    end
  end

  function h.drop_current()
    if pos == 0 then
      return nil
    end
    table.remove(entries, pos)
    -- The first entry has no previous one: the next entry takes its place.
    if pos > 1 then
      pos = pos - 1
    end
    return h.current()
  end

  function h.size()
    return #entries
  end

  return h
end

return M
