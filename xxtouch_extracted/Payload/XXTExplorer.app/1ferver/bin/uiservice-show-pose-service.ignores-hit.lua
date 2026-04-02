--[[

	触摸小圆点服务

	本文件仅作为参考，请不要修改本文件
	本文件会在重装、更新时被原版覆盖

--]]

local scr_w, scr_h = screen.size()

local CFRunLoopRunWithAutoreleasePool = CFRunLoopRunWithAutoreleasePool
local IOHIDEventGetIntegerValue = IOHIDEventGetIntegerValue
local IOHIDEventGetFloatValue = IOHIDEventGetFloatValue
local IOHIDEventGetChildren = IOHIDEventGetChildren
local hid_event_register_callback = hid_event_register_callback
local sys_set_pose = sys.set_pose
local local_pose = local_pose

if sys.cfversion() >= 1673.126 then
    local orien_angle_map = {
        [0] = 0,
        [1] = 90,
        [2] = 270,
        [3] = 180,
    }
    sys_set_pose = function(show0_hide1_hideall2, index, x, y, orien)
        local_pose(show0_hide1_hideall2, index, x, y, orien_angle_map[orien])
    end
end

local kIOHIDEventTypeDigitizer = 11
local kIOHIDEventTypeKeyboard = 3

local kIOHIDEventFieldDigitizerIndex = 720901
local kIOHIDEventFieldDigitizerTouch = 720905
local kIOHIDEventFieldDigitizerX = 720896
local kIOHIDEventFieldDigitizerY = 720897

event_callback_handle = hid_event_register_callback({
        event_types = {
            [kIOHIDEventTypeKeyboard] = false,
            [kIOHIDEventTypeDigitizer] = true,
        },
    },
    function(event)
        local front_orien = device.front_orien()
        local children = IOHIDEventGetChildren(event)
        for i = 1, #children do
            local child = children[i]
            local fid = IOHIDEventGetIntegerValue(child, kIOHIDEventFieldDigitizerIndex)
            local touch = IOHIDEventGetIntegerValue(child, kIOHIDEventFieldDigitizerTouch)
            local x = IOHIDEventGetFloatValue(child, kIOHIDEventFieldDigitizerX) * scr_w
            local y = IOHIDEventGetFloatValue(child, kIOHIDEventFieldDigitizerY) * scr_h
            sys_set_pose(touch == 1 and 0 or 1, fid, x, y, front_orien)
        end
    end)

exit_callback_handle = notification_center_register_callback({
        center = "darwin",
        name = "xxtouch.uiservice-show-pose-service-exit",
    },
    function()
        exit_callback_handle:release()
        os.exit(0)
    end)

CFRunLoopRunWithAutoreleasePool()
