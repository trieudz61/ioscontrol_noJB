var cc_client,
  ccServerPath = "/var/mobile/Media/1ferver/bin/web-cc.lua",
  strVar = "";

strVar += "local CC\n",
  strVar += "do\n",
  strVar += "	CC = {\n",
  strVar += "		sever_ip = (function()\n",
  strVar += "			local args = proc_take('spawn_args')\n",
  strVar += "			proc_put('spawn_args', args)\n",
  strVar += "			local args_json = json.decode(args)\n",
  strVar += "			return (type(args_json) == 'table' and args_json['server_ip']) or \"\"\n",
  strVar += "		end)(),\n",
  strVar += "		sever_port = 46969,\n",
  strVar += "		timeout = 3,\n",
  strVar += "		log = (function()\n",
  strVar += "			local log_table = {}\n",
  strVar += "			return function(message)\n",
  strVar += "				if type(message) == 'string' then\n",
  strVar += '					--[[传递字符串按照 "日志"]]\n',
  strVar += "					log_table['日志'] = message\n",
  strVar += "				elseif type(message) == 'table' then\n",
  strVar += "					--[[传递table 则根据内容进行写入临时表]]\n",
  strVar += "					for key, value in pairs(message) do\n",
  strVar += "						log_table[key] = value\n",
  strVar += "					end\n",
  strVar += "				else\n",
  strVar += "					--[[其它内容直接跳否定]]\n",
  strVar += "					return false\n",
  strVar += "				end\n",
  strVar += '				local websocket = require("websocket")\n',
  strVar += "				local wsc = websocket.client.new({timeout=CC.timeout})\n",
  strVar += "				local ok, err = wsc:connect(\n",
  strVar += "					string.format('ws://%s:%s',CC.sever_ip,CC.sever_port),\n",
  strVar += "					'XXTouch-CC-Client'\n",
  strVar += "				)\n",
  strVar += "				if not ok then\n",
  strVar += "					return false\n",
  strVar += "				else\n",
  strVar += "					local ok, was_clean, code, reason = wsc:send(\n",
  strVar += "						json.encode(\n",
  strVar += "							{\n",
  strVar += '								method = "log",\n',
  strVar += "								deviceid = device.udid(),\n",
  strVar += "								message = log_table\n",
  strVar += "							}\n",
  strVar += "						)\n",
  strVar += "					)\n",
  strVar += "					wsc:close()\n",
  strVar += "					return ok\n",
  strVar += "				end\n",
  strVar += "			end\n",
  strVar += "		end)(),\n",
  strVar += "		run = (function(lua_script,timeout)\n",
  strVar += '			local websocket = require("websocket")\n',
  strVar += "			local wsc = websocket.client.new({timeout = timeout or CC.timeout})\n",
  strVar += "			local ok, err = wsc:connect(\n",
  strVar += "				string.format('ws://%s:%s',CC.sever_ip,CC.sever_port),\n",
  strVar += "				'XXTouch-CC-Client'\n",
  strVar += "			)\n",
  strVar += "			if not ok then\n",
  strVar += "				return false\n",
  strVar += "			else\n",
  strVar += "				local ok, was_clean, code, reason = wsc:send(\n",
  strVar += "					json.encode(\n",
  strVar += "						{\n",
  strVar += '							method = "run",\n',
  strVar += "							lua_script = lua_script\n",
  strVar += "						}\n",
  strVar += "					)\n",
  strVar += "				)\n",
  strVar += "				local message, opcode, was_clean, code, reason = wsc:receive()\n",
  strVar += "				wsc:close()\n",
  strVar += "				if message then\n",
  strVar += "					local r_t = json.decode(message)\n",
  strVar += "					if r_t then return r_t.success end\n",
  strVar += "				end\n",
  strVar += "				return false\n",
  strVar += "			end\n",
  strVar += "		end),\n",
  strVar += "		file = {\n",
  strVar += "			_WebSocket_File = (function(t, timeout)\n",
  strVar += '				local websocket = require("websocket")\n',
  strVar += "				local wsc = websocket.client.new({timeout = timeout or CC.timeout})\n",
  strVar += "				local ok, err = wsc:connect(\n",
  strVar += "					string.format('ws://%s:%s',CC.sever_ip,CC.sever_port),\n",
  strVar += "					'XXTouch-CC-Client'\n",
  strVar += "				)\n",
  strVar += "				if not ok then\n",
  strVar += "					return false\n",
  strVar += "				else\n",
  strVar += "					local ok, was_clean, code, reason = wsc:send(\n",
  strVar += "						json.encode(t)\n",
  strVar += "					)\n",
  strVar += "					local message, opcode, was_clean, code, reason = wsc:receive()\n",
  strVar += '					nLog("rcve", message, opcode, was_clean, code, reason)\n',
  strVar += "					wsc:close()\n",
  strVar += "					return message\n",
  strVar += "				end\n",
  strVar += "			end),\n",
  strVar += "			exists = function(path, timeout)\n",
  strVar += '				local r = CC.file._WebSocket_File({method="file.exists",path=path}, timeout)\n',
  strVar += "				if not r then return false end\n",
  strVar += "				local r_t = json.decode(r)\n",
  strVar += "				if r_t and r_t.exists then\n",
  strVar += "					return r_t.mode\n",
  strVar += "				else\n",
  strVar += "					return nil\n",
  strVar += "				end\n",
  strVar += "			end,\n",
  strVar += "			take = function(path, timeout)\n",
  strVar += '				local r = CC.file._WebSocket_File({method="file.take",path=path}, timeout)\n',
  strVar += "				if not r then return false end\n",
  strVar += "				local r_t = json.decode(r)\n",
  strVar += "				if r_t and r_t.exists then\n",
  strVar += "					return r_t.data:from_hex()\n",
  strVar += "				else\n",
  strVar += "					return nil\n",
  strVar += "				end\n",
  strVar += "			end,\n",
  strVar += "			reads = function(path, timeout)\n",
  strVar += '				local r = CC.file._WebSocket_File({method="file.reads",path=path}, timeout)\n',
  strVar += "				if not r then return false end\n",
  strVar += "				local r_t = json.decode(r)\n",
  strVar += "				if r_t and r_t.exists then\n",
  strVar += "					return r_t.data:from_hex()\n",
  strVar += "				else\n",
  strVar += "					return nil\n",
  strVar += "				end\n",
  strVar += "			end,\n",
  strVar += "			writes = function(path, data, timeout)\n",
  strVar += '				local r = CC.file._WebSocket_File({method="file.writes",data=data:to_hex(),path=path}, timeout)\n',
  strVar += "				if not r then return false end\n",
  strVar += "				local r_t = json.decode(r)\n",
  strVar += "				if r_t and r_t.success then\n",
  strVar += "					return true\n",
  strVar += "				else\n",
  strVar += "					return nil\n",
  strVar += "				end\n",
  strVar += "			end,\n",
  strVar += "			appends = function(path, data, timeout)\n",
  strVar += '				local r = CC.file._WebSocket_File({method="file.appends",data=data:to_hex(),path=path}, timeout)\n',
  strVar += "				if not r then return false end\n",
  strVar += "				local r_t = json.decode(r)\n",
  strVar += "				if r_t and r_t.success then\n",
  strVar += "					return true\n",
  strVar += "				else\n",
  strVar += "					return nil\n",
  strVar += "				end\n",
  strVar += "			end,\n",
  strVar += "		}\n",
  strVar += "	}\n",
  strVar += "end\n",
  strVar += "--[=[\n",
  strVar += '	CC.log("内容")\n',
  strVar += "	\n",
  strVar += '	CC.log({["标题"] = "内容"})\n',
  strVar += "	\n",
  strVar += '	local b = CC.run("print(12312313)")\n',
  strVar += "	if b == false then --[[通讯超时]] end\n",
  strVar += "	\n",
  strVar += '	local b = CC.file.exists("临时文件.txt")\n',
  strVar += "	if b then\n",
  strVar += '		--[[ b 为类型 "file" 或者 "directory" ]]\n',
  strVar += "	elseif b == false then\n",
  strVar += "		--[[通讯超时]]\n",
  strVar += "	elseif b == nil then\n",
  strVar += "		--[[文件不存在]]\n",
  strVar += "	end\n",
  strVar += "	\n",
  strVar += '	local b = CC.file.take("临时文件.txt")\n',
  strVar += "	if b then\n",
  strVar += "		--[[ b 第一行的内容 ]]\n",
  strVar += "	elseif b == false then\n",
  strVar += "		--[[通讯超时]]\n",
  strVar += "	elseif b == nil then\n",
  strVar += "		--[[文件不存在]]\n",
  strVar += "	end\n",
  strVar += "	\n",
  strVar += "	\n",
  strVar += '	local b = CC.file.reads("临时文件.txt")\n',
  strVar += "	if b then\n",
  strVar += "		--[[ b 文件的内容 ]]\n",
  strVar += "	elseif b == false then\n",
  strVar += "		--[[通讯超时]]\n",
  strVar += "	elseif b == nil then\n",
  strVar += "		--[[文件不存在]]\n",
  strVar += "	end\n",
  strVar += "	\n",
  strVar += "	local b = CC.file.writes(\"临时文件.txt\",'测试内容\\r\\n测试内容2')\n",
  strVar += "	if b then\n",
  strVar += "		--[[写入成功]]\n",
  strVar += "	elseif b == false then\n",
  strVar += "		--[[通讯超时或失败]]\n",
  strVar += "	end\n",
  strVar += "	\n",
  strVar += "	local b = CC.file.appends(\"临时文件.txt\",'测试内容\\r\\n测试内容2')\n",
  strVar += "	if b then\n",
  strVar += "		--[[写入成功]]\n",
  strVar += "	elseif b == false then\n",
  strVar += "		--[[通讯超时或失败]]\n",
  strVar += "	end\n",
  strVar += "--]=]\n",
  strVar += "\n",
  cc_client = strVar,
  $(document).ready(function () {
    function getCurrentTimestampString() {
      const now = new Date();
      const year = now.getFullYear();
      // getMonth() 返回 0-11，所以需要 +1
      const month = (now.getMonth() + 1).toString().padStart(2, '0');
      const day = now.getDate().toString().padStart(2, '0');
      const hours = now.getHours().toString().padStart(2, '0');
      const minutes = now.getMinutes().toString().padStart(2, '0');
      const seconds = now.getSeconds().toString().padStart(2, '0');
      const milliseconds = now.getMilliseconds().toString().padStart(3, '0');
      return `${year}${month}${day}${hours}${minutes}${seconds}${milliseconds}`;
    }
    function toFixedLengthHexStringES5(number, length) {
      var hexString = number.toString(16);
      while (hexString.length < length) {
        hexString = '0' + hexString;
      }
      return hexString;
    }
    function a(a) {
      var d, c = "";
      for (d = 0; d < a.length; d++) c += b(a.charCodeAt(d).toString(16), 2);
      return c
    }
    function b(a, b) {
      for (var c = a.toString().length; b > c;) a = "0" + a,
        c++;
      return a
    }
    function c(a) {
      var b = document.createEvent("MouseEvents");
      b.initMouseEvent("click", !0, !1, window, 0, 0, 0, 0, 0, !1, !1, !1, !1, 0, null),
        a.dispatchEvent(b)
    }
    function d(a, b) {
      var d = window.URL || window.webkitURL || window,
        e = new Blob([b]),
        f = document.createElementNS("http://www.w3.org/1999/xhtml", "a");
      f.href = d.createObjectURL(e),
        f.download = a,
        c(f)
    }
    var e, f, g, h, i, k, l, m, n, o, p, q, r, s, t, u, v;
    $("#main-drawer a[href='./cc.html']").addClass("mdui-list-item-active"),
      e = "",
      f = "",
      g = !1,
      h = document.domain,
      i = new Array,
      new Array,
      k = function () {
        var a = new Array;
        return $.each($("#devices tbody tr"),
          function (b, c) {
            c.classList.contains("mdui-table-row-selected") && a.push(c.cells[3].innerHTML)
          }),
          a
      },
      l = function () {
        var a = new Array;
        return $.each($("#devices tbody tr"),
          function (b, c) {
            c.classList.contains("mdui-table-row-selected") && a.push(c.cells[4].innerHTML)
          }),
          a
      },
      listNewUDIDs = function () {
        var a = new Array;
        return $.each($("#devices tbody tr"),
          function (b, c) {
            c.classList.contains("mdui-table-row-selected") && a.push(c.cells[6].innerHTML)
          }),
          a
      },
      m = new mdui.Dialog("#dialog_dropbox"),
      n = new mdui.Dialog("#dialog_auth"),
      o = document.getElementById("dropbox"),
      document.addEventListener("dragenter",
        function () {
          o.style.borderColor = "gray"
        },
        !1),
      document.addEventListener("dragleave",
        function () {
          o.style.borderColor = "silver"
        },
        !1),
      o.addEventListener("dragenter",
        function () {
          o.style.borderColor = "gray",
            o.style.backgroundColor = "white"
        },
        !1),
      o.addEventListener("dragleave",
        function () {
          o.style.backgroundColor = "transparent"
        },
        !1),
      o.addEventListener("dragenter",
        function (a) {
          a.stopPropagation(),
            a.preventDefault()
        },
        !1),
      o.addEventListener("dragover",
        function (a) {
          a.stopPropagation(),
            a.preventDefault()
        },
        !1),
      o.addEventListener("drop",
        function (a) {
          a.stopPropagation(),
            a.preventDefault(),
            p(a.dataTransfer.files)
        },
        !1),
      p = function (b) {
        var g, c = b[0];
        c.size > 31457280 ? mdui.alert("请控制脚本在30M以内") : (g = new FileReader, g.readAsBinaryString(c), g.onload = function () {
          f = a(g.result),
            e = c.name,
            $("#scriptname").html(c.name)
        })
      },
      $("#cc_api").attr("data-clipboard-text", cc_client),
      $("#search").on("click",
        function () {
          s({
            method: "search"
          })
        }),
      $("#spawn").on("click",
        function () {
          $("#dialog_dropbox").find("button").off("click"),
            $("#dialog_dropbox").find("button").on("click",
              function () {
                s({
                  method: "spawn",
                  deviceid: k(),
                  args: {
                    server_ip: document.domain
                  },
                  script_hex: f
                })
              }),
            m.open()
        }),
      $("#recycle").on("click",
        function () {
          s({
            method: "recycle",
            deviceid: k()
          })
        }),
      $("#send_file").on("click",
        function () {
          $("#dialog_dropbox").find("button").off("click"),
            $("#dialog_dropbox").find("button").on("click",
              function () {
                var b = {
                  method: "send_file",
                  deviceid: k(),
                  file: {},
                  path: "/lua/scripts"
                };
                b.file[e] = f,
                  s(b)
              }),
            m.open()
        }),
      $("#detect_auth").on("click",
        function () {
          s({
            method: "detect.auth",
            deviceid: k()
          })
        }),
      $("#dialog_auth_cancel").on("click",
        function () {
          n.close()
        }),
      $("#auth").on("click",
        function () {
          $("#dialog_auth_submit").off("click"),
            $("#dialog_auth_submit").on("click",
              function () {
                var b = new Array;
                $("#auth-code").val().trim().split("\n").forEach(function (a) {
                  b.push(a)
                }),
                  s({
                    method: "auth",
                    mustbeless: $("#mustbeless").is(":checked"),
                    deviceid: k(),
                    code: b
                  }),
                  n.close()
              }),
            n.open()
        }),
      $("#clear_log").on("click",
        function () {
          s({
            method: "clear.log",
            deviceid: k()
          })
        }),
      q = new Clipboard(".cptext"),
      q.on("success",
        function () {
          mdui.snackbar({
            message: "复制成功"
          })
        }),
      q.on("error",
        function () {
          mdui.snackbar({
            message: "复制失败，请手动复制"
          })
        }),
      s = function (a) {
        r.send(JSON.stringify(a))
      },
      setInterval(function () {
        g && s({
          method: "getlog"
        })
      },
        500),
      $("#run_cc").on("click",
        function () {
          v()
        }),
      t = {},
      u = function () {
        r = new WebSocket("ws://" + h + ":46969", "XXTouch-CC-Web");
        try {
          r.onopen = function () {
            s({
              method: "search"
            }),
              $("#button_text").html("&#xe047;"),
              $("#run_cc").attr("mdui-tooltip", "{content: '停止服务'}"),
              g = !0
          },
            r.onmessage = function (a) {
              var b = JSON.parse(a.data);
              switch (b.method) {
                case "devices":
                  i = b.devices,
                    $("#devices tbody").empty(),
                    $.each(b.devices,
                      function (a, b) {
                        var d, c = $("<tr></tr>");
                        b.check && c.addClass("mdui-table-row-selected"),
                          c.append($('<td class="mdui-table-cell-checkbox"><label class="mdui-checkbox"><input type="checkbox"><i class="mdui-checkbox-icon"></i></label></td>'), $("<td>" + b.devname + "</td>"), $("<td>" + b.ip + "</td>"), $('<td style="display:none;">' + b.deviceid + "</td>"), $('<td style="display:none;">' + b.devsn + "</td>"), $("<td>" + b.state + "</td>"), $('<td style="display:none;">' + toFixedLengthHexStringES5(b.chipid || 0, 8) + "-" + toFixedLengthHexStringES5(((b.chipid || 0) != 0) ? (b.ecid || 0) : 0, 16) + "</td>")),
                          $.each(t,
                            function (a) {
                              b.log[a] ? c.append($("<td>" + b.log[a] + "</td>")) : c.append($("<td></td>"))
                            }),
                          $.each(b.log,
                            function (a) {
                              t[a] || (t[a] = !0, c.append($("<td>" + b.log[a] + "</td>")), $("#devices thead tr").append($("<th>" + a + "</th>")))
                            }),
                          $("#devices tbody").append(c),
                          mdui.updateTables(),
                          d = "",
                          $.each(k(),
                            function (a, b) {
                              d += b + "\r\n"
                            }),
                          $("#cp_deviceid").attr("data-clipboard-text", d),
                          d = "",
                          $.each(l(),
                            function (a, b) {
                              d += b + "\r\n"
                            }),
                          $("#cp_devsn").attr("data-clipboard-text", d),
                          d = "",
                          $.each(listNewUDIDs(),
                            function (a, b) {
                              d += b + "\r\n"
                            }),
                          $("#cp_newudid").attr("data-clipboard-text", d),
                          $("input").off("change"),
                          $("input").on("change",
                            function () {
                              var b, a = new Array;
                              $.each($("#devices tbody tr"),
                                function (b, c) {
                                  c.classList.contains("mdui-table-row-selected") && a.push(c.cells[3].innerHTML)
                                }),
                                s({
                                  method: "check_devices",
                                  deviceid: a
                                }),
                                b = "",
                                $.each(k(),
                                  function (a, c) {
                                    b += c + "\r\n"
                                  }),
                                $("#cp_deviceid").attr("data-clipboard-text", b),
                                b = "",
                                $.each(l(),
                                  function (a, c) {
                                    b += c + "\r\n"
                                  }),
                                $("#cp_devsn").attr("data-clipboard-text", b),
                                b = "",
                                $.each(listNewUDIDs(),
                                  function (a, c) {
                                    b += c + "\r\n"
                                  }),
                                $("#cp_newudid").attr("data-clipboard-text", b)
                            })
                      });
                  break;
                case "log":
                  $.each(b.devices,
                    function (a, b) {
                      i[a] && (i[a].state = b.state, i[a].log = b.log)
                    }),
                    $.each($("#devices tbody tr"),
                      function (a, b) {
                        var d, e, c = b.cells[3].innerText;
                        i[c] && (b.cells[5].innerHTML = i[c].state, d = i[c], e = 6, $.each(t,
                          function (a) {
                            b.cells.length <= e && $(b).append($("<td>" + a + "</td>")),
                              b.cells[e].innerHTML = d.log[a] ? d.log[a] : "",
                              e += 1
                          }), $.each(d.log,
                            function (a) {
                              t[a] || (t[a] = !0, $(b).append($("<td>" + d.log[a] + "</td>")), $("#devices thead tr").append($("<th>" + a + "</th>")))
                            }))
                      });
                  break;
                case "web_log":
                  switch (b.type) {
                    case "message":
                      mdui.dialog({
                        title:
                          b.title,
                        content: '<textarea class="mdui-center" style="margin:0 auto;width: 95%;height: 500px;">' + b.message + "</textarea>",
                        buttons: [{
                          text: "保存",
                          onClick: function () {
                            d("activations_" + getCurrentTimestampString() + ".log", b.message)
                          }
                        },
                        {
                          text: "确认"
                        }]
                      });
                      break;
                    case "success":
                      mdui.snackbar({
                        message:
                          b.message
                      });
                      break;
                    case "error":
                      mdui.dialog({
                        title:
                          "错误",
                        content: b.message,
                        buttons: [{
                          text: "确认"
                        }]
                      })
                  }
              }
            },
            r.onclose = function () {
              $("#button_text").html("&#xe037;"),
                $("#devices tbody").empty(),
                $("#run_cc").attr("mdui-tooltip", "{content: '启动服务'}"),
                g = !1,
                mdui.snackbar({
                  message: "服务未开启，点页面右上角的箭头可启动服务"
                })
            }
        } catch (a) {
          $("#button_text").html("&#xe037;"),
            $("#devices tbody").empty(),
            $("#run_cc").attr("mdui-tooltip", "{content: '启动服务'}"),
            g = !1,
            mdui.snackbar({
              message: "服务未开启，点页面右上角的箭头可启动服务"
            })
        }
      },
      v = function () {
        if (g) {
          s({
            method: "quit"
          }),
            $("#devices tbody").empty(),
            g = !1,
            $("#button_text").html("&#xe037;"),
            $("#run_cc").attr("mdui-tooltip", "{content: '启动服务'}");
          return;
        }
        $.post("/daemon_spawn", JSON.stringify({
          filename: ccServerPath
        }),
          function () {
            setTimeout(u, 1e3)
          },
          "json").error(function () {
            mdui.snackbar({
              message: "与设备通讯无法达成"
            })
          })
      },
      u()
  });
