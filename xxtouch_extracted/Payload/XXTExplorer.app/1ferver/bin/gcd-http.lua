-- GCD-based async HTTP client for Lua
-- Uses dispatch_source_register_callback for non-blocking I/O
-- Supports LTN12-like source (request body) / sink (response body)
-- Features: HTTPS, redirects, keep-alive pool, proxy/CONNECT, decode, file helpers

local socket = require 'socket'
local url = require 'socket.url'

local ok_ltn12, ltn12 = pcall(require, 'ltn12')
local ok_ssl, ssl = pcall(require, 'ssl')
local ok_zlib, zlib = pcall(require, 'zlib')
local ok_mime, mime = pcall(require, 'mime')

local M = {
    defaults = {
        keep_alive = false,
        redirect = false,
        max_redirects = 5,
        decode = nil, -- nil => auto (depends on zlib)
        pool_max = 32,
        pool_idle_timeout = 30,
    }
}

local pool = { items = {} }

-- copy_table(src) -> table
-- @param src table|nil Source table.
-- @return table Shallow copy; empty table if src is not a table.
local function copy_table(src)
    if type(src) ~= 'table' then
        return {}
    end
    local out = {}
    for k, v in pairs(src) do
        out[k] = v
    end
    return out
end

-- header_get(headers, name) -> value, key
-- @param headers table|nil Header table.
-- @param name string Header name to match (case-insensitive).
-- @return any|nil, string|nil Header value and original key.
local function header_get(headers, name)
    if type(headers) ~= 'table' then return nil end
    local lname = name:lower()
    for k, v in pairs(headers) do
        if tostring(k):lower() == lname then
            return v, k
        end
    end
    return nil
end

-- header_set(headers, name, value) -> nil
-- @param headers table|nil Header table.
-- @param name string Header name (case-insensitive).
-- @param value any Header value.
local function header_set(headers, name, value)
    if type(headers) ~= 'table' then return end
    local _, key = header_get(headers, name)
    if key then
        headers[key] = value
    else
        headers[name] = value
    end
end

-- header_remove(headers, name) -> nil
-- @param headers table|nil Header table.
-- @param name string Header name (case-insensitive).
local function header_remove(headers, name)
    if type(headers) ~= 'table' then return end
    local lname = name:lower()
    for k, _ in pairs(headers) do
        if tostring(k):lower() == lname then
            headers[k] = nil
        end
    end
end

-- base64_encode(s) -> string
-- @param s string Raw string to encode.
-- @return string Base64-encoded result.
local base64_encode = string.base64_encode
if not base64_encode and ok_mime and mime and type(mime.b64) == 'function' then
    base64_encode = mime.b64
end

-- make_string_source(s) -> source_fn
-- @param s string|nil Body string.
-- @return function LTN12-style source: returns chunk string or nil.
local function make_string_source(s)
    if ok_ltn12 and ltn12 and type(ltn12.source) == 'table' and type(ltn12.source.string) == 'function' then
        return ltn12.source.string(s or '')
    end
    local sent = false
    return function()
        if sent then return nil end
        sent = true
        return s or ''
    end
end

-- normalize_opts(body, opts) -> opts_table, body_value
-- @param body any Request body or opts table (if opts is nil).
-- @param opts table|nil Options table.
-- @return table, any Resolved opts table and body value.
local function normalize_opts(body, opts)
    if type(body) == 'table' and not opts then
        if body.source or body.sink or body.body or body.length or body.body_length or body.size or body.chunked or body.timeout then
            return body, body.body
        end
    end
    return opts or {}, body
end

-- apply_defaults(req) -> req
-- @param req table Request options (mutated).
-- @return table Same req table with defaults filled.
local function apply_defaults(req)
    if req.keep_alive == nil then
        req.keep_alive = M.defaults.keep_alive
    end
    if req.redirect == nil then
        req.redirect = M.defaults.redirect
    end
    if req.max_redirects == nil then
        req.max_redirects = M.defaults.max_redirects
    end
    if req.decode == nil then
        req.decode = ok_zlib and zlib and type(zlib.inflate) == 'function' or false
    end
    if req.pool_max == nil then
        req.pool_max = M.defaults.pool_max
    end
    if req.pool_idle_timeout == nil then
        req.pool_idle_timeout = M.defaults.pool_idle_timeout
    end
    return req
end

-- normalize_request(method, url_value, headers, body, callback, timeout, opts) -> req, cb
-- @param method string|table HTTP method or prebuilt request table.
-- @param url_value string URL.
-- @param headers table|nil Header table.
-- @param body any Body string or source function or opts table.
-- @param callback function|nil Completion callback.
-- @param timeout number|nil Total timeout (seconds).
-- @param opts table|nil Options table.
-- @return table, function|nil Normalized request table and callback.
local function normalize_request(method, url_value, headers, body, callback, timeout, opts)
    if type(method) == 'table' then
        local req = method
        req.method = req.method or 'GET'
        req.headers = req.headers or {}
        if req.timeout and not req.total_timeout then
            req.total_timeout = req.timeout
        end
        apply_defaults(req)
        local cb = req.callback or req.on_done or req.on_complete or callback
        return req, cb
    end

    local req_opts, req_body = normalize_opts(body, opts)
    local req = copy_table(req_opts)
    req.method = method or req.method or 'GET'
    req.url = url_value
    req.headers = headers or req.headers or {}
    req.body = req_body
    req.total_timeout = req.total_timeout or req.timeout or timeout
    req.connect_timeout = req.connect_timeout or req_opts.connect_timeout
    req.read_timeout = req.read_timeout or req_opts.read_timeout
    req.write_timeout = req.write_timeout or req_opts.write_timeout
    apply_defaults(req)
    return req, callback
end

-- encode_query(q) -> string|nil
-- @param q table|nil Query table.
-- @return string|nil Encoded query string or nil.
local function encode_query(q)
    if type(q) ~= 'table' then
        return nil
    end
    local parts = {}
    for k, v in pairs(q) do
        local key = url.escape(tostring(k))
        local val = url.escape(tostring(v))
        parts[#parts + 1] = key .. '=' .. val
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, '&')
end

-- parse_url(raw_url) -> info|nil, err|nil
-- @param raw_url string URL string.
-- @return table|nil, string|nil Parsed info table or error message.
local function parse_url(raw_url)
    if type(raw_url) ~= 'string' or raw_url == '' then
        return nil, 'Invalid URL'
    end
    local parsed = url.parse(raw_url)
    if not parsed or not parsed.host then
        if not raw_url:match('^%w+://') then
            parsed = url.parse('http://' .. raw_url)
        end
    end
    if not parsed or not parsed.host then
        return nil, 'Invalid URL: ' .. tostring(raw_url)
    end
    local scheme = (parsed.scheme or 'http'):lower()
    local port = tonumber(parsed.port)
    if not port then
        if scheme == 'https' then
            port = 443
        else
            port = 80
        end
    end
    local path = parsed.path or '/'
    if parsed.query and parsed.query ~= '' then
        path = path .. '?' .. parsed.query
    end
    return {
        scheme = scheme,
        host = parsed.host,
        port = port,
        path = path,
        raw = raw_url,
        user = parsed.user,
        password = parsed.password,
    }, nil
