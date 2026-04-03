// ═══════════════════════════════════════════
// IOSControl Web IDE — Neon Glass Theme
// Lucide Icons + Glassmorphism
// ═══════════════════════════════════════════

(function () {
  "use strict";

  // ─── Lucide SVG strings (inline for runtime icon swaps) ───
  var LUCIDE = {
    'alert-circle': '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>',
    'check-circle': '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/></svg>',
    'info': '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/></svg>',
    'pause': '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="4" height="16" x="6" y="4"/><rect width="4" height="16" x="14" y="4"/></svg>',
    'play': '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="5 3 19 12 5 21 5 3"/></svg>',
    'home': '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8"/><path d="M3 10a2 2 0 0 1 .709-1.528l7-5.999a2 2 0 0 1 2.582 0l7 5.999A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>',
  };

  // ─── Config ───
  var config = {
    quality: 70,
    interval: 100,
    logInterval: 2000,
    tapDelay: 0,
    showTouchIndicator: true,
  };

  // ─── State ───
  var state = {
    pointsW: 0,
    pointsH: 0,
    imgW: 0,
    imgH: 0,
    scrScale: 1,
    origW: 0,
    origH: 0,
    rotation: 0,
    dragging: false,
    dragStartX: 0,
    dragStartY: 0,
    dragMoved: false,
    lastMoveTime: 0,
    lastMoveX: 0,
    lastMoveY: 0,
    screenTimer: null,
    logTimer: null,
    logPaused: false,
    activeTab: "screen",
    connected: false,
    lastLog: "",
    frameCount: 0,
    fpsTimer: null,
    lastFpsTime: 0,
    currentFps: 0,
    hasReceivedFrame: false,
    colorPickMode: false,
  };

  // ─── DOM Cache ───
  var $ = function (id) {
    return document.getElementById(id);
  };
  var canvas = $("screen-canvas");
  var ctx = canvas.getContext("2d");

  // ═══════════════════════════════════════════
  // Utility
  // ═══════════════════════════════════════════

  function snackbar(msg, type) {
    var el = $("snackbar");
    var textEl = $("snackbar-text");
    var iconEl = $("snackbar-icon");
    textEl.textContent = msg;

    el.className = "snackbar";

    if (type === "error") {
      iconEl.innerHTML = LUCIDE['alert-circle'];
      el.classList.add("error");
    } else if (type === "success") {
      iconEl.innerHTML = LUCIDE['check-circle'];
      el.classList.add("success");
    } else {
      iconEl.innerHTML = LUCIDE['info'];
    }

    el.classList.add("show");
    clearTimeout(el._timer);
    el._timer = setTimeout(function () {
      el.classList.remove("show");
    }, 3000);
  }

  function apiGet(path, cb) {
    var xhr = new XMLHttpRequest();
    xhr.open("GET", path);
    xhr.timeout = 5000;
    xhr.onload = function () {
      if (xhr.status === 200) {
        try {
          cb(null, JSON.parse(xhr.responseText));
        } catch (e) {
          cb(null, xhr.responseText);
        }
      } else {
        cb(xhr.statusText);
      }
    };
    xhr.onerror = function () { cb("network error"); };
    xhr.ontimeout = function () { cb("timeout"); };
    xhr.send();
  }

  function apiPost(path, data, cb) {
    var xhr = new XMLHttpRequest();
    xhr.open("POST", path);
    xhr.setRequestHeader("Content-Type", "application/json");
    xhr.timeout = 5000;
    xhr.onload = function () {
      if (cb) {
        try { cb(null, JSON.parse(xhr.responseText)); }
        catch (e) { cb(null, xhr.responseText); }
      }
    };
    xhr.onerror = function () { if (cb) cb("network error"); };
    xhr.send(JSON.stringify(data));
  }

  function logMsg(msg) { console.log(msg); }

  // ═══════════════════════════════════════════
  // Loading Overlay
  // ═══════════════════════════════════════════

  function hideLoadingOverlay() {
    var el = $("loading-overlay");
    if (el) {
      el.classList.add("hidden");
      setTimeout(function () {
        if (el.parentNode) el.parentNode.removeChild(el);
      }, 600);
    }
  }

  setTimeout(hideLoadingOverlay, 3000);

  // ═══════════════════════════════════════════
  // Drawer Navigation
  // ═══════════════════════════════════════════

  var drawer = $("main-drawer");
  var overlay = $("drawer-overlay");

  function openDrawer() {
    drawer.classList.add("open");
    overlay.classList.add("open");
  }
  function closeDrawer() {
    drawer.classList.remove("open");
    overlay.classList.remove("open");
  }

  $("btn-menu").addEventListener("click", function () {
    drawer.classList.contains("open") ? closeDrawer() : openDrawer();
  });
  overlay.addEventListener("click", closeDrawer);

  var tabTitles = {
    screen: "Live Screen",
    script: "Script Editor",
    log: "Device Log",
    settings: "Settings",
    picker: "Color Picker",
    applist: "App List",
    devcontrol: "Device Control",
    apidocs: "API Docs",
    tplmaker: "Template Maker",
  };

  var tabActions = {
    screen: "screen-actions",
    log: "log-actions",
  };

  document.querySelectorAll(".drawer-item[data-tab]").forEach(function (item) {
    item.addEventListener("click", function () {
      var tab = this.getAttribute("data-tab");
      switchTab(tab);
      if (window.innerWidth < 960) closeDrawer();
    });
  });

  function switchTab(tab) {
    state.activeTab = tab;

    document.querySelectorAll(".drawer-item").forEach(function (el) {
      el.classList.remove("active");
    });
    var activeItem = document.querySelector('.drawer-item[data-tab="' + tab + '"]');
    if (activeItem) activeItem.classList.add("active");

    document.querySelectorAll(".tab-content").forEach(function (el) {
      el.classList.remove("active");
    });
    var tabEl = $("tab-" + tab);
    if (tabEl) tabEl.classList.add("active");

    $("toolbar-title").textContent = tabTitles[tab] || tab;

    document.querySelectorAll(".toolbar-actions").forEach(function (el) {
      el.classList.add("hidden");
    });
    if (tabActions[tab]) {
      $(tabActions[tab]).classList.remove("hidden");
    }

    var fab = $("fab-run");
    fab.classList.toggle("hidden", tab !== "script");

    if (tab === "screen") {
      startScreenCapture();
      startFPSCounter();
    } else {
      stopScreenCapture();
      stopFPSCounter();
    }

    if (tab === "log") {
      startLogPolling();
    } else {
      stopLogPolling();
    }

    // Lazy-load iframe tabs
    if (tabEl) {
      var iframe = tabEl.querySelector('iframe[data-src]');
      if (iframe && !iframe.src) {
        iframe.src = iframe.getAttribute('data-src');
        iframe.removeAttribute('data-src');
      }
    }
  }

  // ═══════════════════════════════════════════
  // Screen Capture
  // ═══════════════════════════════════════════

  function startScreenCapture() {
    stopScreenCapture();
    captureFrame();
  }

  function stopScreenCapture() {
    if (state.screenTimer) {
      clearTimeout(state.screenTimer);
      cancelAnimationFrame(state.screenTimer);
      state.screenTimer = null;
    }
    if (typeof stopScreenPoll === "function") stopScreenPoll();
    if (state.mjpegImg) {
      state.mjpegImg.src = "";
      if (state.mjpegImg.parentNode)
        state.mjpegImg.parentNode.removeChild(state.mjpegImg);
      state.mjpegImg = null;
    }
  }

  function drawImageToCanvas(img) {
    state.imgW = img.naturalWidth || img.width;
    state.imgH = img.naturalHeight || img.height;
    state.origW = state.imgW;
    state.origH = state.imgH;
    if (!state.pointsW) state.pointsW = state.imgW;
    if (!state.pointsH) state.pointsH = state.imgH;

    if (!state.hasReceivedFrame) {
      state.hasReceivedFrame = true;
      var ph = $("screen-placeholder");
      if (ph) ph.classList.add("hidden");
      hideLoadingOverlay();
    }

    var container = $("screen-container");
    var bottomBar = 32;
    var cw = container.clientWidth;
    var ch = container.clientHeight - bottomBar;
    var iw = state.imgW;
    var ih = state.imgH;

    if (state.rotation === 1 || state.rotation === 2) {
      var tmp = iw;
      iw = ih;
      ih = tmp;
    }

    var scale = Math.min(cw / iw, ch / ih, 1);
    state.scrScale = scale;

    var drawW = Math.floor(iw * scale);
    var drawH = Math.floor(ih * scale);
    canvas.width = drawW;
    canvas.height = drawH;

    if (state.rotation !== 0) {
      var rotMap = [0, 270, 90, 180];
      var deg = rotMap[state.rotation % 4];
      ctx.save();
      ctx.translate(drawW / 2, drawH / 2);
      ctx.rotate((deg * Math.PI) / 180);
      ctx.drawImage(
        img,
        (-state.imgW * scale) / 2,
        (-state.imgH * scale) / 2,
        state.imgW * scale,
        state.imgH * scale,
      );
      ctx.restore();
    } else {
      ctx.drawImage(img, 0, 0, drawW, drawH);
    }

    $("screen-resolution").textContent = state.origW + " x " + state.origH;
    state.frameCount++;
  }

  var screenPollImg = null;
  var screenPollRunning = false;

  function screenPollNext() {
    if (!screenPollRunning || state.activeTab !== "screen") {
      screenPollRunning = false;
      return;
    }
    screenPollImg = new Image();
    screenPollImg.src =
      "/api/screen?quality=" + (config.quality || 70) + "&t=" + Date.now();
    screenPollImg.onload = function () {
      drawImageToCanvas(screenPollImg);
      state.frameCount++;
      setTimeout(screenPollNext, config.interval || 100);
    };
    screenPollImg.onerror = function () {
      setTimeout(screenPollNext, 500);
    };
  }

  function captureFrame() { startScreenPoll(); }

  function startScreenPoll() {
    if (screenPollRunning) return;
    screenPollRunning = true;
    screenPollNext();
  }

  function stopScreenPoll() {
    screenPollRunning = false;
    screenPollImg = null;
  }

  // ═══════════════════════════════════════════
  // FPS Counter
  // ═══════════════════════════════════════════

  function startFPSCounter() {
    stopFPSCounter();
    state.frameCount = 0;
    state.lastFpsTime = Date.now();

    state.fpsTimer = setInterval(function () {
      var now = Date.now();
      var elapsed = (now - state.lastFpsTime) / 1000;
      if (elapsed > 0) {
        state.currentFps = Math.round(state.frameCount / elapsed);
        $("screen-fps").textContent = state.currentFps + " fps";
      }
      state.frameCount = 0;
      state.lastFpsTime = now;
    }, 1000);
  }

  function stopFPSCounter() {
    if (state.fpsTimer) {
      clearInterval(state.fpsTimer);
      state.fpsTimer = null;
    }
  }

  // ═══════════════════════════════════════════
  // Touch Control
  // ═══════════════════════════════════════════

  function unrotateXY(px, py) {
    var iw = state.imgW || state.pointsW || 1;
    var ih = state.imgH || state.pointsH || 1;
    var pw = state.pointsW || iw;
    var ph = state.pointsH || ih;
    var rx, ry;
    switch (state.rotation) {
      case 1: rx = iw - py - 1; ry = px; break;
      case 2: rx = py; ry = ih - px - 1; break;
      case 3: rx = iw - px - 1; ry = ih - py - 1; break;
      default: rx = px; ry = py; break;
    }
    return {
      x: Math.round((rx * pw) / iw),
      y: Math.round((ry * ph) / ih),
    };
  }

  function canvasToDevice(canvasX, canvasY) {
    var imgPx = canvasX / state.scrScale;
    var imgPy = canvasY / state.scrScale;
    return unrotateXY(imgPx, imgPy);
  }

  function showTouchRipple(canvasRelX, canvasRelY) {
    if (!config.showTouchIndicator) return;
    var container = $("screen-container");
    var containerRect = container.getBoundingClientRect();
    var canvasRect = canvas.getBoundingClientRect();
    var relX = canvasRect.left - containerRect.left + canvasRelX;
    var relY = canvasRect.top - containerRect.top + canvasRelY;
    var ripple = document.createElement("div");
    ripple.className = "touch-indicator";
    ripple.style.left = relX + "px";
    ripple.style.top = relY + "px";
    container.appendChild(ripple);
    setTimeout(function () {
      if (ripple.parentNode) ripple.parentNode.removeChild(ripple);
    }, 450);
  }

  var wsControl = null;
  var wsConnecting = false;
  var wsPendingQueue = [];
  var wsHeartbeatTimer = null;

  function wsSend(obj) {
    var msg = JSON.stringify(obj);
    if (wsControl && wsControl.readyState === WebSocket.OPEN) {
      wsControl.send(msg);
    } else {
      wsPendingQueue.push(msg);
      if (!wsConnecting) initControlWS();
    }
  }

  function initControlWS() {
    if (wsConnecting) return;
    wsConnecting = true;
    var proto = location.protocol === "https:" ? "wss:" : "ws:";
    wsControl = new WebSocket(proto + "//" + location.host + "/ws/control");
    wsControl.binaryType = "blob";

    wsControl.onopen = function () {
      wsConnecting = false;
      logMsg("WS control connected");
      while (wsPendingQueue.length) wsControl.send(wsPendingQueue.shift());
      clearInterval(wsHeartbeatTimer);
      wsHeartbeatTimer = setInterval(function () {
        if (wsControl && wsControl.readyState === WebSocket.OPEN)
          wsControl.send(JSON.stringify({ mode: "heart" }));
      }, 1000);
    };

    wsControl.onmessage = function (e) {};

    wsControl.onerror = function () { wsConnecting = false; };
    wsControl.onclose = function () {
      wsConnecting = false;
      clearInterval(wsHeartbeatTimer);
      logMsg("WS disconnected - reconnecting in 2s");
      setTimeout(initControlWS, 2000);
    };
  }

  function pressKey(keyName) {
    wsSend({ mode: "key", key: keyName });
  }

  initControlWS();

  var isTouch = "ontouchstart" in window;

  canvas.addEventListener(isTouch ? "touchstart" : "mousedown", function (e) {
    e.preventDefault();
    var rect = canvas.getBoundingClientRect();
    var x, y;
    if (isTouch) {
      x = e.touches[0].clientX - rect.left;
      y = e.touches[0].clientY - rect.top;
    } else {
      x = e.clientX - rect.left;
      y = e.clientY - rect.top;
    }

    if (e.altKey && !isTouch) {
      pickColorAt(x, y);
      return;
    }

    state.dragging = true;
    state.dragStartX = x;
    state.dragStartY = y;
    state.dragMoved = false;

    var pos = canvasToDevice(x, y);
    showTouchRipple(x, y);
    wsSend({ mode: "down", x: pos.x, y: pos.y });
  });

  canvas.addEventListener(isTouch ? "touchmove" : "mousemove", function (e) {
    e.preventDefault();
    var rect = canvas.getBoundingClientRect();
    var x, y;
    if (isTouch) {
      x = e.touches[0].clientX - rect.left;
      y = e.touches[0].clientY - rect.top;
    } else {
      x = e.clientX - rect.left;
      y = e.clientY - rect.top;
    }

    var pos = canvasToDevice(x, y);
    $("screen-coords").textContent =
      Math.round(pos.x) + ", " + Math.round(pos.y);

    if (state.dragging) {
      state.dragMoved = true;
      var now = Date.now();
      var MOVE_INTERVAL_MS = 33;
      var dx = Math.abs(pos.x - state.lastMoveX);
      var dy = Math.abs(pos.y - state.lastMoveY);
      var moved = dx > 1 || dy > 1;

      if (moved && now - state.lastMoveTime >= MOVE_INTERVAL_MS) {
        state.lastMoveTime = now;
        state.lastMoveX = pos.x;
        state.lastMoveY = pos.y;
        wsSend({ mode: "move", x: pos.x, y: pos.y });
      }
    }
  });

  function handleTouchEnd(e) {
    e.preventDefault();
    if (!state.dragging) return;
    state.dragging = false;

    var rect = canvas.getBoundingClientRect();
    var x, y;
    if (isTouch && e.changedTouches && e.changedTouches.length > 0) {
      x = e.changedTouches[0].clientX - rect.left;
      y = e.changedTouches[0].clientY - rect.top;
    } else if (!isTouch) {
      x = e.clientX - rect.left;
      y = e.clientY - rect.top;
    } else {
      x = state.dragStartX;
      y = state.dragStartY;
    }

    var pos = canvasToDevice(x, y);
    wsSend({ mode: "up", x: pos.x, y: pos.y });
  }

  canvas.addEventListener(isTouch ? "touchend" : "mouseup", handleTouchEnd);
  canvas.addEventListener(isTouch ? "touchcancel" : "mouseleave", function (e) {
    if (state.dragging) {
      state.dragging = false;
      var pos = canvasToDevice(state.dragStartX, state.dragStartY);
      wsSend({ mode: "up", x: pos.x, y: pos.y });
    }
  });

  canvas.addEventListener("contextmenu", function (e) {
    e.preventDefault();
    pressKey("HOMEBUTTON");
    snackbar("Home");
    return false;
  });

  // ═══════════════════════════════════════════
  // Color Picker
  // ═══════════════════════════════════════════

  function pickColorAt(canvasX, canvasY) {
    if (!state.hasReceivedFrame) return;

    var pixel = ctx.getImageData(
      Math.round(canvasX),
      Math.round(canvasY),
      1,
      1,
    ).data;
    var hex =
      "#" +
      ((1 << 24) + (pixel[0] << 16) + (pixel[1] << 8) + pixel[2])
        .toString(16)
        .slice(1)
        .toUpperCase();

    var tooltip = $("color-tooltip");
    var swatch = $("color-swatch");
    var valueEl = $("color-value");

    swatch.style.background = hex;
    valueEl.textContent =
      hex + " (" + pixel[0] + "," + pixel[1] + "," + pixel[2] + ")";

    var containerRect = $("screen-container").getBoundingClientRect();
    var canvasRect = canvas.getBoundingClientRect();
    tooltip.style.left =
      canvasRect.left - containerRect.left + canvasX + 16 + "px";
    tooltip.style.top = canvasRect.top - containerRect.top + canvasY - 8 + "px";
    tooltip.classList.add("show");

    try {
      var ta = document.createElement('textarea');
      ta.value = hex;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      document.execCommand('copy');
      ta.remove();
    } catch(e) {}

    snackbar("Color: " + hex + " - copied!", "success");

    clearTimeout(tooltip._hideTimer);
    tooltip._hideTimer = setTimeout(function () {
      tooltip.classList.remove("show");
    }, 2500);
  }

  $("btn-color-pick").addEventListener("click", function () {
    snackbar("Hold Alt + Click on screen to pick color");
  });

  // ═══════════════════════════════════════════
  // Screen Toolbar Buttons
  // ═══════════════════════════════════════════

  $("btn-rotate").addEventListener("click", function () {
    var map = [1, 3, 0, 2];
    state.rotation = map[state.rotation % 4];
    stopScreenCapture();
    captureFrame();
    var labels = [
      "Portrait",
      "Landscape Left",
      "Landscape Right",
      "Upside Down",
    ];
    snackbar("Rotation: " + labels[state.rotation]);
  });

  $("btn-refresh-screen").addEventListener("click", function () {
    stopScreenCapture();
    captureFrame();
  });

  $("btn-home").addEventListener("click", function () {
    pressKey("HOMEBUTTON");
    snackbar("Home");
  });

  // ═══════════════════════════════════════════
  // Log Viewer
  // ═══════════════════════════════════════════

  function startLogPolling() {
    stopLogPolling();
    fetchLog();
  }

  function stopLogPolling() {
    if (state.logTimer) {
      clearTimeout(state.logTimer);
      state.logTimer = null;
    }
  }

  function fetchLog() {
    if (state.logPaused) return;

    apiGet("/api/log", function (err, data) {
      if (!err && typeof data === "string") {
        var logEl = $("log-textarea");
        if (data !== state.lastLog) {
          state.lastLog = data;
          logEl.value = data;
          logEl.scrollTop = logEl.scrollHeight;
        }
        $("log-status-label").textContent = "Log service connected";
        $("log-status-dot").classList.add("connected");
      } else {
        $("log-status-label").textContent = "Waiting for device...";
        $("log-status-dot").classList.remove("connected");
      }
    });

    if (state.activeTab === "log") {
      state.logTimer = setTimeout(fetchLog, config.logInterval);
    }
  }

  $("btn-pause-log").addEventListener("click", function () {
    state.logPaused = !state.logPaused;
    var iconEl = this.querySelector('.toolbar-icon');
    if (state.logPaused) {
      iconEl.outerHTML = LUCIDE['play'].replace('width="18"', 'width="18"').replace('id="pause-icon"', 'id="pause-icon"');
      this.innerHTML = '<svg class="toolbar-icon" xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="5 3 19 12 5 21 5 3"/></svg>';
      $("log-status-label").textContent = "Log paused";
      snackbar("Log paused");
    } else {
      this.innerHTML = '<svg class="toolbar-icon" xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="4" height="16" x="6" y="4"/><rect width="4" height="16" x="14" y="4"/></svg>';
      fetchLog();
      snackbar("Log resumed");
    }
  });

  $("btn-clear-log").addEventListener("click", function () {
    $("log-textarea").value = "";
    state.lastLog = "";
    fetch("/api/system/log", { method: "DELETE" }).catch(function(){});
    snackbar("Log cleared");
  });

  document.querySelectorAll(".log-filter-btn").forEach(function (btn) {
    btn.addEventListener("click", function () {
      document.querySelectorAll(".log-filter-btn").forEach(function (b) {
        b.classList.remove("active");
      });
      this.classList.add("active");
      var filter = this.getAttribute("data-filter");
      snackbar("Log filter: " + filter);
    });
  });

  // ═══════════════════════════════════════════
  // Script Editor Actions
  // ═══════════════════════════════════════════

  function runScript() {
    var iframe = $("script-iframe");
    if (iframe && iframe.contentWindow && iframe.contentWindow.runScript) {
      iframe.contentWindow.runScript();
    } else {
      snackbar("Switch to Script Editor tab first", "error");
    }
  }

  // ═══════════════════════════════════════════
  // Settings
  // ═══════════════════════════════════════════

  $("setting-quality").addEventListener("input", function () {
    config.quality = parseInt(this.value);
    $("quality-value").textContent = this.value + "%";
  });

  $("setting-interval").addEventListener("input", function () {
    config.interval = parseInt(this.value);
    $("interval-value").textContent = this.value + "ms";
  });

  $("setting-tap-delay").addEventListener("input", function () {
    config.tapDelay = parseInt(this.value);
    $("tap-delay-value").textContent = this.value + "ms";
  });

  var touchIndicatorCheckbox = $("setting-touch-indicator");
  if (touchIndicatorCheckbox) {
    touchIndicatorCheckbox.addEventListener("change", function () {
      config.showTouchIndicator = this.checked;
    });
  }

  // ═══════════════════════════════════════════
  // Kill Daemon
  // ═══════════════════════════════════════════

  $("btn-kill-daemon").addEventListener("click", function () {
    if (
      confirm("Kill daemon? You will need to reopen the app to restart it.")
    ) {
      apiGet("/api/kill", function (err, data) {
        snackbar("Daemon killed", "error");
        state.connected = false;
        updateConnectionStatus(false);
      });
    }
  });

  // ═══════════════════════════════════════════
  // Keyboard Shortcuts
  // ═══════════════════════════════════════════

  document.addEventListener("keydown", function (e) {
    if (e.target.tagName === "TEXTAREA" || e.target.tagName === "INPUT") {
      if (!e.ctrlKey && !e.metaKey) return;
    }

    var key = e.key;
    var ctrl = e.ctrlKey || e.metaKey;

    if (ctrl && key === "b") {
      e.preventDefault();
      drawer.classList.contains("open") ? closeDrawer() : openDrawer();
      return;
    }

    if (ctrl && key === "1") {
      e.preventDefault();
      switchTab("screen");
      return;
    }
    if (ctrl && key === "2") {
      e.preventDefault();
      switchTab("script");
      return;
    }
    if (ctrl && key === "3") {
      e.preventDefault();
      switchTab("log");
      return;
    }

    if (ctrl && key === "s") {
      e.preventDefault();
      snackbar("Script saved (local)", "success");
      return;
    }

    if (ctrl && key === "Enter") {
      e.preventDefault();
      if (state.activeTab === "script") {
        runScript();
      }
      return;
    }

    if (key === "Escape") {
      closeDrawer();
      return;
    }

    // iPhone keyboard forwarding
    if (
      state.activeTab === "screen" &&
      !ctrl &&
      e.target.tagName !== "INPUT" &&
      e.target.tagName !== "TEXTAREA"
    ) {
      var iphoneKey = null;
      var keyMap = {
        "Enter": "RETURN",
        "Backspace": "BACKSPACE",
        "Delete": "DEL",
        "Tab": "TAB",
        "Escape": "ESCAPE",
        " ": "SPACE",
        "ArrowUp": "UP",
        "ArrowDown": "DOWN",
        "ArrowLeft": "LEFT",
        "ArrowRight": "RIGHT",
        "PageUp": "PAGEUP",
        "PageDown": "PAGEDOWN",
        "Home": "HOMEKEY",
        "End": "ENDKEY",
        "CapsLock": "CAPSLOCK",
      };

      if (keyMap[key]) {
        iphoneKey = keyMap[key];
      } else if (key.length === 1) {
        e.preventDefault();
        wsSend({ mode: "text", text: key });
        return;
      }

      if (iphoneKey) {
        e.preventDefault();
        wsSend({ mode: "key", key: iphoneKey });
        return;
      }
    }

    if (
      key === "r" &&
      !ctrl &&
      e.target.tagName !== "TEXTAREA" &&
      e.target.tagName !== "INPUT"
    ) {
      if (state.activeTab === "screen") {
        $("btn-rotate").click();
      }
      return;
    }
  });

  // ═══════════════════════════════════════════
  // Status / Connection
  // ═══════════════════════════════════════════

  function updateConnectionStatus(connected) {
    state.connected = connected;
    var dot = document.querySelector(".drawer-footer .status-dot");
    var text = $("status-text");
    if (connected) {
      dot.classList.add("connected");
      text.textContent = "Connected";
    } else {
      dot.classList.remove("connected");
      text.textContent = "Disconnected";
    }
  }

  function fetchStatus() {
    apiGet("/api/status", function (err, data) {
      if (!err && data && data.ok) {
        updateConnectionStatus(true);
        state.pointsW = data.screenWidth || state.imgW || 0;
        state.pointsH = data.screenHeight || state.imgH || 0;
        state.screenW = state.pointsW;
        state.screenH = state.pointsH;

        $("info-daemon").textContent = data.daemon || "—";
        $("info-version").textContent = data.version || "—";
        $("info-pid").textContent = data.pid || "—";
        $("info-screen").textContent =
          (data.screenWidth || "?") + " x " + (data.screenHeight || "?");
        $("info-sender").textContent = data.senderID || "—";
        $("drawer-version").textContent = "v" + (data.version || "0.5.0");

        hideLoadingOverlay();
      } else {
        updateConnectionStatus(false);
      }
    });
  }

  fetchStatus();
  setInterval(fetchStatus, 10000);

  // ═══════════════════════════════════════════
  // FAB
  // ═══════════════════════════════════════════

  $("fab-run").addEventListener("click", function () {
    runScript();
  });

  // ═══════════════════════════════════════════
  // Init
  // ═══════════════════════════════════════════

  switchTab("screen");

  var resizeTimer;
  window.addEventListener("resize", function () {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(function () {
      if (state.activeTab === "screen") {
        stopScreenCapture();
        captureFrame();
      }
    }, 100);
  });
})();
