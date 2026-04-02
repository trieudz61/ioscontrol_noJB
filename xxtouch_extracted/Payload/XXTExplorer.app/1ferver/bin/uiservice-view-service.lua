-- local pid_file = jbroot "/tmp/.xxtouch-uiservice-view-service.singleton"

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

local CFRunLoopRunWithAutoreleasePool = CFRunLoopRunWithAutoreleasePool

if type(toast_service_start) == "function" then
	dispatch_async('concurrent', function()
		toast_service_start("xxtouch.view-service-center")
		CFRunLoopRunWithAutoreleasePool()
	end)
end

local ffi = require 'ffi'
local objc = require 'objc'

ffi.cdef [[
    int setgid(int);
    int setuid(int);
]]

ffi.C.setgid(501)
ffi.C.setuid(501)

UIApp = objc.UIApplication.sharedApplication()
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

return CFRunLoopRunWithAutoreleasePool()
