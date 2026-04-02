--[[

    部分兼容触摸精灵的 HTTP 接口服务
    接口文档：http://ask.touchelf.net/docs/touchelfAPI

    本文件仅作为参考，请不要修改本文件
    本文件会在重装、更新时被原版覆盖

--]]

-- if not lockfile("/tmp/touchelf-httpd.lua.singleton") then
--     return -- 如果文件已经被别的进程锁定，那么说明不需要再次运行
-- end

local json = require('cjson.safe')
local lfs = require('lfs')

local function _internal_error_message(ctx, code, msg)
    ctx.status = code
    ctx:header('Content-type', 'application/json; charset=utf-8')
    return string.format([[{"code": %d, "message": %q}]], code, tostring(msg))
end

local _open_router_factor = loadfile(XXT_BIN_PATH .. "/open-http-router.lua")

local _http_uri_router_table = {
    ['/api/app/register'] = function(ctx)
        ctx.status = 204
        ctx:header('Content-type', 'text/html; charset=utf-8')
        return ''
    end,
    ['/ui'] = function(ctx)
        ctx.status = 200
        ctx:header('Content-type', 'text/html; charset=utf-8')
        local wifi_ip = "127.0.0.1"
        for i, v in ipairs(device.ifaddrs()) do
            if #tostring(v[1]) > 2 and tostring(v[1]):sub(1, 2) == "en" then
                wifi_ip = v[2]
                if tostring(v[1]) == "en0" then
                    break
                end
            end
        end
        return [[<html><script type="text/javascript"> window.location.href="http://]] ..
        wifi_ip .. [[:46952"; </script></html>]]
    end,
    ['/'] = function(ctx)
        ctx.status = 200
        ctx:header('Content-type', 'text/html; charset=utf-8')
        return ''
    end,
}

local _http_uri_router_match_table = {
    --
}

local function _uri_router(ctx)
    local handler = _http_uri_router_table[ctx.uri]
    if type(handler) == 'function' then
        local noerr, ret = pcall(handler, ctx)
        if noerr then
            return ret
        else
            return _internal_error_message(ctx, 502, ret)
        end
    end

    for _, handler in ipairs(_http_uri_router_match_table) do
        if string.find(ctx.uri, handler[1]) == 1 then
            local noerr, ret = pcall(handler[2], ctx)
            if noerr then
                return ret
            else
                return _internal_error_message(ctx, 502, ret)
            end
        end
    end
end

if type(_open_router_factor) == "function" then
    local _open_router = _open_router_factor()
    local _router = function(ctx)
        ctx.status = 200
        ctx:header("Content-type", "text/plain; charset=utf-8")
        local success, ret = pcall(_open_router, ctx)
        if success then
            return ret
        else
            success, ret = pcall(_uri_router, ctx)
            if success then
                return ret
            end
            return nil
        end
    end
    exit_callback_handle = notification_center_register_callback({
            center = "darwin",
            name = "xxtouch.touchelf-httpd-service/exit",
        },
        function()
            exit_callback_handle:release()
            os.exit(0)
        end)
    require('gcdwebserver').runloop(8000, _router) -- TouchElf
end
