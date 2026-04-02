-- GCD-based HTTP client test (async)
-- Uses CFRunLoopRunWithAutoreleasePool to keep runloop alive

local socket = require 'socket'
local url = require 'socket.url'

local ok_zlib, zlib = pcall(require, 'zlib')
local ok_ssl, ssl = pcall(require, 'ssl')

local XXT_BIN_PATH = XXT_BIN_PATH or '/var/mobile/Media/1ferver/bin'
local gcd_http = dofile(XXT_BIN_PATH .. '/gcd-http.lua')

local function log(...)
    print('[gcd-http-test]', ...)
end

local function now()
    return socket.gettime()
end

local function write_tmp_file(path, data)
    local f = io.open(path, 'wb')
    if not f then
        return nil, 'open failed'
    end
    f:write(data)
    f:close()
    return true
end

local function build_wantwrite_ssl(real_ssl)
    local wrapper = {}
    for k, v in pairs(real_ssl) do
        wrapper[k] = v
    end
    wrapper.wrap = function(sock, params)
        local real, err = real_ssl.wrap(sock, params)
        if not real then
            return nil, err
        end
        local wantwrite_once = true
        local proxy = {}
        local mt = {
            __index = function(_, key)
                if key == 'receive' then
                    return function(_, pattern, prefix)
                        if wantwrite_once then
                            wantwrite_once = false
                            return nil, 'wantwrite'
                        end
                        return real:receive(pattern, prefix)
                    end
                end
                local v = real[key]
                if type(v) == 'function' then
                    return function(_, ...)
                        return v(real, ...)
                    end
                end
                return v
            end,
            __newindex = function(_, key, value)
                real[key] = value
            end,
        }
        return setmetatable(proxy, mt)
    end
    return wrapper
end

local function load_gcd_http_with_ssl(ssl_mod)
    local old_loaded = package.loaded['ssl']
    local old_preload = package.preload['ssl']
    package.loaded['ssl'] = nil
    package.preload['ssl'] = function()
        return ssl_mod
    end
    local mod = dofile(XXT_BIN_PATH .. '/gcd-http.lua')
    package.preload['ssl'] = old_preload
    package.loaded['ssl'] = old_loaded
    return mod
end

