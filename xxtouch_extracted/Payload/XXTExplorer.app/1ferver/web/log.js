$(document).ready(function () {
  $("#main-drawer a[href='./log.html']").addClass("mdui-list-item-active");
  $("#logTextArea").height(($(window).height() - 270));
  $(window).resize(function () {
    $("#logTextArea").height(($(window).height() - 270))
  });
  var logTextArea = document.getElementById("logTextArea");
  var statusLabel = $("#statusLabel");
  var pauseBtn = $("#pauseBtn");

  var maxLogLength = 1024 * 1024 * 8; // 定义最大日志长度为 8MB
  var trimAmount = 1024 * 1024 * 4;   // 超过时，从开头截掉 4MB

  function setWSStatus(status) {
    statusLabel.text(status)
  }
  function appendLog(message) {
    // 当日志长度超过最大值时，从开头截断一部分，为新日志腾出空间
    if (logTextArea.value.length > maxLogLength) {
      // 为了避免切断半行，我们找到截断点后的第一个换行符
      var cutPoint = logTextArea.value.indexOf('\n', trimAmount);
      var startIndex = (cutPoint !== -1) ? cutPoint + 1 : trimAmount;
      logTextArea.value = logTextArea.value.substring(startIndex);
    }

    // 使用 setRangeText 在末尾追加新消息
    logTextArea.setRangeText(message, logTextArea.value.length, logTextArea.value.length, "end");

    logTextArea.scrollTop = logTextArea.scrollHeight
  }
  function normalizeLogMessage(message) {
    if (!message) {
      return "";
    }
    return message.charAt(message.length - 1) === "\n" ? message : (message + "\n");
  }
  var sseUri = "/api/log/stream";
  var eventSource = null;
  var paused = false;
  var lastErrorTime = 0;
  $("#clearLogs").click(function () {
    logTextArea.value = ""
  });
  $("#pauseBtn").click(function () {
    paused = !paused;
    if (paused) {
      stopEventSource();
      pauseBtn.removeClass("mdui-xxtouch-button");
      pauseBtn.addClass("mdui-xxtouch-color");
      pauseBtn.html("<i class='mdui-icon material-icons'>&#xe037;</i>继续接收")
    } else {
      initEventSource();
      pauseBtn.removeClass("mdui-xxtouch-color");
      pauseBtn.addClass("mdui-xxtouch-button");
      pauseBtn.html("<i class='mdui-icon material-icons'>&#xe034;</i>暂停接收")
    }
  });
  function initEventSource() {
    if (typeof EventSource === "undefined") {
      setWSStatus("浏览器不支持日志流")
      return;
    }
    if (eventSource) {
      eventSource.close();
      eventSource = null;
    }
    var opened = false;
    try {
      eventSource = new EventSource(sseUri);
      eventSource.onopen = function () {
        opened = true;
        setWSStatus("日志服务已连接")
      };
      eventSource.onmessage = function (evt) {
        appendLog(normalizeLogMessage(evt.data))
      };
      eventSource.onerror = function () {
        lastErrorTime = new Date().getTime();
        if (!opened && !paused) {
          setWSStatus("等待设备初始化日志服务……")
        }
      };
    } catch (exception) {
      lastErrorTime = new Date().getTime();
      setWSStatus("日志服务初始化失败")
    }
  }
  function stopEventSource() {
    if (eventSource) {
      eventSource.close();
      eventSource = null;
    }
  }
  function checkSocket() {
    if (eventSource != null) {
      appendLog("EventSource state = " + eventSource.readyState)
    } else {
      appendLog("EventSource is null")
    }
  }
  function while_check() {
    if (!paused) {
      if (eventSource == null || eventSource.readyState === 2) {
        setWSStatus("等待设备初始化日志服务……");
        initEventSource()
      } else if (eventSource.readyState === 1) {
        setWSStatus("日志服务已连接")
      } else {
        setWSStatus("等待设备初始化日志服务……")
      }
    } else {
      setWSStatus("暂停获取日志")
    }
    if (lastErrorTime != 0) {
      lastErrorTime = 0;
      setTimeout(while_check, 10000)
    } else {
      setTimeout(while_check, 1000)
    }
  }
  $(document).ready(function () {
    while_check()
  })
});
