--[[

    本文件仅作为参考，请不要修改本文件
    本文件会在重装、更新时被原版覆盖

--]]

local proc_value_operations = {}
local proc_queue_operations = {}
local proc_dict_operations = {}

proc_dict_operations['run'] = function(lua_code)
    if "string" ~= type(lua_code) then
        return nil, 'argument error.'
    end
    local result, err = proc_dict_run(lua_code)
    if not result then
        return { code = 1, message = "operation failed", ok = false, error = tostring(err):gsub("^%[string \".*\"%]:", "") }
    end
    result = result:base64_encode()
    return { code = 0, message = "operation completed", ok = true, result = result, result_encoding = "base64" }
end

proc_value_operations['put'] = function(body)
    if "string" ~= type(body.value) then
        return nil, 'argument error.'
    end
    local raw_key = body.key
    if body.key_encoding == "base64" then
        raw_key = raw_key:base64_decode()
    else
        body.key_encoding = nil
    end
    if not raw_key then
        return nil, '`key` is invalid'
    end
    local raw_value = body.value
    if body.value_encoding == "base64" then
        raw_value = raw_value:base64_decode()
    else
        body.value_encoding = nil
    end
    if not raw_value then
        return nil, '`value` is invalid'
    end
    local old_val = proc_put(raw_key, raw_value)
    if body.value_encoding == "base64" then
        old_val = old_val:base64_encode()
    end
    return { code = 0, message = "operation completed", key = body.key, old_value = old_val, value = body.value, key_encoding =
    body.key_encoding, value_encoding = body.value_encoding }
end
proc_value_operations['get'] = function(body)
    local raw_key = body.key
    if body.key_encoding == "base64" then
        raw_key = raw_key:base64_decode()
    else
        body.key_encoding = nil
    end
    if not raw_key then
        return nil, '`key` is invalid'
    end
    local val = proc_get(raw_key)
    if body.value_encoding == "base64" then
        val = val:base64_encode()
    else
        body.value_encoding = nil
    end
    return { code = 0, message = "operation completed", key = body.key, value = val, key_encoding = body.key_encoding, value_encoding =
    body.value_encoding }
end

