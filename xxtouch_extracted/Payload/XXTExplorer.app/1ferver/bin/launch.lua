--[[

	新增额外的随服务启动项
		将扩展名为 `.lua` 脚本文件导入到设备的 `/var/mobile/Media/1ferver/daemons` 目录中
		然后于 App 打开 `更多--用户偏好设置--后台额外脚本服务`
		⚠️ 如果脚本文件的扩展名为 `.keepalive.lua` 则该脚本会自动维持运行状态，崩溃或退出会自动再次启动
	退出额外脚本服务
		可于 App 关闭 `更多--用户偏好设置--后台额外脚本服务` 开关

	⚠️ 使用该项功能需要确保你对该项功能的了解，否则带来的风险自行承担 ⚠️

	本文件仅作为参考，请不要修改本文件
	本文件会在重装、更新时被原版覆盖

--]]

local lock_fd = lockfile(jbroot("/tmp/.xxtouch.launch.lua.singleton"))
if not lock_fd then
	return
end

local function _launch_load(filename, keepalive, mainrunloop)
	keepalive = keepalive and true or false
	mainrunloop = mainrunloop and true or false
	return launch_start_lua_daemon(XXT_BIN_PATH .. "/" .. filename, keepalive, mainrunloop)
end

local function _launch_unload(filename)
	return launch_stop_lua_daemon(XXT_BIN_PATH .. "/" .. filename)
end

-- local SIGCHLD = 20
-- local SIG_IGN = 2
-- sys.signal(SIGCHLD, SIG_IGN)

sys.nohup()

_launch_unload("watchdogd.lua")

cpdistributed_messaging_center_send_message_and_receive_reply(
	'xxtouch.watchdogd-service',
	'xxtouch.watchdogd-service/exit',
	{ ping = sys.mtime() }
)

local function _watchdogd_ping()
	local reply = cpdistributed_messaging_center_send_message_and_receive_reply(
		'xxtouch.watchdogd-service',
		'xxtouch.watchdogd-service/ping',
		{ ping = sys.mtime() }
	)
	return type(reply) == "table"
end

local function _need_ping()
	if IS_TROLLSTORE_EDITION then
		return true
	end
	local is_bootstrap = file.exists(jbroot '/basebin/bootstrapd') and
		not file.exists(jbroot '/launchdhook.dylib') and
		not file.exists(jbroot '/basebin/.launchctl_support')
	return is_bootstrap
end

local function _wait_watchdogd_ready(timeout_ms)
	local deadline = sys.mtime() + (timeout_ms or 5000)
	while sys.mtime() < deadline do
		if _watchdogd_ping() then
			return true
		end
		sys.msleep(200)
	end
	return false
end

local need_ping = _need_ping()
while true do
	if _launch_load("watchdogd.lua", true) then
		if (not need_ping) or _wait_watchdogd_ready(8000) then
			break
		end
		_launch_unload("watchdogd.lua")
	end
	sys.msleep(500)
end

unlockfilefd(lock_fd)
