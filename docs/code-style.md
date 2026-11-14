# Code style example

Moved from `SPEC.md` "Code Style". The rules are in `SPEC.md` "Code style". This example shows them in a small module.

```lua
local computer = require("computer")

local M = {}

-- OpenOS kills a program that runs for 5 s without yielding.
local YIELD_INTERVAL = 0.25
local MEMORY_RESERVE = 192 * 1024

local last_yield = os.clock()

local function yield()
  os.sleep(0)
  last_yield = os.clock()
end

function M.tick(lines)
  if os.clock() - last_yield > YIELD_INTERVAL then
    yield()
  end
  -- See lib/html/guard.lua for the settle and its rate limit.
end

return M
```
