-- Test replacement for the OpenOS event library.
-- Only the queue behavior that the program meets is copied. In OpenOS,
-- os.sleep pulls and discards every event that arrives during the sleep
-- (boot/02_os.lua). Only listeners from event.listen see those events.
-- M.test holds the test controls.

local M = {}

local queue, listeners

local function reset()
  queue = {}
  listeners = {}
end
reset()

-- Delivers one event to the listeners of its name.
local function dispatch(ev)
  local list = {}
  for i, l in ipairs(listeners) do
    list[i] = l
  end
  for _, l in ipairs(list) do
    if l.name == nil or l.name == ev[1] then
      l.callback(table.unpack(ev, 1, ev.n))
    end
  end
end

function M.listen(name, callback)
  for _, l in ipairs(listeners) do
    if l.name == name and l.callback == callback then
      return false
    end
  end
  listeners[#listeners + 1] = { name = name, callback = callback }
  return true
end

function M.ignore(name, callback)
  for i, l in ipairs(listeners) do
    if l.name == name and l.callback == callback then
      table.remove(listeners, i)
      return true
    end
  end
  return false
end

-- Returns the first queued event (optionally of the given name) or nil.
-- The timeout is not waited for. Listeners see the event too.
function M.pull(_, name)
  for i, ev in ipairs(queue) do
    if name == nil or ev[1] == name then
      table.remove(queue, i)
      dispatch(ev)
      return table.unpack(ev, 1, ev.n)
    end
  end
  return nil
end

M.test = {}

function M.test.reset()
  reset()
end

function M.test.push(...)
  queue[#queue + 1] = { n = select("#", ...), ... }
end

function M.test.size()
  return #queue
end

-- Called by the env os.sleep. Removes every queued event and gives each to
-- the listeners.
function M.test.drain()
  while #queue > 0 do
    dispatch(table.remove(queue, 1))
  end
end

return M
