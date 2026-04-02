--[[

本文件仅作为参考，请不要修改本文件
本文件会在重装、更新时被原版覆盖

--]]

local ffi = require("ffi")
local objc = require("objc")
local spawn = require("spawn")
local json = require('cjson.safe')
local lfs = require('lfs')

local sposix = require("spawn.posix")
local spawnp = sposix.spawnp
local waitpid = require("spawn.wait").waitpid

-- local SIGCHLD = 20
-- local SIG_IGN = 2
-- sys.signal(SIGCHLD, SIG_IGN)

local function watchdogd_log(...)
	if type(NSLog) == 'function' then
		NSLog(...)
	end
end

local function _fexists_not_directory(filepath)
	local mode = lfs.attributes(filepath, 'mode')
	return mode and mode ~= 'directory' and filepath
end

local function _string_endswith(str, suffix, case_insensitive)
	if #suffix > #str then
		return false
	end
	if case_insensitive then
		str = str:lower()
		suffix = suffix:lower()
	end
	local suffix_len = #suffix
	if str == suffix then
		return true
	elseif #str > suffix_len then
		local s = str:sub(-(suffix_len), -1)
		return s == suffix
	end
	return false
end

local _kill_bootstrapd_tm = 0
local function _restart_bootstrapd_if_need()
	if file.exists(jbroot '/basebin/bootstrapd') and not file.exists(jbroot '/launchdhook.dylib') and not file.exists(jbroot '/basebin/.launchctl_support') then
		dispatch_async('main', function()
			_kill_bootstrapd_tm = sys.mtime() + 1500
			dispatch_after(1600, 'main', function()
				if _kill_bootstrapd_tm < sys.mtime() then
					sys.killall(9, 'bootstrapd')
					local task = sys.task(jbroot '/basebin/bootstrapd', 'daemon', '-f')
					task:set_stdin('/dev/null')
					task:set_stdout('/dev/null')
					task:set_stderr('/dev/null')
					task:launch()
					task:wait_until_exit()
				end
			end)
		end)
	end
end

local function _read_conf()
	local conf = json.decode(file.reads(XXT_CONF_FILE_NAME) or "")
	conf = (type(conf) == 'table') and conf or {}
	return conf
end

function stopAllServices()
	for name in lfs.dir(jbroot('/tmp/')) do
		if name:find('^%.xxtouch%.daemon%..-%.pid$') then
			local pidfilepath = jbroot('/tmp/' .. name)
			local pid = tonumber((file.reads(pidfilepath)))
			if pid ~= nil and pid ~= 0 then
				sys.kill(pid, 9)
			end
			os.remove(pidfilepath)
		end
	end
end

stopAllServices()

local keepAlivedServices = {}
local servicePids = {}

function stopService(args)
	local pidfilepath = jbroot "/tmp/.xxtouch.daemon." .. table.concat(args, ' '):sha1() .. '.pid'
	keepAlivedServices[pidfilepath] = nil
	local pid = tonumber((file.reads(pidfilepath)))
	if pid ~= nil and pid ~= 0 then
		sys.kill(pid, 9)
		os.remove(pidfilepath)
	end
end

-- if sys.cfversion() > 1900 then
-- 	if file.exists(jbroot '/Applications/XXTExplorer.app/XXTExplorer') then
-- 		sys.lchmod(XXT_SYSTEM_PATH..'/fastPathSign', 7*8^2 | 5*8^1 | 5*8^0)
-- 		spawn.run(XXT_SYSTEM_PATH..'/fastPathSign', XXT_SYSTEM_PATH..'/XXTUIService.app/XXTUIService')
-- 		spawn.run(XXT_SYSTEM_PATH..'/fastPathSign', jbroot '/Applications/XXTExplorer.app/XXTExplorer')
-- 	end
-- end

