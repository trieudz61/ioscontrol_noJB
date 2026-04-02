-- GCD-based WebSocket test server
-- Mirrors layout/var/mobile/Media/1ferver/bin/wstest.lua behavior using server_gcd

local websocket = require 'websocket'

local server = websocket.server.gcd.listen {
  queue = 'main',
  protocols = {
    ['lws-mirror-protocol'] = function(ws)
      ws:on_message(function(ws, data, opcode)
        if opcode == websocket.TEXT then
          ws:broadcast(data)
        end
      end)
    end,
    ['dumb-increment-protocol'] = function(ws)
      local number = 0
      local t
      -- fire every 100ms
      t = dispatch_source_register_callback('timer', 100, 100, function()
        ws:send(tostring(number))
        number = number + 1
      end, 'main')
      ws:on_message(function(ws, message, opcode)
        if opcode == websocket.TEXT then
          if message:match('reset') then
            number = 0
          end
        end
      end)
      ws:on_close(function()
        if t then
          t:release(); t = nil
        end
      end)
      ws:on_error(function(_, err)
        if t then
          t:release(); t = nil
        end
        print('server error:', err)
      end)
    end,
  },
  port = 12345,
}

-- Keep process alive to serve events
CFRunLoopRunWithAutoreleasePool()
