--[[

	巨魔版卸载脚本

	本文件仅作为参考，请不要修改本文件
	本文件会在重装、更新时被原版覆盖

--]]

local LLANG = (function()
	local _localizations = {
		en = {
			["XXTouch"] = "XXTouch",
			["OK"] = "OK",
			["XXTouch has been uninstalled.\n\nDo you need to completely delete the scripts and related archives of XXTouch?"] =
			"XXTouch has been uninstalled.\n\nDo you need to completely delete the scripts and related archives of XXTouch?\n\n(⚠️DELETION IS UNRECOVERABLE)",
			["Keep Them"] = "Keep Them",
			["Delete All"] = "Delete All",
			["You can be in `/var/mobile/Media/1ferver` to find them later."] =
			"You can be in `/var/mobile/Media/1ferver` to find them later.",
			["Cancel"] = "Cancel",
			["Delete"] = "Delete",
			["Type %s to confirm deletion\n(case-insensitive)"] = "Type %s to confirm deletion\n(case-insensitive)",
		},
		zh = {
			["XXTouch"] = "X.X.T.",
			["OK"] = "好",
			["XXTouch has been uninstalled.\n\nDo you need to completely delete the scripts and related archives of XXTouch?"] =
			"X.X.T. 已从设备卸载。\n\n是否需要完全删除 X.X.T. 的脚本和相关存档？\n\n（⚠️删除后不可恢复）",
			["Keep Them"] = "保留",
			["Delete All"] = "删除",
			["You can be in `/var/mobile/Media/1ferver` to find them later."] = "稍后你可以在 `/var/mobile/Media/1ferver` 找到它们",
			["Cancel"] = "取消",
			["Delete"] = "删除",
			["Type %s to confirm deletion\n(case-insensitive)"] = "输入 %s 以确认删除\n（不区分大小写）",
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

function find_remove(pattern)
	local list = file.find(pattern)
	for _, path in ipairs(list or {}) do
		file.remove(path)
	end
end

function remove_app_caches(name)
	file.remove('/var/root/Library/WebKit/' .. name)
	file.remove('/var/root/Library/Caches/' .. name)
	file.remove('/var/root/Library/HTTPStorages/' .. name)
	file.remove('/var/root/Library/SplashBoard/Snapshots/' .. name)
	file.remove('/var/root/Library/Saved Application State/' .. name .. '.savedState')
	file.remove('/var/mobile/Library/Caches/' .. name)
	file.remove('/var/mobile/Library/WebKit/' .. name)
	file.remove('/var/mobile/Library/HTTPStorages/' .. name)
	file.remove('/var/mobile/Library/SplashBoard/Snapshots/' .. name)
	file.remove('/var/mobile/Library/Saved Application State/' .. name .. '.savedState')
end

function remove_app_preferences(name)
	file.remove('/var/root/Library/Preferences/' .. name .. '.plist')
	file.remove('/var/mobile/Library/Preferences/' .. name .. '.plist')
end

find_remove('/private/var/containers/Bundle/Application/.jbroot-*/Library/MobileSubstrate/DynamicLibraries/1feaks.*')
find_remove('/private/var/containers/Bundle/Application/.jbroot-*/usr/lib/TweakInject/1feaks.*')
find_remove { '/private/preboot/', { '^[A-F0-9]+$' }, { '^.+$' }, '/procursus/Library/MobileSubstrate/DynamicLibraries/', { '^1feaks.+$' } }
find_remove { '/private/preboot/', { '^[A-F0-9]+$' }, { '^.+$' }, '/procursus/usr/lib/TweakInject/', { '^1feaks.+$' } }

remove_app_caches('com.xxtouch.XXTExplorer')
remove_app_caches('app.xxtouch.XXTUIService')
remove_app_preferences('app.xxtouch.XXTUIService')

file.remove('/var/mobile/Library/Preferences/XXTEUserDefaults.plist')

local path_op = file.path

local ok, buildin_files = pcall(dofile, XXT_BIN_PATH .. '/module-xxt-buildin-list.lua')
if ok then
	for _, buildin_file in ipairs(buildin_files or {}) do
		local ts_full_path = path_op.add_component(XXT_HOME_PATH, buildin_file)
		os.remove(ts_full_path)
	end
end

find_remove { '/tmp/', { '^%.xxtouch.+$' } }
find_remove { '/tmp/', { '^%.1ferver.+$' } }

if sys.alert(LLANG("XXTouch has been uninstalled.\n\nDo you need to completely delete the scripts and related archives of XXTouch?"), 0, LLANG("XXTouch"), LLANG("Keep Them"), LLANG("Delete All")) == 1 then
	math.randomseed(sys.rnd())
	local del, choice
	local ranstr
	repeat
		ranstr = string.random("QWERTYUIOPASDFGHJKLZXCVBNM", 3)
		del, choice = sys.input_box(LLANG('XXTouch'),
			string.format(LLANG('Type %s to confirm deletion\n(case-insensitive)'), ranstr), ranstr, '', '',
			LLANG('Cancel'), LLANG('Delete'), 0)
	until choice ~= 2 or (del:upper() == ranstr and choice == 2)
	if choice ~= 2 then
		return
	end
	remove_app_preferences('com.xxtouch.XXTExplorer')
	file.remove('/var/mobile/Library/uicfg')
	file.remove('/tmp/1ferver.backup')
	file.move('/var/mobile/Media/1ferver', '/tmp/1ferver.backup')
	file.remove('/var/mobile/Media/1ferver')
	sys.killall(9, 'cfprefsd')
else
	sys.killall(9, 'cfprefsd')
	sys.alert(LLANG("You can be in `/var/mobile/Media/1ferver` to find them later."), 0, LLANG("XXTouch"), LLANG("OK"))
end