end

-- normalize_proxy(proxy) -> proxy_info|nil, err|nil
-- @param proxy string|table|nil Proxy spec or nil.
-- @return table|nil, string|nil Normalized proxy table or error message.
local function normalize_proxy(proxy)
    if not proxy then
        return nil
    end
    if type(proxy) == 'string' then
        local p = proxy
        if not p:match('^%w+://') then
            p = 'http://' .. p
        end
        local info, err = parse_url(p)
        if not info then
            return nil, err
        end
        return {
            scheme = info.scheme or 'http',
            host = info.host,
            port = info.port or 80,
            user = info.user,
            password = info.password,
        }
    end
    if type(proxy) == 'table' then
        if not proxy.host then
            return nil, 'Invalid proxy'
        end
        return {
            scheme = (proxy.scheme or 'http'):lower(),
            host = proxy.host,
            port = proxy.port or 80,
            user = proxy.user,
            password = proxy.password,
            auth = proxy.auth,
            tunnel = proxy.tunnel,
        }
    end
    return nil, 'Invalid proxy'
end

local function strip_ipv6_brackets(host)
    if type(host) == 'string' and host:sub(1, 1) == '[' and host:sub(-1) == ']' then
        return host:sub(2, -2)
    end
    return host
end

local function is_ipv4_literal(host)
    if type(host) ~= 'string' then return false end
    return host:match('^%d+%.%d+%.%d+%.%d+$') ~= nil
end

local function is_ipv6_literal(host)
    if type(host) ~= 'string' then return false end
    return host:find(':', 1, true) ~= nil
end

local function format_host_literal(host)
    if type(host) ~= 'string' then return host end
    if host:sub(1, 1) == '[' and host:sub(-1) == ']' then
        return host
    end
    if is_ipv6_literal(host) then
        return '[' .. host .. ']'
    end
    return host
end

