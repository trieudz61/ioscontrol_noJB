--[[

	toast 服务

	本文件仅作为参考，请不要修改本文件
	本文件会在重装、更新时被原版覆盖

--]]

-- local pid_file = jbroot "/tmp/.xxtouch-uiservice-toast-service.singleton"

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

local ffi = require("ffi")
local objc = require("objc")

ffi.cdef [[
    int setgid(int);
    int setuid(int);
]]

ffi.C.setgid(501)
ffi.C.setuid(501)

local CFRunLoopRunWithAutoreleasePool = CFRunLoopRunWithAutoreleasePool

if type(toast_service_start) == "function" then
	dispatch_async('concurrent', function()
		toast_service_start("xxtouch.toast-service-center")
		CFRunLoopRunWithAutoreleasePool()
	end)
	return CFRunLoopRunWithAutoreleasePool()
end

local CPDMsgCenter = require("CPDMsgCenter")

local XXTLocalToastCenter = CPDMsgCenter("xxtouch.toast-service-center")

XXTLocalToastCenter.registerMessage("send-toast", function(name, args)
	local text = args.objectForKey("text")()
	local orien = ffi.tonumber(args.objectForKey("orien")().integerValue())
	local allow_screenshot = ffi.tonumber(args.objectForKey("allow_screenshot")().boolValue())
	local_toast(tostring(text), { orien = orien, allow_screenshot = allow_screenshot ~= 0 })
	return 1
end)

XXTLocalToastCenter.registerMessage("show-pose", function(name, args)
	local show0_hide1_hideall2 = args.objectForKey("show0_hide1_hideall2")().integerValue()
	local index = args.objectForKey("index")().integerValue()
	local x = args.objectForKey("x")().doubleValue()
	local y = args.objectForKey("y")().doubleValue()
	local angle = args.objectForKey("angle")().doubleValue()
	local_pose(show0_hide1_hideall2, index, x, y, angle)
	return 1
end)

XXTLocalToastCenter.registerMessage("eval-script", function(name, args)
	local script = args.objectForKey("script")()
	if script == ffi.nullptr then
		return objc.toobj({ ok = ok, results = { false, "bad script" } })
	end
	if objc.isa(script, objc.NSString) then
		script = script.UTF8String()
	elseif objc.isa(script, objc.NSData) then
		script = ffi.string(ffi.cast("char *", script.bytes()), ffi.tonumber(script.length()))
	else
		return objc.toobj({ ok = ok, results = { false, "bad script" } })
	end
	local ret = { objc.try(load(script) or function() error("bad script") end) }
	local ok = false
	if ret[1] then
		ok = true
	end
	ret = { select(2, table.unpack(ret)) }
	return objc.toobj({ ok = ok, results = table.deep_dump(ret, true) })
end)

XXTLocalToastCenter.start()

CFRunLoopRunWithAutoreleasePool()