function launchService(args, actions)
	if type(args) ~= 'table' then
		return
	end
	if type(args[1]) ~= "string" then
		return
	end
	if type(actions) ~= 'table' then
		actions = {}
	end
	local pidfilepath = jbroot "/tmp/.xxtouch.daemon." .. table.concat(args, ' '):sha1() .. '.pid'
	keepAlivedServices[pidfilepath] = (actions.keepalive == true) and true or nil
	local runFirstTime = true
	local function _service_loop()
		if not runFirstTime and not keepAlivedServices[pidfilepath] then
			return
		end
		runFirstTime = false
		if type(actions.pre_run) == 'function' then
			pcall(actions.pre_run, args)
		end
		local ok, msg, errno
		pcall(function()
			local pid, err
			pid = tonumber((file.reads(pidfilepath)))
			if pid ~= nil and pid ~= 0 then
				sys.kill(pid, 9)
				os.remove(pidfilepath)
			end
			local task = sys.task(table.unpack(args))
			task:set_stdin('/dev/null')
			task:set_stdout('/dev/null')
			task:set_stderr('/dev/null')
			task:launch()
			pid = task:pid()
			if pid ~= nil and pid ~= 0 then
				servicePids[pidfilepath] = pid
				file.writes(pidfilepath, tostring(pid))
				_restart_bootstrapd_if_need()
				task:wait_until_exit()
				ok = false
				msg = task:termination_reason()
				errno = task:termination_status()
				if errno == 0 then
					ok = true
				end
				-- ok, msg, errno = waitpid(pid)
			end
		end)
		if type(actions.post_run) == 'function' then
			pcall(actions.post_run, args, ok, msg, errno)
		end
		if keepAlivedServices[pidfilepath] then
			dispatch_after(1000, 'concurrent', _service_loop)
		end
	end
	dispatch_async('concurrent', _service_loop)
end

function launchUIService(path, ignores_hit, actions)
	if type(actions) ~= 'table' then
		actions = {}
	end
	path = _fexists_not_directory(path)
	if not path then
		return
	end
	local post_run = actions.post_run
	actions.post_run = function(args, ok, msg, errno)
		if errno ~= 0 and errno ~= 9 then
			watchdogd_log(path .. ' exited.', ok, msg, errno)
		end
		if type(post_run) == 'function' then
			pcall(actions.post_run, path, ok, msg, errno)
		end
	end
	local ignores_hit_option = (ignores_hit == true) and "--ignores-hit=YES" or ""
	local no_idle_foreground_option = (actions.no_idle_foreground == true) and "--no-idle-foreground=YES" or ""
	return launchService(
	{ XXT_SYSTEM_PATH .. '/XXTUIService.app/XXTUIService', ignores_hit_option, no_idle_foreground_option, '--file', path }, actions)
end

function launchBackService(path, mainrunloop, options)
	return launchService({ XXT_EXE_PATH, mainrunloop and 'dofile-runloop' or 'dofile', path }, options)
end

function stopBackService(path, mainrunloop)
	return stopService({ XXT_EXE_PATH, mainrunloop and 'dofile-runloop' or 'dofile', path })
end

function launchXXTService(name, mainrunloop, options)
	return launchBackService(XXT_BIN_PATH .. "/" .. name, mainrunloop, options)
end

function stopXXTService(name, mainrunloop)
	return stopBackService(XXT_BIN_PATH .. "/" .. name, mainrunloop)
end

function launchXXTUIService(name, ignores_hit, options)
	return launchUIService(XXT_BIN_PATH .. "/" .. name, ignores_hit, options)
end

local conf = _read_conf()

if conf.allow_remote_access then
	notify_post("xxtouch.touchelf-udpd-service/exit")
	launchXXTService('touchelf-udpd.lua', false, { keepalive = true })
	-- 需要打开触摸精灵兼容请配置 conf.touchelf_httpd = true
	-- App -- 更多 -- 用户偏好设置 -- 支持 `触摸精灵` 开发工具
	notify_post("xxtouch.touchelf-httpd-service/exit")
	if conf.touchelf_httpd then
		launchXXTService('touchelf-httpd.lua', false, { keepalive = true })
	else
		stopXXTService('touchelf-httpd.lua', false)
	end
	-- 触摸精灵标准云控接口实现
	notify_post("xxtouch.open-cloud-control-client-service/exit")
	if type(conf.open_cloud_control) == 'table' and type(conf.open_cloud_control.enable) == 'boolean' and type(conf.open_cloud_control.address) == 'string' and conf.open_cloud_control.enable then
		launchXXTService('open-cloud-control-client.lua', false, { keepalive = true })
	else
		stopXXTService('open-cloud-control-client.lua', false)
	end