local function start_tls_server()
    if not ok_ssl or not ssl then
        return nil
    end
    local cert = [[-----BEGIN CERTIFICATE-----
MIIDCTCCAfGgAwIBAgIUMhAdpB5UHaSuRiosm+1/dbq0IDwwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MDEyMjAyNDkwNFoXDTI3MDEy
MjAyNDkwNFowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEA4n5XWaWa0JpYmhwfRYZO59KcRcwTzfxTtD/b2rs/dTxT
/h1DAvQ9qotwfNL8vADwb4dFdX8I8vkbhoOAujUMY6vn2NGIdLawNbwzNMZdrrHY
P8NrSRJv4Sb+2C/i8wmzmNU30ihkoOIf9pfunyzlITdpPRPPYK7QhZngjTZ4aJtT
IJsIhe8Aoxurx2dfupHA2085q/ND0KTYtLZN4H6S7QdINJaNVCixFTYdhaJvfqB+
Upct9fq7uQmWOFl8yx6eoDj74Si5vROXYj2PfU/4uLpQ3Ei47LjdVkFNqstP/OuE
lF8YJBYNugv9g9VJ8rVKiAyIYdx6zaY4YZW72DXpUQIDAQABo1MwUTAdBgNVHQ4E
FgQU5ZZVIZNoDkfFq0shur5tJLG81RgwHwYDVR0jBBgwFoAU5ZZVIZNoDkfFq0sh
ur5tJLG81RgwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEANa5C
uibCkqF5Kh/99x+m0vMigg6tb9M4diD/VXat+pLOmreDx8xcQraRSQFG7FH7F00n
byL2ujWpNDn8R0UpMUBZiNX8TN021oG94vy0rWCS/nSOUBOMxhh3O00BUPmUFD53
JIInU6H7ma6zDMnjghLbv5mnHhl42+ZvHfA3VRUFCqGs4n3b/4zvyfXoJCzfrf0m
0bJf15xHbC9XIwySLeuTpSx7FSFSb5iqTsfIYM3knYkjHxshR/ILHP/rNKeiyV8U
KaRY+U3QpuZ71Zu51hrU7DnPKuYtu1CMsdRCdHU9SOeIFWGIE+Q4eGzGTvFRcEV4
YIeNu1Q3RX+ieW63Kw==
-----END CERTIFICATE-----]]
    local key = [[-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDifldZpZrQmlia
HB9Fhk7n0pxFzBPN/FO0P9vauz91PFP+HUMC9D2qi3B80vy8APBvh0V1fwjy+RuG
g4C6NQxjq+fY0Yh0trA1vDM0xl2usdg/w2tJEm/hJv7YL+LzCbOY1TfSKGSg4h/2
l+6fLOUhN2k9E89grtCFmeCNNnhom1MgmwiF7wCjG6vHZ1+6kcDbTzmr80PQpNi0
tk3gfpLtB0g0lo1UKLEVNh2Fom9+oH5Sly31+ru5CZY4WXzLHp6gOPvhKLm9E5di
PY99T/i4ulDcSLjsuN1WQU2qy0/864SUXxgkFg26C/2D1UnytUqIDIhh3HrNpjhh
lbvYNelRAgMBAAECggEAHA/7UqgqHl6BS9bgKQUTEbYOlrdKXOM+m76txtQccLIg
1gNaIiuQ2Gieb1jU55ZWM/tWp9Atk605s9jnQisAdfj+qOaNOajI/F9tGMTbJqHy
YTQdPtiB9CuYt8B3JhW1ouIIIInQrf5WZ387mY0+dncfGuoxb5E5VNRT9ishkBQy
84qtudB0LKxhFBKRcAZsNblzsAI+jLgkAq+MFER3OGKB09kt0kR4hpcu7hKzmtSz
NBCR4k9AGYVR5Zw1q2b0V+kAqn5jCKUoXezI08splpQn1L8XkuTJYUGnvPJyEYFy
Fv2GZygBP4zTiXV/atwocnT+93zrrL8ZjpQBaS8lYQKBgQD0M+rYSovsxTO8zByk
8UkrJwWAJJ0vTFaRbkWpOUQH/vRJET3yo1TxqZvzkeoX6e2JyTksN1JSje6PnTB7
dvaTG7fpygQK8/7gNzIKNvGHUdyXr3G1KIOmBxxG4p1JrV3KmFPRnSvyvlvgwZUA
B20uoi4SzyLstG7J9OXnGTlTSwKBgQDtb2lGiaGw1hHfVHYwfV7mB9hvVLS09Zem
hiOA+GzgR03yExwFBH2nXPuZA47s+JE4W9lnzUArWdjWVx8Quef9beNqwq44BZte
CdeacV9IPFAHFOnLdaGI1jy0GVMhrYUJq9nsVon/gWxrwbbNkJ+GH/WeSnfhBncL
H9ZrqQa4UwKBgFOGrnzsgo+po9ift+xy2yP3ZNo/q8PRyIpVvV30SGCzw7p6O0YS
t6sw6DaXYgpr6OOIABYvlejGwyI8EakpN415nZ5Jirh0XGk0d9kmkdZHGbyINcxQ
3zaamAFm4YWh1sLE92Zq6+1LTwHBNMWdxKp+rmOglcGAtaQ+L6Sr6/+hAoGBAMEd
tMqidtiVxMOYtuiJj/4Ys3kZtEDa4BWZVJc5d5STalpSIKAUHv9ZKWoy8rTbF4J3
ckRzNJYN5cev5Jx+GKqQDkBvR7RZGx1JdAsx2wWtyIl6AQ5zBod9eLIjRvJFZ8eN
9xm66VLfuYeLb1uTHazBocy1VPu5fmmV45h9SfHxAoGAEseVuV+P0NnLRhYvJljL
OKmGRotVBjHOpF5qZRaBzHsd2F64RhQJMwDLHjCuijcQlFVUEN8Xs3qq3IW58N+S
WC2CBkXZCB10pkb91CDuF2qGRYksaTYqTfjEzGNCxyucFtd0IaWVWoaXTK5eo7cU
B5rb/yvbzj/DsAOhumsl5+4=
-----END PRIVATE KEY-----]]
    local cert_path = '/tmp/gcd-http-test.crt'
    local key_path = '/tmp/gcd-http-test.key'
    local ok1, err1 = write_tmp_file(cert_path, cert)
    local ok2, err2 = write_tmp_file(key_path, key)
    if not ok1 or not ok2 then
        return nil
    end
    local server = assert(socket.bind('127.0.0.1', 0))
    server:settimeout(0)
    local _, port = server:getsockname()
    local stopped = false

    dispatch_async('concurrent', function()
        while not stopped do
            local client = server:accept()
            if not client then
                socket.sleep(0.01)
            else
                client:settimeout(5)
                local params = {
                    mode = 'server',
                    protocol = 'tlsv1_2',
                    key = key_path,
                    certificate = cert_path,
                    verify = 'none',
                    options = 'all',
                }
                local wrapped, werr = ssl.wrap(client, params)
                if wrapped then
                    wrapped:settimeout(5)
                    local ok_hs = wrapped:dohandshake()
                    if ok_hs then
                        while true do
                            local line, lerr = wrapped:receive('*l')
                            if not line then
                                break
                            end
                            if line == '' then
                                break
                            end
                        end
                        local body = 'tls-ok'
                        local resp = 'HTTP/1.1 200 OK\r\n' ..
                            'Content-Length: ' .. #body .. '\r\n' ..
                            'Content-Type: text/plain\r\n' ..
                            'Connection: close\r\n\r\n' ..
                            body
                        wrapped:send(resp)
                    end
                    pcall(function() wrapped:close() end)
                else
                    pcall(function() client:close() end)
                end
            end
        end
        pcall(function() server:close() end)
    end)

    local function stop()
        stopped = true
        pcall(function() server:close() end)
    end

    return port, stop
end

