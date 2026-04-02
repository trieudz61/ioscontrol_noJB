--[[

	安全模式下的音量键控制

	桌面插件无法运行需要使用这个守护程序来启停脚本

	本文件仅作为参考，请不要修改本文件
	本文件会在重装、更新时被原版覆盖

--]]

-- local pid_file = jbroot "/tmp/.xxtouch-uiservice-volume-key-control-service.singleton"

-- function service_pid(pid_file)
-- 	local pid = sys.getpid()
-- 	if not lockfile(pid_file) then
-- 		pid = 0
-- 		local f = io.open(pid_file, 'r')
-- 		if f then
-- 			pid = tonumber(f:read('a')) or 0
-- 			f:close()
-- 		end
-- 	end
-- 	return pid
-- end

-- local pid = service_pid(pid_file)

-- if pid == 0 then
-- 	sys.log("An unknown process locked the file `"..pid_file.."`")
-- 	os.exit(0)
-- elseif pid ~= sys.getpid() then
-- 	sys.kill(pid, 9)
-- 	os.exit(0)
-- end

watchdog_exit_handle = dispatch_source_register_callback("proc", sys.getppid(), DISPATCH_PROC_EXIT, function()
	root_start(XXT_EXE_PATH, "dofile", XXT_BIN_PATH .. "/launch.lua")
	watchdog_exit_handle:release()
	os.exit(0)
end)

