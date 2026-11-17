---@meta

-- OpenOS adds sleep to the standard os library.
---@param seconds? number
function os.sleep(seconds) end

---@type string
_OSVERSION = ""

-- The internet card component (OpenComputers InternetCard).
---@class InternetCard
---@field isHttpEnabled fun(): boolean
---@field request fun(url: string, data?: string, headers?: table<string, string>): InternetRequest?, string?
local InternetCard = {}

-- A request handle from InternetCard.request.
---@class InternetRequest
---@field finishConnect fun(): boolean?, string?
---@field response fun(): integer?, string?, table<string, string[]>?
---@field read fun(n?: integer): string?, string?
---@field close fun()
local InternetRequest = {}

-- OpenOS sets or clears an environment variable of the process. A nil value
-- clears it.
---@param name string
---@param value? string
function os.setenv(name, value) end
