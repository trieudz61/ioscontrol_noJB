--[[

	捕获一些触摸信息

	本文件仅作为参考，请不要修改本文件
	本文件会在重装、更新时被原版覆盖

--]]

local objc = require('objc')
local ffi = require('ffi')

local IOHIDEventGetFloatValue = IOHIDEventGetFloatValue
local IOHIDEventGetChildren = IOHIDEventGetChildren
local objc_description = objc_description
local kIOHIDEventTypeDigitizer = 11
local kIOHIDEventTypeKeyboard = 3
local kIOHIDEventFieldDigitizerQualityRadiiAccuracy = 720922

event_callback_handle = hid_event_register_callback({
		event_types = {
			[kIOHIDEventTypeKeyboard] = false,
			[kIOHIDEventTypeDigitizer] = true,
		},
	},
	function(event)
		local event_description = objc_description(event)
		if type(event_description) == "string" and not event_description:find("NON KERNEL SENDER") then
			local children = IOHIDEventGetChildren(event)
			for i, child in ipairs(children) do
				local accuracy = IOHIDEventGetFloatValue(child, kIOHIDEventFieldDigitizerQualityRadiiAccuracy)
				if accuracy > 0 and accuracy < 0.5 then
					xxtouch.post("/api/touch/set-accuracy", "{}", json.encode { accuracy = accuracy })
					os.exit(0)
				end
			end
		end
	end)

exit_callback_handle = notification_center_register_callback({
		center = "darwin",
		name = "xxtouch.catch-touch-info-service-exit",
	},
	function()
		exit_callback_handle:release()
		os.exit(0)
	end)

CFRunLoopRunWithAutoreleasePool()
