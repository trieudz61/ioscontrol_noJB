--[[

    巨魔版从越狱版迁移文件的脚本，异步询问用户是否需要迁移，防止大文件迁移慢

    本文件仅作为参考，请不要修改本文件
    本文件会在重装、更新时被原版覆盖

--]]

if not IS_TROLLSTORE_EDITION then
	return
end

local LLANG = (function()
	local _localizations = {
		en = {
			["XXTouch"] = "XXTouch",
			["Skip Migration"] = "Skip Migration",
			["Migrate Now"] = "Migrate Now",
			["Detection to jailbreak edition XXTouch documents, whether to migrate to trollstore edition?\n\nMigration will be performed in the background."] =
			"Detection to jailbreak edition XXTouch documents, whether to migrate to trollstore edition?\n\nMigration will be performed in the background.",
		},
		zh = {
			["XXTouch"] = "X.X.T.",
			["Skip Migration"] = "暂不迁移",
			["Migrate Now"] = "即刻迁移",
			["Detection to jailbreak edition XXTouch documents, whether to migrate to trollstore edition?\n\nMigration will be performed in the background."] =
			"检测到有越狱版 XXTouch 文档，是否需要迁移到巨魔版？\n\n迁移会在后台进行",
		},
	}
	local lang = sys.language() or 'en'
	return function(str)
		for k, v in pairs(_localizations) do
			if lang:find(k, 1, true) then
				if _localizations[k][str] then
					return _localizations[k][str]
				end
			end
		end
		return _localizations["en"][str] or str
	end
end)()

local lfs = require('lfs')

local path_op = file.path

local ok, buildin_files = pcall(dofile, XXT_BIN_PATH .. '/module-xxt-buildin-list.lua')

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

local function migrate_to_xxt_home(bak_prefix, jb_home_path)
	if jb_home_path then
		for _, buildin_file in ipairs(buildin_files or {}) do
			local jb_full_path = path_op.add_component(jb_home_path, buildin_file)
			os.remove(jb_full_path)
		end
		for _, jb_full_path in ipairs(file.list(jb_home_path, true) or {}) do
			if lfs.symlinkattributes(jb_full_path, 'mode') ~= 'file' then
				goto continue
			end
			local relative_path = jb_full_path:sub(#jb_home_path + 2)
			local target_full_path = path_op.add_component(XXT_HOME_PATH, relative_path)
			if file.exists(target_full_path) then
				goto continue
			end
			sys.mkdir_p(path_op.remove_last_component(target_full_path))
			file.move(jb_full_path, target_full_path)
			::continue::
		end
		remove_dir_if_no_files(jb_home_path)
		file.move(jb_home_path, XXT_SCRIPTS_PATH .. '/' .. bak_prefix .. '1ferver-' .. os.date('%Y%m%d%H%M%S'))
	end
end

local function find_jbpath(path)
	local jb_path = file.find {
		'/private/preboot/',
		{ "^[A-F0-9]+$" },
		{ "^.+$" },
		'/procursus',
		path
	}
	if jb_path[1] then
		return jb_path[1]
	end
	jb_path = file.find {
		'/private/var/containers/Bundle/Application/',
		{ "^%.jbroot%-[A-F0-9]+$" },
		"/",
		path
	}
	return jb_path[1]
end

if find_jbpath('/Applications/XXTExplorer.app') then
	return
end

-- 迁移 rootless 版脚本
local paths = file.find {
	'/private/preboot/',
	{ "^[A-F0-9]+$" },
	{ "^.+$" },
	'/procursus/var/mobile/Media/1ferver'
}

local rootless_xxt_home = paths[1]

-- 迁移 roothide 版脚本
local paths = file.find {
	'/private/var/containers/Bundle/Application/',
	{ "^%.jbroot%-[A-F0-9]+$" },
	'/var/mobile/Media/1ferver'
}

local roothide_xxt_home = paths[1]

-- if rootless_xxt_home or roothide_xxt_home then
-- 	local c = sys.alert(LLANG('Detection to jailbreak edition XXTouch documents, whether to migrate to trollstore edition?\n\nMigration will be performed in the background.'), 30, LLANG('XXTouch'), LLANG('Skip Migration'), LLANG('Migrate Now'))
-- 	if c ~= 1 then
-- 		return
-- 	end
-- else
-- 	return
-- end

migrate_to_xxt_home('rootless-', rootless_xxt_home)
migrate_to_xxt_home('roothide-', roothide_xxt_home)