end

if _fexists_not_directory(XXT_BIN_PATH .. "/daemon.lua") then
	launchXXTService("daemon.lua", false, { keepalive = false }) -- daemon.lua 保持和旧版一致，keepAlive 选项关闭
end

if type(conf.touch_accuracy) ~= "number" or conf.touch_accuracy < 0 or conf.touch_accuracy > 0.5 then
	launchXXTService("uiservice-catch-touch-info-service.lua", false, {
		keepalive = false,
		pre_run = function(args)
			notify_post("xxtouch.uiservice-catch-touch-info-service-exit")
		end,
		post_run = function(args, ok, msg, errno)
			if errno ~= 0 and errno ~= 9 then
				watchdogd_log(args, 'exited', ok, msg, errno)
			end
			os.remove(jbroot "/tmp/.xxtouch-uiservice-catch-touch-info-service.singleton")
		end
	})
end

if conf.startup_run then
	local function system_startup()
		local port = tonumber(conf.port) or 46952
		if port < 1 or port > 65535 then
			port = 46952
		end
		local c, h, r = http.post("http://127.0.0.1:" .. port .. "/" .. XXT_INTER_NAME .. ".system_startup", 10)
		if c == -1 then
			dispatch_after(5000, 'concurrent', system_startup)
		end
	end
	dispatch_after(10000, 'concurrent', system_startup)
	os.remove("/tmp/.xxtouch.widget-startup-need-lock")
else
	dispatch_after(5000, 'concurrent', function()
		if file.exists("/tmp/.xxtouch.widget-startup-need-lock") then
			os.remove("/tmp/.xxtouch.widget-startup-need-lock")
			if not conf.startup_run then
				device.lock_screen()
			end
		end
	end)
end

if conf.launch_daemons then
	if lfs.attributes(XXT_DAEMONS_PATH, 'mode') == 'directory' then
		for filename in lfs.dir(XXT_DAEMONS_PATH) do
			if _string_endswith(filename, ".lua", true) then
				local filepath = _fexists_not_directory(XXT_DAEMONS_PATH .. "/" .. filename)
				if filepath then
					if _string_endswith(filename, ".mainrunloop.keepalive.lua", true) or _string_endswith(filename, ".keepalive.mainrunloop.lua", true) then
						launchBackService(filepath, true, { keepalive = true })
					elseif _string_endswith(filename, ".keepalive.lua", true) then
						launchBackService(filepath, false, { keepalive = true })
					elseif _string_endswith(filename, ".mainrunloop.lua", true) then
						launchBackService(filepath, true, { keepalive = false })
					else --if _string_endswith(filename, ".lua", true) then
						launchBackService(filepath, false, { keepalive = false })
					end
				end
			end
		end
	end
	if sys.cfversion() >= 1673.126 then -- iOS >= 13.2
		local general_actions = {
			keepalive = true,
			pre_run = function(path)
				local s = file.reads(path .. ".pre_run")
				if type(s) == 'string' then
					local func, err = load(s)
					if func then
						local ok, err = pcall(func, path)
						if not ok then
							watchdogd_log(path .. ".pre_run runtime error:", err)
						end
					else
						watchdogd_log(path .. ".pre_run syntax error:", err)
					end
				end
			end,
			post_run = function(path, done, msg, errno)
				local s = file.reads(path .. ".post_run")
				if type(s) == 'string' then
					local func, err = load(s)
					if func then
						local ok, err = pcall(func, path, done, msg, errno)
						if not ok then
							watchdogd_log(path .. ".post_run runtime error:", err)
						end
					else
						watchdogd_log(path .. ".post_run syntax error:", err)
					end
				end
			end,
		}
		if lfs.attributes(XXT_UISERVICES_PATH, 'mode') == 'directory' then
			for filename in lfs.dir(XXT_UISERVICES_PATH) do
				if _string_endswith(filename, ".lua", true) then
					local filepath = _fexists_not_directory(XXT_UISERVICES_PATH .. "/" .. filename)
					if filepath then
						if _string_endswith(filename, ".ignores-hit.lua", true) then
							launchUIService(filepath, true, general_actions)
						else
							launchUIService(filepath, false, general_actions)
						end
					end
				end
			end
		end
	end