local LLANG = (function()
	local _localizations = {
		en = {
			["XXTouch"] = "XXTouch",
			["OK"] = "OK",
			["Options"] = "Options",
			["🚫 Cancel"] = "🚫 Cancel",
			["▶️ Launch"] = "▶️ Launch",
			["⏹️ Stop"] = "⏹️ Stop",
			["⏺️ Record"] = "⏺️ Record",
			["⏩ Resume"] = "⏩ Resume",
			["⏸️ Pause"] = "⏸️ Pause",
			["⏩ Script is running..."] = "⏩ Script is running...",
			["⏸️ Script is pausing..."] = "⏸️ Script is pausing...",
			["Start recording script"] = "Start recording script",
			["✅ Recording finished\nscript saved to `%s`"] = "✅ Recording finished\nscript saved to `%s`",
			["❌ Failed to communicate with daemon\nService has not started yet, please wait..."] =
			"❌ Failed to communicate with daemon\nService has not started yet, please wait...",
		},
		zh = {
			["XXTouch"] = "X.X.T.",
			["OK"] = "好",
			["Options"] = "选择需要做出的操作",
			["🚫 Cancel"] = "🚫 取消",
			["▶️ Launch"] = "▶️ 启动脚本",
			["⏹️ Stop"] = "⏹️ 停止脚本",
			["⏺️ Record"] = "⏺️ 录制脚本",
			["⏩ Resume"] = "⏩ 继续脚本",
			["⏸️ Pause"] = "⏸️ 暂停脚本",
			["⏩ Script is running..."] = "⏩ 脚本运行中...",
			["⏸️ Script is pausing..."] = "⏸️ 脚本暂停中...",
			["Start recording script"] = "开始录制脚本",
			["✅ Recording finished\nscript saved to `%s`"] = "✅ 录制完成\n脚本保存为 `%s`",
			["❌ Failed to communicate with daemon\nService has not started yet, please wait..."] =
			"❌ 与守护进程的通讯发生故障\n服务可能尚未启动完成，请稍等...",
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

local objc = require('objc')
local ffi = require('ffi')

ffi.cdef [[
	typedef void(*IOHIDEventSystemClientEventCallback)(void* target, void* refcon, id queue, id event);
	id IOHIDEventSystemClientCreate(void *);
	void IOHIDEventSystemClientScheduleWithRunLoop(id client, id runloop, id mode);
	void IOHIDEventSystemClientRegisterEventCallback(id client, IOHIDEventSystemClientEventCallback callback, void* target, void* refcon);
	void CFRunLoopRun();
	id CFRunLoopGetCurrent();
	id kCFRunLoopDefaultMode;
	int IOHIDEventGetType(id event);
	int IOHIDEventGetIntegerValue(id event, int field);
	typedef void (*CFNotificationCallback)(id center, void *observer, id name, const void *object, id userInfo);
	id CFNotificationCenterGetDarwinNotifyCenter();
	void CFNotificationCenterAddObserver(id center, const void *observer, CFNotificationCallback callBack, id name, const void *object, long suspensionBehavior);
	void CFNotificationCenterRemoveObserver(id center, const void *observer, id name, const void *object);
	double CACurrentMediaTime();
    int setgid(int);
    int setuid(int);
]]

ffi.C.setgid(501)
ffi.C.setuid(501)

local IOHIDEventGetIntegerValue = IOHIDEventGetIntegerValue
local CFRunLoopRun = ffi.C.CFRunLoopRun
local CFRunLoopGetCurrent = ffi.C.CFRunLoopGetCurrent
local CFNotificationCenterGetDarwinNotifyCenter = ffi.C.CFNotificationCenterGetDarwinNotifyCenter
local CFNotificationCenterAddObserver = ffi.C.CFNotificationCenterAddObserver
local CACurrentMediaTime = ffi.C.CACurrentMediaTime

local kCFRunLoopDefaultMode = ffi.C.kCFRunLoopDefaultMode
local kIOHIDEventTypeDigitizer = 11
local kIOHIDEventTypeKeyboard = 3
local kIOHIDEventFieldKeyboardUsagePage = 196608
local kIOHIDEventFieldKeyboardUsage = 196609
local kIOHIDEventFieldKeyboardDown = 196610
local NULL = ffi.nullptr
local CFNotificationSuspensionBehaviorDeliverImmediately = 4
local mach_absolute_ms = mach_absolute_ms or sys.mtime

UIApp = UIApp or objc.UIApplication.sharedApplication()

if not oneTimeBlockTie then
	local release_fixed_block = release_fixed_block
	local new_fixed_block_8 = new_fixed_block_8

	local oneTimeBlockInternal = function(func, blocks)
		blocks = blocks or {}
		blocks[#blocks + 1] = new_fixed_block_8(function(...)
			dispatch_async('main', function()
				for i = #blocks, 1, -1 do
					release_fixed_block(table.remove(blocks, i))
				end
			end)
			return func(...)
		end)
		return ffi.cast('id', blocks[#blocks])
	end

	oneTimeBlockTie = function() -- 创建多个绑定在一起的一次性 block，它只允许其中任意一个 block 被执行一次
		return setmetatable({}, {
			__call = function(self, func)
				return oneTimeBlockInternal(func, self)
			end,
			__index = {
				release = function(self)
					for i = #self, 1, -1 do
						release_fixed_block(table.remove(self, i))
					end
				end,
			},
		})
	end

	oneTimeBlock = function(func) -- 创建一个一次性 block，该 block 会在执行一次后被释放
		return oneTimeBlockTie()(func)
	end
end

if rootVC == nil then
	dispatch_async('main', function()
		local fullScreenFrame = objc.UIScreen.mainScreen().bounds()
		local secureview = require('secureview')
		if secureview then
			sharedSecureView = secureview.create()
			sharedSecureView.setFrame(fullScreenFrame)()
			sharedSecureView.hidden = false
		end
		keyWindow = UIApp.keyWindow()
		rootVC = keyWindow.rootViewController()
		rootVC.view().addSubview(sharedSecureView)()
	end)
end

local SIAlertViewClass = objc['SIAlertView插插头xxt闷声防大冲突']

local SIAlertButtonTypes = {
	NORMAL = 0,
	DESTRUCTIVE = 1,
	CANCEL = 2,
}

local alert_poped = false

function SIAlert(delay_ms, title, message, buttons, callback)
	dispatch_after(delay_ms or 0, 'main', function()
		if alert_poped then
			return
		end
		local avblock = oneTimeBlockTie()
		local av = SIAlertViewClass.alloc().initWithTitle(title or "").andMessage(message or "")()
		av.autorelease()
		av.transitionStyle = 4
		for i = 1, #buttons do
			av.addButtonWithTitle(buttons[i].title or "").type(buttons[i].type or SIAlertButtonTypes.NORMAL).handler(
			avblock(function(av)
				if type(callback) == "function" then
					callback(i)
				end
			end))()
		end
		av.didDismissHandler = oneTimeBlock(function(av)
			alert_poped = false
		end)
		av.show()
		av.alertWindow().setWindowLevel(20000099.9)()
		alert_poped = true
	end)
end

function script_is_running()
	local c, _, r = xxtouch.post('/is_running')
	if c == 200 then
		r = json.decode(r) or { code = 0 }
		if r.code == 3 then
			local d = r.data or { is_script_paused = false }
			return true, d.is_script_paused
		elseif r.code == 9 then
			return false, true -- recording
		end
	else
		return false, false
	end
end

function script_start()
	local c, _, r = xxtouch.post("/launch_script_file")
	if c == 200 then
		r = json.decode(r) or { code = -99, message = "unknown error #-99" }
		if r.code ~= 0 then
			return false, r.message
		else
			return true
		end
	else
		return false, LLANG("❌ Failed to communicate with daemon\nService has not started yet, please wait...")
	end
end

function script_pause()
	local c, _, r = xxtouch.post('/pause_script')
	if c == 200 then
		return (json.decode(r) or { code = -1 }).code == 0
	else
		return false
	end
end

function script_resume()
	local c, _, r = xxtouch.post('/resume_script')
	if c == 200 then
		return (json.decode(r) or { code = -1 }).code == 0
	else
		return false
	end
end

function script_stop()
	local c, _, r = xxtouch.post('/stop_script')
	if c == 200 then
		return (json.decode(r) or { code = -1 }).code == 0
	else
		return false
	end
end

function record_start()
	local c, _, r = xxtouch.post('/start_record')
	if c == 200 then
		r = json.decode(r) or { code = -97, message = "unknown error #-97" }
		if r.code ~= 0 then
			return false, r.message
		else
			return true
		end
	else
		return false
	end
end

function record_stop_save()
	local c, _, r = xxtouch.post('/stop_record_save')
	if c == 200 then
		r = json.decode(r) or { code = -1 }
		if r.code == 0 then
			return r.data.filename
		else
			return nil
		end
	else
		return nil
	end
end

local volume_down_down_ts = 0
local volume_up_down_ts = 0
local volume_up_down_event_uuid = nil
local volume_down_down_event_uuid = nil
local holding_event_uuids = {}

function run_or_stop()
	dispatch_async('concurrent', function()
		local is_running, is_paused_or_recording = script_is_running()
		if is_running then
			script_stop()
		else
			if is_paused_or_recording then
				local filename = record_stop_save()
				if filename then
					SIAlert(0, LLANG("XXTouch"),
						string.format(LLANG("✅ Recording finished\nscript saved to `%s`"), filename),
						{ { title = LLANG("OK"), type = SIAlertButtonTypes.NORMAL } })
				end
			else
				local ok, err = script_start()
				if not ok then
					SIAlert(0, LLANG("XXTouch"), err, { { title = LLANG("OK"), type = SIAlertButtonTypes.NORMAL } })
				end
			end
		end
	end)
end

local function pop_action_alert()
	local is_running, is_paused_or_recording = script_is_running()
	if is_running then
		if not is_paused_or_recording then
			script_pause()
			SIAlert(0, LLANG("XXTouch"), LLANG("⏩ Script is running..."), {
				{ title = LLANG("⏸️ Pause"), type = SIAlertButtonTypes.NORMAL },
				{ title = LLANG("⏹️ Stop"), type = SIAlertButtonTypes.DESTRUCTIVE },
				{ title = LLANG("🚫 Cancel"), type = SIAlertButtonTypes.CANCEL },
			}, function(index)
				dispatch_async('concurrent', function()
					if index == 3 then
						script_resume()
					elseif index == 2 then
						script_stop()
					end
				end)
			end)
		else
			SIAlert(0, LLANG("XXTouch"), LLANG("⏸️ Script is pausing..."), {
				{ title = LLANG("⏩ Resume"), type = SIAlertButtonTypes.NORMAL },
				{ title = LLANG("⏹️ Stop"), type = SIAlertButtonTypes.DESTRUCTIVE },
				{ title = LLANG("🚫 Cancel"), type = SIAlertButtonTypes.CANCEL },
			}, function(index)
				dispatch_async('concurrent', function()
					if index == 1 then
						script_resume()
					elseif index == 2 then
						script_stop()
					end
				end)
			end)
		end
	else
		local is_recording = is_paused_or_recording
		if is_recording then
			local filename = record_stop_save()
			if filename then
				SIAlert(0, LLANG("XXTouch"), string.format(LLANG("✅ Recording finished\nscript saved to `%s`"), filename),
					{ { title = LLANG("OK"), type = SIAlertButtonTypes.NORMAL } })
			end
		else
			SIAlert(0, LLANG("XXTouch"), LLANG("Options"), {
				{ title = LLANG("▶️ Launch"), type = SIAlertButtonTypes.NORMAL },
				{ title = LLANG("⏺️ Record"), type = SIAlertButtonTypes.DESTRUCTIVE },
				{ title = LLANG("🚫 Cancel"), type = SIAlertButtonTypes.CANCEL },
			}, function(index)
				if index == 1 then
					dispatch_async('concurrent', function()
						local ok, err = script_start()
						if not ok then
							SIAlert(400, LLANG("XXTouch"), err, { { title = LLANG("OK"), type = SIAlertButtonTypes.NORMAL } })
						end
					end)
				elseif index == 2 then
					dispatch_async('concurrent', function()
						local ok, err = record_start()
						if not ok then
							SIAlert(400, LLANG("XXTouch"), err, { { title = LLANG("OK"), type = SIAlertButtonTypes.NORMAL } })
						else
							sys.toast(LLANG("Start recording script"),
								{ orien = device.front_orien(), allow_screenshot = true })
						end
					end)
				end
			end)
		end
	end
end

event_callback_handle = hid_event_register_callback({
		event_types = {
			[kIOHIDEventTypeKeyboard] = true,
			[kIOHIDEventTypeDigitizer] = false,
		},
	},
	function(event)
		if alert_poped then
			return
		end
		if sys.cfversion() < 1946 and sb_ping() then -- iOS 16 禁用春板上的音量键弹窗
			return
		end
		local key_page = IOHIDEventGetIntegerValue(event, kIOHIDEventFieldKeyboardUsagePage)
		local key_code = IOHIDEventGetIntegerValue(event, kIOHIDEventFieldKeyboardUsage)
		local key_down = IOHIDEventGetIntegerValue(event, kIOHIDEventFieldKeyboardDown)
		if key_page ~= 12 or (key_code ~= 233 and key_code ~= 234) then
			return
		end
		local is_volume_up_key = key_code == 233
		local is_volume_down_key = key_code == 234
		if key_down == 1 then
			local current_uuid = nil
			if is_volume_up_key then
				volume_up_down_ts = mach_absolute_ms()
				volume_up_down_event_uuid = utils.gen_uuid()
				current_uuid = volume_up_down_event_uuid
				holding_event_uuids[current_uuid] = true
			elseif is_volume_down_key then
				volume_down_down_ts = mach_absolute_ms()
				volume_down_down_event_uuid = utils.gen_uuid()
				current_uuid = volume_down_down_event_uuid
				holding_event_uuids[current_uuid] = true
			else
				return
			end
			dispatch_async('concurrent', function()
				local c, _, r = xxtouch.post("/get_all_conf")
				if c ~= 200 then
					return
				end
				local conf = json.decode(r) or {}
				conf = conf.data or {}
				local hold_volume_up = conf.hold_volume_up or 2
				local hold_volume_down = conf.hold_volume_down or 2
				-- local click_volume_up = conf.click_volume_up or 2
				-- local click_volume_down = conf.click_volume_down or 2
				local device_control_toggle = conf.device_control_toggle or false
				if not device_control_toggle then
					return
				end
				dispatch_after(400, 'main', function()
					holding_event_uuids[current_uuid] = nil -- triggered
					if is_volume_up_key and volume_up_down_event_uuid == current_uuid then
						if hold_volume_up == 0 then
							dispatch_async('concurrent', function()
								pcall(pop_action_alert)
							end)
						elseif hold_volume_up == 1 then
							dispatch_async('concurrent', function()
								run_or_stop()
							end)
						end
					elseif is_volume_down_key and volume_down_down_event_uuid == current_uuid then
						if hold_volume_down == 0 then
							dispatch_async('concurrent', function()
								pcall(pop_action_alert)
							end)
						elseif hold_volume_down == 1 then
							dispatch_async('concurrent', function()
								run_or_stop()
							end)
						end
					end
				end)
			end)
		elseif key_down == 0 then
			local is_volume_up_hold_not_triggered = false
			local is_volume_down_hold_not_triggered = false
			local current_uuid = nil
			if is_volume_up_key then
				current_uuid = volume_up_down_event_uuid
				volume_up_down_event_uuid = nil -- holding stop
				if current_uuid then
					if holding_event_uuids[current_uuid] then
						is_volume_up_hold_not_triggered = true
						holding_event_uuids[current_uuid] = nil
					end
				end
			elseif is_volume_down_key then
				current_uuid = volume_down_down_event_uuid
				volume_down_down_event_uuid = nil -- holding stop
				if current_uuid then
					if holding_event_uuids[current_uuid] then
						is_volume_down_hold_not_triggered = true
						holding_event_uuids[current_uuid] = nil
					end
				end
			else
				return
			end
			dispatch_async('concurrent', function()
				local c, _, r = xxtouch.post("/get_all_conf")
				if c ~= 200 then
					return
				end
				local conf = json.decode(r) or {}
				conf = conf.data or {}
				local click_volume_up = conf.click_volume_up or 2
				local click_volume_down = conf.click_volume_down or 2
				local device_control_toggle = conf.device_control_toggle or false
				if not device_control_toggle then
					return
				end
				if is_volume_up_key then
					if is_volume_up_hold_not_triggered then
						if click_volume_up == 0 then
							pcall(pop_action_alert)
						elseif click_volume_up == 1 then
							run_or_stop()
						end
					end
				elseif is_volume_down_key then
					if is_volume_down_hold_not_triggered then
						if click_volume_down == 0 then
							pcall(pop_action_alert)
						elseif click_volume_down == 1 then
							run_or_stop()
						end
					end
				end
			end)
		end
	end)

exit_callback_handle = notification_center_register_callback({
		center = "darwin",
		name = "xxtouch.uiservice-volume-key-control-service-exit",
	},
	function()
		exit_callback_handle:release()
		os.exit(0)
	end)

UIApp._registerForUserDefaultsChanges()
UIApp._registerForSignificantTimeChangeNotification()
UIApp._registerForLanguageChangedNotification()
UIApp._registerForLocaleWillChangeNotification()
UIApp._registerForLocaleChangedNotification()
UIApp._registerForAlertItemStateChangeNotification()
UIApp._registerForKeyBagLockStatusNotification()
UIApp._registerForNameLayerTreeNotification()
UIApp._registerForBackgroundRefreshStatusChangedNotification()
UIApp._registerForHangTracerEnabledStateChangedNotification()

CFRunLoopRunWithAutoreleasePool()
