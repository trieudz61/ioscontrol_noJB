(function (global) {
  function resolve(elOrSelector) {
    if (!elOrSelector) return null;
    if (typeof elOrSelector === 'string') {
      return document.querySelector(elOrSelector);
    }
    return elOrSelector;
  }

  function showToast(elOrSelector, message, duration) {
    var toast = resolve(elOrSelector);
    if (!toast) return;
    if (typeof duration !== 'number') duration = 2000;
    toast.textContent = message;
    toast.classList.add('show');
    if (toast.__matrixToastTimer) {
      clearTimeout(toast.__matrixToastTimer);
    }
    toast.__matrixToastTimer = setTimeout(function () {
      toast.classList.remove('show');
    }, duration);
  }

  function openModal(elOrSelector) {
    var modal = resolve(elOrSelector);
    if (!modal) return;
    modal.style.display = 'flex';
  }

  function closeModal(elOrSelector) {
    var modal = resolve(elOrSelector);
    if (!modal) return;
    modal.style.display = 'none';
  }

  function bindModalBackdropClose(elOrSelector) {
    var modal = resolve(elOrSelector);
    if (!modal || modal.__matrixBindBackdrop) return;
    var mouseDownTarget = null;
    modal.addEventListener('mousedown', function (e) {
      mouseDownTarget = e.target;
    });
    modal.addEventListener('click', function (e) {
      if (e.target === modal && mouseDownTarget === modal) {
        closeModal(modal);
      }
    });
    modal.__matrixBindBackdrop = true;
  }

  // 存储所有绑定了ESC关闭的modal，用于处理多个modal时只关闭最顶层的
  var _escBoundModals = [];

  /**
   * 绑定ESC键关闭弹窗功能
   * @param {string|Element} elOrSelector - 弹窗元素或选择器
   * @param {string|Element} [cancelBtnOrSelector] - 可选，取消按钮元素或选择器，如果提供则点击该按钮而非直接关闭
   */
  function bindModalEscClose(elOrSelector, cancelBtnOrSelector) {
    var modal = resolve(elOrSelector);
    if (!modal || modal.__matrixBindEsc) return;

    var cancelBtn = cancelBtnOrSelector ? resolve(cancelBtnOrSelector) : null;

    // 将modal信息添加到列表
    _escBoundModals.push({
      modal: modal,
      cancelBtn: cancelBtn
    });

    modal.__matrixBindEsc = true;
  }

  // 全局ESC键监听器（只注册一次）
  var _escListenerBound = false;
  function _ensureGlobalEscListener() {
    if (_escListenerBound) return;
    document.addEventListener('keydown', function (e) {
      if (e.key !== 'Escape') return;

      // 如果焦点在输入框内，不处理ESC（让输入框自己处理）
      var activeEl = document.activeElement;
      if (activeEl && (activeEl.tagName === 'INPUT' || activeEl.tagName === 'TEXTAREA')) {
        // 但如果输入框在modal内，还是要处理
        var inModal = false;
        for (var i = 0; i < _escBoundModals.length; i++) {
          if (_escBoundModals[i].modal.contains(activeEl) && 
              _escBoundModals[i].modal.style.display !== 'none') {
            inModal = true;
            break;
          }
        }
        if (!inModal) return;
      }

      // 找到当前可见的最后一个modal（最顶层）
      var topModal = null;
      for (var i = _escBoundModals.length - 1; i >= 0; i--) {
        var item = _escBoundModals[i];
        if (item.modal.style.display !== 'none') {
          topModal = item;
          break;
        }
      }

      if (topModal) {
        e.preventDefault();
        e.stopPropagation();
        if (topModal.cancelBtn) {
          topModal.cancelBtn.click();
        } else {
          closeModal(topModal.modal);
        }
      }
    });
    _escListenerBound = true;
  }

  // 确保在绑定时启动全局监听器
  var _origBindModalEscClose = bindModalEscClose;
  bindModalEscClose = function (elOrSelector, cancelBtnOrSelector) {
    _ensureGlobalEscListener();
    _origBindModalEscClose(elOrSelector, cancelBtnOrSelector);
  };

  function formatCoord(x, y) {
    return x + ', ' + y;
  }

  function formatRect(rect) {
    if (!rect) return '0, 0, 0, 0';
    var l = rect.left != null ? rect.left : rect.x != null ? rect.x : 0;
    var t = rect.top != null ? rect.top : rect.y != null ? rect.y : 0;
    var r = rect.right != null ? rect.right : rect.x != null && rect.w != null ? rect.x + rect.w : 0;
    var b = rect.bottom != null ? rect.bottom : rect.y != null && rect.h != null ? rect.y + rect.h : 0;
    return [l, t, r, b].join(', ');
  }

  function clamp(v, min, max) {
    return Math.max(min, Math.min(max, v));
  }

  function normalizeRect(x0, y0, x1, y1) {
    var x = Math.min(x0, x1);
    var y = Math.min(y0, y1);
    var w = Math.abs(x1 - x0);
    var h = Math.abs(y1 - y0);
    return { x: x, y: y, w: w, h: h };
  }

  function timestampCompact() {
    var now = new Date();
    var pad = function (n, w) { return String(n).padStart(w, '0'); };
    return pad(now.getFullYear(), 4)
      + pad(now.getMonth() + 1, 2)
      + pad(now.getDate(), 2)
      + pad(now.getHours(), 2)
      + pad(now.getMinutes(), 2)
      + pad(now.getSeconds(), 2)
      + pad(now.getMilliseconds(), 3);
  }

  // timestampReadable 与 timestampCompact 相同，保留别名以兼容
  var timestampReadable = timestampCompact;

  function copyText(text) {
    if (text == null) return Promise.resolve(false);
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(String(text)).then(function () { return true; }).catch(function () {
        return fallbackCopy(text);
      });
    }
    return Promise.resolve(fallbackCopy(text));
  }

  function fallbackCopy(text) {
    try {
      var tmp = document.createElement('textarea');
      tmp.value = String(text);
      tmp.style.position = 'fixed';
      tmp.style.opacity = '0';
      document.body.appendChild(tmp);
      tmp.select();
      var ok = document.execCommand('copy');
      document.body.removeChild(tmp);
      return ok;
    } catch (e) {
      console.warn('copyText fallback failed', e);
      return false;
    }
  }

  function clampHex(str) {
    return (str || '').replace(/[^0-9a-fA-F]/g, '').toUpperCase().slice(0, 6).padEnd(6, '0');
  }

  function hexToRgb(hex6) {
    if (!hex6 || hex6.length < 6) return null;
    return [
      parseInt(hex6.slice(0, 2), 16),
      parseInt(hex6.slice(2, 4), 16),
      parseInt(hex6.slice(4, 6), 16)
    ];
  }

  function rgbToHex(r, g, b) {
    return [r, g, b].map(function (v) { return v.toString(16).padStart(2, '0'); }).join('').toUpperCase();
  }

  // 调整框大小的手柄检测
  function getResizeHandle(canvasX, canvasY, selection, imgW, imgH, baseX, baseY, scale, handleSize) {
    if (!selection || selection.w <= 0 || selection.h <= 0) return null;
    handleSize = handleSize || 8;
    var selX = baseX + selection.x * scale;
    var selY = baseY + selection.y * scale;
    var selW = selection.w * scale;
    var selH = selection.h * scale;
    var tolerance = Math.max(8, handleSize);
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
      var h = handles[i];
      if (Math.abs(canvasX - h.x) <= tolerance && Math.abs(canvasY - h.y) <= tolerance) {
        return h.name;
      }
    }
    return null;
  }

  // 根据手柄类型获取对应的光标样式
  function getResizeCursor(handle) {
    var cursors = {
      'n': 'ns-resize', 's': 'ns-resize',
      'e': 'ew-resize', 'w': 'ew-resize',
      'nw': 'nwse-resize', 'se': 'nwse-resize',
      'ne': 'nesw-resize', 'sw': 'nesw-resize'
    };
    return cursors[handle] || 'default';
  }

  // 安全读取 localStorage
  function storageGet(key, defaultValue) {
    try {
      var saved = localStorage.getItem(key);
      return saved ? JSON.parse(saved) : defaultValue;
    } catch (e) {
      console.warn('读取 localStorage 失败:', key, e);
      return defaultValue;
    }
  }

  // 安全写入 localStorage
  function storageSet(key, value) {
    try {
      localStorage.setItem(key, JSON.stringify(value));
      return true;
    } catch (e) {
      console.warn('写入 localStorage 失败:', key, e);
      return false;
    }
  }

  // 绘制悬停像素高亮框
  function drawHoverMarker(ctx, hoverPixel, baseX, baseY, scale) {
    if (!hoverPixel) return;
    var drawX = baseX + hoverPixel.x * scale;
    var drawY = baseY + hoverPixel.y * scale;
    var size = Math.max(scale, 4);
    ctx.save();
    ctx.setLineDash([4, 2]);
    ctx.strokeStyle = 'rgba(227, 95, 74, 0.95)';
    ctx.lineWidth = 1.6;
    ctx.strokeRect(drawX - 0.5, drawY - 0.5, size, size);
    ctx.restore();
  }

  // 绘制选区框及调整手柄
  function drawSelectionBox(ctx, selection, baseX, baseY, scale, strokeColor, fillColor) {
    if (!selection || selection.w <= 0 || selection.h <= 0) return;
    var selX = baseX + selection.x * scale;
    var selY = baseY + selection.y * scale;
    var selW = selection.w * scale;
    var selH = selection.h * scale;
    ctx.save();
    ctx.strokeStyle = strokeColor || 'rgba(227,95,74,0.9)';
    ctx.lineWidth = 1.2;
    ctx.setLineDash([6, 4]);
    ctx.fillStyle = fillColor || 'rgba(227, 95, 74, 0.12)';
    ctx.fillRect(selX, selY, selW, selH);
    ctx.strokeRect(selX, selY, selW, selH);
    // 绘制调整手柄
    ctx.setLineDash([]);
    ctx.fillStyle = '#ffffff';
    ctx.strokeStyle = strokeColor || 'rgba(227,95,74,1)';
    ctx.lineWidth = 1.5;
    var hs = Math.max(6, Math.min(10, 8));
    var handles = [
      { x: selX, y: selY }, { x: selX + selW / 2, y: selY }, { x: selX + selW, y: selY },
      { x: selX + selW, y: selY + selH / 2 }, { x: selX + selW, y: selY + selH },
      { x: selX + selW / 2, y: selY + selH }, { x: selX, y: selY + selH }, { x: selX, y: selY + selH / 2 }
    ];
    for (var i = 0; i < handles.length; i++) {
      var h = handles[i];
      ctx.beginPath();
      ctx.rect(h.x - hs / 2, h.y - hs / 2, hs, hs);
      ctx.fill();
      ctx.stroke();
    }
    ctx.restore();
  }

  global.MatrixHelpers = {
    resolve: resolve,
    showToast: showToast,
    openModal: openModal,
    closeModal: closeModal,
    bindModalBackdropClose: bindModalBackdropClose,
    bindModalEscClose: bindModalEscClose,
    formatCoord: formatCoord,
    formatRect: formatRect,
    clamp: clamp,
    normalizeRect: normalizeRect,
    timestampCompact: timestampCompact,
    timestampReadable: timestampReadable,
    copyText: copyText,
    clampHex: clampHex,
    hexToRgb: hexToRgb,
    rgbToHex: rgbToHex,
    getResizeHandle: getResizeHandle,
    getResizeCursor: getResizeCursor,
    storageGet: storageGet,
    storageSet: storageSet,
    drawHoverMarker: drawHoverMarker,
    drawSelectionBox: drawSelectionBox
  };
})(window);
