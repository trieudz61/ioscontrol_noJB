--[[

	兼容触摸精灵和 XXTouchNG 的 UDP 发现服务

	本文件仅作为参考，请不要修改本文件
	本文件会在重装、更新时被原版覆盖

--]]

local socket = require('socket')

local udpserver_ng = socket.udp4()
udpserver_ng:settimeout(0)
udpserver_ng:setsockname('*', 14099) -- XXTouchNG
print(udpserver_ng, udpserver_ng:getfd())
udpserver_ng_source_handle = dispatch_source_register_callback("read", udpserver_ng:getfd(), 0, function()
	local res, ip, port = udpserver_ng:receivefrom()
	if res then
		udpserver_ng:sendto('touchelf-' .. device.name(), ip, port)
		-- 	print('ng', ip, port, res)
		-- else
		-- 	print('ng ?')
	end
end)

local function _read_conf()
	local conf = json.decode(file.reads(XXT_CONF_FILE_NAME) or "")
	conf = (type(conf) == 'table') and conf or {}
	return conf
end

local conf = _read_conf()

if conf.touchelf_httpd then
	local udpserver_te = socket.udp4()
	udpserver_te:settimeout(0)
	udpserver_te:setsockname('*', 8001) -- TouchElf
	print(udpserver_te, udpserver_te:getfd())
	udpserver_te_source_handle = dispatch_source_register_callback("read", udpserver_te:getfd(), 0, function()
		local res, ip, port = udpserver_te:receivefrom()
		if res then
			udpserver_te:sendto('touchelf', ip, port)
			-- 	print('te', ip, port, res)
			-- else
			-- 	print('te ?')
		end
	end)
end

exit_callback_handle = notification_center_register_callback({
		center = "darwin",
		name = "xxtouch.touchelf-udpd-service/exit",
	},
	function()
		exit_callback_handle:release()
		os.exit(0)
	end)

CFRunLoopRunWithAutoreleasePool()