local function start_origin_server(opts)
    opts = opts or {}
    local server = assert(socket.bind('127.0.0.1', 0))
    server:settimeout(0)
    local _, port = server:getsockname()
    local clients = {}
    local accept_source
    local conn_seq = 0

    local function close_client(c)
        if c.write_source then
            pcall(function() c.write_source:release() end)
            c.write_source = nil
        end
        if c.read_source then
            pcall(function() c.read_source:release() end)
            c.read_source = nil
        end
        if c.sock then
            pcall(function() c.sock:shutdown() end)
            pcall(function() c.sock:close() end)
            c.sock = nil
        end
        clients[c] = nil
    end

    local function compress(data, mode)
        if not ok_zlib or not zlib then
            return nil, 'zlib unavailable'
        end
        local window_bits = (mode == 'gzip') and 31 or 15
        local def = zlib.deflate(nil, window_bits)
        if type(def) ~= 'function' then
            return nil, 'deflate unavailable'
        end
        local ok, out = pcall(def, data, 'finish')
        if not ok then
            return nil, out
        end
        return out
    end

    local function send_response(c, status_line, headers, body, is_chunked)
        local lines = { 'HTTP/1.1 ' .. status_line }
        local has_connection = false
        headers = headers or {}
        for k, v in pairs(headers) do
            if tostring(k):lower() == 'connection' then
                has_connection = true
            end
            table.insert(lines, tostring(k) .. ': ' .. tostring(v))
        end
        if not has_connection then
            if c.keep_alive then
                table.insert(lines, 'Connection: keep-alive')
            else
                table.insert(lines, 'Connection: close')
            end
        end
        table.insert(lines, 'X-Conn-Id: ' .. tostring(c.conn_id))

        local head = table.concat(lines, '\r\n') .. '\r\n\r\n'
        local payload
        if is_chunked then
            payload = head .. (body or '')
        else
            payload = head .. (body or '')
        end

        c.send_queue = { payload }
        c.send_item = payload
        c.send_offset = 1

        local function setup_write()
            if c.write_source then return end
            c.write_source = dispatch_source_register_callback('write', c.fd, 0, function()
                local spin = 0
                while spin < 16 do
                    spin = spin + 1
                    if not c.send_item then
                        if #c.send_queue == 0 then
                            if c.keep_alive then
                                if c.write_source then
                                    pcall(function() c.write_source:release() end)
                                    c.write_source = nil
                                end
                                c.header_parsed = false
                                c.method = nil
                                c.path = nil
                                c.headers = nil
                                c.body_length = 0
                                c.body = nil
                                c.keep_alive = false
                                return
                            end
                            close_client(c)
                            return
                        end
                        c.send_item = c.send_queue[1]
                        c.send_offset = 1
                    end
                    local sent, err, last = c.sock:send(c.send_item, c.send_offset)
                    if sent then
                        c.send_offset = c.send_offset + sent
                        if c.send_offset > #c.send_item then
                            table.remove(c.send_queue, 1)
                            c.send_item = nil
                            c.send_offset = 1
                        end
                    elseif err == 'timeout' or err == 'wantwrite' then
                        if last and last >= c.send_offset then
                            c.send_offset = last + 1
                        end
                        return
                    elseif err == 'wantread' then
                        if last and last >= c.send_offset then
                            c.send_offset = last + 1
                        end
                        return
                    else
                        close_client(c)
                        return
                    end
                end
            end, 'main')
        end

        setup_write()
    end

    local function send_raw_response(c, payload, keep_open)
        c.send_queue = { payload }
        c.send_item = payload
        c.send_offset = 1

        local function setup_write()
            if c.write_source then return end
            c.write_source = dispatch_source_register_callback('write', c.fd, 0, function()
                local spin = 0
                while spin < 16 do
                    spin = spin + 1
                    if not c.send_item then
                        if #c.send_queue == 0 then
                            if keep_open and c.keep_alive then
                                if c.write_source then
                                    pcall(function() c.write_source:release() end)
                                    c.write_source = nil
                                end
                                c.header_parsed = false
                                c.method = nil
                                c.path = nil
                                c.headers = nil
                                c.body_length = 0
                                c.body = nil
                                c.keep_alive = false
                                return
                            end
                            close_client(c)
                            return
                        end
                        c.send_item = c.send_queue[1]
                        c.send_offset = 1
                    end
                    local sent, err, last = c.sock:send(c.send_item, c.send_offset)
                    if sent then
                        c.send_offset = c.send_offset + sent
                        if c.send_offset > #c.send_item then
                            table.remove(c.send_queue, 1)
                            c.send_item = nil
                            c.send_offset = 1
                        end
                    elseif err == 'timeout' or err == 'wantwrite' then
                        if last and last >= c.send_offset then
                            c.send_offset = last + 1
                        end
                        return
                    elseif err == 'wantread' then
                        if last and last >= c.send_offset then
                            c.send_offset = last + 1
                        end
                        return
                    else
                        close_client(c)
                        return
                    end
                end
            end, 'main')
        end

        setup_write()
    end

    local function handle_request(c, method, path, headers, body)
        local resp_body

        if opts.auth_check and path == '/auth-check' then
            if headers['authorization'] or headers['cookie'] then
                send_response(c, '400 Bad Request', {
                    ['Content-Length'] = 0
                }, '', false)
            else
                resp_body = 'auth-ok'
                send_response(c, '200 OK', {
                    ['Content-Length'] = #resp_body,
                    ['Content-Type'] = 'text/plain'
                }, resp_body, false)
            end
            return
        end

        if path == '/hello' then
            resp_body = 'ok'
            send_response(c, '200 OK', {
                ['Content-Length'] = #resp_body,
                ['Content-Type'] = 'text/plain'
            }, resp_body, false)
            return
        end

        if path == '/keepalive' then
            resp_body = 'ka'
            send_response(c, '200 OK', {
                ['Content-Length'] = #resp_body,
                ['Content-Type'] = 'text/plain'
            }, resp_body, false)
            return
        end

        if path == '/echo' then
            resp_body = body or ''
            send_response(c, '200 OK', {
                ['Content-Length'] = #resp_body,
                ['Content-Type'] = 'application/octet-stream'
            }, resp_body, false)
            return
        end

        if path == '/chunked-check' then
            local te = headers['transfer-encoding']
            local cl = headers['content-length']
            if te and tostring(te):lower():find('chunked', 1, true) and cl then
                resp_body = 'bad'
                send_response(c, '400 Bad Request', {
                    ['Content-Length'] = #resp_body,
                    ['Content-Type'] = 'text/plain'
                }, resp_body, false)
            else
                resp_body = 'ok'
                send_response(c, '200 OK', {
                    ['Content-Length'] = #resp_body,
                    ['Content-Type'] = 'text/plain'
                }, resp_body, false)
            end
            return
        end

        if path == '/continue' then
            resp_body = 'ok'
            local resp = 'HTTP/1.1 100 Continue\r\n\r\n' ..
                'HTTP/1.1 200 OK\r\n' ..
                'Content-Length: ' .. #resp_body .. '\r\n' ..
                'Content-Type: text/plain\r\n' ..
                'Connection: close\r\n' ..
                'X-Conn-Id: ' .. tostring(c.conn_id) .. '\r\n\r\n' ..
                resp_body
            send_raw_response(c, resp, false)
            return
        end

        if path == '/drop' then
            resp_body = 'abc'
            local resp = 'HTTP/1.1 200 OK\r\n' ..
                'Content-Length: 10\r\n' ..
                'Content-Type: text/plain\r\n' ..
                'Connection: keep-alive\r\n' ..
                'X-Conn-Id: ' .. tostring(c.conn_id) .. '\r\n\r\n' ..
                resp_body
            send_raw_response(c, resp, false)
            return
        end

        if path == '/http10' then
            resp_body = 'v10'
            local resp = 'HTTP/1.0 200 OK\r\n' ..
                'Content-Length: ' .. #resp_body .. '\r\n' ..
                'Content-Type: text/plain\r\n' ..
                'X-Conn-Id: ' .. tostring(c.conn_id) .. '\r\n\r\n' ..
                resp_body
            send_raw_response(c, resp, true)
            return
        end

        if path == '/bigheader' then
            resp_body = 'ok'
            local big = string.rep('A', 8192)
            local resp = 'HTTP/1.1 200 OK\r\n' ..
                'X-Big: ' .. big .. '\r\n' ..
                'Content-Length: ' .. #resp_body .. '\r\n' ..
                'Content-Type: text/plain\r\n' ..
                'Connection: close\r\n' ..
                'X-Conn-Id: ' .. tostring(c.conn_id) .. '\r\n\r\n' ..
                resp_body
            send_raw_response(c, resp, false)
            return
        end

        if path == '/cookies' then
            resp_body = 'cookie-ok'
            local resp = 'HTTP/1.1 200 OK\r\n' ..
                'Set-Cookie: a=1\r\n' ..
                'Set-Cookie: b=2\r\n' ..
                'Content-Length: ' .. #resp_body .. '\r\n' ..
                'Content-Type: text/plain\r\n' ..
                'Connection: close\r\n' ..
                'X-Conn-Id: ' .. tostring(c.conn_id) .. '\r\n\r\n' ..
                resp_body
            send_raw_response(c, resp, false)
            return
        end

        if opts.external_base_url and path == '/redirect-external' then
            send_response(c, '302 Found', {
                ['Content-Length'] = 0,
                ['Location'] = opts.external_base_url .. '/auth-check'
            }, '', false)
            return
        end

        if path == '/chunked' then
            local chunks = {
                '3\r\nfoo\r\n',
                '3\r\nbar\r\n',
                '5\r\n12345\r\n',
                '0\r\n\r\n'
            }
            resp_body = table.concat(chunks)
            send_response(c, '200 OK', {
                ['Transfer-Encoding'] = 'chunked',
                ['Content-Type'] = 'text/plain'
            }, resp_body, true)
            return
        end

        if path == '/large' then
            resp_body = string.rep('A', 256 * 1024)
            send_response(c, '200 OK', {
                ['Content-Length'] = #resp_body,
                ['Content-Type'] = 'application/octet-stream'
            }, resp_body, false)
            return
        end

        if path == '/redirect1' then
            send_response(c, '302 Found', {
                ['Content-Length'] = 0,
                ['Location'] = '/hello'
            }, '', false)
            return
        end

        if path == '/redirect307' then
            send_response(c, '307 Temporary Redirect', {
                ['Content-Length'] = 0,
                ['Location'] = '/echo'
            }, '', false)
            return
        end

        if path == '/gzip' then
            resp_body = 'hello-gzip'
            local compressed, err = compress(resp_body, 'gzip')
            if not compressed then
                send_response(c, '500 Internal Server Error', {
                    ['Content-Length'] = 0
                }, '', false)
                return
            end
            send_response(c, '200 OK', {
                ['Content-Length'] = #compressed,
                ['Content-Type'] = 'text/plain',
                ['Content-Encoding'] = 'gzip'
            }, compressed, false)
            return
        end

        if path == '/deflate' then
            resp_body = 'hello-deflate'
            local compressed, err = compress(resp_body, 'deflate')
            if not compressed then
                send_response(c, '500 Internal Server Error', {
                    ['Content-Length'] = 0
                }, '', false)
                return
            end
            send_response(c, '200 OK', {
                ['Content-Length'] = #compressed,
                ['Content-Type'] = 'text/plain',
                ['Content-Encoding'] = 'deflate'
            }, compressed, false)
            return
        end

        resp_body = 'not found'
        send_response(c, '404 Not Found', {
            ['Content-Length'] = #resp_body,
            ['Content-Type'] = 'text/plain'
        }, resp_body, false)
    end

    local function parse_headers(header_section)
        local lines = {}
        for line in header_section:gmatch('[^\r\n]+') do
            table.insert(lines, line)
        end
        local request_line = lines[1] or ''
        local method, path = request_line:match('^(%S+)%s+(%S+)')
        local headers = {}
        for i = 2, #lines do
            local k, v = lines[i]:match('^([^:]+):%s*(.*)$')
            if k then
                headers[k:lower()] = v
            end
        end
        return method, path, headers
    end

    local function on_client_read(c)
        local chunk, err, partial = c.sock:receive(8192)
        local data = chunk or partial
        if data and #data > 0 then
            c.buffer = c.buffer .. data
        end

        if not c.header_parsed then
            local header_end = c.buffer:find('\r\n\r\n', 1, true)
            if header_end then
                local header_section = c.buffer:sub(1, header_end - 1)
                c.buffer = c.buffer:sub(header_end + 4)
                c.method, c.path, c.headers = parse_headers(header_section)
                c.header_parsed = true
                local cl = c.headers['content-length']
                c.body_length = tonumber(cl) or 0
                local conn_hdr = c.headers['connection']
                if conn_hdr and tostring(conn_hdr):lower():find('keep-alive', 1, true) then
                    c.keep_alive = true
                end
            end
        end

        if c.header_parsed then
            if c.body_length <= 0 then
                c.body = ''
                handle_request(c, c.method, c.path, c.headers, c.body)
                return
            end
            if #c.buffer >= c.body_length then
                c.body = c.buffer:sub(1, c.body_length)
                c.buffer = c.buffer:sub(c.body_length + 1)
                handle_request(c, c.method, c.path, c.headers, c.body)
                return
            end
        end

        if err and err ~= 'timeout' and err ~= 'wantread' then
            close_client(c)
        end
    end

    accept_source = dispatch_source_register_callback('read', server:getfd(), 0, function()
        local client = server:accept()
        if not client then
            return
        end
        client:settimeout(0)
        local fd = client:getfd()
        conn_seq = conn_seq + 1
        local c = {
            sock = client,
            fd = fd,
            buffer = '',
            header_parsed = false,
            method = nil,
            path = nil,
            headers = nil,
            body_length = 0,
            body = nil,
            keep_alive = false,
            conn_id = conn_seq,
        }
        clients[c] = true

        c.read_source = dispatch_source_register_callback('read', fd, 0, function()
            on_client_read(c)
        end, 'main')
    end, 'main')

    local function stop()
        if accept_source then
            pcall(function() accept_source:release() end)
            accept_source = nil
        end
        for c in pairs(clients) do
            close_client(c)
        end
        pcall(function() server:close() end)
    end

    return port, stop