local function build_addr_candidates(addrinfo)
    local out = {}
    if type(addrinfo) ~= 'table' then
        return out
    end
    for _, alt in ipairs(addrinfo) do
        if alt and alt.addr then
            local family = (alt.family == 'inet6') and 'inet6' or 'inet'
            out[#out + 1] = { family = family, addr = alt.addr }
        end
    end
    return out
end

local function resolve_async(host, queue, cb)
    if type(dispatch_async) ~= 'function' then
        local addrinfo, err = socket.dns.getaddrinfo(host)
        cb(addrinfo, err)
        return
    end
    dispatch_async('concurrent', function()
        local addrinfo, err = socket.dns.getaddrinfo(host)
        dispatch_async(queue or 'main', function()
            cb(addrinfo, err)
        end)
    end)
end

-- build_request_lines(method, host, port, default_port, path, headers, body_length, use_chunked, keep_alive)
-- -> lines, has_cl, has_te, te_value
-- @param method string HTTP method.
-- @param host string Hostname.
-- @param port number Port.
-- @param default_port number Default port for scheme.
-- @param path string Request path or absolute URL.
-- @param headers table|nil Header table.
-- @param body_length number|nil Body length.
-- @param use_chunked boolean Chunked transfer flag.
-- @param keep_alive boolean Keep-alive flag.
-- @return table, boolean, boolean, string|nil Request lines and header flags.
local function build_request_lines(method, host, port, default_port, path, headers, body_length, use_chunked, keep_alive)
    local request_lines = {
        method .. ' ' .. path .. ' HTTP/1.1',
    }

    local has_content_length = false
    local has_transfer_encoding = false
    local has_host = false
    local has_connection = false
    local transfer_encoding_value = nil

    headers = headers or {}
    for k, v in pairs(headers) do
        local key = tostring(k)
        local val = tostring(v)
        local lower = key:lower()
        if lower == 'content-length' then
            has_content_length = true
        elseif lower == 'transfer-encoding' then
            has_transfer_encoding = true
            transfer_encoding_value = val
        elseif lower == 'host' then
            has_host = true
        elseif lower == 'connection' then
            has_connection = true
        end
        request_lines[#request_lines + 1] = key .. ': ' .. val
    end

    if not has_host then
        local host_header = format_host_literal(host)
        if port and default_port and port ~= default_port then
            host_header = host_header .. ':' .. port
        end
        request_lines[#request_lines + 1] = 'Host: ' .. host_header
    end

    if not has_connection then
        request_lines[#request_lines + 1] = 'Connection: ' .. (keep_alive and 'keep-alive' or 'close')
    end

    if use_chunked then
        if not has_transfer_encoding then
            request_lines[#request_lines + 1] = 'Transfer-Encoding: chunked'
        end
    elseif type(body_length) == 'number' and body_length >= 0 and not has_content_length then
        request_lines[#request_lines + 1] = 'Content-Length: ' .. body_length
    end

    return request_lines, has_content_length, has_transfer_encoding, transfer_encoding_value
end

-- build_ssl_params(host, req_ssl) -> params
-- @param host string Hostname for SNI/verify.
-- @param req_ssl table|nil LuaSec params override.
-- @return table SSL params table.
local function build_ssl_params(host, req_ssl)
    local params = {
        mode = 'client',
        protocol = 'tlsv1_2',
        options = 'all',
        verify = 'none',
    }
    if type(req_ssl) == 'table' then
        for k, v in pairs(req_ssl) do
            params[k] = v
        end
    end
    if not params.sni and host then
        params.sni = host
    end
    if params.verify_host and not params.verifyext then
        params.verify = params.verify or 'peer'
        params.verifyext = { 'lsec', host }
    end
    return params
end

-- ssl_fingerprint(params) -> string
-- @param params table|nil SSL params table.
-- @return string Stable fingerprint string for pooling.
local function ssl_fingerprint(params)
    if type(params) ~= 'table' then
        return ''
    end
    local keys = {
        'protocol', 'options', 'verify', 'cafile', 'capath', 'ciphers', 'ciphersuites',
        'depth', 'verifyext', 'sni', 'alpn'
    }
    local parts = {}
    for _, k in ipairs(keys) do
        local v = params[k]
        if v ~= nil then
            if type(v) == 'table' then
                local t = {}
                for _, item in ipairs(v) do
                    t[#t + 1] = tostring(item)
                end
                v = table.concat(t, ',')
            else
                v = tostring(v)
            end
            parts[#parts + 1] = k .. '=' .. v
        end
    end
    return table.concat(parts, ';')
end

-- conn_close(conn) -> nil
-- @param conn table|nil Connection object.
local function conn_close(conn)
    if not conn then return end
    conn.closed = true
    if conn.sock then
        pcall(function() conn.sock:shutdown() end)
        pcall(function() conn.sock:close() end)
        conn.sock = nil
    end
end

-- pool_key(url_info, proxy, use_tls, ssl_params, proxy_tunnel) -> string
-- @param url_info table Parsed URL info.
-- @param proxy table|nil Proxy info.
-- @param use_tls boolean TLS flag.
-- @param ssl_params table|nil SSL params.
-- @param proxy_tunnel boolean Proxy tunnel flag.
-- @return string Pool key.
local function pool_key(url_info, proxy, use_tls, ssl_params, proxy_tunnel)
    local key = url_info.scheme .. '|' .. url_info.host .. '|' .. tostring(url_info.port)
    if proxy then
        key = key .. '|proxy=' .. tostring(proxy.host) .. ':' .. tostring(proxy.port)
        if proxy_tunnel then
            key = key .. '|tunnel'
        end
    end
    if use_tls then
        key = key .. '|tls=' .. ssl_fingerprint(ssl_params)
    end
    return key
end

-- pool_take(key, idle_timeout) -> conn|nil
-- @param key string Pool key.
-- @param idle_timeout number|nil Idle timeout seconds.
-- @return table|nil Connection object or nil.
local function pool_take(key, idle_timeout)
    local list = pool.items[key]
    if not list then
        return nil
    end
    local now = socket.gettime()
    for i = #list, 1, -1 do
        local conn = list[i]
        if conn.closed then
            table.remove(list, i)
        elseif idle_timeout and now - conn.last_used > idle_timeout then
            table.remove(list, i)
            conn_close(conn)
        end
    end
    local conn = table.remove(list, 1)
    if conn then
        conn.busy = true
    end
    return conn
end

-- pool_put(conn, max, idle_timeout) -> nil
-- @param conn table Connection object.
-- @param max number|nil Max pool size.
-- @param idle_timeout number|nil Idle timeout seconds.
local function pool_put(conn, max, idle_timeout)
    if not conn or conn.closed then
        conn_close(conn)
        return
    end
    conn.busy = false
    conn.last_used = socket.gettime()
    local list = pool.items[conn.key]
    if not list then
        list = {}
        pool.items[conn.key] = list
    end
    list[#list + 1] = conn
    if max and #list > max then
        local extra = #list - max
        for i = 1, extra do
            local victim = table.remove(list, 1)
            conn_close(victim)
        end
    end
end

-- build_absolute_url(info, path) -> string
-- @param info table Parsed URL info.
-- @param path string Path/query string.
-- @return string Absolute URL.
local function build_absolute_url(info, path)
    local host = format_host_literal(info.host)
    local scheme = info.scheme
    local port = info.port
    local default_port = (scheme == 'https') and 443 or 80
    if port and port ~= default_port then
        return string.format('%s://%s:%d%s', scheme, host, port, path)
    end
    return string.format('%s://%s%s', scheme, host, path)
end

local function same_origin(a, b)
    if type(a) ~= 'table' or type(b) ~= 'table' then
        return false
    end
    return (a.scheme == b.scheme) and (a.host == b.host) and (tonumber(a.port) == tonumber(b.port))
end

-- create_decoder(encoding) -> decoder|nil, err|nil
-- @param encoding string "gzip" or "deflate".
-- @return function|nil, string|nil Decoder function or error message.
local function create_decoder(encoding)
    if not ok_zlib or not zlib or type(zlib.inflate) ~= 'function' then
        return nil, 'zlib not available'
    end

    local function try_inflate(bits)
        local ok, infl = pcall(zlib.inflate, bits)
        if ok and type(infl) == 'function' then
            return infl
        end
        return nil
    end

    local inflater
    if encoding == 'gzip' then
        inflater = try_inflate(31) or try_inflate(47)
    elseif encoding == 'deflate' then
        inflater = try_inflate(15) or try_inflate(47)
    else
        return nil, 'unsupported encoding'
    end

    if type(inflater) ~= 'function' then
        return nil, 'zlib.inflate unavailable'
    end

    local done = false
    local failed = false
    return function(chunk)
        if failed then
            return nil, 'decode failed'
        end
        if done then
            if chunk == nil or chunk == '' then
                return ''
            end
            return '', nil
        end
        local ok, out, eof = pcall(inflater, chunk or '')
        if not ok then
            failed = true
            return nil, out
        end
        if type(out) ~= 'string' then
            failed = true
            return nil, 'decode failed'
        end
        if eof then
            done = true
        end
        return out, eof
    end
end

-- decode_full(encoding, data) -> decoded|nil, err|nil
-- @param encoding string "gzip" or "deflate".
-- @param data string|nil Encoded payload.
-- @return string|nil, string|nil Decoded string or error message.
local function decode_full(encoding, data)
    local decoder, err = create_decoder(encoding)
    if not decoder then
        return nil, err
    end
    local out, derr = decoder(data or '')
    if not out then
        return nil, derr
    end
    local tail, terr = decoder(nil)
    if tail == nil then
        return nil, terr
    end
    return out .. tail
end

-- request_internal(req, callback, handle, redirect_count) -> nil
-- @param req table Normalized request.
-- @param callback function|nil Completion callback.
-- @param handle table Request handle.
-- @param redirect_count number Current redirect depth.
local function request_internal(req, callback, handle, redirect_count)
    if handle.cancelled then
        return
    end

    local url_info, url_err = parse_url(req.url)
    if not url_info then
        if callback then
            callback(nil, nil, nil, url_err)
        end
        return
    end

    local method = tostring(req.method or 'GET'):upper()
    local scheme = url_info.scheme
    local host = url_info.host
    local port = url_info.port
    local path = url_info.path

    local query_str = encode_query(req.query)
    if query_str and query_str ~= '' then
        if path:find('?', 1, true) then
            path = path .. '&' .. query_str
        else
            path = path .. '?' .. query_str
        end
    end

    local proxy, proxy_err = normalize_proxy(req.proxy)
    if proxy_err then
        if callback then
            callback(nil, nil, nil, proxy_err)
        end
        return
    end

    local proxy_tunnel = proxy and (scheme == 'https' or req.proxy_tunnel == true or proxy.tunnel == true)
    local request_path = path
    if proxy and not proxy_tunnel then
        request_path = build_absolute_url(url_info, path)
    end

    local headers = copy_table(req.headers or {})

    if req.decode and not header_get(headers, 'accept-encoding') then
        header_set(headers, 'Accept-Encoding', 'gzip, deflate')
    end

    local proxy_auth = nil
    if proxy then
        if proxy.auth then
            proxy_auth = proxy.auth
        elseif proxy.user then
            local token = base64_encode(proxy.user .. ':' .. (proxy.password or ''))
            proxy_auth = 'Basic ' .. token
        end
    end

    if proxy and proxy_auth and not proxy_tunnel then
        header_set(headers, 'Proxy-Authorization', proxy_auth)
    end

    local body_source = nil
    local body_length = nil
    local force_chunked = req.chunked == true

    if type(req.source) == 'function' then
        body_source = req.source
        body_length = tonumber(req.length or req.body_length or req.size)
    elseif type(req.body) == 'string' then
        body_source = make_string_source(req.body)
        body_length = #req.body
    elseif type(req.body) == 'function' then
        body_source = req.body
        body_length = tonumber(req.length or req.body_length or req.size)
    elseif req.body ~= nil then
        if callback then
            callback(nil, nil, nil, 'Unsupported body type: ' .. type(req.body))
        end
        return
    end

    local use_chunked = false
    if body_source then
        if force_chunked then
            use_chunked = true
        elseif not body_length then
            use_chunked = true
        end
    end

    local req_te = header_get(headers, 'transfer-encoding')
    if req_te and tostring(req_te):lower():find('chunked', 1, true) then
        use_chunked = true
    end
    if use_chunked then
        header_remove(headers, 'content-length')
    end

    local want_keep_alive = req.keep_alive == true
    local request_conn_hdr = header_get(headers, 'connection')
    local request_connection_close = request_conn_hdr and tostring(request_conn_hdr):lower():find('close', 1, true) ~= nil

    local default_port = (scheme == 'https') and 443 or 80
    local request_lines, has_content_length, has_transfer_encoding, te_value = build_request_lines(
        method, host, port, default_port, request_path, headers, body_length, use_chunked, want_keep_alive
    )

    if has_transfer_encoding and te_value and te_value:lower():find('chunked', 1, true) then
        use_chunked = true
    end

    local request_head = table.concat(request_lines, '\r\n') .. '\r\n\r\n'

    local connect_host = proxy and proxy.host or host
    local connect_port = proxy and proxy.port or port
    connect_host = strip_ipv6_brackets(connect_host)

    local use_tls = (scheme == 'https')
    local ssl_params = nil
    local tls_wrapped = false
    local tls_done = false
    if use_tls then
        if not ok_ssl or not ssl then
            if callback then
                callback(nil, nil, nil, 'SSL module not available')
            end
            return
        end
        ssl_params = build_ssl_params(host, req.ssl)
    end

    local conn
    local conn_key
    if want_keep_alive then
        conn_key = pool_key(url_info, proxy, use_tls, ssl_params, proxy_tunnel)
        conn = pool_take(conn_key, req.pool_idle_timeout)
    end

    if conn then
        use_tls = conn.use_tls
        tls_wrapped = conn.tls_wrapped
        tls_done = conn.tls_done
        ssl_params = conn.ssl_params
    end

    local request_start_time = socket.gettime()
    local early_cancelled = false
    handle._cancel = function(reason)
        if early_cancelled then return end
        early_cancelled = true
        if callback then
            callback(nil, nil, nil, reason or 'cancelled')
        end
    end

    local function start_with_conn(conn, pooled, connect_host_override, on_connect_fail)
        if handle.cancelled or early_cancelled then
            return
        end
        local sock = conn.sock
        local fd = conn.fd
        local connect_target = connect_host_override or connect_host

        -- State machine
        local state = pooled and 'sending' or 'connecting'
        local read_source, write_source, timeout_timer
        local queue = req.queue

        local send_queue = {}
        local send_item = nil
        local send_offset = 1
        local body_done = not body_source
        local body_sent_bytes = 0
        local sent_total_bytes = 0
    
        local response_buffer = ''
        local response_chunks = {}
        local response_sink = type(req.sink) == 'function' and req.sink or nil
        local response_headers = nil
        local response_http_version = nil
        local status_code = nil
        local header_parsed = false
        local response_complete = false
        local sink_error = nil
        local on_headers = type(req.on_headers) == 'function' and req.on_headers or nil
        local on_progress = type(req.on_progress) == 'function' and req.on_progress or nil
    
        local body_mode = nil -- 'chunked', 'length', 'close', 'none'
        local remaining_length = nil
        local chunk_size = nil
        local body_received_bytes = 0
    
        local proxy_active = proxy_tunnel and not pooled
        local proxy_done = not proxy_active
        local proxy_buffer = ''
        local proxy_request = nil
    
        if proxy_active then
            local connect_host = format_host_literal(host)
            local connect_line = string.format('CONNECT %s:%d HTTP/1.1', connect_host, port)
            local proxy_lines = { connect_line, 'Host: ' .. connect_host .. ':' .. port }
            if proxy_auth then
                proxy_lines[#proxy_lines + 1] = 'Proxy-Authorization: ' .. proxy_auth
            end
            proxy_lines[#proxy_lines + 1] = 'Proxy-Connection: keep-alive'
            proxy_request = table.concat(proxy_lines, '\r\n') .. '\r\n\r\n'
            send_queue[#send_queue + 1] = proxy_request
        else
            send_queue[#send_queue + 1] = request_head
        end
    
        local decoder = nil
        local decode_encoding = nil
        local decode_buffered = false
        local max_header_bytes = tonumber(req.max_header_bytes)
        local max_body_bytes = tonumber(req.max_body_bytes)
    
        local start_time = request_start_time
        local connect_start = start_time
        local last_write = start_time
        local last_read = start_time
        local total_timeout = req.total_timeout or req.timeout
        local connect_timeout = req.connect_timeout
        local write_timeout = req.write_timeout
        local read_timeout = req.read_timeout
        local timer_interval_ms = tonumber(req.timer_interval_ms) or 500
    
        local function touch_write()
            last_write = socket.gettime()
            if on_progress then
                pcall(on_progress, handle, body_sent_bytes, body_received_bytes)
            end
        end
    
        local function mark_read()
            last_read = socket.gettime()
        end
    
        local function touch_read(bytes)
            mark_read()
            if bytes and bytes > 0 then
                body_received_bytes = body_received_bytes + bytes
            end
            if on_progress then
                pcall(on_progress, handle, body_sent_bytes, body_received_bytes)
            end
        end
    
        local function enqueue(data)
            if data and #data > 0 then
                send_queue[#send_queue + 1] = data
            end
        end
    
        local function sink_chunk(chunk)
            if decoder then
                local out, derr = decoder(chunk)
                if not out then
                    sink_error = derr or 'decode error'
                    return false
                end
                if out == '' then
                    return true
                end
                chunk = out
            end
            if response_sink then
                local ok, serr = response_sink(chunk)
                if ok == nil then
                    sink_error = serr or 'sink error'
                    return false
                end
                return true
            end
            if chunk and #chunk > 0 then
                response_chunks[#response_chunks + 1] = chunk
            end
            return true
        end
    
        local function finalize_sink()
            if decoder then
                local out, derr = decoder(nil)
                if out and out ~= '' then
                    if response_sink then
                        local ok, serr = response_sink(out)
                        if ok == nil and not sink_error then
                            sink_error = serr or 'sink error'
                        end
                    else
                        response_chunks[#response_chunks + 1] = out
                    end
                elseif not out and not sink_error then
                    sink_error = derr or 'decode error'
                end
            end
            if response_sink then
                local ok, serr = response_sink(nil)
                if ok == nil and not sink_error then
                    sink_error = serr or 'sink error'
                end
            end
        end
    
        local function release_sources()
            if timeout_timer then
                pcall(function() timeout_timer:release() end)
                timeout_timer = nil
            end
            if read_source then
                pcall(function() read_source:release() end)
                read_source = nil
            end
            if write_source then
                pcall(function() write_source:release() end)
                write_source = nil
            end
        end
    
        local function cleanup(close_socket)
            release_sources()
            if close_socket ~= false and conn then
                conn_close(conn)
            end
        end
    
        local callback_called = false
        local function do_callback(status, headers_out, body_out, err_out)
            if callback_called then return end
            callback_called = true
            cleanup(true)
            if callback then
                callback(status, headers_out, body_out, err_out)
            end
        end
    
        local function can_reuse_connection()
            if not want_keep_alive then
                return false
            end
            if request_connection_close then
                return false
            end
            if not conn or conn.closed then
                return false
            end
            if body_mode == 'close' then
                return false
            end
            if response_headers then
                local conn_hdr = response_headers['connection']
                if response_http_version == '1.0' then
                    if not conn_hdr or not tostring(conn_hdr):lower():find('keep-alive', 1, true) then
                        return false
                    end
                end
                if conn_hdr and tostring(conn_hdr):lower():find('close', 1, true) then
                    return false
                end
            end
            if req.close == true then
                return false
            end
            return true
        end
    
        local function apply_redirect_if_needed()
            if not req.redirect then
                return false
            end
            if not response_headers then
                return false
            end
            local location = response_headers['location']
            if not location or location == '' then
                return false
            end
            local code = status_code or 0
            if code ~= 301 and code ~= 302 and code ~= 303 and code ~= 307 and code ~= 308 then
                return false
            end
            local max_redirects = tonumber(req.max_redirects) or 0
            if redirect_count >= max_redirects then
                do_callback(status_code or 0, response_headers or {}, nil, 'Too many redirects')
                return true
            end
    
            local new_url
            if location:match('^%w+://') then
                new_url = location
            else
                local base = url_info.raw
                new_url = url.absolute(base, location)
            end

            local new_info = parse_url(new_url)
            if not same_origin(url_info, new_info) then
                header_remove(req.headers, 'authorization')
                header_remove(req.headers, 'cookie')
                header_remove(req.headers, 'cookie2')
            end
    
            if scheme == 'https' and new_url:match('^http://') and not req.allow_insecure_redirect then
                do_callback(status_code or 0, response_headers or {}, nil, 'Insecure redirect blocked')
                return true
            end
    
            local new_method = method
            if code == 303 or ((code == 301 or code == 302) and method ~= 'GET' and method ~= 'HEAD') then
                new_method = 'GET'
            end
    
            if new_method ~= method then
                req.body = nil
                req.source = nil
                req.length = nil
                req.body_length = nil
                req.size = nil
                req.chunked = nil
                header_remove(req.headers, 'content-length')
                header_remove(req.headers, 'transfer-encoding')
                header_remove(req.headers, 'content-type')
            elseif req.body == nil and type(req.source) == 'function' then
                if type(req.source_rewind) == 'function' then
                    req.source = req.source_rewind()
                else
                    do_callback(status_code or 0, response_headers or {}, nil, 'Redirect with non-rewindable body')
                    return true
                end
            end
    
            req.method = new_method
            req.url = new_url
            header_remove(req.headers, 'host')
            header_remove(req.headers, 'connection')
    
            cleanup(true)
            request_internal(req, callback, handle, redirect_count + 1)
            return true
        end
    
        local function finish_response(err_out)
            if response_complete then
                return
            end
            response_complete = true
            finalize_sink()
            if sink_error and not err_out then
                err_out = sink_error
            end
            if not err_out and apply_redirect_if_needed() then
                return
            end
            local body_out = nil
            if not response_sink then
                body_out = table.concat(response_chunks)
                if decode_buffered and decode_encoding and not err_out then
                    if body_out and #body_out > 0 then
                        local decoded, derr = decode_full(decode_encoding, body_out)
                        if decoded then
                            body_out = decoded
                            if response_headers then
                                response_headers['content-encoding'] = 'identity'
                                response_headers['content-length'] = tostring(#body_out)
                            end
                        else
                            err_out = derr or 'decode error'
                        end
                    elseif response_headers then
                        response_headers['content-encoding'] = 'identity'
                        response_headers['content-length'] = tostring(#(body_out or ''))
                    end
                end
            end
            if not err_out and can_reuse_connection() then
                release_sources()
                conn.tls_wrapped = tls_wrapped
                conn.tls_done = tls_done
                conn.use_tls = use_tls
                conn.ssl_params = ssl_params
                pool_put(conn, req.pool_max, req.pool_idle_timeout)
                if callback and not callback_called then
                    callback_called = true
                    callback(status_code or 0, response_headers or {}, body_out, err_out)
                end
                return
            end
            do_callback(status_code or 0, response_headers or {}, body_out, err_out)
        end
    
        handle._cancel = function(reason)
            finish_response(reason or 'cancelled')
        end
    
        local function parse_headers()
            local header_end = response_buffer:find('\r\n\r\n', 1, true)
            if not header_end then
                return false
            end

            local header_section = response_buffer:sub(1, header_end - 1)
            response_buffer = response_buffer:sub(header_end + 4)

            local status_line = header_section:match('^[^\r\n]+') or ''
            local major, minor = status_line:match('^HTTP/(%d+)%.(%d+)')
            if major and minor then
                response_http_version = major .. '.' .. minor
            else
                response_http_version = nil
            end
            local status = status_line:match('^HTTP/%d%.%d%s+(%d+)')
            status_code = tonumber(status) or 0

            response_headers = {}
            for line in header_section:gmatch('[^\r\n]+') do
                local k, v = line:match('^([^:]+):%s*(.*)$')
                if k then
                    local key = k:lower()
                    if key == 'set-cookie' or key == 'set-cookie2' then
                        local existing = response_headers[key]
                        if existing then
                            if type(existing) == 'table' then
                                existing[#existing + 1] = v
                            else
                                response_headers[key] = { existing, v }
                            end
                        else
                            response_headers[key] = v
                        end
                    else
                        response_headers[key] = v
                    end
                end
            end

            if on_headers then
                pcall(on_headers, status_code, response_headers)
            end

            if status_code >= 100 and status_code < 200 and status_code ~= 101 then
                response_headers = nil
                response_http_version = nil
                status_code = nil
                body_mode = nil
                remaining_length = nil
                chunk_size = nil
                header_parsed = false
                return true, true
            end

            if req.decode and not decoder and not decode_buffered then
                local enc = response_headers['content-encoding']
                if enc then
                    enc = tostring(enc):lower()
                    if enc:find('gzip', 1, true) then
                        decode_encoding = 'gzip'
                    elseif enc:find('deflate', 1, true) then
                        decode_encoding = 'deflate'
                    end
                end
                if decode_encoding then
                    if response_sink then
                        local dec, derr = create_decoder(decode_encoding)
                        if dec then
                            decoder = dec
                            response_headers['content-encoding'] = 'identity'
                            response_headers['content-length'] = nil
                        else
                            finish_response('Decode unavailable: ' .. tostring(derr))
                            return true
                        end
                    else
                        decode_buffered = true
                    end
                end
            end
    
            local te = response_headers['transfer-encoding']
            local cl = response_headers['content-length']
    
            if method == 'HEAD' or status_code == 204 or status_code == 304 or (status_code >= 100 and status_code < 200) then
                body_mode = 'none'
            elseif te and te:lower():find('chunked', 1, true) then
                body_mode = 'chunked'
            elseif cl then
                remaining_length = tonumber(cl)
                if remaining_length and remaining_length >= 0 then
                    body_mode = 'length'
                else
                    body_mode = 'close'
                end
            else
                body_mode = 'close'
            end
            if max_body_bytes and body_mode == 'length' and remaining_length and remaining_length > max_body_bytes then
                finish_response('Response body too large')
                return true, false
            end

            header_parsed = true
            return true, false
        end
    
        local function process_chunked()
            while true do
                if not chunk_size then
                    local line_end = response_buffer:find('\r\n', 1, true)
                    if not line_end then
                        return false
                    end
                    local line = response_buffer:sub(1, line_end - 1)
                    response_buffer = response_buffer:sub(line_end + 2)
                    local size_str = line:match('^%s*([0-9A-Fa-f]+)')
                    if not size_str then
                        finish_response('Invalid chunk size')
                        return true
                    end
                    chunk_size = tonumber(size_str, 16)
                    if chunk_size == 0 then
                        if response_buffer:sub(1, 2) == '\r\n' then
                            response_buffer = response_buffer:sub(3)
                            return true
                        end
                        local trailer_end = response_buffer:find('\r\n\r\n', 1, true)
                        if not trailer_end then
                            return false
                        end
                        response_buffer = response_buffer:sub(trailer_end + 4)
                        return true
                    end
                    if max_body_bytes and (body_received_bytes + chunk_size) > max_body_bytes then
                        finish_response('Response body too large')
                        return true
                    end
                end
    
                if #response_buffer < chunk_size + 2 then
                    return false
                end
    
                local chunk = response_buffer:sub(1, chunk_size)
                local crlf = response_buffer:sub(chunk_size + 1, chunk_size + 2)
                if crlf ~= '\r\n' then
                    finish_response('Invalid chunk terminator')
                    return true
                end
                response_buffer = response_buffer:sub(chunk_size + 3)
                chunk_size = nil
    
                if not sink_chunk(chunk) then
                    finish_response(sink_error or 'sink error')
                    return true
                end
                touch_read(#chunk)
            end
        end
    
        local function process_length_body()
            if not remaining_length or remaining_length <= 0 then
                return true
            end
            if #response_buffer == 0 then
                return false
            end
            local take = math.min(remaining_length, #response_buffer)
            local chunk = response_buffer:sub(1, take)
            response_buffer = response_buffer:sub(take + 1)
            remaining_length = remaining_length - take
            if max_body_bytes and (body_received_bytes + #chunk) > max_body_bytes then
                finish_response('Response body too large')
                return true
            end
            if not sink_chunk(chunk) then
                finish_response(sink_error or 'sink error')
                return true
            end
            touch_read(#chunk)
            return remaining_length == 0
        end
    
        local function process_response_data()
            while true do
                if not header_parsed then
                    local parsed, informational = parse_headers()
                    if not parsed then
                        return false
                    end
                    if response_complete then
                        return true
                    end
                    if informational then
                        if #response_buffer == 0 then
                            return false
                        end
                    else
                        if body_mode == 'none' then
                            finish_response(nil)
                            return true
                        end
                        break
                    end
                else
                    break
                end
            end
    
            if body_mode == 'chunked' then
                local done = process_chunked()
                if done then
                    finish_response(nil)
                    return true
                end
            elseif body_mode == 'length' then
                local done = process_length_body()
                if done then
                    finish_response(nil)
                    return true
                end
            elseif body_mode == 'close' then
                if #response_buffer > 0 then
                    local chunk = response_buffer
                    response_buffer = ''
                    if max_body_bytes and (body_received_bytes + #chunk) > max_body_bytes then
                        finish_response('Response body too large')
                        return true
                    end
                    if not sink_chunk(chunk) then
                        finish_response(sink_error or 'sink error')
                        return true
                    end
                    touch_read(#chunk)
                end
            end
    
            return false
        end
    
        local function prepare_next_body_chunk()
            if body_done then
                return false
            end
            if not use_chunked and body_length and body_sent_bytes >= body_length then
                body_done = true
                return false
            end

            local chunk, cerr = body_source and body_source()
            if chunk == nil then
                if cerr then
                    finish_response('Request body error: ' .. tostring(cerr))
                    return false
                end
                body_done = true
                if not use_chunked and body_length and body_sent_bytes < body_length then
                    finish_response('Request body incomplete')
                    return false
                end
                if use_chunked then
                    enqueue('0\r\n\r\n')
                end
                return false
            end
    
            if not use_chunked and body_length then
                local remain = body_length - body_sent_bytes
                if #chunk > remain then
                    chunk = chunk:sub(1, remain)
                    body_done = true
                end
            end
    
            if #chunk > 0 then
                body_sent_bytes = body_sent_bytes + #chunk
                if use_chunked then
                    chunk = string.format('%X\r\n%s\r\n', #chunk, chunk)
                end
                enqueue(chunk)
                return true
            end
    
            return false
        end
    
        local function progress_tls_handshake()
            if not use_tls or tls_done then
                return true
            end
            if not tls_wrapped then
                local wrapped, werr = ssl.wrap(sock, ssl_params)
                if not wrapped then
                    finish_response('tls wrap failed: ' .. tostring(werr))
                    return nil, 'fatal'
                end
                sock = wrapped
                conn.sock = wrapped
                pcall(function() sock:settimeout(0) end)
                tls_wrapped = true
            end
            local ok, herr = sock:dohandshake()
            if ok then
                tls_done = true
                return true
            end
            if herr == 'wantread' or herr == 'wantwrite' or herr == 'timeout' then
                return false, herr
            end
            finish_response('tls handshake failed: ' .. tostring(herr))
            return nil, 'fatal'
        end
    
        local setup_read_source
        local setup_write_source
        local drive_send
        local function schedule_send_after_proxy()
            local delay_ms = tonumber(req.proxy_tunnel_delay_ms) or 50
            if type(dispatch_after) == 'function' and delay_ms > 0 then
                dispatch_after(delay_ms, queue or 'main', function()
                    if response_complete or handle.cancelled then return end
                    drive_send()
                    if state == 'sending' or state == 'proxying' then
                        setup_write_source()
                    end
                end)
            else
                drive_send()
                if state == 'sending' or state == 'proxying' then
                    setup_write_source()
                end
            end
        end
    
        drive_send = function()
            if state == 'connecting' then
                state = proxy_active and 'proxying' or (use_tls and 'handshaking' or 'sending')
            end
    
            if proxy_active and not proxy_done then
                -- only send CONNECT request
            elseif use_tls and not tls_done then
                local handshake_ok, handshake_err = progress_tls_handshake()
                if handshake_ok == nil then
                    return
                elseif not handshake_ok then
                    if handshake_err == 'wantread' then
                        setup_read_source()
                    end
                    return
                end
                if state == 'handshaking' then
                    state = 'sending'
                end
            end
    
            if state ~= 'sending' and state ~= 'proxying' then
                return
            end
    
            local spin = 0
            while spin < 16 do
                spin = spin + 1
    
                if not send_item then
                    if #send_queue == 0 then
                        if state == 'sending' and body_source and not body_done then
                            prepare_next_body_chunk()
                        end
                        if #send_queue == 0 then
                            if state == 'sending' and body_source and not body_done then
                                return
                            end
                            if state == 'proxying' then
                                return
                            end
                            state = 'receiving'
                            if write_source then
                                pcall(function() write_source:release() end)
                                write_source = nil
                            end
                            return
                        end
                    end
                    send_item = send_queue[1]
                    send_offset = 1
                end
    
                local sent, serr, last = sock:send(send_item, send_offset)
                if sent then
                    sent_total_bytes = sent_total_bytes + sent
                    send_offset = send_offset + sent
                    touch_write()
                    if send_offset > #send_item then
                        table.remove(send_queue, 1)
                        send_item = nil
                        send_offset = 1
                    end
                elseif serr == 'timeout' or serr == 'wantwrite' then
                    if last and last >= send_offset then
                        send_offset = last + 1
                    end
                    return
                elseif serr == 'wantread' then
                    if last and last >= send_offset then
                        send_offset = last + 1
                    end
                    setup_read_source()
                    return
                else
                    finish_response('Send error: ' .. tostring(serr))
                    return
                end
            end
        end
    
        local function process_proxy_response()
            local header_end = proxy_buffer:find('\r\n\r\n', 1, true)
            if not header_end then
                return false
            end
            local header_section = proxy_buffer:sub(1, header_end - 1)
            proxy_buffer = proxy_buffer:sub(header_end + 4)
            local status_line = header_section:match('^[^\r\n]+') or ''
            local code = status_line:match('^HTTP/%d%.%d%s+(%d+)')
            local status = tonumber(code) or 0
            if status < 200 or status >= 300 then
                finish_response('Proxy CONNECT failed: ' .. status_line)
                return true
            end
            proxy_done = true
            if #proxy_buffer > 0 then
                response_buffer = response_buffer .. proxy_buffer
                proxy_buffer = ''
            end
            send_queue = {}
            send_item = nil
            send_offset = 1
            if use_tls then
                state = 'handshaking'
            else
                state = 'sending'
            end
            enqueue(request_head)
            if write_source then
                pcall(function() write_source:release() end)
                write_source = nil
            end
            schedule_send_after_proxy()
            return true
        end
    
        local function check_timeouts()
            if response_complete then
                return
            end
            local now = socket.gettime()
            if total_timeout and now - start_time > total_timeout then
                finish_response('Request timeout')
                return
            end
            if state == 'connecting' and connect_timeout and now - connect_start > connect_timeout then
                finish_response('Connect timeout')
                return
            end
            if (state == 'sending' or state == 'handshaking' or state == 'proxying') and write_timeout and now - last_write > write_timeout then
                finish_response('Write timeout')
                return
            end
            if state == 'receiving' and read_timeout and now - last_read > read_timeout then
                finish_response('Read timeout')
                return
            end
        end
    
        timeout_timer = dispatch_source_register_callback('timer', timer_interval_ms, timer_interval_ms, function()
            check_timeouts()
        end, queue)
    
        setup_write_source = function()
            if write_source then return end
            write_source = dispatch_source_register_callback('write', fd, 0, function()
                drive_send()
            end, queue)
        end
    
        setup_read_source = function()
            if read_source then return end
            read_source = dispatch_source_register_callback('read', fd, 0, function()
                if proxy_active and not proxy_done then
                    local chunk, rerr, partial = sock:receive(8192)
                    local data = chunk or partial
                    if data and #data > 0 then
                        mark_read()
                        proxy_buffer = proxy_buffer .. data
                        if process_proxy_response() then
                            return
                        end
                    end
                    if rerr == 'wantwrite' then
                        setup_write_source()
                        return
                    end
                    if rerr and rerr ~= 'timeout' and rerr ~= 'wantread' then
                        finish_response('Proxy receive error: ' .. tostring(rerr))
                    end
                    return
                end
    
                if use_tls and not tls_done then
                    local handshake_ok, handshake_err = progress_tls_handshake()
                    if handshake_ok == nil then
                        return
                    elseif not handshake_ok then
                        if handshake_err == 'wantwrite' then
                            setup_write_source()
                        end
                        return
                    end
                    if state == 'handshaking' then
                        state = 'sending'
                    end
                end
    
                local chunk, rerr, partial = sock:receive(8192)
                local data = chunk or partial
    
                if data and #data > 0 then
                    mark_read()
                    response_buffer = response_buffer .. data
                    if not header_parsed and max_header_bytes and #response_buffer > max_header_bytes then
                        finish_response('Response header too large')
                        return
                    end
                    if process_response_data() then
                        return
                    end
                end
    
                if rerr then
                    if rerr == 'wantwrite' then
                        setup_write_source()
                        return
                    end
                    if rerr == 'closed' or rerr == 'connection reset by peer' then
                        if #response_buffer > 0 then
                            process_response_data()
                        end
                        if response_complete then
                            return
                        end
                        if not header_parsed then
                            finish_response('Connection closed before response')
                        elseif body_mode == 'close' then
                            finish_response(nil)
                        elseif body_mode == 'length' then
                            if remaining_length and remaining_length > 0 then
                                finish_response('Response body incomplete')
                            else
                                finish_response(nil)
                            end
                        elseif body_mode == 'chunked' then
                            finish_response('Chunked response incomplete')
                        else
                            finish_response(nil)
                        end
                    elseif rerr ~= 'timeout' and rerr ~= 'wantread' then
                        finish_response('Receive error: ' .. tostring(rerr))
                    end
                end
            end, queue)
        end
    
        setup_read_source()
        setup_write_source()
    
        if not pooled then
            local ok, connect_err = sock:connect(connect_target, connect_port)
            if ok then
                state = proxy_active and 'proxying' or (use_tls and 'handshaking' or 'sending')
            elseif connect_err == 'timeout' or connect_err == 'Operation already in progress' then
                -- Connection in progress, wait for write source to fire
            else
                if on_connect_fail then
                    cleanup(true)
                    on_connect_fail(connect_err)
                else
                    finish_response('Connect error: ' .. tostring(connect_err))
                end
            end
        end
    end

    local function create_socket(family)
        local sock, err
        if family == 'inet6' then
            sock, err = socket.tcp6()
        else
            sock, err = socket.tcp4()
        end
        if not sock then
            return nil, nil, 'Socket creation failed: ' .. tostring(err)
        end
        sock:settimeout(0)
        sock:setoption('tcp-nodelay', true)
        local fd = sock:getfd()
        if not fd or fd < 0 then
            sock:close()
            return nil, nil, 'Invalid socket fd'
        end
        return sock, fd
    end

    local function start_new_connection(family, connect_target, on_fail)
        local sock, fd, sock_err = create_socket(family)
        if not sock then
            if on_fail then
                on_fail(sock_err)
            elseif callback then
                callback(nil, nil, nil, sock_err)
            end
            return
        end
        conn = {
            sock = sock,
            fd = fd,
            key = conn_key,
            use_tls = use_tls,
            ssl_params = ssl_params,
            tls_wrapped = false,
            tls_done = false,
            proxy_tunnel = proxy_tunnel,
            proxy = proxy,
            host = host,
            port = port,
        }
        start_with_conn(conn, false, connect_target, on_fail)
    end

    if conn then
        start_with_conn(conn, true)
        return
    end

    if is_ipv4_literal(connect_host) then
        start_new_connection('inet', connect_host)
        return
    end

    if is_ipv6_literal(connect_host) then
        start_new_connection('inet6', connect_host)
        return
    end

    resolve_async(connect_host, req.queue, function(addrinfo, rerr)
        if handle.cancelled or early_cancelled then
            return
        end
        local candidates = build_addr_candidates(addrinfo)
        if #candidates == 0 then
            if callback then
                local reason = rerr or 'no address'
                callback(nil, nil, nil, 'DNS resolve failed: ' .. tostring(reason))
            end
            return
        end
        local idx = 0
        local function try_next(last_err)
            if handle.cancelled or early_cancelled then
                return
            end
            idx = idx + 1
            local cand = candidates[idx]
            if not cand then
                if callback then
                    local reason = rerr or last_err or 'no address'
                    callback(nil, nil, nil, 'DNS resolve failed: ' .. tostring(reason))
                end
                return
            end
            start_new_connection(cand.family, cand.addr, function(connect_err)
                try_next(connect_err)
            end)
        end
        try_next()
    end)
end

-- Simple async HTTP request
-- callback(status_code, headers_table, body_string, error_string)
-- body can be string or source function
-- opts can provide:
--   source: request body source (LTN12-style)
--   length/body_length/size: request body length
--   chunked: force chunked transfer
--   sink: response body sink (LTN12-style)
--   total_timeout/connect_timeout/read_timeout/write_timeout: timeouts in seconds
--   ssl: LuaSec params table
--   query: query table to append to url
--   redirect/max_redirects/allow_insecure_redirect
--   keep_alive/pool_max/pool_idle_timeout
--   proxy/proxy_tunnel
--   decode (bool)
--   max_header_bytes/max_body_bytes
--   on_headers/on_progress: callbacks
-- M.request(method, url_value, headers, body, callback, timeout, opts) -> handle
-- @param method string|table HTTP method or request table.
-- @param url_value string URL.
-- @param headers table|nil Header table.
-- @param body any Body string or source function or opts table.
-- @param callback function|nil Completion callback.
-- @param timeout number|nil Total timeout seconds.
-- @param opts table|nil Options table.
-- @return table Request handle with cancel().
function M.request(method, url_value, headers, body, callback, timeout, opts)
    local req, cb = normalize_request(method, url_value, headers, body, callback, timeout, opts)

    local handle = { cancelled = false }
    handle.cancel = function(reason)
        if handle.cancelled then return end
        handle.cancelled = true
        if type(req.on_cancel) == 'function' then
            pcall(req.on_cancel, reason)
        end
        if type(handle._cancel) == 'function' then
            handle._cancel(reason)
        end
    end

    if handle.cancelled then
        if cb then
            cb(nil, nil, nil, 'cancelled')
        end
        return handle
    end

    request_internal(req, cb, handle, 0)
    return handle
end

M.source = M.source or {}
M.sink = M.sink or {}

-- M.source.file(path, chunk_size) -> source, rewind|nil, err|nil
-- @param path string File path.
-- @param chunk_size number|nil Read chunk size.
-- @return function|nil, function|nil, string|nil Source, rewind, error.
function M.source.file(path, chunk_size)
    local f, err = io.open(path, 'rb')
    if not f then
        return nil, err
    end
    chunk_size = chunk_size or 16384
    local closed = false
    local function src()
        if closed then return nil end
        local data = f:read(chunk_size)
        if not data then
            closed = true
            f:close()
            return nil
        end
        return data
    end
    local function rewind()
        if closed then
            f, err = io.open(path, 'rb')
            if not f then
                return nil, err
            end
            closed = false
        else
            f:seek('set', 0)
        end
        return src
    end
    return src, rewind
end

-- M.sink.file(path, mode) -> sink|nil, err|nil
-- @param path string File path.
-- @param mode string|nil File mode (default "wb").
-- @return function|nil, string|nil Sink function or error.
function M.sink.file(path, mode)
    local f, err = io.open(path, mode or 'wb')
    if not f then
        return nil, err
    end
    return function(chunk)
        if chunk == nil then
            f:close()
            return true
        end
        local ok, werr = f:write(chunk)
        if not ok then
            return nil, werr
        end
        return true
    end
end

-- M.download(url_value, path, opts, callback) -> handle|nil
-- @param url_value string URL.
-- @param path string Destination file path.
-- @param opts table|nil Options table.
-- @param callback function|nil Completion callback.
-- @return table|nil Request handle or nil on setup error.
function M.download(url_value, path, opts, callback)
    opts = opts or {}
    local sink, err = M.sink.file(path, 'wb')
    if not sink then
        if callback then callback(nil, nil, nil, err) end
        return nil
    end
    opts.sink = sink
    return M.request('GET', url_value, opts.headers, opts.body, callback, opts.timeout, opts)
end

-- M.upload(url_value, path, opts, callback) -> handle|nil
-- @param url_value string URL.
-- @param path string Source file path.
-- @param opts table|nil Options table.
-- @param callback function|nil Completion callback.
-- @return table|nil Request handle or nil on setup error.
function M.upload(url_value, path, opts, callback)
    opts = opts or {}
    local src, rewind = M.source.file(path, opts.chunk_size)
    if not src then
        if callback then callback(nil, nil, nil, 'open file failed') end
        return nil
    end
    local f = io.open(path, 'rb')
    local size = nil
    if f then
        f:seek('end')
        size = f:seek()
        f:close()
    end
    opts.source = src
    opts.source_rewind = rewind
    if size then
        opts.length = size
    end
    return M.request('PUT', url_value, opts.headers, opts.body, callback, opts.timeout, opts)
end

return M
