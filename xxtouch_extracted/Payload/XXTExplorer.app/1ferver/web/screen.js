$(document).ready(function () {
  var ws_client, scr_scale, app_bar, edge_size, main_drawer, all_canvas, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, a = "local keycodemap = { [48] = { 0x07, 39}, [49] = { 0x07, 30}, [50] = { 0x07, 31}, [51] = { 0x07, 32}, [52] = { 0x07, 33}, [53] = { 0x07, 34}, [54] = { 0x07, 35}, [55] = { 0x07, 36}, [56] = { 0x07, 37}, [57] = { 0x07, 38}, [65] = { 0x07, 4}, [66] = { 0x07, 5}, [67] = { 0x07, 6}, [68] = { 0x07, 7}, [69] = { 0x07, 8}, [70] = { 0x07, 9}, [71] = { 0x07, 10}, [72] = { 0x07, 11}, [73] = { 0x07, 12}, [74] = { 0x07, 13}, [75] = { 0x07, 14}, [76] = { 0x07, 15}, [77] = { 0x07, 16}, [78] = { 0x07, 17}, [79] = { 0x07, 18}, [80] = { 0x07, 19}, [81] = { 0x07, 20}, [82] = { 0x07, 21}, [83] = { 0x07, 22}, [84] = { 0x07, 23}, [85] = { 0x07, 24}, [86] = { 0x07, 25}, [87] = { 0x07, 26}, [88] = { 0x07, 27}, [89] = { 0x07, 28}, [90] = { 0x07, 29}, [13] = { 0x07, 40}, [27] = { 0x07, 41}, [8] = { 0x07, 42}, [9] = { 0x07, 43}, [32] = { 0x07, 44}, [189] = { 0x07, 45}, [187] = { 0x07, 46}, [219] = { 0x07, 47}, [221] = { 0x07, 48}, [220] = { 0x07, 49}, [186] = { 0x07, 51}, [222] = { 0x07, 52}, [192] = { 0x07, 53}, [188] = { 0x07, 54}, [190] = { 0x07, 55}, [191] = { 0x07, 56}, [20] = { 0x07, 57}, [112] = { 0x07, 58}, [113] = { 0x07, 59}, [114] = { 0x07, 60}, [115] = { 0x07, 61}, [116] = { 0x07, 62}, [117] = { 0x07, 63}, [118] = { 0x07, 64}, [119] = { 0x07, 65}, [120] = { 0x07, 66}, [121] = { 0x07, 67}, [122] = { 0x07, 68}, [123] = { 0x07, 69}, [145] = { 0x07, 71}, [19] = { 0x07, 72}, [45] = { 0x07, 73}, [36] = { 0x07, 74}, [33] = { 0x07, 75}, [46] = { 0x07, 76}, [35] = { 0x07, 77}, [34] = { 0x07, 78}, [39] = { 0x07, 79}, [37] = { 0x07, 80}, [40] = { 0x07, 81}, [38] = { 0x07, 82}, [17] = { 0x07, 224}, [16] = { 0x07, 225}, [18] = { 0x07, 226}, [91] = { 0x07, 227}, [92] = { 0x07, 231}, [144] = { 0x07, 83}, [111] = { 0x07, 84}, [106] = { 0x07, 85}, [109] = { 0x07, 86}, [107] = { 0x07, 87}, [96] = { 0x07, 98}, [97] = { 0x07, 89}, [98] = { 0x07, 90}, [99] = { 0x07, 91}, [100] = { 0x07, 92}, [101] = { 0x07, 93}, [102] = { 0x07, 94}, [103] = { 0x07, 95}, [104] = { 0x07, 96}, [105] = { 0x07, 97}, [110] = { 0x07, 99}, } local d_btn = {} local websocket = require'websocket' local server = websocket.server.gcd.listen{ queue = 'main', protocols = { ['RC'] = function(ws) sys.toast('已经建立远程控制连接', {allow_screenshot = true}) local heartbeat_handle local function stop_timer() if heartbeat_handle then pcall(function() heartbeat_handle:release() end) heartbeat_handle = nil end end local function cleanup() stop_timer() for _, btn in ipairs(d_btn) do key.up(btn[1], btn[2]) end end local index = 5 heartbeat_handle = dispatch_source_register_callback('timer', 1000, 1000, function() if index <= 0 then cleanup() sys.toast('已断开远程控制连接', {allow_screenshot = true}) os.exit() end index = index - 1 pcall(function() ws:send(json.encode({mode = 'heart'})) end) end, 'main') ws:on_message(function(ws,message,opcode) if opcode == websocket.TEXT then local jobj = json.decode(message) if jobj then if jobj.mode == 'down' then touch.down(28,jobj.x,jobj.y) elseif jobj.mode == 'move' then touch.move(28,jobj.x,jobj.y) elseif jobj.mode == 'up' then touch.up(28) elseif jobj.mode == 'clipboard' then sys.toast(jobj.data, {allow_screenshot = true}) _old = jobj.data pasteboard.write(jobj.data) elseif jobj.mode == 'input' then local k = keycodemap[jobj.key] if k then key.press(k[1], k[2]) end elseif jobj.mode == 'input_down' then local k = keycodemap[jobj.key] if k then key.down(k[1], k[2]) end elseif jobj.mode == 'input_up' then local k = keycodemap[jobj.key] if k then for i = 1, #d_btn do if d_btn[i] == k then table.remove(d_btn, i) break end end key.up(k[1], k[2]) end elseif jobj.mode == 'home' then key.press(0x0C, 64) elseif jobj.mode == 'power' then key.press(0x0C, 48) elseif jobj.mode == 'quit' then cleanup() sys.toast('已断开远程控制连接', {allow_screenshot = true}) os.exit() elseif jobj.mode == 'heart' then index = 5 end end end end) ws:on_close(function() cleanup() sys.toast('已断开远程控制连接', {allow_screenshot = true}) os.exit() end) ws:on_error(function(_, err) cleanup() sys.toast('远程控制连接异常: '..tostring(err), {allow_screenshot = true}) os.exit() end) end }, port = 46968 } CFRunLoopRunWithAutoreleasePool()";
  var orig_w, orig_h, current_orien = 0;
  var default_screen_title, screen_title_element, set_screen_title, load_device_name;
  default_screen_title = "实时桌面",
    screen_title_element = $("#screen-title"),
    set_screen_title = function (title) {
      var safe_title = typeof title === "string" ? title.replace(/^\s+|\s+$/g, "") : "";
      screen_title_element.length && screen_title_element.text(safe_title || default_screen_title)
    },
    load_device_name = function () {
      $.post("/deviceinfo", "",
        function (resp) {
          var devname = "";
          0 == resp.code && resp.data && "string" == typeof resp.data.devname && (devname = resp.data.devname.replace(/^\s+|\s+$/g, "")),
            set_screen_title(devname || default_screen_title)
        },
        "json").error(function () {
          set_screen_title(default_screen_title)
        })
    },
    set_screen_title(default_screen_title),
    load_device_name(),
  $("#main-drawer a[href='./screen.html']").addClass("mdui-list-item-active"),
    ws_client = null,
    scr_scale = 1,
    all_canvas = document.getElementById("all_canvas"),
    app_bar = document.getElementsByClassName("mdui-appbar mdui-appbar-fixed")[0],
    main_drawer = document.getElementById("main-drawer"),
    all_canvas.style.cursor = "crosshair",
    document.oncontextmenu = new Function("event.returnValue=false;"),
    document.onselectstart = new Function("event.returnValue=false;"),
    e = null,
    edge_size = 5,
    rotateImage90 = function (image, degrees = 90) {
      // 创建canvas
      const canvas = document.createElement('canvas');
      const ctx = canvas.getContext('2d');

      // 计算旋转后的尺寸
      if (degrees === 90 || degrees === 270) {
        // 90度或270度旋转时，交换宽高
        canvas.width = image.height;
        canvas.height = image.width;
      } else {
        // 0度或180度旋转时，保持宽高
        canvas.width = image.width;
        canvas.height = image.height;
      }

      // 平移坐标系到中心
      ctx.translate(canvas.width / 2, canvas.height / 2);

      // 旋转画布
      ctx.rotate((degrees * Math.PI) / 180);

      // 绘制图片（调整绘制位置）
      ctx.drawImage(image, -image.width / 2, -image.height / 2);

      // 返回旋转后的图片
      return canvas.toDataURL();
    },
    f = function () {
      var orig_img;
      img_scale = scr_scale.toFixed(2);
      orig_img = new Image;
      if ("localhost" == document.domain || "127.0.0.1" == document.domain) {
        orig_img.src = "snapshot?ext=jpg&compress=0.7&zoom=1&t=" + (new Date).getTime().toString();
      } else {
        orig_img.src = "snapshot?ext=jpg&compress=0.00001&zoom=1&t=" + (new Date).getTime().toString();
      }
      orig_img.onload = function () {
        orig_w = orig_img.width;
        orig_h = orig_img.height;
        var rect = main_drawer.getBoundingClientRect();
        var drawer_real_width = rect.x + rect.width;
        drawer_real_width = drawer_real_width > 0 ? drawer_real_width : 0;
        var app_bar_real_height = app_bar.clientHeight;
        var width_spacing = drawer_real_width + edge_size * 2;
        var height_spacing = app_bar_real_height + edge_size * 2;
        if (current_orien != 0) {
          var omap = [0, 270, 90, 180];
          var rotated_img = new Image;
          rotated_img.src = rotateImage90(orig_img, omap[current_orien % 4]);
          rotated_img.onload = function () {
            var w, h;
            if (current_orien == 1 || current_orien == 2) {
              w = $(window).width() - width_spacing;
              scr_scale = w / rotated_img.width;
              h = rotated_img.height * scr_scale;
              if (h > $(window).height() - height_spacing) {
                h = $(window).height() - height_spacing;
                scr_scale = h / rotated_img.height;
                w = rotated_img.width * scr_scale;
              }
            } else {
              h = $(window).height() - height_spacing;
              scr_scale = h / rotated_img.height;
              w = rotated_img.width * scr_scale;
              if (w > $(window).width() - width_spacing) {
                w = $(window).width() - width_spacing;
                scr_scale = w / rotated_img.width;
                h = rotated_img.height * scr_scale;
              }
            }
            $("#all_canvas").attr("height", h),
              $("#all_canvas").attr("width", w),
              all_canvas.getContext("2d").drawImage(rotated_img, 0, 0, rotated_img.width, rotated_img.height, 0, 0, w, h),
              e = setTimeout(f, 10)
          }
          rotated_img.onerror = function () {
            e = setTimeout(f, 10)
          }
        } else {
          var w, h;
          h = $(window).height() - height_spacing;
          scr_scale = h / orig_img.height;
          w = orig_img.width * scr_scale;
          if (w > $(window).width() - width_spacing) {
            w = $(window).width() - width_spacing;
            scr_scale = w / orig_img.width;
            h = orig_img.height * scr_scale;
          }
          $("#all_canvas").attr("height", h),
            $("#all_canvas").attr("width", w),
            all_canvas.getContext("2d").drawImage(orig_img, 0, 0, orig_img.width, orig_img.height, 0, 0, w, h),
            e = setTimeout(f, 10)
        }
      },
        orig_img.onerror = function () {
          e = setTimeout(f, 10)
        }
    },
    unrotate_xy = function (x, y, orien) {
      switch (orien) {
        case 1:
          return { x: orig_w - y - 1, y: x }
        case 2:
          return { x: y, y: orig_h - x - 1 }
        case 3:
          return { x: orig_w - x - 1, y: orig_h - y - 1 }
        default:
          return { x: x, y: y }
      }
    },
    f(),
    $("#all_canvas").on("selectstart",
      function () {
        return !1
      }),
    $(document).on("touchmove",
      function (a) {
        a.preventDefault()
      }),
    g = !1,
    h = "ontouchstart" in window,
    i = h ? {
      down: "touchstart",
      move: "touchmove",
      up: "touchend",
      over: "touchstart",
      out: "touchcancel"
    } : {
      down: "mousedown",
      move: "mousemove",
      up: "mouseup",
      over: "mouseover",
      out: "mouseout"
    },
    j = {
      start: function (x, y) {
        var pos = unrotate_xy(x / scr_scale, y / scr_scale, current_orien)
        ws_client.send(JSON.stringify({
          mode: "down",
          x: pos.x,
          y: pos.y
        }))
      },
      move: function (x, y) {
        var pos = unrotate_xy(x / scr_scale, y / scr_scale, current_orien)
        ws_client.send(JSON.stringify({
          mode: "move",
          x: pos.x,
          y: pos.y
        }))
      },
      end: function () {
        ws_client.send(JSON.stringify({
          mode: "up"
        }))
      },
      homebutton: function () {
        ws_client.send(JSON.stringify({
          mode: "home"
        }))
      },
      input: function (a) {
        ws_client.send(JSON.stringify({
          mode: "input",
          key: a
        }))
      },
      input_down: function (a) {
        console.log(a),
          ws_client.send(JSON.stringify({
            mode: "input_down",
            key: a
          }))
      },
      input_up: function (a) {
        console.log(a),
          ws_client.send(JSON.stringify({
            mode: "input_up",
            key: a
          }))
      }
    },
    $(document).on("keydown",
      function (a) {
        var b = a.keyCode || a.which || a.charCode;
        return a.ctrlKey || a.metaKey,
          j.input_down(b),
          a.returnValue = !1,
          a.preventDefault(),
          !1
      }),
    $(document).on("keyup",
      function (a) {
        var b = a.keyCode || a.which || a.charCode;
        return a.ctrlKey || a.metaKey,
          j.input_up(b),
          a.returnValue = !1,
          a.preventDefault(),
          !1
      }),
    $("#all_canvas").on(i.down,
      function (a) {
        var b, c;
        a.preventDefault(),
          b = (a.pageX || a.originalEvent.targetTouches[0].pageX) - this.offsetLeft,
          c = (a.pageY || a.originalEvent.targetTouches[0].pageY) - this.offsetTop,
          h ? (g = !0, j.start(b, c)) : 3 == a.which ? j.homebutton() : (g = !0, j.start(b, c))
      }),
    $("#all_canvas").on(i.move,
      function (a) {
        var b, c;
        a.preventDefault(),
          b = (a.pageX || a.originalEvent.targetTouches[0].pageX) - this.offsetLeft,
          c = (a.pageY || a.originalEvent.targetTouches[0].pageY) - this.offsetTop,
          g && j.move(b, c)
      }),
    $("#all_canvas").on(i.up,
      function (a) {
        a.preventDefault(),
          g && (g = !1, j.end())
      }),
    $("#all_canvas").on(i.out,
      function (a) {
        a.preventDefault(),
          g && (g = !1, j.end())
      }),
    $(window).unload(function () {
      ws_client && ws_client.onclose()
    }),
    $("#home").on("click",
      function () {
        ws_client.send(JSON.stringify({
          mode: "home"
        }))
      }),
    $("#power").on("click",
      function () {
        ws_client.send(JSON.stringify({
          mode: "power"
        }))
      }),
    $("#rotate_turn_left").on("click", function () {
      var turn_left_orien_map = [1, 3, 0, 2];
      current_orien = turn_left_orien_map[current_orien % 4];
      clearTimeout(e);
      f();
    }),
    k = !0,
    l = null,
    m = null,
    n = function () {
      l && clearTimeout(l),
        l = setTimeout(function () {
          clearInterval(m),
            ws_client.onclose(),
            clearTimeout(e),
            mdui.dialog({
              title: "远控连接已断开",
              content: "请等待服务恢复后重新建立连接",
              buttons: [{
                text: "重新连接",
                onClick: function () {
                  k = !0,
                    s()
                }
              }, {
                text: "WebRTC 远控",
                onClick: function (inst) {
                  inst.close();
                  setTimeout(function () {
                    window.location.href = "./webrtc/";
                  }, 100);
                }
              }]
            })
        },
          1e4)
    },
    o = function () {
      m = setInterval(function () {
        ws_client.send(JSON.stringify({
          mode: "heart"
        }))
      },
        1e4)
    },
    p = function (a) {
      var c = JSON.parse(a.data);
      "heart" == c["mode"] && (n(), ws_client.send(JSON.stringify({
        mode: "heart"
      })))
    },
    q = function () {
      k ? (k = !1, r()) : mdui.snackbar({
        message: "远控连接已断开"
      })
    },
    r = function () {
      $.post("/write_file", JSON.stringify({
        filename: "/bin/screen.lua",
        data: Base64.encode(a)
      }),
        function () {
          $.post("/daemon_spawn", "{\"filename\":\"/var/mobile/Media/1ferver/bin/screen.lua\"}",
            function () {
              setTimeout(function () {
                ws_client = new WebSocket("ws://" + document.domain + ":46968", "RC");
                try {
                  ws_client.onopen = o,
                    ws_client.onmessage = p,
                    ws_client.onclose = q
                } catch (a) {
                  console.log(a)
                }
              },
                1e3)
            },
            "json").error(function () {
              mdui.snackbar({
                message: "与设备通讯无法达成"
              })
            })
        },
        "json").error(function () {
          mdui.snackbar({
            message: "与设备通讯无法达成"
          })
        })
    },
    s = function () {
      ws_client = new WebSocket("ws://" + document.domain + ":46968", "RC");
      try {
        ws_client.onopen = o,
          ws_client.onmessage = p,
          ws_client.onclose = q
      } catch (a) {
        console.log(a)
      }
    },
    s()
});