end

local function start_proxy_server(origin_port)
    local server = assert(socket.bind('127.0.0.1', 0))
    server:settimeout(0)
    local _, port = server:getsockname()
    local clients = {}
    local accept_source
    local function proxy_log(...)
        print('[gcd-http-proxy]', ...)
    end

    local function close_client(c)
        if c.write_source then
            pcall(function() c.write_source:release() end)
            c.write_source = nil
        end
        if c.read_source then
            pcall(function() c.read_source:release() end)
            c.read_source = nil
        end
        if c.up_read_source then
            pcall(function() c.up_read_source:release() end)
            c.up_read_source = nil
        end
        if c.up_write_source then
            pcall(function() c.up_write_source:release() end)
            c.up_write_source = nil
        end
        if c.upstream then
            pcall(function() c.upstream:shutdown() end)
            pcall(function() c.upstream:close() end)
            c.upstream = nil
        end
        if c.sock then
            pcall(function() c.sock:shutdown() end)
            pcall(function() c.sock:close() end)
            c.sock = nil
        end
        clients[c] = nil
    end

    local function send_simple_response(c, status_line, body)
        body = body or ''
        local head = 'HTTP/1.1 ' .. status_line .. '\r\n' ..
            'Content-Length: ' .. #body .. '\r\n' ..
            'Connection: close\r\n\r\n'
        local payload = head .. body
        c.send_queue = { payload }
        c.send_item = nil
        c.send_offset = 1
        if c.write_source then return end
        c.write_source = dispatch_source_register_callback('write', c.fd, 0, function()
            local item = c.send_item or c.send_queue[1]
            if not item then
                close_client(c)
                return
            end
            c.send_item = item
            local sent, err, last = c.sock:send(item, c.send_offset)
            if sent then
                c.send_offset = c.send_offset + sent
                if c.send_offset > #item then
                    close_client(c)
                end
            elseif err == 'timeout' or err == 'wantwrite' then
                if last and last >= c.send_offset then
                    c.send_offset = last + 1
                end
                return
            else
                close_client(c)
            end
        end, 'main')
    end

    local function is_bad_ipv6_uri(target)
        if type(target) ~= 'string' then
            return false
        end
        local _, rest = target:match('^(%w+://)(.+)$')
        if not rest then
            return false
        end
        local hostport = rest:match('^([^/]+)') or rest
        if hostport:find('::', 1, true) and hostport:sub(1, 1) ~= '[' then
            return true
        end
        return false
    end

    local function setup_pipe(c)
        local function pipe_read(src_sock, dst_sock, dst_queue, close_fn, label)
            return function()
                local chunk, err, partial = src_sock:receive(8192)
                local data = chunk or partial
                if data and #data > 0 then
                    proxy_log('pipe', label, #data)
                    table.insert(dst_queue, data)
                    if dst_sock == c.sock then
                        if not c.write_source then
                            c.write_source = dispatch_source_register_callback('write', c.fd, 0, function()
                                if #c.to_client == 0 then return end
                                local item = c.to_client[1]
                                local sent, serr, last = c.sock:send(item, c.to_client_off)
                                if sent then
                                    c.to_client_off = c.to_client_off + sent
                                    if c.to_client_off > #item then
                                        table.remove(c.to_client, 1)
                                        c.to_client_off = 1
                                        if #c.to_client == 0 and c.close_after_send then
                                            proxy_log('close after send', 'client')
                                            close_client(c)
                                            return
                                        end
                                    end
                                elseif serr == 'timeout' or serr == 'wantwrite' then
                                    if last and last >= c.to_client_off then
                                        c.to_client_off = last + 1
                                    end
                                else
                                    close_fn()
                                end
                            end, 'main')
                        end
                    else
                        if not c.up_write_source then
                            c.up_write_source = dispatch_source_register_callback('write', c.up_fd, 0, function()
                                if #c.to_upstream == 0 then return end
                                local item = c.to_upstream[1]
                                local sent, serr, last = c.upstream:send(item, c.to_upstream_off)
                                if sent then
                                    c.to_upstream_off = c.to_upstream_off + sent
                                    if c.to_upstream_off > #item then
                                        table.remove(c.to_upstream, 1)
                                        c.to_upstream_off = 1
                                    end
                                elseif serr == 'timeout' or serr == 'wantwrite' then
                                    if last and last >= c.to_upstream_off then
                                        c.to_upstream_off = last + 1
                                    end
                                else
                                    close_fn()
                                end
                            end, 'main')
                        end
                    end
                end
                if err and err ~= 'timeout' and err ~= 'wantread' then
                    if data and #data > 0 and label == 'u->c' then
                        c.close_after_send = true
                        proxy_log('defer close', label, err)
                        return
                    end
                    close_fn()
                end
            end
        end

        c.to_upstream = {}
        c.to_client = {}
        c.to_upstream_off = 1
        c.to_client_off = 1

        c.read_source = dispatch_source_register_callback('read', c.fd, 0, pipe_read(c.sock, c.upstream, c.to_upstream, function()
            close_client(c)
        end, 'c->u'), 'main')

        c.up_read_source = dispatch_source_register_callback('read', c.up_fd, 0, pipe_read(c.upstream, c.sock, c.to_client, function()
            close_client(c)
        end, 'u->c'), 'main')
    end

    local function handle_connect(c, target, pending_data)
        local host, port = target:match('^([^:]+):(%d+)$')
        port = tonumber(port)
        if not host or not port then
            send_simple_response(c, '400 Bad Request', '')
            return
        end
        proxy_log('connect', target)
        c.tunneling = true
        if c.read_source then
            pcall(function() c.read_source:release() end)
            c.read_source = nil
        end
        c.upstream = socket.tcp4()
        c.upstream:settimeout(0)
        c.upstream:setoption('tcp-nodelay', true)
        c.up_fd = c.upstream:getfd()

        local function finish_tunnel(ok)
            if c.up_connect_source then
                pcall(function() c.up_connect_source:release() end)
                c.up_connect_source = nil
            end
            if not ok then
                proxy_log('connect failed', target)
                send_simple_response(c, '502 Bad Gateway', '')
                return
            end
            proxy_log('connect ok', target)
            local resp = 'HTTP/1.1 200 Connection Established\r\n' ..
                'Proxy-Agent: gcd-http-test\r\n' ..
                'Connection: keep-alive\r\n\r\n'
            c.send_queue = { resp }
            c.send_item = nil
            c.send_offset = 1
            c.write_source = dispatch_source_register_callback('write', c.fd, 0, function()
                local item = c.send_queue[1]
                if not item then
                    return
                end
                local sent, serr, last = c.sock:send(item, c.send_offset)
                if sent then
                    c.send_offset = c.send_offset + sent
                    if c.send_offset > #item then
                        c.send_queue = {}
                        c.send_item = nil
                        c.send_offset = 1
                        if c.write_source then
                            pcall(function() c.write_source:release() end)
                            c.write_source = nil
                        end
                        if c.read_source then
                            pcall(function() c.read_source:release() end)
                            c.read_source = nil
                        end
                        setup_pipe(c)
                        if pending_data and #pending_data > 0 then
                            proxy_log('pending->upstream', #pending_data)
                            table.insert(c.to_upstream, pending_data)
                            pending_data = nil
                            if not c.up_write_source then
                                c.up_write_source = dispatch_source_register_callback('write', c.up_fd, 0, function()
                                    if #c.to_upstream == 0 then return end
                                    local item = c.to_upstream[1]
                                    local sent, serr, last = c.upstream:send(item, c.to_upstream_off)
                                    if sent then
                                        c.to_upstream_off = c.to_upstream_off + sent
                                        if c.to_upstream_off > #item then
                                            table.remove(c.to_upstream, 1)
                                            c.to_upstream_off = 1
                                        end
                                    elseif serr == 'timeout' or serr == 'wantwrite' then
                                        if last and last >= c.to_upstream_off then
                                            c.to_upstream_off = last + 1
                                        end
                                    else
                                        close_client(c)
                                    end
                                end, 'main')
                            end
                        end
                    end
                elseif serr == 'timeout' or serr == 'wantwrite' then
                    if last and last >= c.send_offset then
                        c.send_offset = last + 1
                    end
                else
                    close_client(c)
                end
            end, 'main')
        end

        local ok, err = c.upstream:connect(host, port)
        if ok then
            finish_tunnel(true)
            return
        end
        if err ~= 'timeout' and err ~= 'Operation already in progress' then
            finish_tunnel(false)
            return
        end

        c.up_connect_source = dispatch_source_register_callback('write', c.up_fd, 0, function()
            local ok2, err2 = c.upstream:connect(host, port)
            if ok2 or tostring(err2):lower():find('connected') then
                finish_tunnel(true)
            elseif err2 == 'timeout' or err2 == 'Operation already in progress' then
                return
            else
                finish_tunnel(false)
            end
        end, 'main')
    end

    local function handle_proxy_request(c)
        local header_end = c.buffer:find('\r\n\r\n', 1, true)
        if not header_end then
            return false
        end
        local header_section = c.buffer:sub(1, header_end - 1)
        c.buffer = c.buffer:sub(header_end + 4)
        local lines = {}
        for line in header_section:gmatch('[^\r\n]+') do
            table.insert(lines, line)
        end
        local request_line = lines[1] or ''
        local method, target = request_line:match('^(%S+)%s+(%S+)')
        local headers = {}
        for i = 2, #lines do
            local k, v = lines[i]:match('^([^:]+):%s*(.*)$')
            if k then
                headers[k:lower()] = v
            end
        end

        if method == 'CONNECT' then
            local pending = c.buffer
            c.buffer = ''
            handle_connect(c, target, pending)
            return true
        end

        if is_bad_ipv6_uri(target) then
            send_simple_response(c, '400 Bad Request', 'bad-ipv6-uri')
            return true
        end

        local proxy_auth = headers['proxy-authorization']
        local auth_ok = (proxy_auth and proxy_auth:find('Basic', 1, true) ~= nil)
        local info = url.parse(target)
        local path = info and (info.path or '/') or target
        local body = (auth_ok and 'proxy-auth-ok:' or 'proxy-auth-missing:') .. path
        send_simple_response(c, '200 OK', body)
        return true
    end

    local function on_client_read(c)
        if c.tunneling then
            return
        end
        local chunk, err, partial = c.sock:receive(8192)
        local data = chunk or partial
        if data and #data > 0 then
            c.buffer = c.buffer .. data
            if handle_proxy_request(c) then
                return
            end
        end
        if err and err ~= 'timeout' and err ~= 'wantread' then
            close_client(c)
        end
    end

    accept_source = dispatch_source_register_callback('read', server:getfd(), 0, function()
        local client = server:accept()
        if not client then return end
        client:settimeout(0)
        local fd = client:getfd()
        local c = {
            sock = client,
            fd = fd,
            buffer = '',
            send_queue = nil,
            send_item = nil,
            send_offset = 1,
            write_source = nil,
            read_source = nil,
            up_read_source = nil,
            up_write_source = nil,
            upstream = nil,
            up_fd = nil,
            to_upstream = nil,
            to_client = nil,
            to_upstream_off = 1,
            to_client_off = 1,
        }
        clients[c] = true
        c.read_source = dispatch_source_register_callback('read', fd, 0, function()
            on_client_read(c)
        end, 'main')
    end, 'main')

    local function stop()
        if accept_source then
            pcall(function() accept_source:release() end)
            accept_source = nil
        end
        for c in pairs(clients) do
            close_client(c)
        end
        pcall(function() server:close() end)
    end

    return port, stop
end

local function run_tests(origin_port, proxy_port, tls_port)
    local pending = 0
    local failed = 0

    local function done(name, ok, err)
        if ok then
            log('OK', name)
        else
            failed = failed + 1
            log('FAIL', name, err or '')
        end
        pending = pending - 1
        if pending == 0 then
            return failed
        end
        return nil
    end

    local function skip(name, reason)
        log('SKIP', name, reason or '')
    end

    local function finish_when_ready(stop_all)
        dispatch_after(50, 'main', function()
            if pending == 0 then
                local exit_code = failed == 0 and 0 or 1
                stop_all()
                os.exit(exit_code)
            end
        end)
    end

    local base_url = string.format('http://127.0.0.1:%d', origin_port)
    local proxy_url = string.format('http://user:pass@127.0.0.1:%d', proxy_port)

    pending = pending + 1
    gcd_http.request('GET', base_url .. '/hello', nil, nil, function(status, headers, body, err)
        local ok = (status == 200 and body == 'ok' and not err)
        done('GET /hello', ok, err or tostring(status))
    end, 10)

    pending = pending + 1
    local echo_body = 'ping-echo'
    local echo_sent = false
    local function echo_source()
        if echo_sent then return nil end
        echo_sent = true
        return echo_body
    end
    gcd_http.request('POST', base_url .. '/echo', {
        ['Content-Type'] = 'application/octet-stream'
    }, {
        source = echo_source,
        length = #echo_body
    }, function(status, headers, body, err)
        local ok = (status == 200 and body == echo_body and not err)
        done('POST /echo', ok, err or tostring(status))
    end, 10)

    pending = pending + 1
    gcd_http.request('GET', base_url .. '/chunked', nil, nil, function(status, headers, body, err)
        local ok = (status == 200 and body == 'foobar12345' and not err)
        done('GET /chunked', ok, err or tostring(status))
    end, 10)

    if ok_ssl and ssl and tls_port then
        local wantwrite_ssl = build_wantwrite_ssl(ssl)
        local gcd_http_ww = load_gcd_http_with_ssl(wantwrite_ssl)
        pending = pending + 1
        gcd_http_ww.request('GET', string.format('https://127.0.0.1:%d/tls', tls_port), nil, nil, function(status, headers, body, err)
            local ok = (status == 200 and body == 'tls-ok' and not err)
            done('TLS wantwrite read', ok, err or tostring(status))
        end, 10, { ssl = { verify = 'none' } })
    else
        skip('TLS wantwrite read', 'ssl not available')
    end

    pending = pending + 1
    local chunked_sent = false
    local function chunked_source()
        if chunked_sent then return nil end
        chunked_sent = true
        return 'ping'
    end
    gcd_http.request('POST', base_url .. '/chunked-check', {
        ['Content-Type'] = 'text/plain',
        ['Content-Length'] = '999'
    }, {
        source = chunked_source,
        chunked = true
    }, function(status, headers, body, err)
        local ok = (status == 200 and body == 'ok' and not err)
        done('Chunked without Content-Length', ok, err or tostring(status))
    end, 10)

    pending = pending + 1
    gcd_http.request('GET', base_url .. '/continue', nil, nil, function(status, headers, body, err)
        local ok = (status == 200 and body == 'ok' and not err)
        done('GET /continue (1xx)', ok, err or tostring(status))
    end, 10)

    pending = pending + 1
    local large_path = '/tmp/gcd-http-test.bin'
    local f = assert(io.open(large_path, 'wb'))
    local bytes = 0
    local function file_sink(chunk)
        if chunk == nil then
            f:close()
            return true
        end
        f:write(chunk)
        bytes = bytes + #chunk
        return true
    end
    gcd_http.request('GET', base_url .. '/large', nil, {
        sink = file_sink
    }, function(status, headers, body, err)
        local ok = (status == 200 and bytes == 256 * 1024 and not err)
        done('GET /large sink', ok, err or tostring(status))
        pcall(function() os.remove(large_path) end)
    end, 10)

    pending = pending + 1
    gcd_http.request('GET', base_url .. '/large', nil, nil, function(status, headers, body, err)
        local ok = (err and tostring(err):lower():find('body too large', 1, true))
        done('Max body bytes', ok, err or tostring(status))
    end, 10, { max_body_bytes = 1024 })

    pending = pending + 1
    gcd_http.request('GET', base_url .. '/bigheader', nil, nil, function(status, headers, body, err)
        local ok = (err and tostring(err):lower():find('header too large', 1, true))
        done('Max header bytes', ok, err or tostring(status))
    end, 10, { max_header_bytes = 1024 })

    pending = pending + 1
    gcd_http.request('GET', base_url .. '/redirect1', nil, nil, function(status, headers, body, err)
        local ok = (status == 200 and body == 'ok' and not err)
        done('Redirect GET 302', ok, err or tostring(status))
    end, 10, {
        redirect = true,
        max_redirects = 3
    })

    pending = pending + 1
    gcd_http.request('GET', base_url .. '/redirect-external', {
        ['Authorization'] = 'Bearer secret',
        ['Cookie'] = 'sid=1'
    }, nil, function(status, headers, body, err)
        local ok = (status == 200 and body == 'auth-ok' and not err)
        done('Redirect strips auth headers', ok, err or tostring(status))
    end, 10, {
        redirect = true,
        max_redirects = 3
    })

    pending = pending + 1
    local post_body = 'keep-post'
    local post_sent = false
    local function post_source()
        if post_sent then return nil end
        post_sent = true
        return post_body
    end
    gcd_http.request('POST', base_url .. '/redirect307', {
        ['Content-Type'] = 'application/octet-stream'
    }, {
        source = post_source,
        length = #post_body,
        redirect = true,
        max_redirects = 3,
        source_rewind = function()
            post_sent = false
            return post_source
        end
    }, function(status, headers, body, err)
        local ok = (status == 200 and body == post_body and not err)
        done('Redirect POST 307 (keep body)', ok, err or tostring(status))
    end, 10)

    pending = pending + 1
    gcd_http.request('GET', base_url .. '/keepalive', nil, nil, function(status1, headers1, body1, err1)
        if status1 ~= 200 or err1 or body1 ~= 'ka' then
            done('Keep-Alive reuse (step1)', false, err1 or tostring(status1))
            return
        end
        local id1 = headers1 and headers1['x-conn-id']
        gcd_http.request('GET', base_url .. '/keepalive', nil, nil, function(status2, headers2, body2, err2)
            local id2 = headers2 and headers2['x-conn-id']
            local ok = (status2 == 200 and body2 == 'ka' and not err2 and id1 == id2)
            done('Keep-Alive reuse', ok, err2 or tostring(status2))
        end, 10, { keep_alive = true })
    end, 10, { keep_alive = true })

    pending = pending + 1
    gcd_http.request('GET', base_url .. '/http10', nil, nil, function(status1, headers1, body1, err1)
        if status1 ~= 200 or err1 or body1 ~= 'v10' then
            done('HTTP/1.0 no keep-alive (step1)', false, err1 or tostring(status1))
            return
        end
        local id1 = headers1 and headers1['x-conn-id']
        gcd_http.request('GET', base_url .. '/keepalive', nil, nil, function(status2, headers2, body2, err2)
            local id2 = headers2 and headers2['x-conn-id']
            local ok = (status2 == 200 and body2 == 'ka' and not err2 and (not id1 or id2 ~= id1))
            done('HTTP/1.0 no keep-alive', ok, err2 or tostring(status2))
        end, 10, { keep_alive = true })
    end, 10, { keep_alive = true })

    pending = pending + 1
    gcd_http.request('GET', base_url .. '/drop', nil, nil, function(status, headers, body, err)
        local id1 = headers and headers['x-conn-id']
        if not err then
            done('Reuse after error', false, 'expected error')
            return
        end
        gcd_http.request('GET', base_url .. '/keepalive', nil, nil, function(status2, headers2, body2, err2)
            local id2 = headers2 and headers2['x-conn-id']
            local ok = (status2 == 200 and body2 == 'ka' and not err2 and (not id1 or id2 ~= id1))
            done('Reuse after error', ok, err2 or tostring(status2))
        end, 10, { keep_alive = true })
    end, 10, { keep_alive = true })

    pending = pending + 1
    gcd_http.request('GET', base_url .. '/hello', nil, nil, function(status, headers, body, err)
        local ok = (status == 200 and body == 'proxy-auth-ok:/hello' and not err)
        done('Proxy HTTP (absolute URI)', ok, err or tostring(status))
    end, 10, { proxy = proxy_url })

    pending = pending + 1
    local old_getaddrinfo = socket.dns.getaddrinfo
    socket.dns.getaddrinfo = function(host)
        if host == 'fallback.test' then
            return {
                { family = 'inet', addr = '0.0.0.0' },
                { family = 'inet', addr = '127.0.0.1' },
            }
        end
        return old_getaddrinfo(host)
    end
    gcd_http.request('GET', string.format('http://fallback.test:%d/hello', origin_port), nil, nil, function(status, headers, body, err)
        socket.dns.getaddrinfo = old_getaddrinfo
        local ok = (status == 200 and body == 'ok' and not err)
        done('DNS fallback', ok, err or tostring(status))
    end, 10)

    pending = pending + 1
    gcd_http.request('GET', 'http://[::1]:12345/ipv6', nil, nil, function(status, headers, body, err)
        local ok = (status == 200 and body == 'proxy-auth-ok:/ipv6' and not err)
        done('Proxy IPv6 absolute URI', ok, err or tostring(status))
    end, 10, { proxy = proxy_url })

    pending = pending + 1
    gcd_http.request('GET', base_url .. '/cookies', nil, nil, function(status, headers, body, err)
        local cookies = headers and headers['set-cookie']
        local ok = (status == 200 and body == 'cookie-ok' and type(cookies) == 'table' and #cookies == 2 and not err)
        done('Multiple Set-Cookie', ok, err or tostring(status))
    end, 10)

    pending = pending + 1
    gcd_http.request('GET', base_url .. '/hello', nil, nil, function(status, headers, body, err)
        local ok = (status == 200 and body == 'ok' and not err)
        done('Proxy CONNECT tunnel', ok, err or tostring(status))
    end, 10, { proxy = proxy_url, proxy_tunnel = true, proxy_tunnel_delay_ms = 50, debug = true })

    if ok_zlib and zlib then
        pending = pending + 1
        gcd_http.request('GET', base_url .. '/gzip', nil, nil, function(status, headers, body, err)
            local ok = (status == 200 and body == 'hello-gzip' and not err)
            done('Decode gzip', ok, err or tostring(status))
        end, 10, { decode = true })

        pending = pending + 1
        gcd_http.request('GET', base_url .. '/deflate', nil, nil, function(status, headers, body, err)
            local ok = (status == 200 and body == 'hello-deflate' and not err)
            done('Decode deflate', ok, err or tostring(status))
        end, 10, { decode = true })
    else
        skip('Decode gzip', 'zlib not available')
        skip('Decode deflate', 'zlib not available')
    end

    local function check_exit(stop_all)
        if pending == 0 then
            local exit_code = failed == 0 and 0 or 1
            stop_all()
            os.exit(exit_code)
        else
            finish_when_ready(stop_all)
        end
    end

    return check_exit
end

local auth_port, stop_auth = start_origin_server({ auth_check = true })
local auth_base = string.format('http://127.0.0.1:%d', auth_port)
local origin_port, stop_origin = start_origin_server({ external_base_url = auth_base })
local proxy_port, stop_proxy = start_proxy_server(origin_port)
local tls_port, stop_tls = start_tls_server()
log('auth server listening on', auth_port)
log('origin server listening on', origin_port)
log('proxy server listening on', proxy_port)
if tls_port then
    log('tls server listening on', tls_port)
end

local function stop_all()
    stop_proxy()
    stop_origin()
    stop_auth()
    if stop_tls then
        stop_tls()
    end
end

local check_exit = run_tests(origin_port, proxy_port, tls_port)

-- give callbacks time to finish, then exit
dispatch_after(100, 'main', function()
    check_exit(stop_all)
end)

CFRunLoopRunWithAutoreleasePool()