end

if conf.show_user_touch_pose then
	if sys.cfversion() < 1673.126 then
		launchXXTService("uiservice-show-pose-service.ignores-hit.lua", false, {
			keepalive = true,
			pre_run = function(args)
				notify_post("xxtouch.uiservice-show-pose-service-exit")
			end,
			post_run = function(args, ok, msg, errno)
				if errno ~= 0 and errno ~= 9 then
					watchdogd_log(args, 'exited', ok, msg, errno)
				end
				os.remove(jbroot "/tmp/.xxtouch-uiservice-show-pose-service.singleton")
			end
		})
	else
		launchXXTUIService("uiservice-show-pose-service.ignores-hit.lua", true, {
			keepalive = true,
			pre_run = function(path)
				notify_post("xxtouch.uiservice-show-pose-service-exit")
			end,
			post_run = function(path, ok, msg, errno)
				if errno ~= 0 and errno ~= 9 then
					watchdogd_log(path, 'exited', ok, msg, errno)
				end
				os.remove(jbroot "/tmp/.xxtouch-uiservice-show-pose-service.singleton")
			end,
		})
	end
end

if sys.cfversion() < 1673.126 then -- iOS < 13.2
	launchXXTService("uiservice-volume-key-control-service.lua", false, {
		keepalive = true,
		pre_run = function(args)
			notify_post("xxtouch.uiservice-volume-key-control-service-exit")
		end,
		post_run = function(args, ok, msg, errno)
			if errno ~= 0 and errno ~= 9 then
				watchdogd_log(args, 'exited', ok, msg, errno)
			end
			os.remove(jbroot "/tmp/.xxtouch-uiservice-volume-key-control-service.singleton")
		end
	})
	return CFRunLoopRunWithAutoreleasePool()
end

launchXXTUIService("uiservice-toast-service.ignores-hit.lua", true, {
	keepalive = true,
	no_idle_foreground = IS_TROLLSTORE_EDITION,
	pre_run = function(path)
		cpdistributed_messaging_center_send_message("xxtouch.toast-service-center", "eval-script",
			{ script = "os.exit(0)" })
	end,
	post_run = function(path, ok, msg, errno)
		os.remove(jbroot "/tmp/.xxtouch-uiservice-toast-service.singleton")
	end,
})

launchXXTUIService("uiservice-volume-key-control-service-sialert.lua", false, {
	keepalive = true,
	pre_run = function(path)
		notify_post("xxtouch.uiservice-volume-key-control-service-exit")
	end,
	post_run = function(path, ok, msg, errno)
		if errno ~= 0 and errno ~= 9 then
			watchdogd_log(path, 'exited', ok, msg, errno)
		end
		os.remove(jbroot "/tmp/.xxtouch-uiservice-volume-key-control-service.singleton")
	end,
})

dispatch_async("concurrent", function()
	local function kill_children()
		for pidfilepath, pid in pairs(servicePids) do
			keepAlivedServices[pidfilepath] = nil
			if pid > 0 then
				sys.kill(pid, 9)
			end
			os.remove(pidfilepath)
		end
		os.exit(0)
	end
	cpd_exit_callback_handle = cpdistributed_messaging_center_register_callback('xxtouch.watchdogd-service', 'exit',
		function(userInfo)
			kill_children()
			return { pong = sys.mtime() }
		end)
	cpd_ping_callback_handle = cpdistributed_messaging_center_register_callback('xxtouch.watchdogd-service', 'ping',
		function(userInfo)
			return { pong = sys.mtime() }
		end)
	cpdistributed_messaging_center_run_server_on_current_thread('xxtouch.watchdogd-service')
	exit_callback_handle = notification_center_register_callback({
			center = "darwin",
			name = "xxtouch.watchdogd-service/exit",
		},
		function()
			exit_callback_handle:release()
			kill_children()
			os.exit(0)
		end)
	CFRunLoopRunWithAutoreleasePool()
end)

xxtouch_start_watcher()

_restart_bootstrapd_if_need()

return CFRunLoopRunWithAutoreleasePool()