proc_queue_operations['push-back'] = function(body)
    if "string" ~= type(body.value) then
        return nil, "argument error."
    end
    local queue_size = 0
    local raw_key = body.key
    if body.key_encoding == "base64" then
        raw_key = raw_key:base64_decode()
    end
    if not raw_key then
        return nil, "`key` is invalid"
    end
    local raw_value = body.value
    if body.value_encoding == "base64" then
        raw_value = raw_value:base64_decode()
    end
    if not raw_value then
        return nil, "`value` is invalid"
    end
    local max_size = type(body.max_size) == "number" and (body.max_size // 1) or 10000
    queue_size = proc_queue_push_back(raw_key, raw_value, max_size)
    return { code = 0, message = "operation completed", key = body.key, size = queue_size, key_encoding = body
    .key_encoding }
end
proc_queue_operations['push-front'] = function(body)
    if "string" ~= type(body.value) then
        return nil, "argument error."
    end
    local raw_key = body.key
    if body.key_encoding == "base64" then
        raw_key = raw_key:base64_decode()
    end
    if not raw_key then
        return nil, "`key` is invalid"
    end
    local raw_value = body.value
    if body.value_encoding == "base64" then
        raw_value = raw_value:base64_decode()
    end
    if not raw_value then
        return nil, "`value` is invalid"
    end
    local max_size = type(body.max_size) == "number" and (body.max_size // 1) or 10000
    queue_size = proc_queue_push_front(raw_key, raw_value, max_size)
    return { code = 0, message = "operation completed", key = body.key, size = queue_size, key_encoding = body
    .key_encoding }
end
proc_queue_operations['pop-front'] = function(body)
    local raw_key = body.key
    if body.key_encoding == "base64" then
        raw_key = raw_key:base64_decode()
    else
        body.key_encoding = nil
    end
    if not raw_key then
        return nil, "`key` is invalid"
    end
    local val = proc_queue_pop_front(raw_key)
    if body.value_encoding == "base64" then
        val = val:base64_encode()
    else
        body.value_encoding = nil
    end
    return { code = 0, message = "operation completed", key = body.key, value = val, key_encoding = body.key_encoding, value_encoding =
    body.value_encoding }
end
proc_queue_operations['pop-back'] = function(body)
    local raw_key = body.key
    if body.key_encoding == "base64" then
        raw_key = raw_key:base64_decode()
    else
        body.key_encoding = nil
    end
    if not raw_key then
        return nil, "`key` is invalid"
    end
    local val = proc_queue_pop_back(raw_key)
    if body.value_encoding == "base64" then
        val = val:base64_encode()
    else
        body.value_encoding = nil
    end
    return { code = 0, message = "operation completed", key = body.key, value = val, key_encoding = body.key_encoding, value_encoding =
    body.value_encoding }
end
proc_queue_operations['count-value'] = function(body)
    if "string" ~= type(body.value) then
        return nil, "argument error."
    end
    local raw_key = body.key
    if body.key_encoding == "base64" then
        raw_key = raw_key:base64_decode()
    end
    if not raw_key then
        return nil, "`key` is invalid"
    end
    local raw_value = body.value
    if body.value_encoding == "base64" then
        raw_value = raw_value:base64_decode()
    end
    if not raw_value then
        return nil, "`value` is invalid"
    end
    local queue_size = proc_queue_count_value(raw_key, raw_value)
    return { code = 0, message = "operation completed", key = body.key, size = queue_size, key_encoding = body
    .key_encoding }
end
proc_queue_operations['pop-value'] = function(body)
    if "string" ~= type(body.value) then
        return nil, "argument error."
    end
    local raw_key = body.key
    if body.key_encoding == "base64" then
        raw_key = raw_key:base64_decode()
    end
    if not raw_key then
        return nil, "`key` is invalid"
    end
    local raw_value = body.value
    if body.value_encoding == "base64" then
        raw_value = raw_value:base64_decode()
    end
    if not raw_value then
        return nil, "`value` is invalid"
    end
    local queue_size = proc_queue_pop_value(raw_key, raw_value)
    return { code = 0, message = "operation completed", key = body.key, size = queue_size, key_encoding = body
    .key_encoding }
end
proc_queue_operations['clear'] = function(body)
    local raw_key = body.key
    if body.key_encoding == "base64" then
        raw_key = raw_key:base64_decode()
    else
        body.key_encoding = nil
    end
    if not raw_key then
        return nil, "`key` is invalid"
    end
    local vals = proc_queue_clear(raw_key)
    if body.value_encoding == "base64" then
        for i = 1, #vals do
            vals[i] = vals[i]:base64_encode()
        end
    else
        body.value_encoding = nil
    end
    return { code = 0, message = "operation completed", key = body.key, values = vals, key_encoding = body.key_encoding, value_encoding =
    body.value_encoding }
end
proc_queue_operations['read'] = function(body)
    local raw_key = body.key
    if body.key_encoding == "base64" then
        raw_key = raw_key:base64_decode()
    else
        body.key_encoding = nil
    end
    if not raw_key then
        return nil, "`key` is invalid"
    end
    local vals = proc_queue_read(raw_key)
    if body.value_encoding == "base64" then
        for i = 1, #vals do
            vals[i] = vals[i]:base64_encode()
        end
    else
        body.value_encoding = nil
    end
    return { code = 0, message = "operation completed", key = body.key, values = vals, key_encoding = body.key_encoding, value_encoding =
    body.value_encoding }
end
proc_queue_operations['push'] = proc_queue_operations['push-back']
proc_queue_operations['pop'] = proc_queue_operations['pop-back']

return {
    proc_value_operations = proc_value_operations,
    proc_queue_operations = proc_queue_operations,
    proc_dict_operations = proc_dict_operations,
}
