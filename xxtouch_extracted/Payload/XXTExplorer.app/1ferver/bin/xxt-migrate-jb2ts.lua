--[[

	巨魔版从越狱版迁移文件的脚本

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
			["⚠️Current jailbreak edition is not uninstalled\n\nTo avoid conflicts, it is recommended to delete the trollstore edition first, then activate the jailbreak, uninstall the jailbreak edition, and then install the trollstore edition"] =
			'⚠️Current jailbreak edition is not uninstalled\n\nTo avoid conflicts, it is recommended to delete the trollstore edition first, then activate the jailbreak, uninstall the jailbreak edition, and then install the trollstore edition',
		},
		zh = {
			["XXTouch"] = "X.X.T.",
			["⚠️Current jailbreak edition is not uninstalled\n\nTo avoid conflicts, it is recommended to delete the trollstore edition first, then activate the jailbreak, uninstall the jailbreak edition, and then install the trollstore edition"] =
			'⚠️当前越狱版未卸载\n\n为避免冲突，建议先删除巨魔版，然后激活越狱并卸载越狱版，再安装巨魔版',
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

local function migrate_files_to_xxt_home(files)
	local jb_home_patterns = {
		{
			'/private/preboot/',
			{ "^[A-F0-9]+$" },
			{ "^.+$" },
			'/procursus/var/mobile/Media/1ferver/',
		},
		{
			'/private/var/containers/Bundle/Application/',
			{ "^%.jbroot%-[A-F0-9]+$" },
			'/var/mobile/Media/1ferver/',
		},
	}
	for _, pattern in ipairs(jb_home_patterns) do
		local jb_home = file.find(pattern)
		if jb_home[1] then
			for _, fn in ipairs(files) do
				local src = path_op.add_component(jb_home[1], fn)
				local dst = path_op.add_component(XXT_HOME_PATH, fn)
				if not file.move(src, dst) then
					file.copy(src, dst)
				end
			end
		end
	end
end

migrate_files_to_xxt_home {
	path_op.last_component(XXT_CONF_FILE_NAME),
	'cert/cert.crt',
	'cert/pri.key',
	'log/sys.log',
}

if find_jbpath('/Applications/XXTExplorer.app') then
	start_daemon(XXT_EXE_PATH, 'eval',
		string.format([[sys.alert(%q, 30, %q)]],
			LLANG(
			"⚠️Current jailbreak edition is not uninstalled\n\nTo avoid conflicts, it is recommended to delete the trollstore edition first, then activate the jailbreak, uninstall the jailbreak edition, and then install the trollstore edition"),
			LLANG("XXTouch")))
	return
end

start_daemon(XXT_EXE_PATH, 'dofile', XXT_HOME_PATH .. '/bin/xxt-migrate-jb2ts-user.lua')
