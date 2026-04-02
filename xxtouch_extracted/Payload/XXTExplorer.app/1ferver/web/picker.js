$(document).ready(function () {
  var getCurrentTimestampString = MatrixHelpers.timestampCompact;

  // 使用 UPNG.js 进行优化的 PNG 编码（无损压缩，体积更小）
  function canvasToOptimizedPngDataUrl(canvas) {
    if (typeof UPNG === 'undefined') {
      // 回退到原生方法
      return canvas.toDataURL("image/png");
    }
    try {
      var ctx = canvas.getContext("2d");
      var imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
      // UPNG.encode: 参数为 [frames], width, height, colorDepth (0=无损)
      var pngArrayBuffer = UPNG.encode([imageData.data.buffer], canvas.width, canvas.height, 0);
      // 转换为 base64 data URL
      var binary = '';
      var bytes = new Uint8Array(pngArrayBuffer);
      for (var i = 0; i < bytes.byteLength; i++) {
        binary += String.fromCharCode(bytes[i]);
      }
      return 'data:image/png;base64,' + btoa(binary);
    } catch (e) {
      console.warn("UPNG 编码失败，回退到原生方法:", e);
      return canvas.toDataURL("image/png");
    }
  }

  // 使用 UPNG.js 获取优化的 PNG Blob
  function canvasToOptimizedPngBlob(canvas) {
    if (typeof UPNG === 'undefined') {
      // 回退到原生方法
      var dataUrl = canvas.toDataURL("image/png");
      return dataUrlToBlob(dataUrl);
    }
    try {
      var ctx = canvas.getContext("2d");
      var imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
      var pngArrayBuffer = UPNG.encode([imageData.data.buffer], canvas.width, canvas.height, 0);
      return new Blob([pngArrayBuffer], { type: "image/png" });
    } catch (e) {
      console.warn("UPNG 编码失败，回退到原生方法:", e);
      var dataUrl = canvas.toDataURL("image/png");
      return dataUrlToBlob(dataUrl);
    }
  }

  // 将 data URL 转换为 Blob 的辅助函数
  function dataUrlToBlob(dataUrl) {
    var parts = dataUrl.split(",");
    var mime = parts[0].match(/:(.*?);/)[1];
    var binary = atob(parts[1]);
    var len = binary.length;
    var arr = new Uint8Array(len);
    while (len--) {
      arr[len] = binary.charCodeAt(len);
    }
    return new Blob([arr], { type: mime });
  }

  var showToast = function (message) { MatrixHelpers.showToast('#pk-toast', message); };
  var openModal = MatrixHelpers.openModal;
  var closeModal = MatrixHelpers.closeModal;
  var formatRect = MatrixHelpers.formatRect;
  var formatCoord = MatrixHelpers.formatCoord;
  var clamp = MatrixHelpers.clamp;
  var normalizeRect = MatrixHelpers.normalizeRect;
  var copyText = MatrixHelpers.copyText;

  function copyWithToast(text, msg) {
    copyText(text).then(function (ok) {
      if (ok !== false) {
        showToast(msg || '已拷贝到剪贴板');
      }
    });
  }

  // 视图状态：缩放和平移
  var view = { scale: 1, offsetX: 0, offsetY: 0 };
  var panDragging = false;
  var panStart = { x: 0, y: 0, offsetX: 0, offsetY: 0 };
  var touchPanState = { active: false, moved: false, tapAction: "pick", startX: 0, startY: 0, startOffsetX: 0, startOffsetY: 0 };
  var touchPinchState = { active: false, startDistance: 1, startScale: 1, startOffsetX: 0, startOffsetY: 0, startCenterDX: 0, startCenterDY: 0 };
  var touchSelectionState = { active: false, target: "shift", startX: 0, startY: 0 };
  var TOUCH_PAN_THRESHOLD = 6;

  // 持久化选框状态 (参考 matrix_dict.html)
  var shiftSelection = null;  // Shift+左键框选的框 {x, y, w, h}
  var metaSelection = null;   // Meta+左键框选的框 {x, y, w, h}

  // 框选拖动状态
  var shiftDragging = false;
  var metaDragging = false;
  var boxDragStart = { x: 0, y: 0 };

  // 移动框状态
  var shiftMoveBoxDragging = false;  // 右键拖动 shift 框
  var metaMoveBoxDragging = false;   // Meta+右键拖动 meta 框
  var moveBoxStart = { x: 0, y: 0, selX: 0, selY: 0 };

  // 调整框大小状态
  var shiftResizeDragging = false;
  var metaResizeDragging = false;
  var resizeHandle = null; // 'n', 's', 'e', 'w', 'nw', 'ne', 'sw', 'se'
  var resizeStart = { x: 0, y: 0, selX: 0, selY: 0, selW: 0, selH: 0 };
  var resizingSelection = null; // 'shift' or 'meta'
  var HANDLE_SIZE = 8;

  // 鼠标悬停高亮的像素坐标（图像坐标系）
  var hoverPixel = null;

  // 画布交互模式（常驻切换）
  // null | 'record' | 'select-shift' | 'select-meta'
  var armedInteractionMode = null;

  // 点色记录圆盘状态
  var recordSlotPicker = null;
  var recordSlotPickerCancelBtn = null;
  var recordSlotPickerCloseTimer = 0;
  var recordSlotPickerOpenRaf = 0;
  var recordSlotPickerState = {
    open: false,
    imgX: 0,
    imgY: 0
  };

  // 将选区坐标规范化为正方向
  // 检测鼠标是否在选框的调整手柄上
  function getResizeHandle(canvasX, canvasY, selection) {
    if (!selection || selection.w <= 0 || selection.h <= 0 || !t) return null;

    var mainCanvasSize = getMainCanvasLogicalSize();
    var containerW = mainCanvasSize.width;
    var containerH = mainCanvasSize.height;
    var centerX = containerW / 2;
    var centerY = containerH / 2;
    var imgW = t.width * view.scale;
    var imgH = t.height * view.scale;
    var baseX = centerX - imgW / 2 + view.offsetX;
    var baseY = centerY - imgH / 2 + view.offsetY;

    var selX = baseX + selection.x * view.scale;
    var selY = baseY + selection.y * view.scale;
    var selW = selection.w * view.scale;
    var selH = selection.h * view.scale;

    var tolerance = Math.max(8, HANDLE_SIZE);

    // 定义手柄位置
    var handles = [
      { name: 'nw', x: selX, y: selY },
      { name: 'n', x: selX + selW / 2, y: selY },
      { name: 'ne', x: selX + selW, y: selY },
      { name: 'e', x: selX + selW, y: selY + selH / 2 },
      { name: 'se', x: selX + selW, y: selY + selH },
      { name: 's', x: selX + selW / 2, y: selY + selH },
      { name: 'sw', x: selX, y: selY + selH },
      { name: 'w', x: selX, y: selY + selH / 2 }
    ];

    for (var i = 0; i < handles.length; i++) {
      var handle = handles[i];
      if (Math.abs(canvasX - handle.x) <= tolerance && Math.abs(canvasY - handle.y) <= tolerance) {
        return handle.name;
      }
    }

    return null;
  }

  // 根据手柄类型获取对应的光标样式
  function getResizeCursor(handle) {
    var cursors = {
      'n': 'ns-resize',
      's': 'ns-resize',
      'e': 'ew-resize',
      'w': 'ew-resize',
      'nw': 'nwse-resize',
      'se': 'nwse-resize',
      'ne': 'nesw-resize',
      'sw': 'nesw-resize'
    };
    return cursors[handle] || 'default';
  }

  // 获取画布坐标（不转换为图像坐标）
  function getCanvasCoord(evt) {
    var rect = b.getBoundingClientRect();
    return {
      x: evt.clientX - rect.left,
      y: evt.clientY - rect.top
    };
  }

  // 检测点是否在选框内部
  function isPointInSelection(canvasX, canvasY, selection) {
    if (!selection || selection.w <= 0 || selection.h <= 0 || !t) return false;

    var mainCanvasSize = getMainCanvasLogicalSize();
    var containerW = mainCanvasSize.width;
    var containerH = mainCanvasSize.height;
    var centerX = containerW / 2;
    var centerY = containerH / 2;
    var imgW = t.width * view.scale;
    var imgH = t.height * view.scale;
    var baseX = centerX - imgW / 2 + view.offsetX;
    var baseY = centerY - imgH / 2 + view.offsetY;

    var selX = baseX + selection.x * view.scale;
    var selY = baseY + selection.y * view.scale;
    var selW = selection.w * view.scale;
    var selH = selection.h * view.scale;

    return canvasX >= selX && canvasX <= selX + selW && canvasY >= selY && canvasY <= selY + selH;
  }

  function updateZoomUI() {
    var percent = Math.round(view.scale * 100);
    $("#zoom_info").text(percent + "%");
  }

  // 更新主图尺寸显示
  function updateImageSizeInfo() {
    var sizeInfo = document.getElementById('pk-imageSizeInfo');
    if (sizeInfo) {
      if (t) {
        sizeInfo.textContent = "(" + t.width + " × " + t.height + ")";
      } else {
        sizeInfo.textContent = "";
      }
    }
  }

  function updateMainCanvasContainerHeight() {
    $("#all_div").height($(window).height() - 100);
  }

  var resizeDrawTimer = null;
  $("#main-drawer a[href='./picker.html']").addClass("mdui-list-item-active");
  $(window).resize(function () {
    updateMainCanvasContainerHeight();
    clearTimeout(resizeDrawTimer);
    resizeDrawTimer = setTimeout(function () {
      if (t) {
        drawCanvas();
      } else {
        ensureMainCanvasSize();
      }
    }, 80);
  });
  updateMainCanvasContainerHeight();
  $("#open").click(function () {
    var v = $('<input type="file" style="display:none" name="upload"/>');
    v.change(function (w) {
      l(w.target.files)
    });
    v.click()
  });
  $("#save").click(function () {
    // 保存原始图像而不是缩放后的画布，使用 UPNG 优化压缩
    var w = canvasToOptimizedPngBlob(a);
    var filename = "IMG_" + getCurrentTimestampString() + ".png";
    saveImageFile(w, filename);
  });
  $("#rotate").click(function () {
    // 向左旋转90度
    if (!t) {
      mdui.snackbar({ message: "请先打开或截取一张图片" });
      return;
    }
    var tempCanvas = document.createElement("canvas");
    var tempCtx = tempCanvas.getContext("2d");
    tempCanvas.width = t.height;
    tempCanvas.height = t.width;
    tempCtx.translate(0, tempCanvas.height);
    tempCtx.rotate(-Math.PI / 2);
    tempCtx.drawImage(t, 0, 0);
    var rotatedImg = new Image();
    rotatedImg.crossOrigin = "anonymous";
    // 使用原生 toDataURL，比 UPNG 编码快很多
    rotatedImg.src = tempCanvas.toDataURL("image/png");
    rotatedImg.onload = function () {
      t = rotatedImg;
      $("#hide_canvas").attr("width", t.width);
      $("#hide_canvas").attr("height", t.height);
      k.setTransform(1, 0, 0, 1, 0, 0);
      k.clearRect(0, 0, t.width, t.height);
      k.drawImage(t, 0, 0);
      view.scale = 1;
      view.offsetX = 0;
      view.offsetY = 0;
      // 清除选框
      shiftSelection = null;
      metaSelection = null;
      f.shiftRectImg = "";
      f.metaRectImg = "";
      updateSelectionRecordUI();
      f.refresh();
      updateZoomUI();
      updateImageSizeInfo();
      drawCanvas();
      m(0, 0);
    };
  });
  var b = document.getElementById("all_canvas");
  var i = b.getContext("2d");
  var a = document.getElementById("hide_canvas");
  var k = a.getContext("2d");
  // 放大镜
  var magnifierCanvas = document.getElementById("pk-magnifierCanvas");
  var q = magnifierCanvas ? magnifierCanvas.getContext("2d") : null;
  if (q) q.imageSmoothingEnabled = false;
  var magnifierCoord = document.getElementById("pk-magnifierCoord");
  var magnifierHex = document.getElementById("pk-magnifierHex");
  var magnifierRgb = document.getElementById("pk-magnifierRgb");
  var magnifierSwatch = document.getElementById("pk-magnifierSwatch");
  var magnifierZoomInput = document.getElementById("pk-magnifierZoom");
  var magnifierZoomLabel = document.getElementById("pk-magnifierZoomLabel");
  var magnifierZoomLevel = 10;
  if (magnifierCanvas) {
    magnifierCanvas.width = 120;
    magnifierCanvas.height = 120;
  }
  if (magnifierZoomLabel) {
    magnifierZoomLabel.textContent = magnifierZoomLevel + "x";
  }
  var allDiv = document.getElementById("all_div");
  var t = null;

  function getCanvasDevicePixelRatio() {
    return Math.max(1, window.devicePixelRatio || 1);
  }

  function getMainCanvasLogicalSize() {
    var rect = allDiv ? allDiv.getBoundingClientRect() : null;
    var width = (rect && rect.width) || (allDiv && allDiv.clientWidth) || b.clientWidth || 1;
    var height = (rect && rect.height) || (allDiv && allDiv.clientHeight) || b.clientHeight || 1;
    return {
      width: Math.max(1, Math.round(width)),
      height: Math.max(1, Math.round(height))
    };
  }

  function ensureMainCanvasSize() {
    var logical = getMainCanvasLogicalSize();
    var dpr = getCanvasDevicePixelRatio();
    var pixelWidth = Math.max(1, Math.round(logical.width * dpr));
    var pixelHeight = Math.max(1, Math.round(logical.height * dpr));
    if (b.width !== pixelWidth) b.width = pixelWidth;
    if (b.height !== pixelHeight) b.height = pixelHeight;
    b.style.width = "100%";
    b.style.height = "100%";
    return {
      logicalWidth: logical.width,
      logicalHeight: logical.height,
      scaleX: b.width / Math.max(1, logical.width),
      scaleY: b.height / Math.max(1, logical.height)
    };
  }

  // 绘制持久化选框
  function drawSelectionBox(ctx, selection, color, fillColor) {
    if (!selection || selection.w <= 0 || selection.h <= 0 || !t) return;

    var mainCanvasSize = getMainCanvasLogicalSize();
    var containerW = mainCanvasSize.width;
    var containerH = mainCanvasSize.height;
    var centerX = containerW / 2;
    var centerY = containerH / 2;
    var imgW = t.width * view.scale;
    var imgH = t.height * view.scale;
    var baseX = centerX - imgW / 2 + view.offsetX;
    var baseY = centerY - imgH / 2 + view.offsetY;

    var selX = baseX + selection.x * view.scale;
    var selY = baseY + selection.y * view.scale;
    var selW = selection.w * view.scale;
    var selH = selection.h * view.scale;

    ctx.save();
    ctx.strokeStyle = color;
    ctx.lineWidth = 1.2;
    ctx.setLineDash([6, 4]);

    // 绘制填充遮罩
    ctx.fillStyle = fillColor;
    ctx.fillRect(selX, selY, selW, selH);

    // 绘制边框
    ctx.strokeRect(selX, selY, selW, selH);

    // 绘制调整手柄（角落和边缘中点）
    ctx.setLineDash([]);
    ctx.fillStyle = '#ffffff';
    ctx.strokeStyle = color;
    ctx.lineWidth = 1.5;

    var handleScreenSize = Math.max(6, Math.min(10, 8));
    var handles = [
      { x: selX, y: selY },                                    // nw
      { x: selX + selW / 2, y: selY },                        // n
      { x: selX + selW, y: selY },                            // ne
      { x: selX + selW, y: selY + selH / 2 },                 // e
      { x: selX + selW, y: selY + selH },                     // se
      { x: selX + selW / 2, y: selY + selH },                 // s
      { x: selX, y: selY + selH },                            // sw
      { x: selX, y: selY + selH / 2 }                         // w
    ];

    for (var i = 0; i < handles.length; i++) {
      var h = handles[i];
      ctx.beginPath();
      ctx.rect(h.x - handleScreenSize / 2, h.y - handleScreenSize / 2, handleScreenSize, handleScreenSize);
      ctx.fill();
      ctx.stroke();
    }

    ctx.restore();
  }

  // 标记点状态
  var showPointMarks = true;
  var showRecordMarks = true; // 颜色记录标记状态

  // 从 localStorage 加载标记状态
  function loadMarkStates() {
    try {
      var saved = localStorage.getItem("picker_mark_states");
      if (saved) {
        var cfg = JSON.parse(saved);
        if (cfg.showPointMarks !== undefined) showPointMarks = cfg.showPointMarks;
        if (cfg.showRecordMarks !== undefined) showRecordMarks = cfg.showRecordMarks;
      }
    } catch (e) {
      console.warn("加载标记状态失败", e);
    }
  }

  // 保存标记状态到 localStorage
  function saveMarkStates() {
    try {
      localStorage.setItem("picker_mark_states", JSON.stringify({
        showPointMarks: showPointMarks,
        showRecordMarks: showRecordMarks
      }));
    } catch (e) {
      console.warn("保存标记状态失败", e);
    }
  }

  loadMarkStates();

  // 颜色记录数据结构（固定5个点）
  var colorRecords = [
    { x: 0, y: 0, color: '0x000000', active: false },
    { x: 0, y: 0, color: '0x000000', active: false },
    { x: 0, y: 0, color: '0x000000', active: false },
    { x: 0, y: 0, color: '0x000000', active: false },
    { x: 0, y: 0, color: '0x000000', active: false }
  ];

  // 从 localStorage 加载颜色记录
  function loadColorRecords() {
    try {
      var saved = localStorage.getItem("picker_color_records");
      if (saved) {
        var cfg = JSON.parse(saved);
        if (cfg && Array.isArray(cfg) && cfg.length === 5) {
          colorRecords = cfg;
        }
      }
    } catch (e) {
      console.warn("加载颜色记录失败", e);
    }
  }

  // 保存颜色记录到 localStorage
  function saveColorRecords() {
    try {
      localStorage.setItem("picker_color_records", JSON.stringify(colorRecords));
    } catch (e) {
      console.warn("保存颜色记录失败", e);
    }
  }

  loadColorRecords();

  var armedRecordBtn = document.getElementById("pk-armedRecordBtn");
  var armedShiftBtn = document.getElementById("pk-armedShiftBtn");
  var armedMetaBtn = document.getElementById("pk-armedMetaBtn");

  function updateArmedModeButtonsUI() {
    if (armedRecordBtn) armedRecordBtn.classList.toggle("is-active", armedInteractionMode === "record");
    if (armedShiftBtn) armedShiftBtn.classList.toggle("is-active", armedInteractionMode === "select-shift");
    if (armedMetaBtn) armedMetaBtn.classList.toggle("is-active", armedInteractionMode === "select-meta");
  }

  function toggleArmedInteractionMode(mode) {
    armedInteractionMode = (armedInteractionMode === mode) ? null : mode;
    if (armedInteractionMode !== "record") {
      closeRecordSlotPicker(true);
    }
    updateArmedModeButtonsUI();
  }

  function disarmArmedInteractionMode(mode) {
    if (armedInteractionMode !== mode) return;
    armedInteractionMode = null;
    updateArmedModeButtonsUI();
  }

  if (armedRecordBtn) {
    armedRecordBtn.addEventListener("click", function () {
      toggleArmedInteractionMode("record");
    });
  }
  if (armedShiftBtn) {
    armedShiftBtn.addEventListener("click", function () {
      toggleArmedInteractionMode("select-shift");
    });
  }
  if (armedMetaBtn) {
    armedMetaBtn.addEventListener("click", function () {
      toggleArmedInteractionMode("select-meta");
    });
  }
  updateArmedModeButtonsUI();

  function setColorRecordAt(slotIndex, x, y) {
    if (!t) return false;
    if (slotIndex < 0 || slotIndex >= colorRecords.length) return false;
    var clampedX = clamp(Math.floor(x), 0, t.width - 1);
    var clampedY = clamp(Math.floor(y), 0, t.height - 1);
    var imgData = k.getImageData(clampedX, clampedY, 1, 1);
    var red = imgData.data[0], green = imgData.data[1], blue = imgData.data[2];
    var hexStr = n(red, green, blue).toUpperCase();

    colorRecords[slotIndex] = {
      x: clampedX,
      y: clampedY,
      color: "0x" + hexStr,
      active: true
    };
    saveColorRecords();
    renderColorRecordsList();
    refreshColorRecordsCode();
    if (showRecordMarks) {
      drawCanvas();
    }
    showToast("已记录第 " + (slotIndex + 1) + " 点: (" + clampedX + ", " + clampedY + ")");
    return true;
  }

  // 更新选区记录 UI
  function updateSelectionRecordUI() {
    var shiftCoordEl = document.getElementById('pk-shiftSelectionCoord');
    var metaCoordEl = document.getElementById('pk-metaSelectionCoord');

    if (shiftCoordEl) {
      if (shiftSelection && shiftSelection.w > 0 && shiftSelection.h > 0) {
        shiftCoordEl.textContent = formatRect({ x: shiftSelection.x, y: shiftSelection.y, w: shiftSelection.w, h: shiftSelection.h });
        shiftCoordEl.style.color = 'var(--md-text)';
      } else {
        shiftCoordEl.textContent = formatRect(null);
        shiftCoordEl.style.color = 'var(--md-muted)';
      }
    }

    if (metaCoordEl) {
      if (metaSelection && metaSelection.w > 0 && metaSelection.h > 0) {
        metaCoordEl.textContent = formatRect({ x: metaSelection.x, y: metaSelection.y, w: metaSelection.w, h: metaSelection.h });
        metaCoordEl.style.color = 'var(--md-text)';
      } else {
        metaCoordEl.textContent = formatRect(null);
        metaCoordEl.style.color = 'var(--md-muted)';
      }
    }
  }

  // ==================== 右键菜单相关 ====================
  var currentContextMenu = null;

  function hideContextMenu() {
    if (currentContextMenu) {
      currentContextMenu.remove();
      currentContextMenu = null;
    }
  }

  function showSelectionContextMenu(e, selectionType) {
    hideContextMenu();

    var menu = document.createElement('div');
    menu.className = 'matrix-context-menu';
    menu.style.left = e.clientX + 'px';
    menu.style.top = e.clientY + 'px';

    // 编辑项
    var editItem = document.createElement('div');
    editItem.className = 'matrix-context-menu-item';
    editItem.textContent = '编辑';
    editItem.addEventListener('click', function () {
      hideContextMenu();
      showEditSelectionDialog(selectionType);
    });
    menu.appendChild(editItem);

    document.body.appendChild(menu);
    currentContextMenu = menu;

    // 确保菜单不超出屏幕
    var rect = menu.getBoundingClientRect();
    if (rect.right > window.innerWidth) {
      menu.style.left = (window.innerWidth - rect.width - 5) + 'px';
    }
    if (rect.bottom > window.innerHeight) {
      menu.style.top = (window.innerHeight - rect.height - 5) + 'px';
    }

    // 点击其他地方关闭菜单
    setTimeout(function() {
      document.addEventListener('click', hideContextMenu, { once: true });
    }, 0);
  }

  // 显示点色的右键菜单
  function showPointContextMenu(e, pointType, index) {
    hideContextMenu();

    var menu = document.createElement('div');
    menu.className = 'matrix-context-menu';
    menu.style.left = e.clientX + 'px';
    menu.style.top = e.clientY + 'px';

    // 编辑项
    var editItem = document.createElement('div');
    editItem.className = 'matrix-context-menu-item';
    editItem.textContent = '编辑';
    editItem.addEventListener('click', function () {
      hideContextMenu();
      showEditPointDialog(pointType, index);
    });
    menu.appendChild(editItem);

    // 拷贝点色项
    var copyItem = document.createElement('div');
    copyItem.className = 'matrix-context-menu-item';
    copyItem.textContent = '拷贝点色';
    copyItem.addEventListener('click', function () {
      hideContextMenu();
      
      // 获取点色数据
      var pointData;
      if (pointType === 'colorList') {
        pointData = f.color_list[index];
      } else if (pointType === 'colorRecord') {
        pointData = colorRecords[index];
        if (!pointData.active) {
          showToast('该点色记录未激活');
          return;
        }
      }
      
      if (pointData) {
        // 格式化为 {x, y, color}
        var copyText = '{' + pointData.x + ', ' + pointData.y + ', ' + pointData.color + '}';
        copyWithToast(copyText, '已拷贝 "' + copyText + '" 到剪贴板');
      }
    });
    menu.appendChild(copyItem);

    document.body.appendChild(menu);
    currentContextMenu = menu;

    // 确保菜单不超出屏幕
    var rect = menu.getBoundingClientRect();
    if (rect.right > window.innerWidth) {
      menu.style.left = (window.innerWidth - rect.width - 5) + 'px';
    }
    if (rect.bottom > window.innerHeight) {
      menu.style.top = (window.innerHeight - rect.height - 5) + 'px';
    }

    // 点击其他地方关闭菜单
    setTimeout(function() {
      document.addEventListener('click', hideContextMenu, { once: true });
    }, 0);
  }

  // ==================== 编辑区域弹窗相关 ====================
  var editSelectionType = null; // 'shift' or 'meta'
  var editSelectionModal = document.getElementById('pk-editSelectionModal');
  var editSelectionTitle = document.getElementById('pk-editSelectionTitle');
  var editSelectionInput = document.getElementById('pk-editSelectionInput');
  var closeEditSelectionModal = document.getElementById('pk-closeEditSelectionModal');
  var editSelectionCancelBtn = document.getElementById('pk-editSelectionCancelBtn');
  var editSelectionConfirmBtn = document.getElementById('pk-editSelectionConfirmBtn');
  MatrixHelpers.bindModalBackdropClose(editSelectionModal);
  MatrixHelpers.bindModalEscClose(editSelectionModal, editSelectionCancelBtn);

  function showEditSelectionDialog(selectionType) {
    editSelectionType = selectionType;
    var selection = selectionType === 'shift' ? shiftSelection : metaSelection;
    
    // 设置标题
    editSelectionTitle.textContent = selectionType === 'shift' ? '编辑 Shift 框' : '编辑 Meta 框';
    
    // 设置当前值
    editSelectionInput.value = formatRect(selection && selection.w > 0 && selection.h > 0 ? {
      x: selection.x,
      y: selection.y,
      w: selection.w,
      h: selection.h
    } : null);
    
    openModal(editSelectionModal);
    editSelectionInput.focus();
    editSelectionInput.select();
  }

  function hideEditSelectionModal() {
    closeModal(editSelectionModal);
    editSelectionType = null;
  }

  function confirmEditSelection() {
    if (!editSelectionType) return;

    var newValue = editSelectionInput.value.trim();
    
    // 解析坐标
    var parts = newValue.split(',').map(function(s) { return s.trim(); });
    if (parts.length !== 4) {
      showToast('格式不正确，应为: left, top, right, bottom');
      return;
    }

    var left = parseInt(parts[0], 10);
    var top = parseInt(parts[1], 10);
    var right = parseInt(parts[2], 10);
    var bottom = parseInt(parts[3], 10);

    // 验证数字
    if (isNaN(left) || isNaN(top) || isNaN(right) || isNaN(bottom)) {
      showToast('坐标必须是数字');
      return;
    }

    // 如果没有图像，不允许编辑
    if (!t) {
      showToast('请先打开或截取一张图片');
      return;
    }

    // 自动修正坐标（如果起点大于终点，则交换）
    if (left > right) {
      var temp = left;
      left = right;
      right = temp;
    }
    if (top > bottom) {
      var temp = top;
      top = bottom;
      bottom = temp;
    }

    // 确保坐标在图像范围内
    left = clamp(left, 0, t.width - 1);
    top = clamp(top, 0, t.height - 1);
    right = clamp(right, 0, t.width);
    bottom = clamp(bottom, 0, t.height);

    // 计算宽度和高度
    var w = right - left;
    var h = bottom - top;

    // 验证区域有效
    if (w <= 0 || h <= 0) {
      showToast('区域无效，宽度和高度必须大于0');
      return;
    }

    // 更新选区
    var newSelection = { x: left, y: top, w: w, h: h };
    
    if (editSelectionType === 'shift') {
      shiftSelection = newSelection;
      // 更新 shiftRectImg
      var imgData = k.getImageData(left, top, w, h);
      var rgba = imgData.data;
      var hexBytes = [];
      for (var i = 0; i < w * h; i++) {
        var r = rgba[i * 4];
        var g = rgba[i * 4 + 1];
        var b = rgba[i * 4 + 2];
        hexBytes.push(
          ((r >> 4) & 0xF).toString(16) + (r & 0xF).toString(16) +
          ((g >> 4) & 0xF).toString(16) + (g & 0xF).toString(16) +
          ((b >> 4) & 0xF).toString(16) + (b & 0xF).toString(16)
        );
      }
      f.shiftRectImg = hexBytes.join('').toUpperCase();
    } else {
      metaSelection = newSelection;
      // 更新 metaRectImg
      var imgData = k.getImageData(left, top, w, h);
      var rgba = imgData.data;
      var hexBytes = [];
      for (var i = 0; i < w * h; i++) {
        var r = rgba[i * 4];
        var g = rgba[i * 4 + 1];
        var b = rgba[i * 4 + 2];
        hexBytes.push(
          ((r >> 4) & 0xF).toString(16) + (r & 0xF).toString(16) +
          ((g >> 4) & 0xF).toString(16) + (g & 0xF).toString(16) +
          ((b >> 4) & 0xF).toString(16) + (b & 0xF).toString(16)
        );
      }
      f.metaRectImg = hexBytes.join('').toUpperCase();
    }

    hideEditSelectionModal();
    updateSelectionRecordUI();
    f.refresh();
    drawCanvas();
    showToast('已更新区域');
  }

  // 绑定事件
  if (closeEditSelectionModal) {
    closeEditSelectionModal.addEventListener('click', hideEditSelectionModal);
  }
  if (editSelectionCancelBtn) {
    editSelectionCancelBtn.addEventListener('click', hideEditSelectionModal);
  }
  if (editSelectionConfirmBtn) {
    editSelectionConfirmBtn.addEventListener('click', confirmEditSelection);
  }
  if (editSelectionInput) {
    editSelectionInput.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') {
        e.preventDefault();
        confirmEditSelection();
      }
    });
  }

  // 为选区记录项添加右键菜单
  // 需要在 DOM 加载后再绑定，因为这些元素是静态的
  setTimeout(function() {
    var selectionList = document.querySelector('.matrix-selection-list');
    if (selectionList) {
      var selectionItems = selectionList.querySelectorAll('.matrix-selection-item');
      
      // 第一个是 Shift框（索引0）
      if (selectionItems[0]) {
        selectionItems[0].addEventListener('contextmenu', function (e) {
          e.preventDefault();
          showSelectionContextMenu(e, 'shift');
        });
      }
      
      // 第二个是 Meta框（索引1）
      if (selectionItems[1]) {
        selectionItems[1].addEventListener('contextmenu', function (e) {
          e.preventDefault();
          showSelectionContextMenu(e, 'meta');
        });
      }
    }
  }, 100);

  // ==================== 编辑点色弹窗相关 ====================
  var editPointType = null; // 'colorList' or 'colorRecord'
  var editPointIndex = -1;
  var editPointModal = document.getElementById('pk-editPointModal');
  var editPointTitle = document.getElementById('pk-editPointTitle');
  var editPointInput = document.getElementById('pk-editPointInput');
  var editPointColorInput = document.getElementById('pk-editPointColorInput');
  var editPointColorPreview = document.getElementById('pk-editPointColorPreview');
  var closeEditPointModal = document.getElementById('pk-closeEditPointModal');
  var editPointCancelBtn = document.getElementById('pk-editPointCancelBtn');
  var editPointConfirmBtn = document.getElementById('pk-editPointConfirmBtn');
  MatrixHelpers.bindModalBackdropClose(editPointModal);
  MatrixHelpers.bindModalEscClose(editPointModal, editPointCancelBtn);

  // 更新颜色预览
  function updateColorPreview(hexValue) {
    if (!editPointColorPreview) return;
    
    var normalizedColor = normalizeColorInput(hexValue);
    if (normalizedColor) {
      editPointColorPreview.style.backgroundColor = '#' + normalizedColor.substring(2);
    } else {
      editPointColorPreview.style.backgroundColor = '#888';
    }
  }

  function syncEditPointColorPreviewHeight() {
    if (!editPointColorInput || !editPointColorPreview) return;

    var inputHeight = Math.round(editPointColorInput.getBoundingClientRect().height);
    if (inputHeight > 0) {
      editPointColorPreview.style.height = inputHeight + 'px';
    }
  }

  // 规范化颜色输入：支持 1-6 位十六进制，不足 6 位高位补 0
  function normalizeColorInput(input) {
    if (!input) return null;
    
    // 移除 0x 前缀（如果有）
    var cleaned = input.trim().replace(/^0x/i, '');
    
    // 验证是否为有效的十六进制（1-6位）
    if (!/^[0-9A-Fa-f]{1,6}$/.test(cleaned)) {
      return null;
    }
    
    // 左边补 0 到 6 位
    var padded = cleaned.toUpperCase().padStart(6, '0');
    
    return '0x' + padded;
  }

  function showEditPointDialog(pointType, index) {
    editPointType = pointType;
    editPointIndex = index;
    
    // 获取当前点的数据
    var point;
    if (pointType === 'colorList') {
      if (!f || !f.color_list || index < 0 || index >= f.color_list.length) return;
      point = f.color_list[index];
      editPointTitle.textContent = '编辑点色 #' + (index + 1);
    } else if (pointType === 'colorRecord') {
      if (index < 0 || index >= colorRecords.length) return;
      point = colorRecords[index];
      editPointTitle.textContent = '编辑点色记录 #' + (index + 1);
    } else {
      return;
    }
    
    // 未激活的点色记录允许编辑，默认从 0,0 和 0x000000 开始
    var initialX = 0;
    var initialY = 0;
    var initialColor = '0x000000';
    if (pointType === 'colorList' || (point && point.active)) {
      initialX = parseInt(point.x, 10);
      initialY = parseInt(point.y, 10);
      initialX = isNaN(initialX) ? 0 : initialX;
      initialY = isNaN(initialY) ? 0 : initialY;
      initialColor = normalizeColorInput(point.color || '') || '0x000000';
    }

    // 设置当前值
    editPointInput.value = initialX + ', ' + initialY;
    editPointColorInput.value = initialColor;
    
    // 更新颜色预览
    updateColorPreview(initialColor);
    
    openModal(editPointModal);
    setTimeout(syncEditPointColorPreviewHeight, 0);
    editPointInput.focus();
    editPointInput.select();
  }

  function hideEditPointModal() {
    closeModal(editPointModal);
    editPointType = null;
    editPointIndex = -1;
  }

  function confirmEditPoint() {
    if (!editPointType || editPointIndex < 0) return;

    var newValue = editPointInput.value.trim();
    
    // 解析坐标
    var parts = newValue.split(',').map(function(s) { return s.trim(); });
    if (parts.length !== 2) {
      showToast('坐标格式不正确，应为: x, y');
      return;
    }

    var x = parseInt(parts[0], 10);
    var y = parseInt(parts[1], 10);

    // 验证数字
    if (isNaN(x) || isNaN(y)) {
      showToast('坐标必须是数字');
      return;
    }

    // 如果没有图像，不允许编辑
    if (!t) {
      showToast('请先打开或截取一张图片');
      return;
    }

    // 确保坐标在图像范围内
    x = clamp(x, 0, t.width - 1);
    y = clamp(y, 0, t.height - 1);

    // 处理颜色值
    var newColor;
    var colorInput = editPointColorInput.value.trim();
    
    if (colorInput) {
      // 用户输入了颜色值，使用规范化函数处理
      newColor = normalizeColorInput(colorInput);
      if (!newColor) {
        showToast('颜色格式不正确，应为 1-6 位十六进制数字');
        return;
      }
    } else {
      // 用户未输入颜色值，从图像自动获取
      var imgData = k.getImageData(x, y, 1, 1);
      var r = imgData.data[0];
      var g = imgData.data[1];
      var b = imgData.data[2];
      var hexStr = ((r >> 4) & 0xF).toString(16) + (r & 0xF).toString(16) +
                   ((g >> 4) & 0xF).toString(16) + (g & 0xF).toString(16) +
                   ((b >> 4) & 0xF).toString(16) + (b & 0xF).toString(16);
      newColor = '0x' + hexStr.toUpperCase();
    }

    // 更新点数据
    if (editPointType === 'colorList') {
      f.color_list[editPointIndex].x = x;
      f.color_list[editPointIndex].y = y;
      f.color_list[editPointIndex].color = newColor;
      f.refresh(); // 刷新点色列表显示
    } else if (editPointType === 'colorRecord') {
      if (!colorRecords[editPointIndex]) {
        colorRecords[editPointIndex] = { x: 0, y: 0, color: '0x000000', active: false };
      }
      colorRecords[editPointIndex].x = x;
      colorRecords[editPointIndex].y = y;
      colorRecords[editPointIndex].color = newColor;
      colorRecords[editPointIndex].active = true;
      saveColorRecords();
      renderColorRecordsList(); // 刷新点色记录显示
    }

    hideEditPointModal();
    drawCanvas(); // 重新绘制画布（更新标记位置）
    showToast('已更新点色');
  }

  // 绑定编辑点色弹窗事件
  if (closeEditPointModal) {
    closeEditPointModal.addEventListener('click', hideEditPointModal);
  }
  if (editPointCancelBtn) {
    editPointCancelBtn.addEventListener('click', hideEditPointModal);
  }
  if (editPointConfirmBtn) {
    editPointConfirmBtn.addEventListener('click', confirmEditPoint);
  }
  if (editPointInput) {
    editPointInput.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') {
        e.preventDefault();
        confirmEditPoint();
      }
    });
  }
  
  // 颜色输入实时预览
  if (editPointColorInput) {
    editPointColorInput.addEventListener('input', function (e) {
      updateColorPreview(e.target.value);
    });
    
    editPointColorInput.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') {
        e.preventDefault();
        confirmEditPoint();
      }
    });
  }

  // 绘制颜色记录标记（使用紫色，与颜色列表区分）
  function drawRecordMarks(ctx, drawX, drawY, scale) {
    if (!showRecordMarks) return;

    ctx.save();
    var radius = 8; // 固定圆圈大小

    colorRecords.forEach(function (item, idx) {
      if (!item.active) return; // 只绘制激活的记录

      // 将标记位置放在像素块的中心（偏移0.5个像素）
      var px = drawX + (item.x + 0.5) * scale;
      var py = drawY + (item.y + 0.5) * scale;
      var label = String(idx + 1);

      // 绘制圆形背景（使用紫色）
      ctx.beginPath();
      ctx.arc(px, py, radius, 0, Math.PI * 2);
      ctx.fillStyle = 'rgba(156, 39, 176, 0.95)'; // 紫色
      ctx.fill();
      ctx.strokeStyle = '#ffffff';
      ctx.lineWidth = 1;
      ctx.stroke();

      // 根据数字位数调整字体大小，确保能放进圆圈
      var fontSize = 10;
      ctx.fillStyle = '#ffffff';
      ctx.font = '500 ' + fontSize + 'px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText(label, px, py + 0.5);
    });
    ctx.restore();
  }

  // 在画布上绘制鼠标所在像素的红框高亮
  function drawHoverMarker(ctx, drawX, drawY, scale) {
    if (!t || !hoverPixel) return;

    var px = hoverPixel.x;
    var py = hoverPixel.y;

    // 将图像坐标转换为画布坐标
    var markerX = drawX + px * scale;
    var markerY = drawY + py * scale;

    // 保证在低缩放时也能看见高亮框
    var size = Math.max(scale, 4);

    ctx.save();
    ctx.setLineDash([4, 2]);
    ctx.strokeStyle = 'rgba(227, 95, 74, 0.95)';
    ctx.lineWidth = 1.6;
    ctx.strokeRect(markerX - 0.5, markerY - 0.5, size, size);
    ctx.restore();
  }

  // 更新鼠标悬停的像素位置，返回是否发生变化
  function updateHoverPixel(imgX, imgY) {
    if (!t) return false;
    var x = clamp(Math.floor(imgX), 0, t.width - 1);
    var y = clamp(Math.floor(imgY), 0, t.height - 1);
    var changed = !hoverPixel || hoverPixel.x !== x || hoverPixel.y !== y;
    hoverPixel = { x: x, y: y };
    return changed;
  }

  // 清除悬停像素标记
  function clearHoverPixel() {
    if (!hoverPixel) return;
    hoverPixel = null;
    drawCanvas();
  }

  // 绘制点色标记
  function drawPointMarks(ctx, drawX, drawY, scale) {
    if (!showPointMarks || !f || !f.color_list || f.color_list.length === 0) return;

    ctx.save();
    var radius = 8; // 固定圆圈大小

    f.color_list.forEach(function (item, idx) {
      // 将标记位置放在像素块的中心（偏移0.5个像素）
      var px = drawX + (item.x + 0.5) * scale;
      var py = drawY + (item.y + 0.5) * scale;
      var label = String(idx + 1);

      // 绘制圆形背景
      ctx.beginPath();
      ctx.arc(px, py, radius, 0, Math.PI * 2);
      ctx.fillStyle = 'rgba(227, 95, 74, 0.95)';
      ctx.fill();
      ctx.strokeStyle = '#ffffff';
      ctx.lineWidth = 1;
      ctx.stroke();

      // 根据数字位数调整字体大小，确保能放进圆圈
      var fontSize = label.length === 1 ? 10 : (label.length === 2 ? 8 : 6);
      ctx.fillStyle = '#ffffff';
      ctx.font = '500 ' + fontSize + 'px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText(label, px, py + 0.5);
    });
    ctx.restore();
  }

  // 绘制主画布
  function drawCanvas() {
    if (!t) return;
    var canvasSize = ensureMainCanvasSize();
    var containerW = canvasSize.logicalWidth;
    var containerH = canvasSize.logicalHeight;

    i.setTransform(1, 0, 0, 1, 0, 0);
    i.clearRect(0, 0, b.width, b.height);
    i.setTransform(canvasSize.scaleX, 0, 0, canvasSize.scaleY, 0, 0);

    // 计算居中偏移
    var centerX = containerW / 2;
    var centerY = containerH / 2;
    var imgW = t.width * view.scale;
    var imgH = t.height * view.scale;
    var drawX = centerX - imgW / 2 + view.offsetX;
    var drawY = centerY - imgH / 2 + view.offsetY;

    i.imageSmoothingEnabled = false;
    // 直接从原始图像 t 绘制
    i.drawImage(t, 0, 0, t.width, t.height, drawX, drawY, imgW, imgH);

    // 绘制持久化选框
    // Shift 选框 - 红色
    if (shiftSelection && shiftSelection.w > 0 && shiftSelection.h > 0) {
      drawSelectionBox(i, shiftSelection, 'rgba(227,95,74,0.9)', 'rgba(227, 95, 74, 0.12)');
    }
    // Meta 选框 - 黑色
    if (metaSelection && metaSelection.w > 0 && metaSelection.h > 0) {
      drawSelectionBox(i, metaSelection, 'rgba(60,150,222,0.9)', 'rgba(60, 150, 222, 0.12)');
    }

    // 绘制点色标记
    drawPointMarks(i, drawX, drawY, view.scale);

    // 绘制颜色记录标记
    drawRecordMarks(i, drawX, drawY, view.scale);

    // 绘制鼠标悬停像素高亮框
    drawHoverMarker(i, drawX, drawY, view.scale);
  }
  // 截图与跨域设置
  var snapshotOrient = 0; // 0=Home在下,1=Home在右,2=Home在左,3=Home在上
  var remoteSnapshotEnabled = false;
  var remoteHost = "";
  var remotePort = 46952;

  // File System Access API 相关
  var fileSystemAccessSupported = 'showDirectoryPicker' in window;
  var savePathEnabled = false;
  var saveDirectoryHandle = null;
  var savePathName = "";

  // 从本地存储加载
  function loadSnapshotSettings() {
    try {
      var saved = localStorage.getItem("picker_snapshot_settings");
      if (saved) {
        var cfg = JSON.parse(saved);
        snapshotOrient = cfg.orient || 0;
        remoteSnapshotEnabled = cfg.remoteEnabled || false;
        remoteHost = cfg.remoteHost || "";
        remotePort = cfg.remotePort || 46952;
        savePathEnabled = cfg.savePathEnabled || false;
        savePathName = cfg.savePathName || "";
      }
    } catch (e) {
      console.warn("加载截图设置失败", e);
    }
  }
  function saveSnapshotSettings() {
    try {
      localStorage.setItem("picker_snapshot_settings", JSON.stringify({
        orient: snapshotOrient,
        remoteEnabled: remoteSnapshotEnabled,
        remoteHost: remoteHost,
        remotePort: remotePort,
        savePathEnabled: savePathEnabled,
        savePathName: savePathName
      }));
    } catch (e) {
      console.warn("保存截图设置失败", e);
    }
  }

  // 使用 File System Access API 保存图片
  async function saveImageToFileSystem(blob, filename) {
    if (!saveDirectoryHandle) {
      return false;
    }
    try {
      // 验证权限
      var permission = await saveDirectoryHandle.queryPermission({ mode: 'readwrite' });
      if (permission !== 'granted') {
        permission = await saveDirectoryHandle.requestPermission({ mode: 'readwrite' });
        if (permission !== 'granted') {
          showToast("文件夹访问权限已被拒绝");
          return false;
        }
      }
      // 创建文件并写入
      var fileHandle = await saveDirectoryHandle.getFileHandle(filename, { create: true });
      var writable = await fileHandle.createWritable();
      await writable.write(blob);
      await writable.close();
      return true;
    } catch (e) {
      console.error("保存图片到文件系统失败", e);
      return false;
    }
  }

  // 通用保存图片函数
  async function saveImageFile(blob, filename) {
    if (savePathEnabled && saveDirectoryHandle && fileSystemAccessSupported) {
      var success = await saveImageToFileSystem(blob, filename);
      if (success) {
        showToast("图片已保存到: " + savePathName + "/" + filename);
        return;
      }
      // 如果保存失败，回退到下载方式
    }
    // 传统下载方式
    var url = window.URL.createObjectURL(blob);
    var link = document.createElement("a");
    link.href = url;
    link.download = filename;
    link.click();
    window.URL.revokeObjectURL(url);
  }

  loadSnapshotSettings();

  // 设置弹窗元素
  var settingsModal = document.getElementById("pk-settingsModal");
  var snapshotOrientBtns = document.getElementById("pk-snapshotOrientBtns");
  var remoteSnapshotEnabledCheckbox = document.getElementById("pk-remoteSnapshotEnabled");
  var remoteSnapshotSettings = document.getElementById("pk-remoteSnapshotSettings");
  var remoteHostInput = document.getElementById("pk-remoteHost");
  var remotePortInput = document.getElementById("pk-remotePort");
  var settingsCancelBtn = document.getElementById("pk-settingsCancelBtn");
  var settingsSaveBtn = document.getElementById("pk-settingsSaveBtn");
  var closeSettingsModal = document.getElementById("pk-closeSettingsModal");

  // File System Access API 设置元素
  var savePathSettingWrapper = document.getElementById("pk-savePathSettingWrapper");
  var savePathEnabledCheckbox = document.getElementById("pk-savePathEnabled");
  var savePathSettings = document.getElementById("pk-savePathSettings");
  var savePathDisplay = document.getElementById("pk-savePathDisplay");
  var selectSavePathBtn = document.getElementById("pk-selectSavePathBtn");

  // 如果浏览器支持 File System Access API，显示设置选项
  if (fileSystemAccessSupported && savePathSettingWrapper) {
    savePathSettingWrapper.style.display = "block";
  }

  // 方向按钮状态
  var selectedOrient = snapshotOrient;
  function updateOrientBtnsState(orient) {
    snapshotOrientBtns.querySelectorAll(".matrix-orient-btn").forEach(function (btn) {
      var active = parseInt(btn.dataset.orient) === orient;
      btn.classList.toggle("active", active);
    });
  }
  updateOrientBtnsState(snapshotOrient);

  snapshotOrientBtns.addEventListener("click", function (e) {
    var btn = e.target.closest(".matrix-orient-btn");
    if (!btn) return;
    selectedOrient = parseInt(btn.dataset.orient) || 0;
    updateOrientBtnsState(selectedOrient);
  });

  remoteSnapshotEnabledCheckbox.addEventListener("change", function () {
    remoteSnapshotSettings.style.display = remoteSnapshotEnabledCheckbox.checked ? "block" : "none";
  });

  // File System Access API 设置事件
  if (savePathEnabledCheckbox) {
    savePathEnabledCheckbox.addEventListener("change", function () {
      savePathSettings.style.display = savePathEnabledCheckbox.checked ? "block" : "none";
    });
  }

  if (selectSavePathBtn) {
    selectSavePathBtn.addEventListener("click", async function () {
      try {
        saveDirectoryHandle = await window.showDirectoryPicker({
          mode: 'readwrite'
        });
        savePathName = saveDirectoryHandle.name;
        savePathDisplay.value = savePathName;
        showToast("已选择文件夹: " + savePathName);
      } catch (e) {
        if (e.name !== 'AbortError') {
          console.error("选择文件夹失败", e);
          showToast("选择文件夹失败");
        }
      }
    });
  }

  function openSettingsModal() {
    selectedOrient = snapshotOrient;
    updateOrientBtnsState(snapshotOrient);
    remoteSnapshotEnabledCheckbox.checked = remoteSnapshotEnabled;
    remoteSnapshotSettings.style.display = remoteSnapshotEnabled ? "block" : "none";
    remoteHostInput.value = remoteHost;
    remotePortInput.value = remotePort;
    // File System Access API 设置状态
    if (savePathEnabledCheckbox) {
      savePathEnabledCheckbox.checked = savePathEnabled;
      savePathSettings.style.display = savePathEnabled ? "block" : "none";
      savePathDisplay.value = savePathName || "未选择保存路径";
    }
    openModal(settingsModal);
  }
  function closeSettingsModalFn() { closeModal(settingsModal); }
  $("#set").on("click", openSettingsModal);
  settingsCancelBtn.addEventListener("click", closeSettingsModalFn);
  closeSettingsModal.addEventListener("click", closeSettingsModalFn);
  MatrixHelpers.bindModalBackdropClose(settingsModal);
  MatrixHelpers.bindModalEscClose(settingsModal, settingsCancelBtn);
  settingsSaveBtn.addEventListener("click", function () {
    snapshotOrient = selectedOrient;
    remoteSnapshotEnabled = remoteSnapshotEnabledCheckbox.checked;
    remoteHost = remoteHostInput.value.trim();
    remotePort = parseInt(remotePortInput.value, 10) || 46952;
    // 保存 File System Access API 设置
    if (savePathEnabledCheckbox) {
      savePathEnabled = savePathEnabledCheckbox.checked;
      // 如果启用但没有选择文件夹，提示用户
      if (savePathEnabled && !saveDirectoryHandle) {
        showToast("请先选择保存文件夹");
        return;
      }
    }
    saveSnapshotSettings();
    closeSettingsModalFn();
    mdui.snackbar({ message: "设置已保存" });
  });

  // 模板配置弹窗
  var templateConfigModal = document.getElementById("pk-templateConfigModal");
  var templateConfigBtn = document.getElementById("pk-templateConfigBtn");
  var closeTemplateConfigModal = document.getElementById("pk-closeTemplateConfigModal");
  var templateConfigCancelBtn = document.getElementById("pk-templateConfigCancelBtn");
  var templateConfigSaveBtn = document.getElementById("pk-templateConfigSaveBtn");
  var compactModeCheckbox = document.getElementById("pk-compactModeEnabled");

  function openTemplateConfigModal() {
    if (compactModeCheckbox) {
      compactModeCheckbox.checked = templateConfig.compactMode;
    }
    openModal(templateConfigModal);
  }
  function closeTemplateConfigModalFn() {
    closeModal(templateConfigModal);
  }

  if (templateConfigBtn) {
    templateConfigBtn.addEventListener("click", openTemplateConfigModal);
  }
  if (closeTemplateConfigModal) {
    closeTemplateConfigModal.addEventListener("click", closeTemplateConfigModalFn);
  }
  if (templateConfigCancelBtn) {
    templateConfigCancelBtn.addEventListener("click", closeTemplateConfigModalFn);
  }
  if (templateConfigModal) {
    MatrixHelpers.bindModalBackdropClose(templateConfigModal);
    MatrixHelpers.bindModalEscClose(templateConfigModal, templateConfigCancelBtn);
  }
  if (templateConfigSaveBtn) {
    templateConfigSaveBtn.addEventListener("click", function () {
      templateConfig.compactMode = compactModeCheckbox ? compactModeCheckbox.checked : false;
      saveTemplateConfig();
      f.refresh();
      closeTemplateConfigModalFn();
      showToast("模板配置已保存");
    });
  }

  $("#snapshot").on("click",
    function () {
      d()
    });
  $("#clear").on("click",
    function () {
      // 关闭图片
      if (!t) {
        showToast("当前没有打开的图片");
        return;
      }
      t = null;
      // 清除画布
      ensureMainCanvasSize();
      i.setTransform(1, 0, 0, 1, 0, 0);
      i.clearRect(0, 0, b.width, b.height);
      // 清除隐藏画布
      a.width = 1;
      a.height = 1;
      k.clearRect(0, 0, 1, 1);
      // 重置视图状态
      view.scale = 1;
      view.offsetX = 0;
      view.offsetY = 0;
      updateZoomUI();
      updateImageSizeInfo();
      // 清除选区
      shiftSelection = null;
      metaSelection = null;
      updateSelectionRecordUI();
      showToast("图片已关闭");
    });
  $("#pk-clearColorListBtn").on("click", function () {
    f.clear();
    showToast("列表已清空");
  });
  // 重新取色按钮 - 颜色列表
  $("#pk-repickColorsBtn").on("click", function () {
    if (!t) {
      showToast("请先打开或截取一张图片");
      return;
    }
    if (!f.color_list || f.color_list.length === 0) {
      showToast("颜色列表为空");
      return;
    }
    var repickCount = 0;
    for (var i = 0; i < f.color_list.length; i++) {
      var pt = f.color_list[i];
      // 检查坐标是否在图像范围内
      if (pt.x >= 0 && pt.x < t.width && pt.y >= 0 && pt.y < t.height) {
        var imgData = k.getImageData(pt.x, pt.y, 1, 1);
        var r = imgData.data[0], g = imgData.data[1], b2 = imgData.data[2];
        var hexStr = n(r, g, b2);
        f.color_list[i].color = '0x' + hexStr;
        repickCount++;
      }
    }
    if (repickCount > 0) {
      f.refresh();
      showToast("已重新取色 " + repickCount + " 个点");
    } else {
      showToast("没有在图像范围内的点");
    }
  });
  // 标记按钮点击事件
  var markPointsBtn = document.getElementById("pk-markPointsBtn");
  // 初始化按钮状态
  function updateMarkPointsBtnUI() {
    if (!markPointsBtn) return;
    if (showPointMarks) {
      markPointsBtn.classList.remove("secondary");
      markPointsBtn.style.background = "linear-gradient(120deg, #e35f4a 0%, #f08070 100%)";
      markPointsBtn.style.color = "#fff";
    } else {
      markPointsBtn.classList.add("secondary");
      markPointsBtn.style.background = "";
      markPointsBtn.style.color = "";
    }
  }
  updateMarkPointsBtnUI();
  if (markPointsBtn) {
    markPointsBtn.addEventListener("click", function () {
      showPointMarks = !showPointMarks;
      updateMarkPointsBtnUI();
      saveMarkStates();
      drawCanvas();
    });
  }
  var e = new Clipboard(".mdui-btn, .cp");
  e.on("success",
    function (v) {
      mdui.snackbar({
        message: "拷贝成功"
      })
    });
  e.on("error",
    function (v) {
      mdui.snackbar({
        message: "拷贝失败，请手动拷贝"
      })
    });

  // 代码模板相关
  var codeTemplates = {
    tpl1: '$pointInitList',
    tpl2: 'if (screen.is_colors($pointInitList, 90)) then',
    tpl3: 'x, y = screen.find_color($pointInitList, 90, $metaRect.left, $metaRect.top, $metaRect.right, $metaRect.bottom)',
    tpl4: 'x, y = screen.find_color($pointInitList, 90, $xMin, $yMin, $xMax, $yMax)',
    tpl5: '$xMin, $yMin, $xMax, $yMax'
  };

  // 模板配置
  var templateConfig = {
    compactMode: false
  };

  // 从 localStorage 加载模板配置
  function loadTemplateConfig() {
    try {
      var saved = localStorage.getItem("picker_template_config");
      if (saved) {
        var cfg = JSON.parse(saved);
        if (cfg.compactMode !== undefined) templateConfig.compactMode = cfg.compactMode;
      }
    } catch (e) {
      console.warn("加载模板配置失败", e);
    }
  }

  // 保存模板配置到 localStorage
  function saveTemplateConfig() {
    try {
      localStorage.setItem("picker_template_config", JSON.stringify(templateConfig));
    } catch (e) {
      console.warn("保存模板配置失败", e);
    }
  }

  loadTemplateConfig();

  // 从 localStorage 加载代码模板
  function loadCodeTemplates() {
    try {
      var saved = localStorage.getItem("picker_code_templates");
      if (saved) {
        var cfg = JSON.parse(saved);
        if (cfg.tpl1 !== undefined) codeTemplates.tpl1 = cfg.tpl1;
        if (cfg.tpl2 !== undefined) codeTemplates.tpl2 = cfg.tpl2;
        if (cfg.tpl3 !== undefined) codeTemplates.tpl3 = cfg.tpl3;
        if (cfg.tpl4 !== undefined) codeTemplates.tpl4 = cfg.tpl4;
        if (cfg.tpl5 !== undefined) codeTemplates.tpl5 = cfg.tpl5;
      }
    } catch (e) {
      console.warn("加载代码模板失败", e);
    }
  }

  // 保存代码模板到 localStorage
  function saveCodeTemplates() {
    try {
      localStorage.setItem("picker_code_templates", JSON.stringify(codeTemplates));
    } catch (e) {
      console.warn("保存代码模板失败", e);
    }
  }

  // 应用模板生成代码
  function applyTemplate(template, vars) {
    var result = template;
    for (var key in vars) {
      result = result.split(key).join(vars[key]);
    }
    return result;
  }

  loadCodeTemplates();

  // 初始化5个模板输入框
  for (var tplIdx = 1; tplIdx <= 5; tplIdx++) {
    (function (idx) {
      var tplKey = 'tpl' + idx;
      var tplInput = document.getElementById(tplKey + '_tpl');
      if (tplInput) {
        tplInput.value = codeTemplates[tplKey];
        tplInput.addEventListener("input", function () {
          codeTemplates[tplKey] = tplInput.value;
          saveCodeTemplates();
          f.refresh();
        });
      }
    })(tplIdx);
  }

  var f = {
    color_list: [],
    range: {
      x: 0,
      y: 0,
      x1: 0,
      y1: 0
    },
    img: "",
    shiftRectImg: "",
    metaRectImg: "",
    add: function (G, F, D) {
      this.push({ x: G, y: F }, "0x" + D);
      this.renderList();
    },
    refresh: function () {
      // 生成 $pointInitList（原始点列表）
      var pointInitList = "{";
      for (var x = 0; x < this.color_list.length; x++) {
        var w = this.color_list[x];
        if (w.x !== undefined && w.y !== undefined && w.color) {
          pointInitList += "\r\n\t{ " + w.x + ", " + w.y + ", " + w.color + " },"
        }
      }
      pointInitList += "\r\n}";

      // 生成 $pointList（相对点列表，第一点为0,0）
      var pointList = "{";
      var firstX = 0, firstY = 0;
      if (this.color_list.length > 0 && this.color_list[0].x !== undefined) {
        firstX = this.color_list[0].x;
        firstY = this.color_list[0].y;
      }
      for (var x = 0; x < this.color_list.length; x++) {
        var w = this.color_list[x];
        if (w.x !== undefined && w.y !== undefined && w.color) {
          pointList += "\r\n\t{ " + (w.x - firstX) + ", " + (w.y - firstY) + ", " + w.color + " },"
        }
      }
      pointList += "\r\n}";

      // 生成 $recordInitList（颜色记录原始点列表）
      var recordInitList = "{";
      var activeRecords = colorRecords.filter(function (r) { return r.active; });
      for (var i = 0; i < activeRecords.length; i++) {
        var rec = activeRecords[i];
        recordInitList += "\r\n\t{ " + rec.x + ", " + rec.y + ", " + rec.color + " },";
      }
      recordInitList += "\r\n}";

      // 生成 $recordList（颜色记录相对点列表，第一点为0,0）
      var recordList = "{";
      var recordFirstX = 0, recordFirstY = 0;
      if (activeRecords.length > 0) {
        recordFirstX = activeRecords[0].x;
        recordFirstY = activeRecords[0].y;
      }
      for (var i = 0; i < activeRecords.length; i++) {
        var rec = activeRecords[i];
        recordList += "\r\n\t{ " + (rec.x - recordFirstX) + ", " + (rec.y - recordFirstY) + ", " + rec.color + " },";
      }
      recordList += "\r\n}";

      // 紧凑模式处理
      if (templateConfig.compactMode) {
        pointInitList = pointInitList.replace(/\s+/g, '').replace(/,}/g, '}');
        pointList = pointList.replace(/\s+/g, '').replace(/,}/g, '}');
        recordInitList = recordInitList.replace(/\s+/g, '').replace(/,}/g, '}');
        recordList = recordList.replace(/\s+/g, '').replace(/,}/g, '}');
      }

      // 计算边界值
      var xMin = 0, yMin = 0, xMax = 0, yMax = 0;
      if (this.color_list.length > 0) {
        xMin = xMax = this.color_list[0].x || 0;
        yMin = yMax = this.color_list[0].y || 0;
        for (var i = 1; i < this.color_list.length; i++) {
          var pt = this.color_list[i];
          if (pt.x < xMin) xMin = pt.x;
          if (pt.x > xMax) xMax = pt.x;
          if (pt.y < yMin) yMin = pt.y;
          if (pt.y > yMax) yMax = pt.y;
        }
      }

      // shiftRect 和 metaRect
      var shiftRectLeft = 0, shiftRectTop = 0, shiftRectRight = 0, shiftRectBottom = 0;
      var metaRectLeft = 0, metaRectTop = 0, metaRectRight = 0, metaRectBottom = 0;
      if (shiftSelection && shiftSelection.w > 0 && shiftSelection.h > 0) {
        shiftRectLeft = shiftSelection.x;
        shiftRectTop = shiftSelection.y;
        shiftRectRight = shiftSelection.x + shiftSelection.w;
        shiftRectBottom = shiftSelection.y + shiftSelection.h;
      }
      if (metaSelection && metaSelection.w > 0 && metaSelection.h > 0) {
        metaRectLeft = metaSelection.x;
        metaRectTop = metaSelection.y;
        metaRectRight = metaSelection.x + metaSelection.w;
        metaRectBottom = metaSelection.y + metaSelection.h;
      }

      // 构建模板变量
      var tplVars = {
        "$pointInitList": pointInitList,
        "$pointList": pointList,
        "$recordInitList": recordInitList,
        "$recordList": recordList,
        "$xMin": xMin,
        "$yMin": yMin,
        "$xMax": xMax,
        "$yMax": yMax,
        "$xFirst": firstX,
        "$yFirst": firstY,
        "$shiftRect.left": shiftRectLeft,
        "$shiftRect.top": shiftRectTop,
        "$shiftRect.right": shiftRectRight,
        "$shiftRect.bottom": shiftRectBottom,
        "$shiftRectImgData": this.shiftRectImg,
        "$metaRect.left": metaRectLeft,
        "$metaRect.top": metaRectTop,
        "$metaRect.right": metaRectRight,
        "$metaRect.bottom": metaRectBottom,
        "$metaRectImgData": this.metaRectImg
      };

      // 添加 $point[n] 变量（支持正索引和负索引）
      for (var i = 0; i < this.color_list.length; i++) {
        var pt = this.color_list[i];
        // 正索引：$point[1], $point[2], ...（1-based）
        tplVars["$point[" + (i + 1) + "].x"] = pt.x || 0;
        tplVars["$point[" + (i + 1) + "].y"] = pt.y || 0;
        tplVars["$point[" + (i + 1) + "].c"] = pt.color || "0x000000";
        // 负索引：$point[-1] 是最后一项, $point[-2] 是倒数第二项, ...
        var negIdx = i - this.color_list.length; // -n, -n+1, ..., -1
        tplVars["$point[" + negIdx + "].x"] = pt.x || 0;
        tplVars["$point[" + negIdx + "].y"] = pt.y || 0;
        tplVars["$point[" + negIdx + "].c"] = pt.color || "0x000000";
      }

      // 添加 $record[n] 变量（支持正索引和负索引）
      for (var i = 0; i < colorRecords.length; i++) {
        var rec = colorRecords[i];
        // 正索引：$record[1], $record[2], ...（1-based）
        tplVars["$record[" + (i + 1) + "].x"] = rec.active ? rec.x : 0;
        tplVars["$record[" + (i + 1) + "].y"] = rec.active ? rec.y : 0;
        tplVars["$record[" + (i + 1) + "].c"] = rec.active ? rec.color : "0x000000";
        // 负索引：$record[-1] 是最后一项, $record[-2] 是倒数第二项, ...
        var negIdx = i - colorRecords.length; // -n, -n+1, ..., -1
        tplVars["$record[" + negIdx + "].x"] = rec.active ? rec.x : 0;
        tplVars["$record[" + negIdx + "].y"] = rec.active ? rec.y : 0;
        tplVars["$record[" + negIdx + "].c"] = rec.active ? rec.color : "0x000000";
      }

      // 应用5个模板
      for (var tplIdx = 1; tplIdx <= 5; tplIdx++) {
        var tplKey = 'tpl' + tplIdx;
        var result = applyTemplate(codeTemplates[tplKey], tplVars);
        $("#" + tplKey).html(result);
        $("#" + tplKey + "_cp").attr("data-clipboard-text", result);
      }

      this.renderList();
    },
    push: function (y, w) {
      var v = this.color_list.push({
        x: y.x,
        y: y.y,
        color: w
      });
      this.refresh();
      // 滚动到新添加的点色
      var listEl = document.getElementById("color_list");
      if (listEl && listEl.lastElementChild) {
        listEl.lastElementChild.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
      }
      return v
    },
    remove: function (v) {
      var result = this.color_list.remove(v);
      this.refresh();
      return result
    },
    clear: function () {
      this.color_list = [];
      this.renderList();
      this.refresh()
    },
    setimg: function (v) {
      this.img = v;
      this.refresh()
    },
    setrange: function (v, A, w, z) {
      this.range.x = v;
      this.range.y = A;
      this.range.x1 = w;
      this.range.y1 = z;
      this.refresh()
    },
    renderList: function () {
      var listEl = $("#color_list");
      listEl.empty();
      var self = this;
      // 更新点色数显示
      var colorCountEl = document.getElementById("pk-colorCount");
      if (colorCountEl) {
        colorCountEl.textContent = "(" + this.color_list.length + " 点)";
      }
      this.color_list.forEach(function (item, idx) {
        var row = $('<div class="matrix-color-item" draggable="true" data-idx="' + idx + '"></div>');
        var indexNum = $('<span class="matrix-color-index">' + (idx + 1) + '</span>');
        var swatch = $('<div class="matrix-color-swatch"></div>').css("background-color", "#" + item.color.replace(/^0x/i, ""));
        var pos = $('<div class="matrix-color-pos" title="点击拷贝坐标">' + item.x + ", " + item.y + '</div>');
        var hex = $('<div class="matrix-color-hex" title="点击拷贝颜色">' + item.color + '</div>');
        var actions = $('<div class="matrix-color-actions"></div>');
        var delBtn = $('<button class="matrix-delete-btn" title="删除">×</button>');
        actions.append(delBtn);
        // 对齐表头：序号列 + 色块列 + 坐标列 + 颜色列 + 操作列
        row.append(indexNum, swatch, pos, hex, actions);

        pos.on("click", function (e) { e.stopPropagation(); copyWithToast(item.x + ", " + item.y, '已拷贝 "' + item.x + ", " + item.y + '" 到剪贴板'); });
        hex.on("click", function (e) { e.stopPropagation(); copyWithToast(item.color, '已拷贝 "' + item.color + '" 到剪贴板'); });
        delBtn.on("click", function (e) { e.stopPropagation(); self.remove(item); });

        // 拖拽排序
        row.on("dragstart", function (e) {
          row.addClass("dragging");
          e.originalEvent.dataTransfer.effectAllowed = "move";
          e.originalEvent.dataTransfer.setData("text/plain", idx);
        });
        row.on("dragend", function () {
          row.removeClass("dragging");
          $(".matrix-color-item").removeClass("drag-over");
        });
        row.on("dragover", function (e) {
          e.preventDefault();
          row.addClass("drag-over");
        });
        row.on("dragleave", function () {
          row.removeClass("drag-over");
        });
        row.on("drop", function (e) {
          e.preventDefault();
          $(".matrix-color-item").removeClass("drag-over");
          var from = parseInt(e.originalEvent.dataTransfer.getData("text/plain"));
          var to = idx;
          if (isNaN(from) || from === to) return;
          var moved = self.color_list.splice(from, 1)[0];
          self.color_list.splice(to, 0, moved);
          self.renderList();
          self.refresh();
        });

        // 添加右键菜单事件
        row.on('contextmenu', function(e) {
          e.preventDefault();
          e.stopPropagation();
          showPointContextMenu(e.originalEvent || e, 'colorList', idx);
        });

        listEl.append(row);
      });
      // 如果标记功能启用，实时更新图像上的标记
      if (showPointMarks) {
        drawCanvas();
      }
    }
  };

  function renderColorRecordsList() {
    var listEl = $("#color_record_list");
    if (!listEl.length) return;
    listEl.empty();

    // 更新记录数显示
    var activeCount = colorRecords.filter(function (r) { return r.active; }).length;
    var recordCountEl = document.getElementById("pk-recordCount");
    if (recordCountEl) {
      recordCountEl.textContent = "(" + activeCount + "/5 点)";
    }

    colorRecords.forEach(function (item, idx) {
      var row = $('<div class="matrix-color-item matrix-record-item" data-idx="' + idx + '"></div>');
      var indexNum = $('<span class="matrix-color-index" style="color:#9c27b0;">' + (idx + 1) + '</span>');
      var swatch = $('<div class="matrix-color-swatch"></div>');
      var pos, hex;

      if (item.active) {
        swatch.css("background-color", "#" + item.color.replace(/^0x/i, ""));
        pos = $('<div class="matrix-color-pos" title="点击拷贝坐标">' + item.x + ", " + item.y + '</div>');
        hex = $('<div class="matrix-color-hex" title="点击拷贝颜色">' + item.color + '</div>');
      } else {
        swatch.css("background-color", "#888");
        pos = $('<div class="matrix-color-pos" style="color:var(--md-muted);">--</div>');
        hex = $('<div class="matrix-color-hex" style="color:var(--md-muted);">0x------</div>');
      }

      var actions = $('<div class="matrix-color-actions"></div>');
      var delBtn = $('<button class="matrix-delete-btn" title="清除">×</button>');
      actions.append(delBtn);

      row.append(indexNum, swatch, pos, hex, actions);

      // 添加右键菜单事件
      row.on('contextmenu', function(e) {
        e.preventDefault();
        showPointContextMenu(e.originalEvent || e, 'colorRecord', idx);
      });

      if (item.active) {
        pos.on("click", function (e) { e.stopPropagation(); copyWithToast(item.x + ", " + item.y, '已拷贝 "' + item.x + ", " + item.y + '" 到剪贴板'); });
        hex.on("click", function (e) { e.stopPropagation(); copyWithToast(item.color, '已拷贝 "' + item.color + '" 到剪贴板'); });
      }

      delBtn.on("click", function (e) {
        e.stopPropagation();
        colorRecords[idx] = { x: 0, y: 0, color: '0x000000', active: false };
        saveColorRecords();
        renderColorRecordsList();
        refreshColorRecordsCode();
        if (showRecordMarks) {
          drawCanvas();
        }
      });

      listEl.append(row);
    });
  }

  // 刷新颜色记录的代码输出（更新模板）
  function refreshColorRecordsCode() {
    f.refresh();
  }

  // 放大镜控制
  var magnifierCoord = document.getElementById("pk-magnifierCoord");
  var magnifierHex = document.getElementById("pk-magnifierHex");
  var magnifierRgb = document.getElementById("pk-magnifierRgb");
  var magnifierSwatch = document.getElementById("pk-magnifierSwatch");
  var magnifierZoomInput = document.getElementById("pk-magnifierZoom");
  var magnifierZoomLabel = document.getElementById("pk-magnifierZoomLabel");
  var magnifierZoomLevel = 10;

  var lastMagnifierX = null;
  var lastMagnifierY = null;

  function clearMagnifier() {
    if (!magnifierCanvas || !q) return;
    q.clearRect(0, 0, magnifierCanvas.width, magnifierCanvas.height);
    if (magnifierCoord) magnifierCoord.textContent = "--";
    if (magnifierHex) magnifierHex.textContent = "0x------";
    if (magnifierRgb) magnifierRgb.textContent = "--";
    if (magnifierSwatch) magnifierSwatch.style.backgroundColor = "#888";
    lastMagnifierX = lastMagnifierY = null;
  }
  clearMagnifier();

  function drawMagnifierPixel(px, py) {
    if (!magnifierCanvas || !q) return;
    if (!t) { clearMagnifier(); return; }
    if (px < 0 || py < 0 || px >= t.width || py >= t.height) {
      clearMagnifier();
      return;
    }
    lastMagnifierX = px;
    lastMagnifierY = py;

    var w = k.getImageData(px, py, 1, 1);
    var r = w.data[0], g2 = w.data[1], b2 = w.data[2];
    var hexStr = n(r, g2, b2);
    var G = document.getElementById("message");
    G.innerHTML = "Pos:&nbsp;" + px + ", " + py + "<br >Color:&nbsp;0x" + hexStr + "<br>R:&nbsp;" + r + "&nbsp;&nbsp;G:&nbsp;" + g2 + "&nbsp;&nbsp;B:&nbsp;" + b2;
    if (magnifierCoord) magnifierCoord.textContent = "(" + px + ", " + py + ")";
    if (magnifierHex) magnifierHex.textContent = "0x" + hexStr.toUpperCase();
    if (magnifierRgb) magnifierRgb.textContent = r + ", " + g2 + ", " + b2;
    if (magnifierSwatch) magnifierSwatch.style.backgroundColor = "#" + hexStr;

    var canvasSize = magnifierCanvas.width;
    var zoom = magnifierZoomLevel;
    var pixelCount = Math.floor(canvasSize / zoom) | 1; // 奇数
    if (pixelCount < 3) pixelCount = 3;
    var half = (pixelCount - 1) / 2;
    var totalSize = pixelCount * zoom;
    var offset = Math.floor((canvasSize - totalSize) / 2);

    q.fillStyle = "#e8e8e8";
    q.fillRect(0, 0, canvasSize, canvasSize);
    q.fillStyle = "#ffffff";
    for (var pyIdx = 0; pyIdx < pixelCount; pyIdx++) {
      for (var pxIdx = 0; pxIdx < pixelCount; pxIdx++) {
        if ((pxIdx + pyIdx) % 2 === 0) {
          q.fillRect(offset + pxIdx * zoom, offset + pyIdx * zoom, zoom, zoom);
        }
      }
    }

    var srcX = Math.max(0, px - half);
    var srcY = Math.max(0, py - half);
    var srcX2 = Math.min(t.width, px + half + 1);
    var srcY2 = Math.min(t.height, py + half + 1);
    var srcW = srcX2 - srcX;
    var srcH = srcY2 - srcY;
    var batchData = (srcW > 0 && srcH > 0) ? k.getImageData(srcX, srcY, srcW, srcH).data : null;
    for (var dy = -half; dy <= half; dy++) {
      for (var dx = -half; dx <= half; dx++) {
        var ix = px + dx;
        var iy = py + dy;
        if (ix >= 0 && ix < t.width && iy >= 0 && iy < t.height) {
          var bIdx = ((iy - srcY) * srcW + (ix - srcX)) * 4;
          var drawX = offset + (dx + half) * zoom;
          var drawY = offset + (dy + half) * zoom;
          q.fillStyle = "rgba(" + batchData[bIdx] + "," + batchData[bIdx + 1] + "," + batchData[bIdx + 2] + "," + (batchData[bIdx + 3] / 255) + ")";
          q.fillRect(drawX, drawY, zoom, zoom);
        }
      }
    }
    // 中心框
    q.strokeStyle = "rgba(227,95,74,0.9)";
    q.lineWidth = 2;
    q.strokeRect(offset + half * zoom, offset + half * zoom, zoom, zoom);
    // 网格线
    if (zoom >= 8) {
      q.strokeStyle = "rgba(0,0,0,0.1)";
      q.lineWidth = 0.5;
      for (var i = 0; i <= pixelCount; i++) {
        q.beginPath();
        q.moveTo(offset + i * zoom, offset);
        q.lineTo(offset + i * zoom, offset + totalSize);
        q.stroke();
        q.beginPath();
        q.moveTo(offset, offset + i * zoom);
        q.lineTo(offset + totalSize, offset + i * zoom);
        q.stroke();
      }
    }
  }

  // 同步缩放显示
  if (magnifierZoomInput) {
    magnifierZoomInput.addEventListener("input", function () {
      magnifierZoomLevel = Number(magnifierZoomInput.value);
      magnifierZoomLabel.textContent = magnifierZoomLevel + "x";
      if (lastMagnifierX !== null && lastMagnifierY !== null) {
        drawMagnifierPixel(lastMagnifierX, lastMagnifierY);
      }
    });
  }

  var m = function (E, C) {
    drawMagnifierPixel(E, C);
  };
  // 将屏幕坐标转换为图像坐标
  var u = function (v, z) {
    var rect = b.getBoundingClientRect();
    var mainCanvasSize = getMainCanvasLogicalSize();
    var containerW = mainCanvasSize.width;
    var containerH = mainCanvasSize.height;

    // 屏幕坐标转画布坐标
    var canvasX = v - rect.left;
    var canvasY = z - rect.top;

    if (!t) return { x: 0, y: 0, rawX: 0, rawY: 0 };

    // 计算图像在画布上的位置
    var centerX = containerW / 2;
    var centerY = containerH / 2;
    var imgW = t.width * view.scale;
    var imgH = t.height * view.scale;
    var drawX = centerX - imgW / 2 + view.offsetX;
    var drawY = centerY - imgH / 2 + view.offsetY;

    // 画布坐标转图像坐标
    var imgX = (canvasX - drawX) / view.scale;
    var imgY = (canvasY - drawY) / view.scale;

    var rawX = Math.floor(imgX);
    var rawY = Math.floor(imgY);
    return {
      x: clamp(rawX, 0, t.width - 1),
      y: clamp(rawY, 0, t.height - 1),
      rawX: rawX,
      rawY: rawY
    };
  };

  // 将图像坐标转换为画布坐标
  var imageToCanvas = function (imgX, imgY) {
    if (!t) return { x: 0, y: 0 };
    var mainCanvasSize = getMainCanvasLogicalSize();
    var containerW = mainCanvasSize.width;
    var containerH = mainCanvasSize.height;

    var centerX = containerW / 2;
    var centerY = containerH / 2;
    var imgW = t.width * view.scale;
    var imgH = t.height * view.scale;
    var drawX = centerX - imgW / 2 + view.offsetX;
    var drawY = centerY - imgH / 2 + view.offsetY;

    return {
      x: drawX + imgX * view.scale,
      y: drawY + imgY * view.scale
    };
  };

  function imagePixelCenterToClient(imgX, imgY) {
    if (!t) return null;
    var canvasPoint = imageToCanvas(imgX + 0.5, imgY + 0.5);
    var rect = b.getBoundingClientRect();
    return {
      x: rect.left + canvasPoint.x,
      y: rect.top + canvasPoint.y
    };
  }

  function clearRecordSlotPickerTimers() {
    if (recordSlotPickerOpenRaf) {
      window.cancelAnimationFrame(recordSlotPickerOpenRaf);
      recordSlotPickerOpenRaf = 0;
    }
    if (recordSlotPickerCloseTimer) {
      clearTimeout(recordSlotPickerCloseTimer);
      recordSlotPickerCloseTimer = 0;
    }
  }

  function closeRecordSlotPicker(immediate) {
    if (!recordSlotPicker) return;
    clearRecordSlotPickerTimers();
    if (!recordSlotPickerState.open && immediate) {
      recordSlotPicker.classList.remove("is-open");
      recordSlotPicker.classList.remove("is-closing");
      recordSlotPicker.setAttribute("aria-hidden", "true");
      return;
    }
    if (immediate) {
      recordSlotPickerState.open = false;
      recordSlotPicker.classList.remove("is-open");
      recordSlotPicker.classList.remove("is-closing");
      recordSlotPicker.setAttribute("aria-hidden", "true");
      return;
    }
    recordSlotPickerState.open = false;
    recordSlotPicker.classList.remove("is-open");
    recordSlotPicker.classList.add("is-closing");
    recordSlotPickerCloseTimer = window.setTimeout(function () {
      recordSlotPickerCloseTimer = 0;
      if (!recordSlotPicker) return;
      recordSlotPicker.classList.remove("is-closing");
      recordSlotPicker.setAttribute("aria-hidden", "true");
    }, 220);
  }

  function openRecordSlotPicker(payload) {
    if (!recordSlotPicker || !payload) return;
    clearRecordSlotPickerTimers();
    recordSlotPickerState.open = true;
    recordSlotPickerState.imgX = payload.imgX;
    recordSlotPickerState.imgY = payload.imgY;
    recordSlotPicker.style.left = payload.screenX + "px";
    recordSlotPicker.style.top = payload.screenY + "px";
    recordSlotPicker.classList.remove("is-closing");
    recordSlotPicker.classList.remove("is-open");
    recordSlotPicker.setAttribute("aria-hidden", "false");
    recordSlotPickerOpenRaf = window.requestAnimationFrame(function () {
      recordSlotPickerOpenRaf = 0;
      if (!recordSlotPicker || !recordSlotPickerState.open) return;
      recordSlotPicker.classList.add("is-open");
    });
  }

  function openRecordSlotPickerAtImagePoint(imgX, imgY, fallbackClientX, fallbackClientY) {
    var center = imagePixelCenterToClient(imgX, imgY);
    openRecordSlotPicker({
      imgX: imgX,
      imgY: imgY,
      screenX: center ? center.x : fallbackClientX,
      screenY: center ? center.y : fallbackClientY
    });
  }

  function initRecordSlotPicker() {
    recordSlotPicker = document.getElementById("pk-recordSlotPicker");
    recordSlotPickerCancelBtn = document.getElementById("pk-recordSlotPickerCancel");
    if (!recordSlotPicker) return;

    function stopBubble(e) {
      e.stopPropagation();
    }

    if (recordSlotPickerCancelBtn) {
      recordSlotPickerCancelBtn.addEventListener("click", function (e) {
        e.preventDefault();
        e.stopPropagation();
        closeRecordSlotPicker(false);
      });
      recordSlotPickerCancelBtn.addEventListener("mousedown", stopBubble);
      recordSlotPickerCancelBtn.addEventListener("mouseup", stopBubble);
      recordSlotPickerCancelBtn.addEventListener("touchstart", stopBubble, { passive: false });
      recordSlotPickerCancelBtn.addEventListener("touchmove", stopBubble, { passive: false });
      recordSlotPickerCancelBtn.addEventListener("touchend", function (e) {
        e.preventDefault();
        e.stopPropagation();
        closeRecordSlotPicker(false);
      }, { passive: false });
    }

    var slotButtons = recordSlotPicker.querySelectorAll(".pk-record-slot-btn");
    for (var slotBtnIdx = 0; slotBtnIdx < slotButtons.length; slotBtnIdx++) {
      var btn = slotButtons[slotBtnIdx];
      var slotNum = parseInt(btn.getAttribute("data-slot"), 10);
      if (isNaN(slotNum)) continue;
      (function (slotBtn, slotIndex) {
        var onChoose = function (e) {
          if (e) {
            e.preventDefault();
            e.stopPropagation();
          }
          if (recordSlotPickerState.open) {
            setColorRecordAt(slotIndex, recordSlotPickerState.imgX, recordSlotPickerState.imgY);
          }
          closeRecordSlotPicker(false);
        };
        slotBtn.addEventListener("click", onChoose);
        slotBtn.addEventListener("mousedown", stopBubble);
        slotBtn.addEventListener("mouseup", stopBubble);
        slotBtn.addEventListener("touchstart", stopBubble, { passive: false });
        slotBtn.addEventListener("touchmove", stopBubble, { passive: false });
        slotBtn.addEventListener("touchend", onChoose, { passive: false });
      })(btn, slotNum - 1);
    }

    document.addEventListener("mousedown", function (e) {
      if (!recordSlotPickerState.open) return;
      if (recordSlotPicker.contains(e.target)) return;
      closeRecordSlotPicker(false);
    });
    document.addEventListener("touchstart", function (e) {
      if (!recordSlotPickerState.open) return;
      if (recordSlotPicker.contains(e.target)) return;
      closeRecordSlotPicker(false);
    }, { passive: true });
  }
  initRecordSlotPicker();

  var n = function (y, w, v) {
    return (y < 16 ? "0" + y.toString(16).toLowerCase() : y.toString(16).toLowerCase()) + (w < 16 ? "0" + w.toString(16).toLowerCase() : w.toString(16).toLowerCase()) + (v < 16 ? "0" + v.toString(16).toLowerCase() : v.toString(16).toLowerCase())
  };
  var o = function (y) {
    var v = y.split(","),
      A = v[0].match(/:(.*?);/)[1],
      w = atob(v[1]),
      B = w.length,
      z = new Uint8Array(B);
    while (B--) {
      z[B] = w.charCodeAt(B)
    }
    return new Blob([z], {
      type: A
    })
  };
  var j = {
    down: false,
    mode: "",
    tapAction: "pick",
    clientX: 0,
    clientY: 0,
    x: 0,
    y: 0,
    scroll: {
      top: 0,
      left: 0
    }
  };
  var r = {
    ctrl: false,
    alt: false,
    shift: false
  };
  $("#all_canvas").on("selectstart",
    function () {
      return false
    });
  $("#hide_canvas").on("selectstart",
    function () {
      return false
    });
  $("#pk-magnifierCanvas").on("selectstart",
    function () {
      return false
    });
  $("#all_canvas").on("mousedown",
    function (w) {
      r.ctrl = (navigator.platform.match("Mac") ? w.metaKey : w.ctrlKey);
      r.alt = w.altKey;
      r.shift = w.shiftKey;
      var effectiveCtrl = r.ctrl || armedInteractionMode === "select-meta";
      var effectiveShift = r.shift || armedInteractionMode === "select-shift";
      var A = u(w.clientX, w.clientY);
      var v = Math.ceil(A.x),
        z = Math.ceil(A.y);
      var canvasCoord = getCanvasCoord(w);
      closeRecordSlotPicker(true);

      // 检查是否点击在调整手柄上 (shift框)
      if (w.which == 1 && !effectiveCtrl && !r.alt && !effectiveShift && shiftSelection) {
        var handle = getResizeHandle(canvasCoord.x, canvasCoord.y, shiftSelection);
        if (handle) {
          shiftResizeDragging = true;
          resizeHandle = handle;
          resizingSelection = 'shift';
          resizeStart = {
            x: v, y: z,
            selX: shiftSelection.x,
            selY: shiftSelection.y,
            selW: shiftSelection.w,
            selH: shiftSelection.h
          };
          return;
        }
      }

      // 检查是否点击在调整手柄上 (meta框) - 需要按住meta键
      if (w.which == 1 && effectiveCtrl && !r.alt && !effectiveShift && metaSelection) {
        var handle = getResizeHandle(canvasCoord.x, canvasCoord.y, metaSelection);
        if (handle) {
          metaResizeDragging = true;
          resizeHandle = handle;
          resizingSelection = 'meta';
          resizeStart = {
            x: v, y: z,
            selX: metaSelection.x,
            selY: metaSelection.y,
            selW: metaSelection.w,
            selH: metaSelection.h
          };
          return;
        }
      }

      // 右键拖动 shift 框 (无修饰键)
      if (w.which == 3 && !effectiveCtrl && !r.alt && !effectiveShift && shiftSelection && shiftSelection.w > 0 && shiftSelection.h > 0) {
        if (isPointInSelection(canvasCoord.x, canvasCoord.y, shiftSelection)) {
          shiftMoveBoxDragging = true;
          moveBoxStart = { x: v, y: z, selX: shiftSelection.x, selY: shiftSelection.y };
          b.style.cursor = 'grabbing';
          w.preventDefault();
          return;
        }
      }

      // Meta+右键拖动 meta 框
      if (w.which == 3 && effectiveCtrl && !r.alt && !effectiveShift && metaSelection && metaSelection.w > 0 && metaSelection.h > 0) {
        if (isPointInSelection(canvasCoord.x, canvasCoord.y, metaSelection)) {
          metaMoveBoxDragging = true;
          moveBoxStart = { x: v, y: z, selX: metaSelection.x, selY: metaSelection.y };
          b.style.cursor = 'grabbing';
          w.preventDefault();
          return;
        }
      }

      if (!j.down && w.which == 1) {
        j.x = v;
        j.y = z;
        if (!effectiveCtrl && !r.alt && !effectiveShift) {
          // 普通拖拽：平移视图
          panDragging = true;
          panStart = { x: w.clientX, y: w.clientY, offsetX: view.offsetX, offsetY: view.offsetY };
          $(allDiv).addClass("panning");
          j.down = true;
          j.mode = "move&get";
          j.tapAction = armedInteractionMode === "record" ? "record" : "pick";
          j.clientX = w.clientX;
          j.clientY = w.clientY;
        } else {
          if (!effectiveCtrl && !r.alt && effectiveShift) {
            // Shift+左键 框选（创建持久化框）
            shiftDragging = true;
            boxDragStart = { x: v, y: z };
            shiftSelection = { x: v, y: z, w: 0, h: 0 };
            j.down = true;
            j.mode = "cut"
          } else {
            if (!effectiveCtrl && r.alt && !effectiveShift) {
              // picker 中无 Alt+鼠标操作，避免进入 down 状态导致 mode 残留
              j.down = false;
              j.mode = ""
            } else {
              if (effectiveCtrl && !r.alt && !effectiveShift) {
                // Meta+左键 框选（创建持久化框）
                metaDragging = true;
                boxDragStart = { x: v, y: z };
                metaSelection = { x: v, y: z, w: 0, h: 0 };
                j.down = true;
                j.mode = "range"
              } else {
                j.down = false
              }
            }
          }
        }
      }
    });
  $("#all_canvas").on("mousemove",
    function (w) {
      r.ctrl = (navigator.platform.match("Mac") ? w.metaKey : w.ctrlKey);
      r.alt = w.altKey;
      r.shift = w.shiftKey;
      var effectiveCtrl = r.ctrl || armedInteractionMode === "select-meta";
      var A = u(w.clientX, w.clientY);
      var v = Math.ceil(A.x),
        z = Math.ceil(A.y);

      // 拖拽操作进行中时不更新放大镜，避免抖动
      var anyDragging = panDragging || shiftMoveBoxDragging || metaMoveBoxDragging ||
        shiftDragging || metaDragging || shiftResizeDragging || metaResizeDragging;
      if (!anyDragging) {
        // 检查鼠标是否在图像区域内（使用未 clamp 的原始坐标）
        if (t && A.rawX >= 0 && A.rawX < t.width && A.rawY >= 0 && A.rawY < t.height) {
          m(v, z);
        } else {
          clearMagnifier();
        }
      }

      // 更新鼠标悬停像素位置
      var hoverChanged = updateHoverPixel(A.x, A.y);

      var canvasCoord = getCanvasCoord(w);

      // 更新光标样式（仅在没有拖拽操作时）
      if (!panDragging && !shiftMoveBoxDragging && !metaMoveBoxDragging &&
        !shiftDragging && !metaDragging && !shiftResizeDragging && !metaResizeDragging) {
        var shiftHandle = shiftSelection ? getResizeHandle(canvasCoord.x, canvasCoord.y, shiftSelection) : null;
        var metaHandle = (effectiveCtrl && metaSelection) ? getResizeHandle(canvasCoord.x, canvasCoord.y, metaSelection) : null;
        if (shiftHandle || metaHandle) {
          b.style.cursor = getResizeCursor(shiftHandle || metaHandle);
        } else {
          b.style.cursor = 'crosshair';
        }
      }

      // 调整 shift 框大小
      if (shiftResizeDragging && shiftSelection && resizeHandle) {
        b.style.cursor = getResizeCursor(resizeHandle);
        var dx = v - resizeStart.x;
        var dy = z - resizeStart.y;

        var newX = resizeStart.selX;
        var newY = resizeStart.selY;
        var newW = resizeStart.selW;
        var newH = resizeStart.selH;

        if (resizeHandle.indexOf('w') !== -1) { newX = resizeStart.selX + dx; newW = resizeStart.selW - dx; }
        if (resizeHandle.indexOf('e') !== -1) { newW = resizeStart.selW + dx; }
        if (resizeHandle.indexOf('n') !== -1) { newY = resizeStart.selY + dy; newH = resizeStart.selH - dy; }
        if (resizeHandle.indexOf('s') !== -1) { newH = resizeStart.selH + dy; }

        if (newW < 0) { newX = newX + newW; newW = -newW; }
        if (newH < 0) { newY = newY + newH; newH = -newH; }

        newX = clamp(newX, 0, t.width - 1);
        newY = clamp(newY, 0, t.height - 1);
        newW = clamp(newW, 1, t.width - newX);
        newH = clamp(newH, 1, t.height - newY);

        shiftSelection = { x: Math.floor(newX), y: Math.floor(newY), w: Math.floor(newW), h: Math.floor(newH) };
        drawCanvas();
        return;
      }

      // 调整 meta 框大小
      if (metaResizeDragging && metaSelection && resizeHandle) {
        b.style.cursor = getResizeCursor(resizeHandle);
        var dx = v - resizeStart.x;
        var dy = z - resizeStart.y;

        var newX = resizeStart.selX;
        var newY = resizeStart.selY;
        var newW = resizeStart.selW;
        var newH = resizeStart.selH;

        if (resizeHandle.indexOf('w') !== -1) { newX = resizeStart.selX + dx; newW = resizeStart.selW - dx; }
        if (resizeHandle.indexOf('e') !== -1) { newW = resizeStart.selW + dx; }
        if (resizeHandle.indexOf('n') !== -1) { newY = resizeStart.selY + dy; newH = resizeStart.selH - dy; }
        if (resizeHandle.indexOf('s') !== -1) { newH = resizeStart.selH + dy; }

        if (newW < 0) { newX = newX + newW; newW = -newW; }
        if (newH < 0) { newY = newY + newH; newH = -newH; }

        newX = clamp(newX, 0, t.width - 1);
        newY = clamp(newY, 0, t.height - 1);
        newW = clamp(newW, 1, t.width - newX);
        newH = clamp(newH, 1, t.height - newY);

        metaSelection = { x: Math.floor(newX), y: Math.floor(newY), w: Math.floor(newW), h: Math.floor(newH) };
        drawCanvas();
        return;
      }

      // 右键移动 shift 框
      if (shiftMoveBoxDragging && shiftSelection) {
        b.style.cursor = 'grabbing';
        var dx = v - moveBoxStart.x;
        var dy = z - moveBoxStart.y;
        shiftSelection.x = clamp(moveBoxStart.selX + dx, 0, t.width - shiftSelection.w);
        shiftSelection.y = clamp(moveBoxStart.selY + dy, 0, t.height - shiftSelection.h);
        drawCanvas();
        return;
      }

      // Meta+右键移动 meta 框
      if (metaMoveBoxDragging && metaSelection) {
        b.style.cursor = 'grabbing';
        var dx = v - moveBoxStart.x;
        var dy = z - moveBoxStart.y;
        metaSelection.x = clamp(moveBoxStart.selX + dx, 0, t.width - metaSelection.w);
        metaSelection.y = clamp(moveBoxStart.selY + dy, 0, t.height - metaSelection.h);
        drawCanvas();
        return;
      }

      if (panDragging) {
        var dx = w.clientX - panStart.x;
        var dy = w.clientY - panStart.y;
        view.offsetX = panStart.offsetX + dx;
        view.offsetY = panStart.offsetY + dy;
        drawCanvas();
        return;
      }

      if (j.down) {
        if (j.mode == "move&get") {
          // 拖拽平移已在上面处理
        } else {
          if (j.mode == "cut") {
            // Shift+拖拽框选 - 更新持久化框
            if (shiftDragging) {
              shiftSelection = normalizeRect(boxDragStart.x, boxDragStart.y, v, z);
            }
            drawCanvas();
          } else {
            if (j.mode == "range") {
              // Meta+拖拽框选 - 更新持久化框
              if (metaDragging) {
                metaSelection = normalizeRect(boxDragStart.x, boxDragStart.y, v, z);
              }
              drawCanvas();
            }
          }
        }
      } else {
        // 普通鼠标移动时，如果悬停位置变化则重绘以更新高亮框
        if (hoverChanged) {
          drawCanvas();
        }
      }
    });
  $("#all_canvas").on("mouseup",
    function (D) {
      r.ctrl = (navigator.platform.match("Mac") ? D.metaKey : D.ctrlKey);
      r.alt = D.altKey;
      r.shift = D.shiftKey;

      // 结束调整大小
      if (shiftResizeDragging) {
        shiftResizeDragging = false;
        resizeHandle = null;
        resizingSelection = null;
        b.style.cursor = 'crosshair';
        drawCanvas();
        processShiftSelection();
        disarmArmedInteractionMode("select-shift");
        return;
      }
      if (metaResizeDragging) {
        metaResizeDragging = false;
        resizeHandle = null;
        resizingSelection = null;
        b.style.cursor = 'crosshair';
        drawCanvas();
        processMetaSelection();
        disarmArmedInteractionMode("select-meta");
        return;
      }

      // 结束移动框
      if (shiftMoveBoxDragging) {
        shiftMoveBoxDragging = false;
        b.style.cursor = 'crosshair';
        drawCanvas();
        processShiftSelection();
        disarmArmedInteractionMode("select-shift");
        return;
      }
      if (metaMoveBoxDragging) {
        metaMoveBoxDragging = false;
        b.style.cursor = 'crosshair';
        drawCanvas();
        processMetaSelection();
        disarmArmedInteractionMode("select-meta");
        return;
      }

      // 结束平移拖拽
      if (panDragging) {
        panDragging = false;
        $(allDiv).removeClass("panning");
      }

      var F = u(D.clientX, D.clientY);
      var J = Math.ceil(F.x),
        G = Math.ceil(F.y);
      if (j.down) {
        j.down = false;
        if (j.mode == "move&get") {
          if (D.clientX == j.clientX && D.clientY == j.clientY) {
            if (j.tapAction === "record") {
              if (t && F.rawX >= 0 && F.rawX < t.width && F.rawY >= 0 && F.rawY < t.height) {
                openRecordSlotPickerAtImagePoint(J, G, D.clientX, D.clientY);
                disarmArmedInteractionMode("record");
              }
            } else {
              // 点击获取颜色：仅在当前有图片且点击在图片范围内时生效
              if (t && F.rawX >= 0 && F.rawX < t.width && F.rawY >= 0 && F.rawY < t.height) {
                var imgData = k.getImageData(J, G, 1, 1);
                var v = imgData.data[0],
                  C = imgData.data[1],
                  H = imgData.data[2];
                f.add(J, G, n(v, C, H))
              }
            }
          } else {
            // 拖拽结束，重绘
            drawCanvas();
          }
        } else {
          if (j.mode == "cut") {
            // 结束 Shift+拖拽框选
            if (shiftDragging) {
              shiftDragging = false;
              shiftSelection = normalizeRect(boxDragStart.x, boxDragStart.y, J, G);
              drawCanvas();
              processShiftSelection();
              disarmArmedInteractionMode("select-shift");
              j.mode = "";
              return;
            }
          } else {
            if (j.mode == "range") {
              // 结束 Meta+拖拽框选
              if (metaDragging) {
                metaDragging = false;
                metaSelection = normalizeRect(boxDragStart.x, boxDragStart.y, J, G);
                drawCanvas();
                processMetaSelection();
                disarmArmedInteractionMode("select-meta");
                j.mode = "";
                return;
              }
            }
          }
        }
        j.mode = "";
        j.tapAction = "pick";
      }
    });

  // 存储当前 find_image 数据
  var currentFindImageData = {
    canvas: null,
    dataUrl: '',
    code: '',
    loadDataCode: ''
  };

  // 处理 Shift 选框结果 (生成 find_image)
  function processShiftSelection() {
    updateSelectionRecordUI();
    if (!shiftSelection || shiftSelection.w <= 0 || shiftSelection.h <= 0) {
      f.shiftRectImg = "";
      f.refresh();
      currentFindImageData = { canvas: null, dataUrl: '', code: '', loadDataCode: '' };
      return;
    }
    var z = shiftSelection.x;
    var E = shiftSelection.y;
    var selW = shiftSelection.w;
    var selH = shiftSelection.h;

    var A = document.createElement("canvas");
    A.width = selW;
    A.height = selH;
    A.getContext("2d").drawImage(a, z, E, selW, selH, 0, 0, selW, selH);
    var K = canvasToOptimizedPngDataUrl(A);

    // 保存数据供弹窗使用
    currentFindImageData.canvas = A;
    currentFindImageData.dataUrl = K;

    var I = canvasToOptimizedPngBlob(A);
    var B = new FileReader();
    B.onload = function (M) {
      var N = "";
      for (var y = 0; y < M.total; y++) {
        var L = B.result.charCodeAt(y).toString(16);
        if (L.length < 2) {
          L = "0" + L
        }
        N += "\\x" + L
      }
      f.shiftRectImg = N;
      f.refresh();
      currentFindImageData.code = 'x, y = screen.find_image( -- ' + z + ', ' + E + ', ' + (z + selW - 1) + ', ' + (E + selH - 1) + '\n"' + N + '",\n95,' + f.range.x + "," + f.range.y + "," + f.range.x1 + "," + f.range.y1 + ")";
      currentFindImageData.loadDataCode = 'img = image.load_image( -- ' + z + ', ' + E + ', ' + (z + selW - 1) + ', ' + (E + selH - 1) + '\n"' + N + '"\n)';
    };
    B.readAsBinaryString(I)
  }

  // find_image 弹窗相关
  var findImageModal = document.getElementById("pk-findImageModal");
  var closeFindImageModalBtn = document.getElementById("pk-closeFindImageModal");
  var findImageGenBtn = document.getElementById("find_image_gen");
  var findImageSaveBtn = document.getElementById("pk-findImageSaveBtn");
  var findImageCopyBtn = document.getElementById("pk-findImageCopyBtn");
  var findImagePreviewImg = document.getElementById("pk-findImagePreviewImg");
  var findImageCodeArea = document.getElementById("pk-findImageCode");

  function openFindImageModal() {
    if (!currentFindImageData.dataUrl || !currentFindImageData.code) {
      showToast("请先使用 Shift+拖拽 框选图像区域");
      return;
    }
    findImagePreviewImg.src = currentFindImageData.dataUrl;
    findImageCodeArea.value = currentFindImageData.code;
    openModal(findImageModal);
  }

  function closeFindImageModal() {
    closeModal(findImageModal);
  }

  if (findImageGenBtn) {
    findImageGenBtn.addEventListener("click", openFindImageModal);
  }
  if (closeFindImageModalBtn) {
    closeFindImageModalBtn.addEventListener("click", closeFindImageModal);
  }
  if (findImageModal) {
    MatrixHelpers.bindModalBackdropClose(findImageModal);
    MatrixHelpers.bindModalEscClose(findImageModal);
  }
  if (findImageSaveBtn) {
    findImageSaveBtn.addEventListener("click", function () {
      if (!currentFindImageData.canvas) {
        showToast("没有可保存的图像");
        return;
      }
      var blob = canvasToOptimizedPngBlob(currentFindImageData.canvas);
      var filename = "IMG_" + getCurrentTimestampString() + ".png";
      saveImageFile(blob, filename);
    });
  }
  if (findImageCopyBtn) {
    findImageCopyBtn.addEventListener("click", function () {
      if (!currentFindImageData.code) {
        showToast("没有可拷贝的代码");
        return;
      }
      copyWithToast(currentFindImageData.code, "代码已拷贝到剪贴板");
    });
  }

  // load_data 弹窗相关
  var loadDataModal = document.getElementById("pk-loadDataModal");
  var closeLoadDataModalBtn = document.getElementById("pk-closeLoadDataModal");
  var loadDataGenBtn = document.getElementById("load_data_gen");
  var loadDataSaveBtn = document.getElementById("pk-loadDataSaveBtn");
  var loadDataCopyBtn = document.getElementById("pk-loadDataCopyBtn");
  var loadDataPreviewImg = document.getElementById("pk-loadDataPreviewImg");
  var loadDataCodeArea = document.getElementById("pk-loadDataCode");

  function openLoadDataModal() {
    if (!currentFindImageData.dataUrl || !currentFindImageData.loadDataCode) {
      showToast("请先使用 Shift+拖拽 框选图像区域");
      return;
    }
    loadDataPreviewImg.src = currentFindImageData.dataUrl;
    loadDataCodeArea.value = currentFindImageData.loadDataCode;
    openModal(loadDataModal);
  }

  function closeLoadDataModal() {
    closeModal(loadDataModal);
  }

  if (loadDataGenBtn) {
    loadDataGenBtn.addEventListener("click", openLoadDataModal);
  }
  if (closeLoadDataModalBtn) {
    closeLoadDataModalBtn.addEventListener("click", closeLoadDataModal);
  }
  if (loadDataModal) {
    MatrixHelpers.bindModalBackdropClose(loadDataModal);
    MatrixHelpers.bindModalEscClose(loadDataModal);
  }
  if (loadDataSaveBtn) {
    loadDataSaveBtn.addEventListener("click", function () {
      if (!currentFindImageData.canvas) {
        showToast("没有可保存的图像");
        return;
      }
      var blob = canvasToOptimizedPngBlob(currentFindImageData.canvas);
      var filename = "IMG_" + getCurrentTimestampString() + ".png";
      saveImageFile(blob, filename);
    });
  }
  if (loadDataCopyBtn) {
    loadDataCopyBtn.addEventListener("click", function () {
      if (!currentFindImageData.loadDataCode) {
        showToast("没有可拷贝的代码");
        return;
      }
      copyWithToast(currentFindImageData.loadDataCode, "代码已拷贝到剪贴板");
    });
  }

  // 保存区域图像弹窗相关
  var saveRegionModal = document.getElementById("pk-saveRegionModal");
  var closeSaveRegionModalBtn = document.getElementById("pk-closeSaveRegionModal");
  var saveRegionImageBtn = document.getElementById("save_region_image");
  var saveRegionCancelBtn = document.getElementById("pk-saveRegionCancelBtn");
  var saveRegionConfirmBtn = document.getElementById("pk-saveRegionConfirmBtn");
  var saveRegionCopyAndSaveBtn = document.getElementById("pk-saveRegionCopyAndSaveBtn");
  var saveRegionPreviewImg = document.getElementById("pk-saveRegionPreviewImg");
  var saveRegionFilenameInput = document.getElementById("pk-saveRegionFilename");
  var saveRegionCodeTemplateInput = document.getElementById("pk-saveRegionCodeTemplate");
  var saveRegionGeneratedCodeArea = document.getElementById("pk-saveRegionGeneratedCode");

  // 默认代码模板
  var defaultCodeTemplate = '$imgFileBaseName = image.load_file(XXT_HOME_PATH.."/res/$imgFileBaseName.png")';

  // 从 localStorage 加载代码模板
  function loadSaveRegionCodeTemplate() {
    try {
      var saved = localStorage.getItem("picker_save_region_code_template");
      if (saved) {
        return saved;
      }
    } catch (e) {
      console.warn("加载代码模板失败", e);
    }
    return defaultCodeTemplate;
  }

  // 保存代码模板到 localStorage
  function saveSaveRegionCodeTemplate(template) {
    try {
      localStorage.setItem("picker_save_region_code_template", template);
    } catch (e) {
      console.warn("保存代码模板失败", e);
    }
  }

  // 根据文件名和模板生成代码
  function generateCodeFromTemplate(filename, template) {
    if (!template) return "";
    // 移除 .png 后缀用于替换
    var name = filename.replace(/\.png$/i, "");
    return template.split("$imgFileBaseName").join(name);
  }

  // 更新生成的代码
  function updateGeneratedCode() {
    if (!saveRegionFilenameInput || !saveRegionCodeTemplateInput || !saveRegionGeneratedCodeArea) return;
    var filename = saveRegionFilenameInput.value.trim() || "IMG_" + getCurrentTimestampString();
    var template = saveRegionCodeTemplateInput.value;
    var code = generateCodeFromTemplate(filename, template);
    saveRegionGeneratedCodeArea.value = code;
  }

  // 初始化代码模板
  if (saveRegionCodeTemplateInput) {
    saveRegionCodeTemplateInput.value = loadSaveRegionCodeTemplate();

    // 监听模板变化，更新生成的代码并保存模板
    saveRegionCodeTemplateInput.addEventListener("input", function () {
      saveSaveRegionCodeTemplate(saveRegionCodeTemplateInput.value);
      updateGeneratedCode();
    });
  }

  // 监听文件名变化，更新生成的代码
  if (saveRegionFilenameInput) {
    saveRegionFilenameInput.addEventListener("input", updateGeneratedCode);
  }

  function openSaveRegionModal() {
    if (!currentFindImageData.canvas || !currentFindImageData.dataUrl) {
      showToast("请先使用 Shift+拖拽 框选图像区域");
      return;
    }
    saveRegionPreviewImg.src = currentFindImageData.dataUrl;
    // 生成默认文件名
    saveRegionFilenameInput.value = "IMG_" + getCurrentTimestampString();
    // 更新生成的代码
    updateGeneratedCode();
    openModal(saveRegionModal);
    // 聚焦到输入框并选中文本
    setTimeout(function () {
      saveRegionFilenameInput.focus();
      saveRegionFilenameInput.select();
    }, 100);
  }

  function closeSaveRegionModal() {
    closeModal(saveRegionModal);
  }

  async function doSaveRegionImage() {
    if (!currentFindImageData.canvas) {
      showToast("没有可保存的图像");
      return;
    }
    var filename = saveRegionFilenameInput.value.trim();
    if (!filename) {
      filename = "IMG_" + getCurrentTimestampString();
    }
    // 移除可能已经添加的 .png 后缀
    filename = filename.replace(/\.png$/i, "");

    var blob = canvasToOptimizedPngBlob(currentFindImageData.canvas);
    closeSaveRegionModal();
    await saveImageFile(blob, filename + ".png");
  }

  async function doCopyCodeAndSaveImage() {
    if (!currentFindImageData.canvas) {
      showToast("没有可保存的图像");
      return;
    }
    var filename = saveRegionFilenameInput.value.trim();
    if (!filename) {
      filename = "IMG_" + getCurrentTimestampString();
    }
    // 移除可能已经添加的 .png 后缀
    filename = filename.replace(/\.png$/i, "");

    // 获取生成的代码
    var code = saveRegionGeneratedCodeArea.value;

    // 拷贝代码到剪贴板
    if (code) {
      await copyWithToast(code, "代码已拷贝到剪贴板");
    }

    // 保存图像
    var blob = canvasToOptimizedPngBlob(currentFindImageData.canvas);
    closeSaveRegionModal();
    await saveImageFile(blob, filename + ".png");

    if (code) {
      showToast("代码已拷贝，图像已保存");
    }
  }

  if (saveRegionImageBtn) {
    saveRegionImageBtn.addEventListener("click", openSaveRegionModal);
  }
  if (closeSaveRegionModalBtn) {
    closeSaveRegionModalBtn.addEventListener("click", closeSaveRegionModal);
  }
  if (saveRegionCancelBtn) {
    saveRegionCancelBtn.addEventListener("click", closeSaveRegionModal);
  }
  if (saveRegionConfirmBtn) {
    saveRegionConfirmBtn.addEventListener("click", doSaveRegionImage);
  }
  if (saveRegionCopyAndSaveBtn) {
    saveRegionCopyAndSaveBtn.addEventListener("click", doCopyCodeAndSaveImage);
  }
  if (saveRegionModal) {
    MatrixHelpers.bindModalBackdropClose(saveRegionModal);
    MatrixHelpers.bindModalEscClose(saveRegionModal, saveRegionCancelBtn);
  }
  // 支持回车键保存
  if (saveRegionFilenameInput) {
    saveRegionFilenameInput.addEventListener("keydown", function (e) {
      if (e.key === "Enter") {
        e.preventDefault();
        doSaveRegionImage();
      }
    });
  }

  // 随机取色功能
  var randomColorModal = document.getElementById("pk-randomColorModal");
  var randomColorBtn = document.getElementById("pk-randomColorBtn");
  var closeRandomColorModal = document.getElementById("pk-closeRandomColorModal");
  var randomColorCancelBtn = document.getElementById("pk-randomColorCancelBtn");
  var randomColorConfirmBtn = document.getElementById("pk-randomColorConfirmBtn");
  var customRandomCountInput = document.getElementById("pk-customRandomCount");
  var randomColorBtns = document.getElementById("pk-randomColorBtns");
  var customCountWrapper = document.getElementById("pk-customCountWrapper");

  // 当前选中的取色点数
  var selectedRandomCount = 1;
  var customRandomCountValue = 100;

  // 从 localStorage 加载随机取色配置
  function loadRandomColorSettings() {
    try {
      var saved = localStorage.getItem("picker_random_color_settings");
      if (saved) {
        var cfg = JSON.parse(saved);
        selectedRandomCount = cfg.count || 1;
        customRandomCountValue = cfg.customCount || 100;
        if (customRandomCountInput) {
          customRandomCountInput.value = customRandomCountValue;
        }
      }
    } catch (e) {
      console.warn("加载随机取色设置失败", e);
    }
  }

  // 保存随机取色配置到 localStorage
  function saveRandomColorSettings() {
    try {
      localStorage.setItem("picker_random_color_settings", JSON.stringify({
        count: selectedRandomCount,
        customCount: customRandomCountValue
      }));
    } catch (e) {
      console.warn("保存随机取色设置失败", e);
    }
  }

  // 加载配置
  loadRandomColorSettings();

  // 更新按钮分组状态
  function updateRandomColorBtnsState(count) {
    if (!randomColorBtns) return;
    randomColorBtns.querySelectorAll(".matrix-orient-btn").forEach(function (btn) {
      var btnCount = btn.dataset.count;
      var active = (btnCount === String(count)) || (btnCount === "custom" && count === "custom");
      btn.classList.toggle("active", active);
    });
    // 显示/隐藏自定义输入框
    if (customCountWrapper) {
      customCountWrapper.style.display = (count === "custom") ? "block" : "none";
      if (count === "custom" && customRandomCountInput) {
        customRandomCountInput.focus();
      }
    }
  }

  // 监听按钮点击
  if (randomColorBtns) {
    randomColorBtns.addEventListener("click", function (e) {
      var btn = e.target.closest(".matrix-orient-btn");
      if (!btn) return;
      var count = btn.dataset.count;
      if (count === "custom") {
        selectedRandomCount = "custom";
      } else {
        selectedRandomCount = parseInt(count, 10) || 1;
      }
      updateRandomColorBtnsState(count);
      saveRandomColorSettings();
    });
  }

  // 监听自定义输入框变化
  if (customRandomCountInput) {
    customRandomCountInput.addEventListener("input", function () {
      customRandomCountValue = parseInt(customRandomCountInput.value, 10) || 100;
      saveRandomColorSettings();
    });
  }

  function openRandomColorModal() {
    // 检查是否有 shift 框选区域
    if (!shiftSelection || shiftSelection.w <= 0 || shiftSelection.h <= 0) {
      showToast("请先使用 Shift + 鼠标左键框选一个区域");
      return;
    }
    if (!t) {
      showToast("请先打开或截取一张图片");
      return;
    }
    // 恢复上次保存的配置
    updateRandomColorBtnsState(selectedRandomCount);
    if (customRandomCountInput) {
      customRandomCountInput.value = customRandomCountValue;
    }
    openModal(randomColorModal);
    // 将焦点移到确认按钮，以便回车键可以触发确认
    if (randomColorConfirmBtn) {
      randomColorConfirmBtn.focus();
    }
  }

  function closeRandomColorModalFn() {
    closeModal(randomColorModal);
  }

  // 从选区中随机取色
  function randomPickColors(count) {
    if (!shiftSelection || shiftSelection.w <= 0 || shiftSelection.h <= 0) {
      showToast("请先使用 Shift + 鼠标左键框选一个区域");
      return;
    }
    if (!t) {
      showToast("请先打开或截取一张图片");
      return;
    }

    var x = shiftSelection.x;
    var y = shiftSelection.y;
    var w = shiftSelection.w;
    var h = shiftSelection.h;

    // 限制取色点数不超过选区内的像素总数
    var maxPoints = w * h;
    if (count > maxPoints) {
      count = maxPoints;
      showToast("选区内像素不足，已取 " + count + " 个点");
    }

    // 一次性获取整个选区的像素数据，避免多次调用 getImageData
    var imgData = k.getImageData(x, y, w, h);
    var pixels = imgData.data;

    // 生成不重复的随机点
    var pickedPoints = new Set();
    var addedCount = 0;
    var maxAttempts = count * 10; // 避免死循环
    var attempts = 0;

    while (addedCount < count && attempts < maxAttempts) {
      var localX = Math.floor(Math.random() * w);
      var localY = Math.floor(Math.random() * h);
      var key = localX + "," + localY;

      if (!pickedPoints.has(key)) {
        pickedPoints.add(key);

        // 从预取的像素数据中获取颜色
        var pixelIndex = (localY * w + localX) * 4;
        var r = pixels[pixelIndex];
        var g = pixels[pixelIndex + 1];
        var b2 = pixels[pixelIndex + 2];
        var hexStr = n(r, g, b2);

        // 直接添加到列表，不触发刷新
        f.color_list.push({
          x: x + localX,
          y: y + localY,
          color: "0x" + hexStr
        });
        addedCount++;
      }
      attempts++;
    }

    // 批量添加完成后，统一刷新一次
    f.refresh();

    // 滚动到最后添加的点色
    var listEl = document.getElementById("color_list");
    if (listEl && listEl.lastElementChild) {
      listEl.lastElementChild.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }

    showToast("已随机取色 " + addedCount + " 个点");
  }

  if (randomColorBtn) {
    randomColorBtn.addEventListener("click", openRandomColorModal);
  }
  if (closeRandomColorModal) {
    closeRandomColorModal.addEventListener("click", closeRandomColorModalFn);
  }
  if (randomColorCancelBtn) {
    randomColorCancelBtn.addEventListener("click", closeRandomColorModalFn);
  }
  if (randomColorModal) {
    MatrixHelpers.bindModalBackdropClose(randomColorModal);
    MatrixHelpers.bindModalEscClose(randomColorModal, randomColorCancelBtn);
  }
  if (randomColorConfirmBtn) {
    randomColorConfirmBtn.addEventListener("click", function () {
      var count = 1;
      if (selectedRandomCount === "custom") {
        count = parseInt(customRandomCountInput.value, 10) || 1;
        count = Math.max(1, Math.min(1000, count));
      } else {
        count = selectedRandomCount;
      }
      closeRandomColorModalFn();
      randomPickColors(count);
    });
  }
  // 支持回车键确认
  if (randomColorModal) {
    randomColorModal.addEventListener("keydown", function (e) {
      if (e.key === "Enter" && randomColorModal.style.display !== "none") {
        e.preventDefault();
        if (randomColorConfirmBtn) {
          randomColorConfirmBtn.click();
        }
      }
    });
  }

  // 导入点色功能
  var importColorModal = document.getElementById("pk-importColorModal");
  var importColorBtn = document.getElementById("pk-importColorBtn");
  var closeImportColorModal = document.getElementById("pk-closeImportColorModal");
  var importColorCancelBtn = document.getElementById("pk-importColorCancelBtn");
  var importColorConfirmBtn = document.getElementById("pk-importColorConfirmBtn");
  var importColorText = document.getElementById("pk-importColorText");

  function openImportColorModal() {
    if (importColorText) {
      importColorText.value = "";
    }
    openModal(importColorModal);
  }

  function closeImportColorModalFn() {
    closeModal(importColorModal);
  }

  // 解析点色数据
  function parseColorData(text) {
    var results = [];
    if (!text || !text.trim()) return results;

    // 正则匹配: {x, y, 0xcolor} 或 x,y,0xcolor
    // 支持多种格式:
    // 1. {653,367,0x0e43c1}
    // 2. 653,367,0x0e43c1
    var pattern = /\{?\s*(\d+)\s*,\s*(\d+)\s*,\s*(0x[0-9a-fA-F]{6})\s*\}?/g;
    var match;

    while ((match = pattern.exec(text)) !== null) {
      var x = parseInt(match[1], 10);
      var y = parseInt(match[2], 10);
      var color = match[3].toLowerCase();

      if (!isNaN(x) && !isNaN(y) && color) {
        results.push({ x: x, y: y, color: color });
      }
    }

    return results;
  }

  // 导入点色到列表
  function importColors(colorList) {
    if (!colorList || colorList.length === 0) {
      showToast("未找到有效的点色数据");
      return;
    }

    colorList.forEach(function (item) {
      f.push({ x: item.x, y: item.y }, item.color);
    });

    showToast("已导入 " + colorList.length + " 个点色");
  }

  if (importColorBtn) {
    importColorBtn.addEventListener("click", openImportColorModal);
  }
  if (closeImportColorModal) {
    closeImportColorModal.addEventListener("click", closeImportColorModalFn);
  }
  if (importColorCancelBtn) {
    importColorCancelBtn.addEventListener("click", closeImportColorModalFn);
  }
  if (importColorModal) {
    MatrixHelpers.bindModalBackdropClose(importColorModal);
    MatrixHelpers.bindModalEscClose(importColorModal, importColorCancelBtn);
  }
  if (importColorConfirmBtn) {
    importColorConfirmBtn.addEventListener("click", function () {
      var text = importColorText ? importColorText.value : "";
      var colorList = parseColorData(text);
      closeImportColorModalFn();
      importColors(colorList);
    });
  }

  // 处理 Meta 选框结果 (设置查找范围)
  function processMetaSelection() {
    updateSelectionRecordUI();
    if (!metaSelection || metaSelection.w <= 0 || metaSelection.h <= 0) {
      f.metaRectImg = "";
      f.setrange(0, 0, 0, 0);
      return;
    }
    var z = metaSelection.x;
    var E = metaSelection.y;
    var x1 = z + metaSelection.w;
    var y1 = E + metaSelection.h;

    // 生成 metaRect 的图像数据
    var A = document.createElement("canvas");
    A.width = metaSelection.w;
    A.height = metaSelection.h;
    A.getContext("2d").drawImage(a, z, E, metaSelection.w, metaSelection.h, 0, 0, metaSelection.w, metaSelection.h);

    var metaDataUrl = canvasToOptimizedPngDataUrl(A);
    var I = canvasToOptimizedPngBlob(A);
    var B = new FileReader();
    B.onload = function (M) {
      var N = "";
      for (var y = 0; y < M.total; y++) {
        var L = B.result.charCodeAt(y).toString(16);
        if (L.length < 2) {
          L = "0" + L
        }
        N += "\\x" + L
      }
      f.metaRectImg = N;
      f.refresh();
    };
    B.readAsBinaryString(I);

    f.setrange(z, E, x1, y1);
  }
  var d = function () {
    t = new Image();
    t.crossOrigin = "anonymous";
    var snapshotUrl = "";
    if (remoteSnapshotEnabled && remoteHost) {
      snapshotUrl = "http://" + remoteHost + ":" + remotePort + "/snapshot?ext=png&orient=" + snapshotOrient + "&t=" + (new Date().getTime()).toString();
    } else {
      snapshotUrl = "/snapshot?ext=png&orient=" + snapshotOrient + "&t=" + (new Date().getTime()).toString();
    }
    t.src = snapshotUrl;
    t.onload = function () {
      var y = t.width;
      $("#hide_canvas").attr("width", y);
      var w = t.height;
      $("#hide_canvas").attr("height", w);
      k.setTransform(1, 0, 0, 1, 0, 0);
      k.clearRect(0, 0, t.width, t.height);
      k.drawImage(t, 0, 0);

      // 重置视图和选框
      view.scale = 1;
      view.offsetX = 0;
      view.offsetY = 0;
      shiftSelection = null;
      metaSelection = null;
      f.shiftRectImg = "";
      f.metaRectImg = "";
      updateSelectionRecordUI();
      f.refresh();
      updateZoomUI();
      updateImageSizeInfo();
      drawCanvas();
      m(0, 0)
    }
  };
  var l = function (y) {
    var v = y[0];
    var objectURL = (window.URL || window.webkitURL);
    var w = objectURL.createObjectURL(v);
    t = new Image();
    t.crossOrigin = "anonymous";
    t.src = w;
    t.onload = function () {
      objectURL.revokeObjectURL(w);
      var A = t.width;
      $("#hide_canvas").attr("width", A);
      var z = t.height;
      $("#hide_canvas").attr("height", z);
      k.setTransform(1, 0, 0, 1, 0, 0);
      k.clearRect(0, 0, t.width, t.height);
      k.drawImage(t, 0, 0);

      // 重置视图和选框
      view.scale = 1;
      view.offsetX = 0;
      view.offsetY = 0;
      shiftSelection = null;
      metaSelection = null;
      f.shiftRectImg = "";
      f.metaRectImg = "";
      updateSelectionRecordUI();
      f.refresh();
      updateZoomUI();
      updateImageSizeInfo();
      drawCanvas();
      m(0, 0)
    }
    t.onerror = function () {
      objectURL.revokeObjectURL(w);
      showToast("打开图片失败");
    }
  };
  $(document).keyup(function (v) {
    r.ctrl = (navigator.platform.match("Mac") ? v.metaKey : v.ctrlKey);
    r.alt = v.altKey;
    r.shift = v.shiftKey
  });
  $(document).keydown(function (z) {
    r.ctrl = (navigator.platform.match("Mac") ? z.metaKey : z.ctrlKey);
    r.alt = z.altKey;
    r.shift = z.shiftKey;
    if ((navigator.platform.match("Mac") ? z.metaKey : z.ctrlKey) && z.keyCode == 83) {
      z.preventDefault();
      if (!t) {
        showToast("请先打开或截取一张图片");
        return false;
      }
      var w = canvasToOptimizedPngBlob(a);
      var filename = "IMG_" + getCurrentTimestampString() + ".png";
      saveImageFile(w, filename);
      return false
    }
    // 数字键 0：快捷取色（等同于鼠标左键点击取色）
    if (z.keyCode == 48 && !z.ctrlKey && !z.metaKey && !z.altKey) {
      if (!t) return;
      if (lastMagnifierX === null || lastMagnifierY === null) return;

      var imgData = k.getImageData(lastMagnifierX, lastMagnifierY, 1, 1);
      var red = imgData.data[0], green = imgData.data[1], blue = imgData.data[2];
      var hexStr = n(red, green, blue);

      f.add(lastMagnifierX, lastMagnifierY, hexStr);
      showToast("已取色: (" + lastMagnifierX + ", " + lastMagnifierY + ") 0x" + hexStr);
      return false;
    }

    // 数字键 1-5：设置颜色记录
    if (z.keyCode >= 49 && z.keyCode <= 53 && !z.ctrlKey && !z.metaKey && !z.altKey) {
      if (!t) return;
      if (lastMagnifierX === null || lastMagnifierY === null) return;

      var recordIndex = z.keyCode - 49; // 0-4
      setColorRecordAt(recordIndex, lastMagnifierX, lastMagnifierY);
      return false;
    }

    if (z.keyCode === 27) {
      closeRecordSlotPicker(true);
    }

    // M 键：以第一点为基准，将点色列表所有点平移到鼠标位置
    if (z.keyCode == 77 && !z.ctrlKey && !z.metaKey && !z.altKey) {
      if (!t || !f || !f.color_list || f.color_list.length === 0) return;
      if (lastMagnifierX === null || lastMagnifierY === null) return;

      var firstPoint = f.color_list[0];
      var deltaX = lastMagnifierX - firstPoint.x;
      var deltaY = lastMagnifierY - firstPoint.y;

      // 平移所有点并重新取色
      for (var idx = 0; idx < f.color_list.length; idx++) {
        var newX = f.color_list[idx].x + deltaX;
        var newY = f.color_list[idx].y + deltaY;
        // 确保坐标在图像范围内
        newX = clamp(Math.floor(newX), 0, t.width - 1);
        newY = clamp(Math.floor(newY), 0, t.height - 1);
        f.color_list[idx].x = newX;
        f.color_list[idx].y = newY;
        // 重新取色
        var imgData = k.getImageData(newX, newY, 1, 1);
        var red = imgData.data[0], green = imgData.data[1], blue = imgData.data[2];
        f.color_list[idx].color = "0x" + n(red, green, blue);
      }

      f.refresh();
      showToast("已平移 " + f.color_list.length + " 个点");
      return false;
    }

    // Ctrl/Meta+V：粘贴剪贴板图片
    if ((navigator.platform.match("Mac") ? z.metaKey : z.ctrlKey) && z.keyCode == 86) {
      // 检查当前焦点是否在输入框中（不拦截输入框中的粘贴）
      var activeEl = document.activeElement;
      var isInInput = activeEl && (activeEl.tagName === 'INPUT' || activeEl.tagName === 'TEXTAREA');
      if (!isInInput) {
        // 检查是否支持 Clipboard API（需要安全上下文）
        if (navigator.clipboard && navigator.clipboard.read && window.isSecureContext) {
          z.preventDefault();
          handleClipboardPaste();
          return false;
        }
        // 非安全上下文，不调用 preventDefault，让 paste 事件正常触发
      }
    }
  });

  // 待粘贴的图片 Blob（用于确认后加载）
  var pendingPasteBlob = null;

  // 粘贴确认弹窗相关元素
  var pasteConfirmModal = document.getElementById("pk-pasteConfirmModal");
  var closePasteConfirmModal = document.getElementById("pk-closePasteConfirmModal");
  var pasteConfirmCancelBtn = document.getElementById("pk-pasteConfirmCancelBtn");
  var pasteConfirmBtn = document.getElementById("pk-pasteConfirmBtn");

  function showPasteConfirmModal(blob) {
    pendingPasteBlob = blob;
    openModal(pasteConfirmModal);
  }

  function hidePasteConfirmModal() {
    closeModal(pasteConfirmModal);
    pendingPasteBlob = null;
  }

  if (closePasteConfirmModal) {
    closePasteConfirmModal.addEventListener("click", hidePasteConfirmModal);
  }
  if (pasteConfirmCancelBtn) {
    pasteConfirmCancelBtn.addEventListener("click", hidePasteConfirmModal);
  }
  if (pasteConfirmBtn) {
    pasteConfirmBtn.addEventListener("click", function () {
      if (pendingPasteBlob) {
        loadImageFromBlob(pendingPasteBlob);
      }
      hidePasteConfirmModal();
    });
  }
  if (pasteConfirmModal) {
    MatrixHelpers.bindModalBackdropClose(pasteConfirmModal);
    MatrixHelpers.bindModalEscClose(pasteConfirmModal, pasteConfirmCancelBtn);
  }

  // 从剪贴板粘贴图片
  function handleClipboardPaste() {
    navigator.clipboard.read().then(function (clipboardItems) {
      for (var i = 0; i < clipboardItems.length; i++) {
        var item = clipboardItems[i];
        // 查找图片类型
        var imageType = null;
        for (var j = 0; j < item.types.length; j++) {
          if (item.types[j].startsWith('image/')) {
            imageType = item.types[j];
            break;
          }
        }
        if (imageType) {
          item.getType(imageType).then(function (blob) {
            if (t) {
              // 已有图片，显示确认弹窗
              showPasteConfirmModal(blob);
            } else {
              // 没有图片，直接加载
              loadImageFromBlob(blob);
            }
          }).catch(function (err) {
            console.warn('获取剪贴板图片失败:', err);
            showToast('获取剪贴板图片失败');
          });
          return;
        }
      }
      showToast('剪贴板中没有图片');
    }).catch(function (err) {
      console.warn('读取剪贴板失败:', err);
      // 降级方案：监听 paste 事件
      showToast('无法读取剪贴板，请使用 Ctrl+V 重试');
    });
  }

  // 从 Blob 加载图片
  function loadImageFromBlob(blob) {
    var objectURL = (window.URL || window.webkitURL);
    var url = objectURL.createObjectURL(blob);
    t = new Image();
    t.crossOrigin = "anonymous";
    t.src = url;
    t.onload = function () {
      objectURL.revokeObjectURL(url);
      var A = t.width;
      $("#hide_canvas").attr("width", A);
      var z = t.height;
      $("#hide_canvas").attr("height", z);
      k.setTransform(1, 0, 0, 1, 0, 0);
      k.clearRect(0, 0, t.width, t.height);
      k.drawImage(t, 0, 0);

      // 重置视图和选框
      view.scale = 1;
      view.offsetX = 0;
      view.offsetY = 0;
      shiftSelection = null;
      metaSelection = null;
      f.shiftRectImg = "";
      f.metaRectImg = "";
      updateSelectionRecordUI();
      f.refresh();
      updateZoomUI();
      updateImageSizeInfo();
      drawCanvas();
      m(0, 0);
      showToast("已从剪贴板粘贴图片");
    };
    t.onerror = function () {
      objectURL.revokeObjectURL(url);
      showToast("粘贴图片加载失败");
    };
  }

  // 监听 paste 事件（作为备用方案）
  document.addEventListener('paste', function (evt) {
    // 检查当前焦点是否在输入框中（不拦截输入框中的粘贴）
    var activeEl = document.activeElement;
    var isInInput = activeEl && (activeEl.tagName === 'INPUT' || activeEl.tagName === 'TEXTAREA');
    if (isInInput) return;

    var items = evt.clipboardData && evt.clipboardData.items;
    if (!items) return;

    for (var i = 0; i < items.length; i++) {
      if (items[i].type.indexOf('image') !== -1) {
        var blob = items[i].getAsFile();
        if (blob) {
          evt.preventDefault();
          if (t) {
            // 已有图片，显示确认弹窗
            showPasteConfirmModal(blob);
          } else {
            // 没有图片，直接加载
            loadImageFromBlob(blob);
          }
          return;
        }
      }
    }
  });

  // 鼠标滚轮缩放
  function handleWheel(evt) {
    if (!t) return;
    evt.preventDefault();
    var delta = evt.deltaY < 0 ? 1.1 : 0.9;
    var oldScale = view.scale;
    var newScale = clamp(view.scale * delta, 0.1, 20);

    // 计算缩放中心点（鼠标在画布上的位置）
    var canvasSize = ensureMainCanvasSize();
    var rect = b.getBoundingClientRect();
    var containerW = canvasSize.logicalWidth;
    var containerH = canvasSize.logicalHeight;
    var mouseX = evt.clientX - rect.left;
    var mouseY = evt.clientY - rect.top;

    // 鼠标相对于当前视图中心的偏移
    var centerX = containerW / 2;
    var centerY = containerH / 2;
    var mouseDX = mouseX - centerX;
    var mouseDY = mouseY - centerY;

    // 缩放比例变化
    var scaleRatio = newScale / oldScale;

    // 更新偏移量，使鼠标位置在缩放前后保持不变
    view.offsetX = (view.offsetX - mouseDX) * scaleRatio + mouseDX;
    view.offsetY = (view.offsetY - mouseDY) * scaleRatio + mouseDY;
    view.scale = newScale;

    updateZoomUI();
    drawCanvas();
  }

  function getCanvasPointFromClient(clientX, clientY) {
    var rect = b.getBoundingClientRect();
    return {
      x: clientX - rect.left,
      y: clientY - rect.top
    };
  }

  function getTouchDistance(t0, t1) {
    var dx = t1.clientX - t0.clientX;
    var dy = t1.clientY - t0.clientY;
    return Math.sqrt(dx * dx + dy * dy);
  }

  function getTouchCenterOnCanvas(t0, t1) {
    var p0 = getCanvasPointFromClient(t0.clientX, t0.clientY);
    var p1 = getCanvasPointFromClient(t1.clientX, t1.clientY);
    return {
      x: (p0.x + p1.x) / 2,
      y: (p0.y + p1.y) / 2
    };
  }

  function beginTouchPan(touch, suppressTap, tapAction) {
    touchPanState.active = true;
    touchPanState.moved = !!suppressTap;
    touchPanState.tapAction = tapAction || "pick";
    touchPanState.startX = touch.clientX;
    touchPanState.startY = touch.clientY;
    touchPanState.startOffsetX = view.offsetX;
    touchPanState.startOffsetY = view.offsetY;
    $(allDiv).addClass("panning");
  }

  function beginTouchPinch(t0, t1) {
    var canvasSize = ensureMainCanvasSize();
    var center = getTouchCenterOnCanvas(t0, t1);
    touchPinchState.active = true;
    touchPinchState.startDistance = Math.max(1, getTouchDistance(t0, t1));
    touchPinchState.startScale = view.scale;
    touchPinchState.startOffsetX = view.offsetX;
    touchPinchState.startOffsetY = view.offsetY;
    touchPinchState.startCenterDX = center.x - canvasSize.logicalWidth / 2;
    touchPinchState.startCenterDY = center.y - canvasSize.logicalHeight / 2;
  }

  function beginTouchSelection(touch, target) {
    if (!touch || !t) return false;
    var coord = u(touch.clientX, touch.clientY);
    if (coord.rawX < 0 || coord.rawX >= t.width || coord.rawY < 0 || coord.rawY >= t.height) {
      return false;
    }
    touchSelectionState.active = true;
    touchSelectionState.target = target;
    touchSelectionState.startX = coord.x;
    touchSelectionState.startY = coord.y;
    if (target === "shift") {
      shiftDragging = true;
      shiftSelection = { x: coord.x, y: coord.y, w: 0, h: 0 };
    } else {
      metaDragging = true;
      metaSelection = { x: coord.x, y: coord.y, w: 0, h: 0 };
    }
    drawCanvas();
    return true;
  }

  function updateTouchSelection(touch) {
    if (!touchSelectionState.active || !touch || !t) return;
    var coord = u(touch.clientX, touch.clientY);
    var rect = normalizeRect(touchSelectionState.startX, touchSelectionState.startY, coord.x, coord.y);
    if (touchSelectionState.target === "shift") {
      shiftSelection = rect;
    } else {
      metaSelection = rect;
    }
    drawCanvas();
  }

  function finalizeTouchSelection() {
    if (!touchSelectionState.active) return;
    var target = touchSelectionState.target;
    touchSelectionState.active = false;
    shiftDragging = false;
    metaDragging = false;
    if (target === "shift") {
      processShiftSelection();
    } else {
      processMetaSelection();
    }
    disarmArmedInteractionMode(target === "shift" ? "select-shift" : "select-meta");
    drawCanvas();
  }

  function resetTouchSelectionState() {
    if (touchSelectionState.target === "shift" && shiftSelection && (shiftSelection.w <= 0 || shiftSelection.h <= 0)) {
      shiftSelection = null;
    }
    if (touchSelectionState.target === "meta" && metaSelection && (metaSelection.w <= 0 || metaSelection.h <= 0)) {
      metaSelection = null;
    }
    touchSelectionState.active = false;
    shiftDragging = false;
    metaDragging = false;
  }

  function pickColorByTouch(touch) {
    if (!touch || !t) return;
    var coord = u(touch.clientX, touch.clientY);
    if (coord.rawX < 0 || coord.rawX >= t.width || coord.rawY < 0 || coord.rawY >= t.height) {
      return;
    }
    var imgData = k.getImageData(coord.x, coord.y, 1, 1);
    var rr = imgData.data[0];
    var gg = imgData.data[1];
    var bb = imgData.data[2];
    f.add(coord.x, coord.y, n(rr, gg, bb));
    m(coord.x, coord.y);
  }

  b.addEventListener('wheel', handleWheel, { passive: false });
  b.addEventListener('touchstart', function (evt) {
    if (!t) return;
    closeRecordSlotPicker(true);
    if (evt.touches.length >= 2) {
      if (touchSelectionState.active) {
        finalizeTouchSelection();
      }
      touchPanState.active = false;
      touchPanState.moved = true;
      touchPanState.tapAction = "pick";
      $(allDiv).removeClass("panning");
      beginTouchPinch(evt.touches[0], evt.touches[1]);
      evt.preventDefault();
      return;
    }
    if (evt.touches.length === 1) {
      touchPinchState.active = false;
      if (armedInteractionMode === "select-shift" || armedInteractionMode === "select-meta") {
        touchPanState.active = false;
        touchPanState.moved = false;
        touchPanState.tapAction = "pick";
        $(allDiv).removeClass("panning");
        var selectTarget = armedInteractionMode === "select-shift" ? "shift" : "meta";
        if (!beginTouchSelection(evt.touches[0], selectTarget)) {
          beginTouchPan(evt.touches[0], false, "pick");
        }
      } else {
        beginTouchPan(evt.touches[0], false, armedInteractionMode === "record" ? "record" : "pick");
      }
      evt.preventDefault();
    }
  }, { passive: false });

  b.addEventListener('touchmove', function (evt) {
    if (!t) return;

    if (touchSelectionState.active) {
      if (evt.touches.length >= 2) {
        finalizeTouchSelection();
        touchPanState.active = false;
        touchPanState.moved = true;
        touchPanState.tapAction = "pick";
        $(allDiv).removeClass("panning");
        beginTouchPinch(evt.touches[0], evt.touches[1]);
        evt.preventDefault();
        return;
      }
      if (evt.touches.length === 1) {
        updateTouchSelection(evt.touches[0]);
        evt.preventDefault();
        return;
      }
    }

    if (evt.touches.length >= 2) {
      if (!touchPinchState.active) {
        beginTouchPinch(evt.touches[0], evt.touches[1]);
      }

      var distance = Math.max(1, getTouchDistance(evt.touches[0], evt.touches[1]));
      var scaleFactor = distance / Math.max(1, touchPinchState.startDistance);
      var newScale = clamp(touchPinchState.startScale * scaleFactor, 0.1, 20);
      var canvasSize = ensureMainCanvasSize();
      var center = getTouchCenterOnCanvas(evt.touches[0], evt.touches[1]);
      var centerDX = center.x - canvasSize.logicalWidth / 2;
      var centerDY = center.y - canvasSize.logicalHeight / 2;
      var scaleRatio = newScale / Math.max(0.0001, touchPinchState.startScale);

      view.offsetX = (touchPinchState.startOffsetX - touchPinchState.startCenterDX) * scaleRatio + centerDX;
      view.offsetY = (touchPinchState.startOffsetY - touchPinchState.startCenterDY) * scaleRatio + centerDY;
      view.scale = newScale;

      touchPanState.active = false;
      touchPanState.moved = true;
      $(allDiv).removeClass("panning");
      updateZoomUI();
      drawCanvas();
      evt.preventDefault();
      return;
    }

    if (evt.touches.length === 1) {
      var touch = evt.touches[0];
      if (touchPinchState.active) {
        touchPinchState.active = false;
        beginTouchPan(touch, true, armedInteractionMode === "record" ? "record" : "pick");
      }
      if (!touchPanState.active) {
        beginTouchPan(touch, false, armedInteractionMode === "record" ? "record" : "pick");
      }

      var dx = touch.clientX - touchPanState.startX;
      var dy = touch.clientY - touchPanState.startY;
      if (Math.abs(dx) > TOUCH_PAN_THRESHOLD || Math.abs(dy) > TOUCH_PAN_THRESHOLD) {
        touchPanState.moved = true;
      }
      view.offsetX = touchPanState.startOffsetX + dx;
      view.offsetY = touchPanState.startOffsetY + dy;
      drawCanvas();
      evt.preventDefault();
    }
  }, { passive: false });

  b.addEventListener('touchend', function (evt) {
    if (!t) return;

    if (touchSelectionState.active) {
      if (evt.touches.length === 0) {
        finalizeTouchSelection();
      } else if (evt.touches.length === 1) {
        finalizeTouchSelection();
        beginTouchPan(evt.touches[0], true, armedInteractionMode === "record" ? "record" : "pick");
      }
      evt.preventDefault();
      return;
    }

    if (evt.touches.length >= 2) {
      beginTouchPinch(evt.touches[0], evt.touches[1]);
      evt.preventDefault();
      return;
    }

    if (touchPinchState.active && evt.touches.length < 2) {
      touchPinchState.active = false;
    }

    if (evt.touches.length === 1) {
      beginTouchPan(evt.touches[0], true, armedInteractionMode === "record" ? "record" : "pick");
      evt.preventDefault();
      return;
    }

    if (touchPanState.active) {
      var shouldPickColor = !touchPanState.moved;
      var endTouch = evt.changedTouches && evt.changedTouches.length
        ? evt.changedTouches[evt.changedTouches.length - 1]
        : null;
      touchPanState.active = false;
      touchPanState.moved = false;
      $(allDiv).removeClass("panning");
      if (shouldPickColor && endTouch) {
        if (touchPanState.tapAction === "record") {
          var endCoord = u(endTouch.clientX, endTouch.clientY);
          if (endCoord.rawX >= 0 && endCoord.rawX < t.width && endCoord.rawY >= 0 && endCoord.rawY < t.height) {
            openRecordSlotPickerAtImagePoint(endCoord.x, endCoord.y, endTouch.clientX, endTouch.clientY);
            disarmArmedInteractionMode("record");
          }
        } else {
          pickColorByTouch(endTouch);
        }
      }
      touchPanState.tapAction = "pick";
    }

    evt.preventDefault();
  }, { passive: false });

  b.addEventListener('touchcancel', function (evt) {
    resetTouchSelectionState();
    touchPinchState.active = false;
    touchPanState.active = false;
    touchPanState.moved = false;
    touchPanState.tapAction = "pick";
    $(allDiv).removeClass("panning");
    clearMagnifier();
    closeRecordSlotPicker(true);
    evt.preventDefault();
  }, { passive: false });

  // 禁用右键菜单以支持右键拖动
  $("#all_canvas").on("contextmenu", function (e) {
    e.preventDefault();
    return false;
  });

  // 鼠标离开时结束拖拽
  $("#all_canvas").on("mouseleave", function () {
    if (panDragging) {
      panDragging = false;
      $(allDiv).removeClass("panning");
    }
    if (shiftMoveBoxDragging) {
      shiftMoveBoxDragging = false;
      b.style.cursor = 'crosshair';
    }
    if (metaMoveBoxDragging) {
      metaMoveBoxDragging = false;
      b.style.cursor = 'crosshair';
    }
    if (shiftResizeDragging) {
      shiftResizeDragging = false;
      resizeHandle = null;
      b.style.cursor = 'crosshair';
    }
    if (metaResizeDragging) {
      metaResizeDragging = false;
      resizeHandle = null;
      b.style.cursor = 'crosshair';
    }
    clearMagnifier();
    clearHoverPixel();
  });

  // 颜色记录标记按钮点击事件
  var markRecordsBtn = document.getElementById("pk-markRecordsBtn");
  // 初始化按钮状态
  function updateMarkRecordsBtnUI() {
    if (!markRecordsBtn) return;
    if (showRecordMarks) {
      markRecordsBtn.classList.remove("secondary");
      markRecordsBtn.style.background = "linear-gradient(120deg, #9c27b0 0%, #ba68c8 100%)";
      markRecordsBtn.style.color = "#fff";
    } else {
      markRecordsBtn.classList.add("secondary");
      markRecordsBtn.style.background = "";
      markRecordsBtn.style.color = "";
    }
  }
  updateMarkRecordsBtnUI();
  if (markRecordsBtn) {
    markRecordsBtn.addEventListener("click", function () {
      showRecordMarks = !showRecordMarks;
      updateMarkRecordsBtnUI();
      saveMarkStates();
      drawCanvas();
    });
  }

  // 导出到点色列表按钮
  var exportRecordsBtn = document.getElementById("pk-exportRecordsBtn");
  if (exportRecordsBtn) {
    exportRecordsBtn.addEventListener("click", function () {
      var activeRecords = colorRecords.filter(function (r) { return r.active; });
      if (activeRecords.length === 0) {
        showToast("点色记录中没有可导出的记录");
        return;
      }
      var addedCount = 0;
      for (var i = 0; i < activeRecords.length; i++) {
        var rec = activeRecords[i];
        f.color_list.push({
          x: rec.x,
          y: rec.y,
          color: rec.color
        });
        addedCount++;
      }
      f.renderList();
      f.refresh();
      showToast("已导出 " + addedCount + " 个点色记录到点色列表");
    });
  }

  // 重新取色按钮 - 颜色记录
  var repickRecordsBtn = document.getElementById("pk-repickRecordsBtn");
  if (repickRecordsBtn) {
    repickRecordsBtn.addEventListener("click", function () {
      if (!t) {
        showToast("请先打开或截取一张图片");
        return;
      }
      var repickCount = 0;
      for (var i = 0; i < colorRecords.length; i++) {
        var rec = colorRecords[i];
        if (rec.active) {
          // 检查坐标是否在图像范围内
          if (rec.x >= 0 && rec.x < t.width && rec.y >= 0 && rec.y < t.height) {
            var imgData = k.getImageData(rec.x, rec.y, 1, 1);
            var r = imgData.data[0], g = imgData.data[1], b2 = imgData.data[2];
            var hexStr = n(r, g, b2);
            colorRecords[i].color = '0x' + hexStr;
            repickCount++;
          }
        }
      }
      if (repickCount > 0) {
        saveColorRecords();
        renderColorRecordsList();
        refreshColorRecordsCode();
        if (showRecordMarks) {
          drawCanvas();
        }
        showToast("已重新取色 " + repickCount + " 个颜色记录");
      } else {
        showToast("没有可取色的颜色记录");
      }
    });
  }

  // 清空颜色记录按钮
  var clearRecordsBtn = document.getElementById("pk-clearRecordsBtn");
  if (clearRecordsBtn) {
    clearRecordsBtn.addEventListener("click", function () {
      colorRecords = [
        { x: 0, y: 0, color: '0x000000', active: false },
        { x: 0, y: 0, color: '0x000000', active: false },
        { x: 0, y: 0, color: '0x000000', active: false },
        { x: 0, y: 0, color: '0x000000', active: false },
        { x: 0, y: 0, color: '0x000000', active: false }
      ];
      saveColorRecords();
      renderColorRecordsList();
      refreshColorRecordsCode();
      if (showRecordMarks) {
        drawCanvas();
      }
      showToast("颜色记录已清空");
    });
  }

  // 初始化颜色记录列表
  renderColorRecordsList();
  refreshColorRecordsCode();

  // 选区记录点击拷贝事件
  var shiftSelectionCoord = document.getElementById("pk-shiftSelectionCoord");
  var metaSelectionCoord = document.getElementById("pk-metaSelectionCoord");

  if (shiftSelectionCoord) {
    shiftSelectionCoord.addEventListener("click", function () {
      var text = shiftSelectionCoord.textContent;
      copyWithToast(text, '已拷贝 "' + text + '" 到剪贴板');
    });
  }

  if (metaSelectionCoord) {
    metaSelectionCoord.addEventListener("click", function () {
      var text = metaSelectionCoord.textContent;
      copyWithToast(text, '已拷贝 "' + text + '" 到剪贴板');
    });
  }

  // 清除选区按钮事件
  var clearShiftSelectionBtn = document.getElementById("pk-clearShiftSelection");
  var clearMetaSelectionBtn = document.getElementById("pk-clearMetaSelection");

  if (clearShiftSelectionBtn) {
    clearShiftSelectionBtn.addEventListener("click", function () {
      shiftSelection = null;
      updateSelectionRecordUI();
      processShiftSelection();
      drawCanvas();
      showToast("Shift框选区已清除");
    });
  }

  if (clearMetaSelectionBtn) {
    clearMetaSelectionBtn.addEventListener("click", function () {
      metaSelection = null;
      updateSelectionRecordUI();
      processMetaSelection();
      drawCanvas();
      showToast("Meta框选区已清除");
    });
  }

  // 初始化选区记录 UI
  updateSelectionRecordUI();

  m(0, 0);
  document.addEventListener("dragover",
    function (v) {
      v.stopPropagation();
      v.preventDefault()
    },
    false);
  document.addEventListener("drop",
    function (v) {
      v.stopPropagation();
      v.preventDefault();
      var files = v.dataTransfer && v.dataTransfer.files;
      if (files && files.length > 0) { // 只有真正拖入文件时才处理
        l(files);
      }
    },
    false)
});
