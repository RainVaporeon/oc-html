-- Test replacement for the internet card component (not the OpenOS internet
-- library). M.new(opts) returns a fake card proxy and its controller.
-- A script describes the answer to one request (all fields optional):
--   request_error   request() returns nil and this reason
--   request_raise   request() raises this value
--   connect_polls   finishConnect() returns false this many times first
--   connect_error   then finishConnect() returns nil and this reason
--   connect_raise   then finishConnect() raises this value
--   response_polls  response() returns nil this many times first
--   response_after_read
--                   response() returns nil until read() was called once
--   code, message, headers
--                   the response() values (code 200, message "OK" and an
--                   empty headers table by default)
--   body            a list of pieces. read(n) returns at most n bytes of the
--                   current piece. A "" piece is returned once as "".
--   read_error      after the body, read() returns nil and this reason
--   read_raise      after the body, read() raises this value
--   endless         after the body, read() returns "" forever
-- opts: routes (url -> script), default (script for any other url), limit
-- (open connections, default 8), http (isHttpEnabled() result, default true).

local M = {}

local DEFAULT_LIMIT = 8

function M.new(opts)
  opts = opts or {}
  local ctl = { requests = {}, handles = {}, open = 0, max_open = 0,
    closes = 0 }
  local limit = opts.limit or DEFAULT_LIMIT
  local card = {}

  function card.isHttpEnabled()
    return opts.http ~= false
  end

  function card.request(url, data, headers)
    ctl.requests[#ctl.requests + 1] = url
    ctl.data = data
    ctl.headers = headers
    local script = (opts.routes and opts.routes[url]) or opts.default or {}
    if script.request_raise ~= nil then
      error(script.request_raise, 0)
    end
    if script.request_error ~= nil then
      return nil, script.request_error
    end
    if ctl.open >= limit then
      return nil, "too many open connections"
    end
    ctl.open = ctl.open + 1
    ctl.max_open = math.max(ctl.max_open, ctl.open)
    local h = { url = url, closed = 0, reads = 0 }
    ctl.handles[#ctl.handles + 1] = h
    local connect_polls = script.connect_polls or 0
    local response_polls = script.response_polls or 0
    local body = script.body or {}
    local piece, pos = 1, 1

    function h.finishConnect()
      if connect_polls > 0 then
        connect_polls = connect_polls - 1
        return false
      end
      if script.connect_raise ~= nil then
        error(script.connect_raise, 0)
      end
      if script.connect_error ~= nil then
        return nil, script.connect_error
      end
      return true
    end

    function h.response()
      if script.response_after_read and h.reads == 0 then
        return nil
      end
      if response_polls > 0 then
        response_polls = response_polls - 1
        return nil
      end
      return script.code or 200, script.message or "OK",
        script.headers or {}
    end

    function h.read(n)
      h.reads = h.reads + 1
      while piece <= #body do
        local s = body[piece]
        if s == "" then
          piece = piece + 1
          return ""
        end
        if pos <= #s then
          local out = s:sub(pos, pos + (n or #s) - 1)
          pos = pos + #out
          if pos > #s then
            piece, pos = piece + 1, 1
          end
          return out
        end
        piece, pos = piece + 1, 1
      end
      if script.read_raise ~= nil then
        error(script.read_raise, 0)
      end
      if script.read_error ~= nil then
        return nil, script.read_error
      end
      if script.endless then
        return ""
      end
      return nil
    end

    function h.close()
      h.closed = h.closed + 1
      ctl.closes = ctl.closes + 1
      if h.closed == 1 then
        ctl.open = ctl.open - 1
      end
    end

    return h
  end

  return card, ctl
end

-- Splits text into pieces of size bytes, with a "" piece after each piece
-- when gaps is true.
function M.pieces(text, size, gaps)
  local out = {}
  for i = 1, #text, size do
    out[#out + 1] = text:sub(i, i + size - 1)
    if gaps then
      out[#out + 1] = ""
    end
  end
  return out
end

M.test = { reset = function() end }

return M
