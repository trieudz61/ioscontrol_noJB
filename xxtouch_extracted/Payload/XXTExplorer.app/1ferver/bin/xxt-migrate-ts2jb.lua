--[[

	越狱版从巨魔版迁移文件的脚本

    本文件仅作为参考，请不要修改本文件
    本文件会在重装、更新时被原版覆盖

--]]

if IS_TROLLSTORE_EDITION then
    return
end

local lfs = require('lfs')

local path_op = file.path

local ts_home_path = rootfs(XXT_HOME_PATH)

if file.exists(ts_home_path) ~= 'directory' then
    os.remove(ts_home_path)
    lfs.link(XXT_HOME_PATH, ts_home_path, true)
    return
end

local ok, buildin_files = pcall(dofile, XXT_BIN_PATH .. '/module-xxt-buildin-list.lua')
if ok then
    for _, buildin_file in ipairs(buildin_files or {}) do
        local ts_full_path = path_op.add_component(ts_home_path, buildin_file)
        os.remove(ts_full_path)
    end
end

local function is_dir_empty_of_files(path) -- 符号链接也不当作是文件
    for file in lfs.dir(path) do
        if file ~= "." and file ~= ".." then
            local f = path .. "/" .. file
            local mode = lfs.symlinkattributes(f, 'mode')
            if mode == "file" then
                return false
            elseif mode == "directory" then
                if not is_dir_empty_of_files(f) then
                    return false
                end
            end
        end
    end
    return true
end

local function remove_dir_if_no_files(path) -- 如果目录是符号链接，直接删除
    if lfs.symlinkattributes(path, 'mode') == 'link' then
        os.remove(path)
    elseif lfs.symlinkattributes(path, 'mode') == 'directory' and is_dir_empty_of_files(path) then
        file.remove(path)
    end
end

for _, ts_full_path in ipairs(file.list(ts_home_path, true) or {}) do
    if lfs.symlinkattributes(ts_full_path, 'mode') ~= 'file' then
        goto continue
    end
    local relative_path = ts_full_path:sub(#ts_home_path + 2)
    local target_full_path = path_op.add_component(XXT_HOME_PATH, relative_path)
    if file.exists(target_full_path) then
        goto continue
    end
    sys.mkdir_p(path_op.remove_last_component(target_full_path))
    file.move(ts_full_path, target_full_path)
    ::continue::
end

remove_dir_if_no_files(ts_home_path)

file.move(ts_home_path, XXT_SCRIPTS_PATH .. '/bak-1ferver-' .. os.date('%Y%m%d%H%M%S'))
lfs.link(XXT_HOME_PATH, ts_home_path, true)
