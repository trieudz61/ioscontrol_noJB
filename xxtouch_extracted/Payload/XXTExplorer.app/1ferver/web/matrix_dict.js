/**
 * matrix_dict.js - 点阵字库制作
 */

/* 支持的点阵行格式（word 可能包含 $，注意从首个/末尾 $ 定位字段）：
 * 1) bits$word$left.right.match$height[.width]
 * 2) bits$word$match$height$width              （后三段为纯整数，尾部三段倒序定位）
 * 共性规则：
 * - bits 可在末尾使用 @<1~3 位二进制> 保存不足 4 位的尾部数据；无 @ 时按宽高裁剪/补 0。
 * - height<=0 默认 11；缺宽时按 bits 推算；match<=0 视为无效。
 */

$(document).ready(function () {
  // 初始化页面后执行
  setTimeout(initMatrixDict, 100);
});

function initMatrixDict() {
  const showToast = (msg) => MatrixHelpers.showToast('#md-toast', msg);
  const openModal = MatrixHelpers.openModal;
  const closeModal = MatrixHelpers.closeModal;
  const formatCoord = MatrixHelpers.formatCoord;
  const formatRect = MatrixHelpers.formatRect;
  const clamp = MatrixHelpers.clamp;
  const normalizeRect = MatrixHelpers.normalizeRect;
  const getReadableTimestamp = MatrixHelpers.timestampReadable;
  const copyText = MatrixHelpers.copyText;
  const clampHex = MatrixHelpers.clampHex;
  const hexToRgb = MatrixHelpers.hexToRgb;
  const rgbToHex = MatrixHelpers.rgbToHex;

  async function copyWithToast(text, message) {
    const ok = await copyText(text);
    if (ok !== false) {
      showToast(message || '已拷贝到剪贴板');
    }
  }

  const canvasOriginal = document.getElementById('md-stageOriginal');
  const ctxOriginal = canvasOriginal.getContext('2d');
  const canvasBinary = document.getElementById('md-stageBinary');
  const ctxBinary = canvasBinary.getContext('2d');
  ctxOriginal.imageSmoothingEnabled = false;
  ctxBinary.imageSmoothingEnabled = false;

  const wordInput = document.getElementById('md-word');
  const leftInput = document.getElementById('md-leftCols');
  const rightInput = document.getElementById('md-rightCols');
  const statSelection = document.getElementById('md-statSelection');
  const statBitsLen = document.getElementById('md-statBitsLen');
  const lineField = document.getElementById('md-lineField');
  const colorRangeList = document.getElementById('md-colorRangeList');
  const colorRangeText = document.getElementById('md-colorRangeText');
  const setColorRangeBtn = document.getElementById('md-setColorRangeBtn');
  const selectAllColorsBtn = document.getElementById('md-selectAllColors');
  const deselectAllColorsBtn = document.getElementById('md-deselectAllColors');
  const clearColorListBtn = document.getElementById('md-clearColorListBtn');
  const zoomRange = document.getElementById('md-zoomRange');
  const zoomLabel = document.getElementById('md-zoomLabel');
  const panelLeft = document.querySelector('.matrix-panel-left');
  const layoutButtons = document.querySelectorAll('[data-md-layout]');
  const armedAltBtn = document.getElementById('md-armedAltBtn');
  const armedShiftBtn = document.getElementById('md-armedShiftBtn');
  const armedMetaBtn = document.getElementById('md-armedMetaBtn');
  const colorPickPopover = document.getElementById('md-colorPickPopover');
  const colorPickBaseSwatch = document.getElementById('md-colorPickBaseSwatch');
  const colorPickBaseHex = document.getElementById('md-colorPickBaseHex');
  const colorPickCoord = document.getElementById('md-colorPickCoord');
  const colorPickTolHex = document.getElementById('md-colorPickTolHex');
  const colorPickTolR = document.getElementById('md-colorPickTolR');
  const colorPickTolG = document.getElementById('md-colorPickTolG');
  const colorPickTolB = document.getElementById('md-colorPickTolB');
  const colorPickTolRInput = document.getElementById('md-colorPickTolRInput');
  const colorPickTolGInput = document.getElementById('md-colorPickTolGInput');
  const colorPickTolBInput = document.getElementById('md-colorPickTolBInput');
  const colorPickAddBtn = document.getElementById('md-colorPickAddBtn');
  const colorPickCancelBtn = document.getElementById('md-colorPickCancelBtn');

  // 自定义模板相关元素
  const customTpl1Btn = document.getElementById('md-customTpl1Btn');
  const customTpl2Btn = document.getElementById('md-customTpl2Btn');
  const customTpl3Btn = document.getElementById('md-customTpl3Btn');
  const customTpl4Btn = document.getElementById('md-customTpl4Btn');
  const customTpl5Btn = document.getElementById('md-customTpl5Btn');
  const customTpl6Btn = document.getElementById('md-customTpl6Btn');
  const customTplModal = document.getElementById('md-customTplModal');
  const customTplNameInput = document.getElementById('md-customTplNameInput');
  const customTplCode = document.getElementById('md-customTplCode');
  const customTplCoreLine = document.getElementById('md-customTplCoreLine');
  const customTplPreview = document.getElementById('md-customTplPreview');
  const customTplCopyCode = document.getElementById('md-customTplCopyCode');
  const customTplCopyCoreLine = document.getElementById('md-customTplCopyCoreLine');
  const closeCustomTplModal = document.getElementById('md-closeCustomTplModal');

  let img = null;
  let selection = null;
  let dragging = false;
  let dragStart = { x: 0, y: 0 };
  let state = {
    bits: '',
    grid: [],
    width: 0,
    height: 0,
    bitHeight: 0,
    matchCount: 0,
    left: 0,
    right: 0,
    onesInBitHeight: 0
  };
  let colorRanges = [];  // 存储所有颜色范围，每个元素包含 { base, tol, text, enabled }
  let defaultTolerance = '101010';  // 默认容差值
  let colorRangeHistory = [];  // 偏色列表撤销历史
  const MAX_UNDO_HISTORY = 50;  // 最大撤销历史数量
  let binaryMask = null;
  let binaryImageData = null;
  let binaryCanvas = null;
  let sourceCanvas = null;
  let view = { scale: 1, offsetX: 0, offsetY: 0 };
  // 鼠标悬停高亮的像素坐标（图像坐标系）
  let hoverPixel = null;
  let panDragging = false;
  let panStart = { x: 0, y: 0, offsetX: 0, offsetY: 0 };
  let panMoved = false;
  let panDragCanvas = null;
  const MOUSE_PAN_CLICK_THRESHOLD = 4;
  let moveBoxDragging = false;
  let moveBoxStart = { x: 0, y: 0, selX: 0, selY: 0 };
  let layoutMode = 'vertical';

  // 调整选框大小相关状态
  let resizeDragging = false;
  let resizeHandle = null; // 'n', 's', 'e', 'w', 'nw', 'ne', 'sw', 'se'
  let resizeStart = { x: 0, y: 0, selX: 0, selY: 0, selW: 0, selH: 0 };
  const HANDLE_SIZE = 8; // 调整手柄的像素大小（在画布坐标中）

  // Meta 框选状态 (用于代码模板区域)
  let metaSelection = null;  // Meta+左键框选的框 {x, y, w, h}
  let metaDragging = false;
  let metaResizeDragging = false;
  let metaMoveBoxDragging = false;
  let metaMoveBoxStart = { x: 0, y: 0, selX: 0, selY: 0 };
  let metaResizeStart = { x: 0, y: 0, selX: 0, selY: 0, selW: 0, selH: 0 };
  let metaResizeHandle = null;
  let metaDragStart = { x: 0, y: 0 };
  // null | 'sample-alt' | 'select-shift' | 'select-meta'
  let armedInteractionMode = null;
  let touchPanState = {
    active: false,
    moved: false,
    tapAction: 'none',
    canvas: null,
    startX: 0,
    startY: 0,
    startOffsetX: 0,
    startOffsetY: 0
  };
  let touchPinchState = {
    active: false,
    canvas: null,
    startDistance: 1,
    startScale: 1,
    startOffsetX: 0,
    startOffsetY: 0,
    startCenterDX: 0,
    startCenterDY: 0
  };
  let touchSelectionState = {
    active: false,
    target: 'shift',
    startX: 0,
    startY: 0
  };
  let colorPickState = {
    open: false,
    anchorClientX: 0,
    anchorClientY: 0,
    imgX: 0,
    imgY: 0,
    baseRgb: [0, 0, 0],
    tolRgb: [16, 16, 16]
  };
  let colorPickOutsideGuardUntil = 0;
  const TOUCH_PAN_THRESHOLD = 6;

  // 点阵列表相关
  let matrixList = [];
  let selectedMatrixIndex = -1;
  const matrixListBody = document.getElementById('md-matrixListBody');
  const matrixListCount = document.getElementById('md-matrixListCount');
  const importMatrixBtn = document.getElementById('md-importMatrixBtn');
  const exportMatrixBtn = document.getElementById('md-exportMatrixBtn');
  const clearMatrixBtn = document.getElementById('md-clearMatrixBtn');
  const importMatrixFile = document.getElementById('md-importMatrixFile');

  // 工具函数
  function updateZoomUI() {
    const percent = Math.round(view.scale * 100);
    zoomRange.value = clamp(percent, 10, 2000);
    zoomLabel.textContent = `${percent}%`;
  }

  function updateArmedModeButtonsUI() {
    if (armedAltBtn) armedAltBtn.classList.toggle('is-active', armedInteractionMode === 'sample-alt');
    if (armedShiftBtn) armedShiftBtn.classList.toggle('is-active', armedInteractionMode === 'select-shift');
    if (armedMetaBtn) armedMetaBtn.classList.toggle('is-active', armedInteractionMode === 'select-meta');
  }

  function toggleArmedInteractionMode(mode) {
    armedInteractionMode = armedInteractionMode === mode ? null : mode;
    updateArmedModeButtonsUI();
  }

  function disarmArmedInteractionMode(mode) {
    if (armedInteractionMode !== mode) return;
    armedInteractionMode = null;
    updateArmedModeButtonsUI();
  }

  if (armedAltBtn) {
    armedAltBtn.addEventListener('click', () => {
      toggleArmedInteractionMode('sample-alt');
    });
  }
  if (armedShiftBtn) {
    armedShiftBtn.addEventListener('click', () => {
      toggleArmedInteractionMode('select-shift');
    });
  }
  if (armedMetaBtn) {
    armedMetaBtn.addEventListener('click', () => {
      toggleArmedInteractionMode('select-meta');
    });
  }
  updateArmedModeButtonsUI();

  function getCanvasDevicePixelRatio() {
    return Math.max(1, window.devicePixelRatio || 1);
  }

  function getCanvasLogicalSize(cvs, wrapper) {
    if (!cvs) return { width: 1, height: 1 };
    const base = wrapper || cvs.parentElement || cvs;
    const rect = base.getBoundingClientRect();
    const width = (base !== cvs ? rect.width : cvs.clientWidth) || cvs.clientWidth || 1;
    const height = (base !== cvs ? rect.height : cvs.clientHeight) || cvs.clientHeight || 1;
    return {
      width: Math.max(1, Math.round(width)),
      height: Math.max(1, Math.round(height))
    };
  }

  function ensureCanvasResolution(cvs, logicalWidth, logicalHeight) {
    const dpr = getCanvasDevicePixelRatio();
    const pixelWidth = Math.max(1, Math.round(logicalWidth * dpr));
    const pixelHeight = Math.max(1, Math.round(logicalHeight * dpr));
    if (cvs.width !== pixelWidth) cvs.width = pixelWidth;
    if (cvs.height !== pixelHeight) cvs.height = pixelHeight;
    cvs.style.width = `${logicalWidth}px`;
    cvs.style.height = `${logicalHeight}px`;
    return {
      logicalWidth,
      logicalHeight,
      scaleX: cvs.width / Math.max(1, logicalWidth),
      scaleY: cvs.height / Math.max(1, logicalHeight)
    };
  }

  function resizeCanvasToWrapper() {
    const wrappers = document.querySelectorAll('.matrix-canvas-wrapper');
    wrappers.forEach((wrapper, idx) => {
      const cvs = idx === 0 ? canvasOriginal : canvasBinary;
      const logical = getCanvasLogicalSize(cvs, wrapper);
      ensureCanvasResolution(cvs, logical.width, logical.height);
    });
    if (img) {
      drawOriginal();
      renderBinaryOverlayOnly();
    } else {
      resetCanvas();
    }
  }
  function applyLayoutMode(mode) {
    layoutMode = mode === 'horizontal' ? 'horizontal' : 'vertical';
    if (panelLeft) {
      panelLeft.classList.toggle('layout-horizontal', layoutMode === 'horizontal');
      panelLeft.classList.toggle('layout-vertical', layoutMode === 'vertical');
    }
    layoutButtons.forEach(btn => {
      const isActive = (btn.dataset.mdLayout || 'vertical') === layoutMode;
      btn.classList.toggle('active', isActive);
    });
    try {
      localStorage.setItem('matrix_dict_layout_mode', layoutMode);
    } catch (e) {
      console.warn('保存布局失败', e);
    }
    resizeCanvasToWrapper();
  }

  function renderColorRanges() {
    colorRangeList.innerHTML = '';
    // 同步更新文本框，只显示已勾选的偏色
    updateColorRangeText();
    colorRanges.forEach((c, idx) => {
      const div = document.createElement('div');
      div.className = 'matrix-color-item';
      div.draggable = true;
      div.dataset.index = idx;

      // 拖拽手柄
      const dragHandle = document.createElement('span');
      dragHandle.className = 'drag-handle';
      dragHandle.textContent = '⋮⋮';
      dragHandle.title = '拖动排序';
      div.appendChild(dragHandle);

      // 勾选框
      const checkbox = document.createElement('input');
      checkbox.type = 'checkbox';
      checkbox.checked = c.enabled !== false;  // 默认启用
      checkbox.title = '勾选以应用此偏色范围';
      checkbox.addEventListener('change', () => {
        colorRanges[idx].enabled = checkbox.checked;
        updateColorRangeText();  // 勾选变化时更新文本框
        saveColorRangesToStorage();
        recomputeBinary();
      });
      div.appendChild(checkbox);

      // 颜色色块
      const sw = document.createElement('span');
      sw.className = 'swatch';
      sw.style.background = `rgb(${c.base.join(',')})`;
      div.appendChild(sw);

      // 颜色文本
      const txt = document.createElement('span');
      txt.className = 'color-text';
      txt.textContent = c.text;
      txt.title = c.text;
      div.appendChild(txt);

      // 删除按钮
      const btn = document.createElement('button');
      btn.className = 'delete-btn';
      btn.textContent = '×';
      btn.title = '删除';
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        saveColorRangeUndoState();
        colorRanges.splice(idx, 1);
        renderColorRanges();
        saveColorRangesToStorage();
        recomputeBinary();
        showToast('已删除（⌘/Ctrl+Z 撤销）');
      });
      div.appendChild(btn);

      // 点击整行勾选/取消勾选
      div.addEventListener('click', (e) => {
        // 排除拖拽手柄、复选框和删除按钮的点击
        if (e.target.classList.contains('drag-handle') ||
          e.target.type === 'checkbox' ||
          e.target.classList.contains('delete-btn')) {
          return;
        }
        checkbox.checked = !checkbox.checked;
        colorRanges[idx].enabled = checkbox.checked;
        updateColorRangeText();
        saveColorRangesToStorage();
        recomputeBinary();
      });

      // 右键菜单
      div.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        showColorRangeContextMenu(e, idx);
      });

      // 拖拽事件
      div.addEventListener('dragstart', (e) => {
        div.classList.add('dragging');
        e.dataTransfer.effectAllowed = 'move';
        e.dataTransfer.setData('text/plain', idx);
      });
      div.addEventListener('dragend', () => {
        div.classList.remove('dragging');
        document.querySelectorAll('.matrix-color-item.drag-over').forEach(el => el.classList.remove('drag-over'));
      });
      div.addEventListener('dragover', (e) => {
        e.preventDefault();
        e.dataTransfer.dropEffect = 'move';
        div.classList.add('drag-over');
      });
      div.addEventListener('dragleave', () => {
        div.classList.remove('drag-over');
      });
      div.addEventListener('drop', (e) => {
        e.preventDefault();
        div.classList.remove('drag-over');
        const fromIdx = parseInt(e.dataTransfer.getData('text/plain'));
        const toIdx = idx;
        if (fromIdx !== toIdx) {
          const [moved] = colorRanges.splice(fromIdx, 1);
          colorRanges.splice(toIdx, 0, moved);
          renderColorRanges();
          saveColorRangesToStorage();
          recomputeBinary();
        }
      });

      colorRangeList.appendChild(div);
    });
  }

  // 右键菜单相关
  let currentContextMenu = null;

  function hideContextMenu() {
    if (currentContextMenu) {
      currentContextMenu.remove();
      currentContextMenu = null;
    }
  }

  function showColorRangeContextMenu(e, idx) {
    hideContextMenu();

    const menu = document.createElement('div');
    menu.className = 'matrix-context-menu';
    menu.style.left = `${e.clientX}px`;
    menu.style.top = `${e.clientY}px`;

    const item = colorRanges[idx];

    // 勾选/取消勾选
    const toggleItem = document.createElement('div');
    toggleItem.className = 'matrix-context-menu-item';
    toggleItem.textContent = item.enabled !== false ? '取消勾选' : '勾选';
    toggleItem.addEventListener('click', () => {
      colorRanges[idx].enabled = item.enabled === false;
      renderColorRanges();
      saveColorRangesToStorage();
      recomputeBinary();
      hideContextMenu();
    });
    menu.appendChild(toggleItem);

    // 编辑
    const editItem = document.createElement('div');
    editItem.className = 'matrix-context-menu-item';
    editItem.textContent = '编辑';
    editItem.addEventListener('click', () => {
      hideContextMenu();
      showEditColorRangeDialog(idx);
    });
    menu.appendChild(editItem);

    // 分隔线
    const separator = document.createElement('div');
    separator.className = 'matrix-context-menu-separator';
    menu.appendChild(separator);

    // 删除
    const deleteItem = document.createElement('div');
    deleteItem.className = 'matrix-context-menu-item danger';
    deleteItem.textContent = '删除';
    deleteItem.addEventListener('click', () => {
      hideContextMenu();
      saveColorRangeUndoState();
      colorRanges.splice(idx, 1);
      renderColorRanges();
      saveColorRangesToStorage();
      recomputeBinary();
      showToast('已删除（⌘/Ctrl+Z 撤销）');
    });
    menu.appendChild(deleteItem);

    document.body.appendChild(menu);
    currentContextMenu = menu;

    // 确保菜单不超出屏幕
    const rect = menu.getBoundingClientRect();
    if (rect.right > window.innerWidth) {
      menu.style.left = `${window.innerWidth - rect.width - 5}px`;
    }
    if (rect.bottom > window.innerHeight) {
      menu.style.top = `${window.innerHeight - rect.height - 5}px`;
    }

    // 点击其他地方关闭菜单
    setTimeout(() => {
      document.addEventListener('click', hideContextMenu, { once: true });
    }, 0);
  }

  function showSelectionContextMenu(e, selType) {
    hideContextMenu();

    const menu = document.createElement('div');
    menu.className = 'matrix-context-menu';
    menu.style.left = `${e.clientX}px`;
    menu.style.top = `${e.clientY}px`;

    const editItem = document.createElement('div');
    editItem.className = 'matrix-context-menu-item';
    editItem.textContent = '编辑';
    editItem.addEventListener('click', () => {
      hideContextMenu();
      showEditSelectionDialog(selType);
    });
    menu.appendChild(editItem);

    document.body.appendChild(menu);
    currentContextMenu = menu;

    const rect = menu.getBoundingClientRect();
    if (rect.right > window.innerWidth) {
      menu.style.left = `${window.innerWidth - rect.width - 5}px`;
    }
    if (rect.bottom > window.innerHeight) {
      menu.style.top = `${window.innerHeight - rect.height - 5}px`;
    }

    setTimeout(() => {
      document.addEventListener('click', hideContextMenu, { once: true });
    }, 0);
  }

  // 编辑偏色弹窗相关
  let editColorIndex = -1;
  const editColorModal = document.getElementById('md-editColorModal');
  const editColorInput = document.getElementById('md-editColorInput');
  const closeEditColorModal = document.getElementById('md-closeEditColorModal');
  const editColorCancelBtn = document.getElementById('md-editColorCancelBtn');
  const editColorConfirmBtn = document.getElementById('md-editColorConfirmBtn');

  function showEditColorRangeDialog(idx) {
    editColorIndex = idx;
    const item = colorRanges[idx];
    editColorInput.value = item.text;
    openModal(editColorModal);
    editColorInput.focus();
    editColorInput.select();
  }

  function hideEditColorModal() {
    closeModal(editColorModal);
    editColorIndex = -1;
  }

  function confirmEditColor() {
    if (editColorIndex < 0) return;

    const newValue = editColorInput.value.trim();
    const match = newValue.match(/^([0-9A-Fa-f]{6})-([0-9A-Fa-f]{6})$/);
    if (!match) {
      showToast('格式不正确，应为: RRGGBB-RRGGBB');
      return;
    }

    const baseHex = match[1].toUpperCase();
    const tolHex = match[2].toUpperCase();
    const newText = `${baseHex}-${tolHex}`;

    // 检查是否与其他项重复
    if (colorRanges.some((c, i) => i !== editColorIndex && c.text === newText)) {
      showToast('该偏色范围已存在');
      return;
    }

    const base = hexToRgb(baseHex);
    const tol = hexToRgb(tolHex);
    if (!base || !tol) {
      showToast('颜色值无效');
      return;
    }

    colorRanges[editColorIndex].base = base;
    colorRanges[editColorIndex].tol = tol;
    colorRanges[editColorIndex].text = newText;

    hideEditColorModal();
    renderColorRanges();
    saveColorRangesToStorage();
    recomputeBinary();
    showToast('已更新');
  }

  closeEditColorModal.addEventListener('click', hideEditColorModal);
  editColorCancelBtn.addEventListener('click', hideEditColorModal);
  editColorConfirmBtn.addEventListener('click', confirmEditColor);
  MatrixHelpers.bindModalBackdropClose(editColorModal);
  MatrixHelpers.bindModalEscClose(editColorModal, editColorCancelBtn);
  editColorInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      confirmEditColor();
    }
  });

  // 删除偏色确认弹窗相关
  let deleteColorIndex = -1;
  const deleteColorModal = document.getElementById('md-deleteColorModal');
  const deleteColorText = document.getElementById('md-deleteColorText');
  const closeDeleteColorModal = document.getElementById('md-closeDeleteColorModal');
  const deleteColorCancelBtn = document.getElementById('md-deleteColorCancelBtn');
  const deleteColorConfirmBtn = document.getElementById('md-deleteColorConfirmBtn');

  function showDeleteColorRangeDialog(idx) {
    deleteColorIndex = idx;
    const item = colorRanges[idx];
    deleteColorText.textContent = item.text;
    openModal(deleteColorModal);
  }

  function hideDeleteColorModal() {
    closeModal(deleteColorModal);
    deleteColorIndex = -1;
  }

  function confirmDeleteColor() {
    if (deleteColorIndex < 0) return;

    saveColorRangeUndoState();
    colorRanges.splice(deleteColorIndex, 1);
    hideDeleteColorModal();
    renderColorRanges();
    saveColorRangesToStorage();
    recomputeBinary();
    showToast('已删除');
  }

  closeDeleteColorModal.addEventListener('click', hideDeleteColorModal);
  deleteColorCancelBtn.addEventListener('click', hideDeleteColorModal);
  deleteColorConfirmBtn.addEventListener('click', confirmDeleteColor);
  MatrixHelpers.bindModalBackdropClose(deleteColorModal);
  MatrixHelpers.bindModalEscClose(deleteColorModal, deleteColorCancelBtn);

  // 清空偏色列表确认弹窗相关
  const clearColorListModal = document.getElementById('md-clearColorListModal');
  const closeClearColorListModal = document.getElementById('md-closeClearColorListModal');
  const clearColorListCancelBtn = document.getElementById('md-clearColorListCancelBtn');
  const clearColorListConfirmBtn = document.getElementById('md-clearColorListConfirmBtn');

  function showClearColorListDialog() {
    if (colorRanges.length === 0) {
      showToast('列表已为空');
      return;
    }
    openModal(clearColorListModal);
  }

  function hideClearColorListModal() {
    closeModal(clearColorListModal);
  }

  function confirmClearColorList() {
    saveColorRangeUndoState();
    colorRanges = [];
    hideClearColorListModal();
    renderColorRanges();
    saveColorRangesToStorage();
    recomputeBinary();
    showToast('已清空偏色列表');
  }

  closeClearColorListModal.addEventListener('click', hideClearColorListModal);
  clearColorListCancelBtn.addEventListener('click', hideClearColorListModal);
  clearColorListConfirmBtn.addEventListener('click', confirmClearColorList);
  MatrixHelpers.bindModalBackdropClose(clearColorListModal);
  MatrixHelpers.bindModalEscClose(clearColorListModal, clearColorListCancelBtn);

  // 默认容差设置弹窗相关
  const defaultToleranceBtn = document.getElementById('md-defaultToleranceBtn');
  const defaultToleranceModal = document.getElementById('md-defaultToleranceModal');
  const defaultToleranceInput = document.getElementById('md-defaultToleranceInput');
  const closeDefaultToleranceModal = document.getElementById('md-closeDefaultToleranceModal');
  const defaultToleranceCancelBtn = document.getElementById('md-defaultToleranceCancelBtn');
  const defaultToleranceConfirmBtn = document.getElementById('md-defaultToleranceConfirmBtn');

  function showDefaultToleranceModal() {
    defaultToleranceInput.value = defaultTolerance;
    openModal(defaultToleranceModal);
    defaultToleranceInput.focus();
    defaultToleranceInput.select();
  }

  function hideDefaultToleranceModal() {
    closeModal(defaultToleranceModal);
  }

  function confirmDefaultTolerance() {
    const value = defaultToleranceInput.value.trim().toUpperCase();
    if (!/^[0-9A-F]{6}$/.test(value)) {
      showToast('格式不正确，应为 6 位十六进制数');
      return;
    }
    defaultTolerance = value;
    saveDefaultToleranceToStorage();
    hideDefaultToleranceModal();
    showToast(`默认容差已设置为 ${value}`);
  }

  function saveDefaultToleranceToStorage() {
    try {
      localStorage.setItem('matrix_dict_default_tolerance', defaultTolerance);
    } catch (e) {
      console.warn('保存默认容差失败:', e);
    }
  }

  function loadDefaultToleranceFromStorage() {
    try {
      const saved = localStorage.getItem('matrix_dict_default_tolerance');
      if (saved && /^[0-9A-Fa-f]{6}$/.test(saved)) {
        defaultTolerance = saved.toUpperCase();
      }
    } catch (e) {
      console.warn('加载默认容差失败:', e);
    }
  }

  defaultToleranceBtn.addEventListener('click', showDefaultToleranceModal);
  closeDefaultToleranceModal.addEventListener('click', hideDefaultToleranceModal);
  defaultToleranceCancelBtn.addEventListener('click', hideDefaultToleranceModal);
  defaultToleranceConfirmBtn.addEventListener('click', confirmDefaultTolerance);
  MatrixHelpers.bindModalBackdropClose(defaultToleranceModal);
  MatrixHelpers.bindModalEscClose(defaultToleranceModal, defaultToleranceCancelBtn);
  defaultToleranceInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      confirmDefaultTolerance();
    }
  });

  function clampByte(value, fallback) {
    const parsed = Number.parseInt(value, 10);
    if (!Number.isFinite(parsed)) {
      return clamp(Number.isFinite(fallback) ? fallback : 0, 0, 255);
    }
    return clamp(parsed, 0, 255);
  }

  function setPopoverToleranceFromHex(hex) {
    const normalized = (typeof hex === 'string' ? hex.trim().toUpperCase() : '');
    const safeHex = /^[0-9A-F]{6}$/.test(normalized) ? normalized : '101010';
    const rgb = hexToRgb(safeHex);
    if (!rgb) {
      colorPickState.tolRgb = [16, 16, 16];
      return;
    }
    colorPickState.tolRgb = [
      clampByte(rgb[0], 16),
      clampByte(rgb[1], 16),
      clampByte(rgb[2], 16)
    ];
  }

  function setPopoverToleranceFromDefault() {
    setPopoverToleranceFromHex(defaultTolerance);
  }

  function getToleranceHexFromPopover() {
    const [r, g, b] = colorPickState.tolRgb;
    return rgbToHex(clampByte(r, 0), clampByte(g, 0), clampByte(b, 0));
  }

  function syncPopoverControlsFromState() {
    if (!colorPickPopover) return;
    const baseRgb = colorPickState.baseRgb || [0, 0, 0];
    const tolR = clampByte(colorPickState.tolRgb[0], 0);
    const tolG = clampByte(colorPickState.tolRgb[1], 0);
    const tolB = clampByte(colorPickState.tolRgb[2], 0);
    colorPickState.tolRgb = [tolR, tolG, tolB];

    if (colorPickBaseSwatch) {
      colorPickBaseSwatch.style.background = `rgb(${baseRgb[0]}, ${baseRgb[1]}, ${baseRgb[2]})`;
    }
    if (colorPickBaseHex) {
      colorPickBaseHex.textContent = `0x${rgbToHex(baseRgb[0], baseRgb[1], baseRgb[2])}`;
    }
    if (colorPickCoord) {
      colorPickCoord.textContent = `坐标: ${colorPickState.imgX}, ${colorPickState.imgY}`;
    }
    if (colorPickTolHex) {
      colorPickTolHex.textContent = `容差 HEX: ${getToleranceHexFromPopover()}`;
    }
    if (colorPickTolR) colorPickTolR.value = String(tolR);
    if (colorPickTolG) colorPickTolG.value = String(tolG);
    if (colorPickTolB) colorPickTolB.value = String(tolB);
    if (colorPickTolRInput) colorPickTolRInput.value = String(tolR);
    if (colorPickTolGInput) colorPickTolGInput.value = String(tolG);
    if (colorPickTolBInput) colorPickTolBInput.value = String(tolB);
  }

  function syncPopoverStateFromControl(channel, value) {
    const index = channel === 'r' ? 0 : (channel === 'g' ? 1 : 2);
    const fallback = colorPickState.tolRgb[index] || 0;
    const normalized = clampByte(value, fallback);
    colorPickState.tolRgb[index] = normalized;
    syncPopoverControlsFromState();
    return normalized;
  }

  function positionColorPickPopover(clientX, clientY) {
    if (!colorPickPopover) return;
    const margin = 8;
    const gap = 12;
    const popRect = colorPickPopover.getBoundingClientRect();
    const viewportWidth = window.innerWidth;
    const viewportHeight = window.innerHeight;
    let left = clientX + gap;
    let top = clientY + gap;

    if (left + popRect.width + margin > viewportWidth) {
      left = clientX - popRect.width - gap;
    }
    if (left < margin) left = margin;

    if (top + popRect.height + margin > viewportHeight) {
      top = viewportHeight - popRect.height - margin;
    }
    if (top < margin) top = margin;

    colorPickPopover.style.left = `${Math.round(left)}px`;
    colorPickPopover.style.top = `${Math.round(top)}px`;
  }

  function closeColorPickPopover() {
    if (!colorPickPopover || !colorPickState.open) return;
    colorPickState.open = false;
    colorPickPopover.classList.remove('is-open');
    colorPickPopover.setAttribute('aria-hidden', 'true');
    colorPickPopover.style.visibility = '';
  }

  function openColorPickPopoverAt(clientX, clientY, imgX, imgY) {
    if (!img || !sourceCanvas) {
      showToast('请先导入图片');
      return false;
    }
    if (!Number.isFinite(imgX) || !Number.isFinite(imgY) ||
      imgX < 0 || imgX >= img.width || imgY < 0 || imgY >= img.height) {
      showToast('采样点超出图像范围');
      return false;
    }

    const sampled = readSourceColorAtImagePoint(imgX, imgY);
    if (!sampled) {
      showToast('无法读取采样颜色');
      return false;
    }

    colorPickState.open = true;
    colorPickState.anchorClientX = clientX;
    colorPickState.anchorClientY = clientY;
    colorPickState.imgX = sampled.x;
    colorPickState.imgY = sampled.y;
    colorPickState.baseRgb = [sampled.r, sampled.g, sampled.b];
    // 面板打开后锁定红虚线像素框在当前采样点，直到面板关闭
    hoverPixel = { x: sampled.x, y: sampled.y };
    setPopoverToleranceFromDefault();
    syncPopoverControlsFromState();
    drawOriginal();
    renderBinaryOverlayOnly();

    if (colorPickPopover) {
      colorPickPopover.classList.add('is-open');
      colorPickPopover.setAttribute('aria-hidden', 'false');
      colorPickPopover.style.visibility = 'hidden';
      positionColorPickPopover(clientX, clientY);
      colorPickPopover.style.visibility = '';
    }
    colorPickOutsideGuardUntil = performance.now() + 180;
    return true;
  }

  function confirmAddColorRangeFromPopover() {
    if (!colorPickState.open) return;
    const [r, g, b] = colorPickState.baseRgb;
    const baseHex = rgbToHex(r, g, b);
    const tolHex = getToleranceHexFromPopover();
    if (addColorRange(baseHex, tolHex)) {
      recomputeBinary();
      closeColorPickPopover();
    }
  }

  function bindColorPickToleranceControl(rangeEl, inputEl, channel) {
    if (!rangeEl || !inputEl) return;
    rangeEl.addEventListener('input', () => {
      syncPopoverStateFromControl(channel, rangeEl.value);
    });
    inputEl.addEventListener('input', () => {
      syncPopoverStateFromControl(channel, inputEl.value);
    });
    inputEl.addEventListener('blur', () => {
      const normalized = syncPopoverStateFromControl(channel, inputEl.value);
      inputEl.value = String(normalized);
    });
  }

  function handleOutsideColorPickPointerDown(evt) {
    if (!colorPickState.open || !colorPickPopover) return;
    if (typeof evt.timeStamp === 'number' && evt.timeStamp < colorPickOutsideGuardUntil) {
      return;
    }
    if (colorPickPopover.contains(evt.target)) return;
    closeColorPickPopover();
  }

  bindColorPickToleranceControl(colorPickTolR, colorPickTolRInput, 'r');
  bindColorPickToleranceControl(colorPickTolG, colorPickTolGInput, 'g');
  bindColorPickToleranceControl(colorPickTolB, colorPickTolBInput, 'b');
  if (colorPickAddBtn) {
    colorPickAddBtn.addEventListener('click', confirmAddColorRangeFromPopover);
  }
  if (colorPickCancelBtn) {
    colorPickCancelBtn.addEventListener('click', closeColorPickPopover);
  }
  document.addEventListener('mousedown', handleOutsideColorPickPointerDown, true);
  document.addEventListener('touchstart', handleOutsideColorPickPointerDown, { capture: true, passive: true });
  window.addEventListener('resize', () => {
    if (!colorPickState.open) return;
    positionColorPickPopover(colorPickState.anchorClientX, colorPickState.anchorClientY);
  });

  // 颜色范围聚合功能
  const aggregateColorsBtn = document.getElementById('md-aggregateColorsBtn');

  /**
   * 计算颜色范围的覆盖区间 [min, max] 对于每个通道
   */
  function getColorBounds(c) {
    return {
      rMin: Math.max(0, c.base[0] - c.tol[0]),
      rMax: Math.min(255, c.base[0] + c.tol[0]),
      gMin: Math.max(0, c.base[1] - c.tol[1]),
      gMax: Math.min(255, c.base[1] + c.tol[1]),
      bMin: Math.max(0, c.base[2] - c.tol[2]),
      bMax: Math.min(255, c.base[2] + c.tol[2])
    };
  }

  /**
   * 检查两个颜色范围是否可以聚合（各通道区间必须有真正的交集）
   */
  function canAggregate(bounds1, bounds2) {
    // 两个区间必须在所有通道上都有真正的重叠（至少共享一个值）
    const rOverlap = bounds1.rMax >= bounds2.rMin && bounds2.rMax >= bounds1.rMin;
    const gOverlap = bounds1.gMax >= bounds2.gMin && bounds2.gMax >= bounds1.gMin;
    const bOverlap = bounds1.bMax >= bounds2.bMin && bounds2.bMax >= bounds1.bMin;
    return rOverlap && gOverlap && bOverlap;
  }

  /**
   * 合并两个边界为一个新的边界
   */
  function mergeBounds(bounds1, bounds2) {
    return {
      rMin: Math.min(bounds1.rMin, bounds2.rMin),
      rMax: Math.max(bounds1.rMax, bounds2.rMax),
      gMin: Math.min(bounds1.gMin, bounds2.gMin),
      gMax: Math.max(bounds1.gMax, bounds2.gMax),
      bMin: Math.min(bounds1.bMin, bounds2.bMin),
      bMax: Math.max(bounds1.bMax, bounds2.bMax)
    };
  }

  /**
   * 从边界计算新的颜色范围（最小化范围扩展）
   */
  function boundsToColorRange(bounds) {
    // 计算各通道所需的最小容差（向上取整以确保覆盖）
    const rangeR = bounds.rMax - bounds.rMin;
    const rangeG = bounds.gMax - bounds.gMin;
    const rangeB = bounds.bMax - bounds.bMin;

    // 使用 floor 计算容差，然后根据需要调整 base
    const tolR = Math.floor(rangeR / 2);
    const tolG = Math.floor(rangeG / 2);
    const tolB = Math.floor(rangeB / 2);

    // 调整 base 以确保覆盖原始范围
    // 如果范围是奇数，base 放在中间偏上，这样 base-tol 正好等于 min
    const baseR = bounds.rMin + tolR + (rangeR % 2);
    const baseG = bounds.gMin + tolG + (rangeG % 2);
    const baseB = bounds.bMin + tolB + (rangeB % 2);

    // 重新计算容差以确保覆盖两端
    const finalTolR = Math.max(baseR - bounds.rMin, bounds.rMax - baseR);
    const finalTolG = Math.max(baseG - bounds.gMin, bounds.gMax - baseG);
    const finalTolB = Math.max(baseB - bounds.bMin, bounds.bMax - baseB);

    const base = [baseR, baseG, baseB];
    const tol = [finalTolR, finalTolG, finalTolB];
    const baseHex = rgbToHex(baseR, baseG, baseB);
    const tolHex = rgbToHex(finalTolR, finalTolG, finalTolB);
    const text = `${baseHex}-${tolHex}`;

    return { base, tol, text, enabled: true };
  }

  /**
   * 执行颜色范围聚合
   */
  function aggregateColorRanges() {
    const enabledRanges = colorRanges.filter(c => c.enabled !== false);
    const disabledRanges = colorRanges.filter(c => c.enabled === false);

    if (enabledRanges.length < 2) {
      showToast('至少需要 2 个已勾选的偏色才能聚合');
      return;
    }

    // 计算每个颜色的边界
    let items = enabledRanges.map(c => ({
      bounds: getColorBounds(c),
      original: c
    }));

    // 使用 Union-Find 思想进行聚合
    let merged = true;
    while (merged) {
      merged = false;
      for (let i = 0; i < items.length && !merged; i++) {
        for (let j = i + 1; j < items.length && !merged; j++) {
          if (canAggregate(items[i].bounds, items[j].bounds)) {
            // 合并 i 和 j
            const newBounds = mergeBounds(items[i].bounds, items[j].bounds);
            items[i].bounds = newBounds;
            items.splice(j, 1);
            merged = true;
          }
        }
      }
    }

    // 检查是否有实际聚合发生
    if (items.length === enabledRanges.length) {
      showToast('没有可聚合的偏色范围');
      return;
    }

    // 转换回颜色范围格式
    const aggregatedRanges = items.map(item => boundsToColorRange(item.bounds));

    // 保存撤销历史
    saveColorRangeUndoState();

    // 更新颜色范围列表：保留禁用的，用聚合后的替换启用的
    colorRanges = [...aggregatedRanges, ...disabledRanges];

    renderColorRanges();
    saveColorRangesToStorage();
    recomputeBinary();

    const reducedCount = enabledRanges.length - aggregatedRanges.length;
    showToast(`已聚合：${enabledRanges.length} 个偏色 → ${aggregatedRanges.length} 个（减少 ${reducedCount} 个）`);
  }

  aggregateColorsBtn.addEventListener('click', aggregateColorRanges);

  // 更新文本框内容，只显示已勾选的偏色
  function updateColorRangeText() {
    const enabledTexts = colorRanges
      .filter(c => c.enabled !== false)
      .map(c => c.text);
    colorRangeText.value = enabledTexts.join(',');
  }

  // 获取当前启用的颜色范围
  function getEnabledColorRanges() {
    return colorRanges.filter(c => c.enabled !== false);
  }

  // 保存偏色列表撤销状态
  function saveColorRangeUndoState() {
    // 深拷贝当前状态
    const snapshot = colorRanges.map(c => ({
      base: [...c.base],
      tol: [...c.tol],
      text: c.text,
      enabled: c.enabled
    }));
    colorRangeHistory.push(snapshot);
    // 限制历史数量
    if (colorRangeHistory.length > MAX_UNDO_HISTORY) {
      colorRangeHistory.shift();
    }
  }

  // 撤销偏色列表操作
  function undoColorRange() {
    if (colorRangeHistory.length === 0) {
      showToast('没有可撤销的操作');
      return;
    }
    const prevState = colorRangeHistory.pop();
    colorRanges = prevState;
    renderColorRanges();
    saveColorRangesToStorage();
    recomputeBinary();
    showToast('已撤销');
  }

  function addColorRange(baseHex, tolHex) {
    const baseNorm = clampHex(baseHex);
    const tolNorm = clampHex(tolHex || '101010');
    if (baseNorm.length < 6 || tolNorm.length < 6) return false;
    const base = hexToRgb(baseNorm);
    const tol = hexToRgb(tolNorm);
    if (!base || !tol) return false;
    const text = `${baseNorm}-${tolNorm}`;

    const existingColors = colorRanges.map(c => c.text);
    if (existingColors.includes(text)) {
      showToast(`颜色 ${text} 已存在`);
      return false;
    }

    // 保存撤销历史
    saveColorRangeUndoState();

    // 添加到列表最前方，默认启用
    colorRanges.unshift({ base, tol, text, enabled: true });
    renderColorRanges();
    saveColorRangesToStorage();
    return true;
  }

  // 从文本框同步到列表：
  // 1. 文本框中有但列表没有的 -> 添加到列表并勾选
  // 2. 文本框中有且列表也有的 -> 勾选
  // 3. 列表中有但文本框没有的 -> 取消勾选（不删除）
  function syncColorRangesFromText() {
    const text = colorRangeText.value.trim();

    // 解析文本框中的所有颜色
    const textColors = new Set();
    const invalidParts = [];
    let addedCount = 0;

    if (text) {
      const parts = text.split(/[,\n]/).map(s => s.trim()).filter(s => s);
      for (const part of parts) {
        const match = part.match(/^([0-9A-Fa-f]{6})-([0-9A-Fa-f]{6})$/);
        if (match) {
          const baseHex = match[1].toUpperCase();
          const tolHex = match[2].toUpperCase();
          const colorText = `${baseHex}-${tolHex}`;
          textColors.add(colorText);
        } else {
          invalidParts.push(part);
        }
      }
    }

    // 更新列表中已有项的勾选状态
    for (const c of colorRanges) {
      c.enabled = textColors.has(c.text);
    }

    // 添加列表中没有的新颜色
    for (const colorText of textColors) {
      if (!colorRanges.some(c => c.text === colorText)) {
        const match = colorText.match(/^([0-9A-Fa-f]{6})-([0-9A-Fa-f]{6})$/);
        if (match) {
          const baseHex = match[1].toUpperCase();
          const tolHex = match[2].toUpperCase();
          const base = hexToRgb(baseHex);
          const tol = hexToRgb(tolHex);
          if (base && tol) {
            colorRanges.push({ base, tol, text: colorText, enabled: true });
            addedCount++;
          }
        }
      }
    }

    if (invalidParts.length > 0) {
      showToast(`格式不合法: ${invalidParts.slice(0, 3).join(', ')}${invalidParts.length > 3 ? '...' : ''}`);
    } else if (addedCount > 0) {
      showToast(`已添加 ${addedCount} 个偏色范围`);
    }

    renderColorRanges();
    saveColorRangesToStorage();
    recomputeBinary();
    return true;
  }

  // 保留原函数用于兼容性，但改为不替换现有列表
  function parseColorRangesFromText(showError = false) {
    const text = colorRangeText.value.trim();
    if (!text) {
      // 如果文本框为空，不清空列表，只重新渲染
      renderColorRanges();
      return true;
    }
    const parts = text.split(/[,\n]/).map(s => s.trim()).filter(s => s);
    const newRanges = [];
    const invalidParts = [];
    for (const part of parts) {
      const match = part.match(/^([0-9A-Fa-f]{6})-([0-9A-Fa-f]{6})$/);
      if (match) {
        const baseHex = match[1].toUpperCase();
        const tolHex = match[2].toUpperCase();
        const base = hexToRgb(baseHex);
        const tol = hexToRgb(tolHex);
        if (base && tol) {
          newRanges.push({ base, tol, text: `${baseHex}-${tolHex}`, enabled: true });
        } else {
          invalidParts.push(part);
        }
      } else {
        invalidParts.push(part);
      }
    }

    if (invalidParts.length > 0 && showError) {
      showToast(`格式不合法: ${invalidParts.slice(0, 3).join(', ')}${invalidParts.length > 3 ? '...' : ''}`);
      return false;
    }

    colorRanges = newRanges;
    renderColorRanges();
    saveColorRangesToStorage();
    return true;
  }

  function saveColorRangesToStorage() {
    try {
      // 保存包含启用状态的完整数据
      const data = colorRanges.map(c => ({
        text: c.text,
        enabled: c.enabled !== false
      }));
      localStorage.setItem('matrix_dict_color_ranges_v2', JSON.stringify(data));
    } catch (e) {
      console.warn('保存偏色列表失败:', e);
    }
  }

  function loadColorRangesFromStorage() {
    try {
      // 优先加载新格式
      const savedV2 = localStorage.getItem('matrix_dict_color_ranges_v2');
      if (savedV2) {
        const data = JSON.parse(savedV2);
        colorRanges = [];
        for (const item of data) {
          const match = item.text.match(/^([0-9A-Fa-f]{6})-([0-9A-Fa-f]{6})$/);
          if (match) {
            const baseHex = match[1].toUpperCase();
            const tolHex = match[2].toUpperCase();
            const base = hexToRgb(baseHex);
            const tol = hexToRgb(tolHex);
            if (base && tol) {
              colorRanges.push({
                base, tol,
                text: `${baseHex}-${tolHex}`,
                enabled: item.enabled !== false
              });
            }
          }
        }
        renderColorRanges();
        return;
      }

      // 兼容旧格式
      const saved = localStorage.getItem('matrix_dict_color_ranges');
      if (saved) {
        colorRangeText.value = saved;
        parseColorRangesFromText(false);
        colorRangeText.value = '';  // 清空文本框
      }
    } catch (e) {
      console.warn('加载偏色列表失败:', e);
    }
  }
  function loadLayoutModeFromStorage() {
    try {
      const saved = localStorage.getItem('matrix_dict_layout_mode');
      if (saved === 'horizontal' || saved === 'vertical') {
        applyLayoutMode(saved);
        return;
      }
    } catch (e) {
      console.warn('加载布局失败:', e);
    }
    applyLayoutMode('vertical');
  }

  // 布局切换事件
  layoutButtons.forEach(btn => {
    btn.addEventListener('click', () => {
      applyLayoutMode(btn.dataset.mdLayout || 'vertical');
    });
  });

  // ========== 点阵列表相关函数 ==========

  /**
   * 展开点阵 bits，兼容尾部 @<1~3 位二进制> 的写法。
   * - 无 @：直接按十六进制解出比特，再按宽高裁剪/补 0。
   * - 有 @：@ 前为十六进制主体，@ 后最多 3 位 0/1 原样追加，再按宽高裁剪/补 0。
   * @param {string} bits - 原始 bits 字符串（可能包含 @）
   * @param {number} width - 点阵宽度
   * @param {number} height - 点阵高度
   * @returns {string|null} 展开后的完整 hex 字符串；无效格式返回 null
   */
  function expandBits(bits, width, height) {
    if (!bits) return '';
    if (!width || !height) return null;
    const atPos = bits.indexOf('@');
    let hexPart = bits;
    let tailPart = '';
    if (atPos !== -1) {
      hexPart = bits.substring(0, atPos);
      tailPart = bits.substring(atPos + 1);
    }

    if (!/^[0-9A-Fa-f]*$/.test(hexPart)) return null;
    if (tailPart && (!/^[01]+$/.test(tailPart) || tailPart.length > 3)) return null;

    const flatBits = [];
    for (let i = 0; i < hexPart.length; i++) {
      const val = parseInt(hexPart[i], 16);
      flatBits.push((val >> 3) & 1);
      flatBits.push((val >> 2) & 1);
      flatBits.push((val >> 1) & 1);
      flatBits.push(val & 1);
    }
    if (tailPart) {
      for (let i = 0; i < tailPart.length; i++) {
        flatBits.push(tailPart[i] === '1' ? 1 : 0);
      }
    }

    const needBits = width * height;
    if (needBits <= 0) return null;
    if (flatBits.length < needBits) {
      flatBits.push(...new Array(needBits - flatBits.length).fill(0));
    } else if (flatBits.length > needBits) {
      flatBits.length = needBits;
    }
    if (flatBits.length % 4 !== 0) {
      const pad = 4 - (flatBits.length % 4);
      flatBits.push(...new Array(pad).fill(0));
    }

    let fullHex = '';
    for (let i = 0; i < flatBits.length; i += 4) {
      const b0 = flatBits[i] ? 8 : 0;
      const b1 = flatBits[i + 1] ? 4 : 0;
      const b2 = flatBits[i + 2] ? 2 : 0;
      const b3 = flatBits[i + 3] ? 1 : 0;
      fullHex += (b0 + b1 + b2 + b3).toString(16).toUpperCase();
    }
    return fullHex;
  }

  /**
   * 规范化 bits（仅大写，不使用压缩）
   * @param {string} bits - 已按宽高展开的 hex 字符串
   * @returns {string} 规范化后的 hex 字符串
   */
  function normalizeBits(bits) {
    return (bits || '').toUpperCase();
  }

  function parseMatrixLine(line) {
    if (!line || !line.trim()) return null;
    line = line.trim();
    const parts = line.split('$');
    if (parts.length < 4) return null;

    let bits, word, left, right, matchCount, height, width;

    // bits 始终是第一段（首个 $ 之前）
    bits = parts[0];

    // 从末尾往前检测格式：
    // 简化格式: bits$word$matchCount$height$width（后三段均为纯整数）
    // 标准格式: bits$word$left.right.matchCount$height[.width]（后两段含 . 分隔）
    const lastPart = parts[parts.length - 1];
    const secondLastPart = parts[parts.length - 2];
    const thirdLastPart = parts.length >= 4 ? parts[parts.length - 3] : '';

    // 简化格式：后三段都是纯整数
    const isSimpleFormat = parts.length >= 5 &&
      /^\d+$/.test(lastPart) &&
      /^\d+$/.test(secondLastPart) &&
      /^\d+$/.test(thirdLastPart);

    if (isSimpleFormat) {
      // 简化格式: bits$word$matchCount$height$width
      width = parseInt(lastPart) || 0;
      height = parseInt(secondLastPart) || 0;
      matchCount = parseInt(thirdLastPart) || 0;
      // word 是首段之后、后三段之前的所有部分
      word = parts.slice(1, parts.length - 3).join('$');
      left = 0;
      right = 0;
    } else {
      // 标准格式: bits$word$left.right.matchCount$height[.width]
      // 从末尾解析：lastPart = height[.width]，secondLastPart = left.right.matchCount
      const hw = lastPart.split('.');
      const lrm = secondLastPart.split('.');

      if (lrm.length < 3 || hw.length < 1) return null;

      left = parseInt(lrm[0]) || 0;
      right = parseInt(lrm[1]) || 0;
      matchCount = parseInt(lrm[2]) || 0;
      height = parseInt(hw[0]) || 0;
      width = hw.length >= 2 ? (parseInt(hw[1]) || 0) : 0;

      // word 是首段之后、后两段之前的所有部分（可能包含 $）
      word = parts.slice(1, parts.length - 2).join('$');
    }

    // 展开 bits（兼容 @ 尾部原始位，或无 @ 时按宽高裁剪/补 0）
    const expandedBits = expandBits(bits, width, height);
    if (expandedBits === null) return null;
    
    // 规范化 bits，用于存储和导出（不使用 @ 压缩）
    const normalizedBits = normalizeBits(expandedBits);
    
    // 使用规范化格式构建 line
    const normalizedLine = `${normalizedBits}$${word}$${left}.${right}.${matchCount}$${height}.${width}`;

    return {
      line: normalizedLine,
      bits: expandedBits,  // 保留展开后的 bits 用于内部处理
      word: word,
      left: left,
      right: right,
      matchCount: matchCount,
      height: height,
      width: width
    };
  }

  function saveMatrixListToStorage() {
    try {
      const lines = matrixList.map(m => m.line);
      localStorage.setItem('matrix_dict_list', JSON.stringify(lines));
    } catch (e) {
      console.warn('保存点阵列表失败:', e);
    }
  }

  function loadMatrixListFromStorage() {
    try {
      const saved = localStorage.getItem('matrix_dict_list');
      if (saved) {
        const lines = JSON.parse(saved);
        matrixList = [];
        for (const line of lines) {
          const parsed = parseMatrixLine(line);
          if (parsed) {
            matrixList.push(parsed);
          }
        }
        renderMatrixList();
      }
    } catch (e) {
      console.warn('加载点阵列表失败:', e);
    }
  }

  function renderMatrixList() {
    matrixListBody.innerHTML = '';
    matrixListCount.textContent = `${matrixList.length} 条`;

    matrixList.forEach((item, idx) => {
      const tr = document.createElement('tr');
      tr.draggable = true;
      tr.dataset.index = idx;
      if (idx === selectedMatrixIndex) {
        tr.classList.add('selected');
      }

      tr.innerHTML = `
        <td><span class="drag-handle" title="拖动排序">⋮⋮</span> ${escapeHtml(item.word) || '<空>'}</td>
        <td>${item.width}×${item.height}</td>
        <td title="${escapeHtml(item.line)}">${escapeHtml(item.line)}</td>
        <td><button class="delete-btn" title="删除（Delete）">×</button></td>
      `;

      tr.addEventListener('click', (e) => {
        if (e.target.classList.contains('delete-btn') || e.target.classList.contains('drag-handle')) return;
        selectMatrixItem(idx);
      });

      tr.querySelector('.delete-btn').addEventListener('click', (e) => {
        e.stopPropagation();
        // 直接删除，不弹确认
        deleteMatrixItem(idx);
      });

      // 拖拽事件
      tr.addEventListener('dragstart', (e) => {
        tr.classList.add('dragging');
        e.dataTransfer.effectAllowed = 'move';
        e.dataTransfer.setData('text/plain', idx);
      });
      tr.addEventListener('dragend', () => {
        tr.classList.remove('dragging');
        document.querySelectorAll('.matrix-table tr.drag-over').forEach(el => el.classList.remove('drag-over'));
      });
      tr.addEventListener('dragover', (e) => {
        e.preventDefault();
        e.dataTransfer.dropEffect = 'move';
        tr.classList.add('drag-over');
      });
      tr.addEventListener('dragleave', () => {
        tr.classList.remove('drag-over');
      });
      tr.addEventListener('drop', (e) => {
        e.preventDefault();
        tr.classList.remove('drag-over');
        const fromIdx = parseInt(e.dataTransfer.getData('text/plain'));
        const toIdx = idx;
        if (fromIdx !== toIdx) {
          const [moved] = matrixList.splice(fromIdx, 1);
          matrixList.splice(toIdx, 0, moved);
          // 更新选中索引
          if (selectedMatrixIndex === fromIdx) {
            selectedMatrixIndex = toIdx;
          } else if (fromIdx < selectedMatrixIndex && toIdx >= selectedMatrixIndex) {
            selectedMatrixIndex--;
          } else if (fromIdx > selectedMatrixIndex && toIdx <= selectedMatrixIndex) {
            selectedMatrixIndex++;
          }
          renderMatrixList();
          saveMatrixListToStorage();
        }
      });

      // 右键菜单
      tr.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        showMatrixItemContextMenu(e, idx);
      });

      matrixListBody.appendChild(tr);
    });
  }

  // 点阵列表右键菜单
  function showMatrixItemContextMenu(e, idx) {
    hideContextMenu();

    const menu = document.createElement('div');
    menu.className = 'matrix-context-menu';
    menu.style.left = `${e.clientX}px`;
    menu.style.top = `${e.clientY}px`;

    // 删除
    const deleteItem = document.createElement('div');
    deleteItem.className = 'matrix-context-menu-item danger';
    deleteItem.textContent = '删除';
    deleteItem.addEventListener('click', () => {
      hideContextMenu();
      showDeleteMatrixItemDialog(idx);
    });
    menu.appendChild(deleteItem);

    document.body.appendChild(menu);
    currentContextMenu = menu;

    // 确保菜单不超出屏幕
    const rect = menu.getBoundingClientRect();
    if (rect.right > window.innerWidth) {
      menu.style.left = `${window.innerWidth - rect.width - 5}px`;
    }
    if (rect.bottom > window.innerHeight) {
      menu.style.top = `${window.innerHeight - rect.height - 5}px`;
    }

    // 点击其他地方关闭菜单
    setTimeout(() => {
      document.addEventListener('click', hideContextMenu, { once: true });
    }, 0);
  }

  // 删除点阵确认弹窗相关
  let deleteMatrixIndex = -1;
  const deleteMatrixModal = document.getElementById('md-deleteMatrixModal');
  const deleteMatrixText = document.getElementById('md-deleteMatrixText');
  const closeDeleteMatrixModal = document.getElementById('md-closeDeleteMatrixModal');
  const deleteMatrixCancelBtn = document.getElementById('md-deleteMatrixCancelBtn');
  const deleteMatrixConfirmBtn = document.getElementById('md-deleteMatrixConfirmBtn');

  function showDeleteMatrixItemDialog(idx) {
    deleteMatrixIndex = idx;
    const item = matrixList[idx];
    deleteMatrixText.textContent = `"${item.word || '<空>'}" (${item.width}×${item.height})`;
    openModal(deleteMatrixModal);
  }

  function hideDeleteMatrixModal() {
    closeModal(deleteMatrixModal);
    deleteMatrixIndex = -1;
  }

  function confirmDeleteMatrix() {
    if (deleteMatrixIndex < 0) return;
    deleteMatrixItem(deleteMatrixIndex);
    hideDeleteMatrixModal();
  }

  closeDeleteMatrixModal.addEventListener('click', hideDeleteMatrixModal);
  deleteMatrixCancelBtn.addEventListener('click', hideDeleteMatrixModal);
  deleteMatrixConfirmBtn.addEventListener('click', confirmDeleteMatrix);
  MatrixHelpers.bindModalBackdropClose(deleteMatrixModal);
  MatrixHelpers.bindModalEscClose(deleteMatrixModal, deleteMatrixCancelBtn);

  function escapeHtml(str) {
    if (!str) return '';
    return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  function selectMatrixItem(idx) {
    if (idx < 0 || idx >= matrixList.length) return;
    selectedMatrixIndex = idx;
    const item = matrixList[idx];

    wordInput.value = item.word;
    leftInput.value = item.left;
    rightInput.value = item.right;

    state.bits = item.bits;
    state.width = item.width;
    state.height = item.height;
    state.bitHeight = item.height;
    state.matchCount = item.matchCount;
    state.left = item.left;
    state.right = item.right;

    state.grid = bitsToGrid(item.bits, item.width, item.height);

    lineField.value = item.line;
    statSelection.textContent = `${item.width} × ${item.height}`;
    statBitsLen.textContent = item.bits.length;

    renderGrid(state.grid, { resetView: true });
    renderMatrixList();

    // 聚焦到 word 输入框并选中文本
    wordInput.focus();
    wordInput.select();
  }

  function bitsToGrid(bits, width, height) {
    const grid = Array.from({ length: height }, () => new Uint8Array(width));
    const flatBits = [];

    for (let i = 0; i < bits.length; i++) {
      const val = parseInt(bits[i], 16);
      flatBits.push((val >> 3) & 1);
      flatBits.push((val >> 2) & 1);
      flatBits.push((val >> 1) & 1);
      flatBits.push(val & 1);
    }

    let bitIdx = 0;
    for (let col = 0; col < width; col++) {
      for (let row = 0; row < height; row++) {
        if (bitIdx < flatBits.length) {
          grid[row][col] = flatBits[bitIdx++];
        }
      }
    }

    return grid;
  }

  function gridToBits(grid) {
    if (!grid || !grid.length || !grid[0].length) return '';
    const rows = grid.length;
    const cols = grid[0].length;
    const flatBits = [];

    for (let col = 0; col < cols; col++) {
      for (let row = 0; row < rows; row++) {
        flatBits.push(grid[row][col] ? 1 : 0);
      }
    }

    if (flatBits.length % 4 !== 0) {
      const pad = 4 - (flatBits.length % 4);
      flatBits.push(...new Array(pad).fill(0));
    }

    let bits = '';
    for (let i = 0; i < flatBits.length; i += 4) {
      const b0 = flatBits[i] ? 8 : 0;
      const b1 = flatBits[i + 1] ? 4 : 0;
      const b2 = flatBits[i + 2] ? 2 : 0;
      const b3 = flatBits[i + 3] ? 1 : 0;
      const val = b0 + b1 + b2 + b3;
      bits += val.toString(16).toUpperCase();
    }

    return bits;
  }

  function deleteMatrixItem(idx) {
    if (idx < 0 || idx >= matrixList.length) return;
    matrixList.splice(idx, 1);
    if (selectedMatrixIndex === idx) {
      selectedMatrixIndex = -1;
    } else if (selectedMatrixIndex > idx) {
      selectedMatrixIndex--;
    }
    saveMatrixListToStorage();
    renderMatrixList();
    showToast('已删除');
  }

  function addOrUpdateMatrixItem() {
    const currentLine = buildLine();
    if (!currentLine) {
      showToast('当前没有有效的点阵数据');
      return;
    }

    const parsed = parseMatrixLine(currentLine);
    if (!parsed) {
      showToast('点阵数据格式无效');
      return;
    }

    const existingIndex = matrixList.findIndex(m => m.bits === parsed.bits);
    if (existingIndex >= 0) {
      matrixList[existingIndex] = parsed;
      selectedMatrixIndex = existingIndex;
      saveMatrixListToStorage();
      renderMatrixList();
      scrollToSelectedRow(true);
      showToast('已更新点阵');
      return;
    }

    matrixList.push(parsed);
    selectedMatrixIndex = matrixList.length - 1;
    saveMatrixListToStorage();
    renderMatrixList();
    scrollToSelectedRow(true);
    showToast('已添加点阵');
  }

  function importMatrixFromFile(file) {
    if (!file) return;
    const reader = new FileReader();
    reader.onload = (e) => {
      const text = e.target.result;
      const lines = text.split('\n').map(l => l.trim()).filter(l => l);
      let added = 0, updated = 0;

      for (const line of lines) {
        const parsed = parseMatrixLine(line);
        if (!parsed) continue;

        const existingIndex = matrixList.findIndex(m => m.bits === parsed.bits);

        if (existingIndex >= 0) {
          matrixList[existingIndex] = parsed;
          updated++;
        } else {
          matrixList.push(parsed);
          added++;
        }
      }

      saveMatrixListToStorage();
      renderMatrixList();
      showToast(`导入完成: 新增 ${added} 条，更新 ${updated} 条`);
    };
    reader.readAsText(file);
  }

  // 弹窗元素引用
  const exportModal = document.getElementById('md-exportModal');
  const importModal = document.getElementById('md-importModal');
  const clearModal = document.getElementById('md-clearModal');

  function showExportDialog() {
    if (matrixList.length === 0) {
      showToast('点阵列表为空');
      return;
    }

    const text = matrixList.map(m => m.line).join('\n');
    const exportContent = document.getElementById('md-exportContent');
    exportContent.value = text;

    openModal(exportModal);
  }

  function hideExportModal() {
    closeModal(exportModal);
  }

  function showImportDialog() {
    const importContent = document.getElementById('md-importContent');
    importContent.value = '';

    openModal(importModal);
    importContent.focus();
  }

  function hideImportModal() {
    closeModal(importModal);
  }

  function importFromDialogText() {
    const importContent = document.getElementById('md-importContent');
    const text = importContent.value.trim();

    if (!text) {
      showToast('请粘贴点阵数据');
      return;
    }

    const lines = text.split('\n').map(l => l.trim()).filter(l => l);
    let added = 0, updated = 0;

    for (const line of lines) {
      const parsed = parseMatrixLine(line);
      if (!parsed) continue;

      const existingIndex = matrixList.findIndex(m => m.bits === parsed.bits);

      if (existingIndex >= 0) {
        matrixList[existingIndex] = parsed;
        updated++;
      } else {
        matrixList.push(parsed);
        added++;
      }
    }

    saveMatrixListToStorage();
    renderMatrixList();

    hideImportModal();

    showToast(`导入完成: 新增 ${added} 条，更新 ${updated} 条`);
  }

  function exportMatrixToFile() {
    if (matrixList.length === 0) {
      showToast('点阵列表为空');
      return;
    }

    const text = matrixList.map(m => m.line).join('\n');
    const blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    const now = new Date();
    const timestamp = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}_${String(now.getHours()).padStart(2, '0')}-${String(now.getMinutes()).padStart(2, '0')}-${String(now.getSeconds()).padStart(2, '0')}`;
    a.download = `matrix_dict_${timestamp}.txt`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
    showToast('已导出');
  }

  function clearMatrixList() {
    if (matrixList.length === 0) {
      showToast('列表已为空');
      return;
    }
    openModal(clearModal);
  }

  function hideClearModal() {
    closeModal(clearModal);
  }

  function confirmClearMatrixList() {
    matrixList = [];
    selectedMatrixIndex = -1;
    saveMatrixListToStorage();
    renderMatrixList();
    hideClearModal();
    showToast('已清空');
  }

  // ========== 点阵列表事件绑定 ==========

  importMatrixBtn.addEventListener('click', showImportDialog);

  importMatrixFile.addEventListener('change', (e) => {
    importMatrixFromFile(e.target.files[0]);
    e.target.value = '';
  });

  exportMatrixBtn.addEventListener('click', showExportDialog);
  clearMatrixBtn.addEventListener('click', clearMatrixList);

  // ========== 导出弹窗事件绑定 ==========
  document.getElementById('md-closeExportModal').addEventListener('click', hideExportModal);

  document.getElementById('md-exportCopyBtn').addEventListener('click', async () => {
    const exportContent = document.getElementById('md-exportContent');
    await copyWithToast(exportContent.value, '已拷贝到剪贴板');
  });

  document.getElementById('md-exportDownloadBtn').addEventListener('click', () => {
    exportMatrixToFile();
    hideExportModal();
  });

  // 拷贝代码按钮
  document.getElementById('md-exportCopyCodeBtn').addEventListener('click', () => {
    if (matrixList.length === 0) {
      showToast('点阵列表为空');
      return;
    }

    const dictContent = matrixList.map(m => m.line).join('\n');

    // 检测需要使用多少个等号来正确包裹
    function findSafeBracket(content) {
      // 检查是否包含 ]]
      if (content.indexOf(']]') === -1) {
        return { open: '[[', close: ']]' };
      }

      // 需要使用长括号，从1个等号开始检测
      let equalCount = 1;
      while (true) {
        const closePattern = ']' + '='.repeat(equalCount) + ']';
        if (content.indexOf(closePattern) === -1) {
          const open = '[' + '='.repeat(equalCount) + '[';
          const close = ']' + '='.repeat(equalCount) + ']';
          return { open, close };
        }
        equalCount++;
        // 安全限制，防止无限循环
        if (equalCount > 100) {
          break;
        }
      }
      // 降级方案
      return { open: '[[', close: ']]' };
    }

    const bracket = findSafeBracket(dictContent);

    const code = `-- 引入 dm 库
local dm = require("dm")
-- 当前使用 0 号字库
dm.UseDict(0)
-- 加载 0 号字库
dm.LoadDict(0, ${bracket.open}
${dictContent}
${bracket.close})`;

    copyWithToast(code, '已拷贝代码到剪贴板');
  });

  MatrixHelpers.bindModalBackdropClose(exportModal);
  MatrixHelpers.bindModalEscClose(exportModal);

  // ========== 导入弹窗事件绑定 ==========
  document.getElementById('md-closeImportModal').addEventListener('click', hideImportModal);
  document.getElementById('md-importCancelBtn').addEventListener('click', hideImportModal);
  document.getElementById('md-importConfirmBtn').addEventListener('click', importFromDialogText);

  // 点击弹窗外部关闭
  MatrixHelpers.bindModalBackdropClose(importModal);
  MatrixHelpers.bindModalEscClose(importModal, document.getElementById('md-importCancelBtn'));

  // ========== 清空弹窗事件绑定 ==========
  document.getElementById('md-closeClearModal').addEventListener('click', hideClearModal);
  document.getElementById('md-clearCancelBtn').addEventListener('click', hideClearModal);
  document.getElementById('md-clearConfirmBtn').addEventListener('click', confirmClearMatrixList);

  // 点击弹窗外部关闭
  MatrixHelpers.bindModalBackdropClose(clearModal);
  MatrixHelpers.bindModalEscClose(clearModal, document.getElementById('md-clearCancelBtn'));

  function handleParamEnterKey(e) {
    if (e.key === 'Enter') {
      e.preventDefault();
      addOrUpdateMatrixItem();
    }
  }

  function handleWordInputKeydown(e) {
    if (e.key === 'Enter') {
      e.preventDefault();
      addOrUpdateMatrixItem();
    } else if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
      e.preventDefault();
      if (matrixList.length === 0) return;

      let newIndex;
      if (e.key === 'ArrowUp') {
        // 上箭头：选中上一行
        if (selectedMatrixIndex <= 0) {
          newIndex = matrixList.length - 1; // 循环到最后一行
        } else {
          newIndex = selectedMatrixIndex - 1;
        }
      } else {
        // 下箭头：选中下一行
        if (selectedMatrixIndex < 0 || selectedMatrixIndex >= matrixList.length - 1) {
          newIndex = 0; // 循环到第一行
        } else {
          newIndex = selectedMatrixIndex + 1;
        }
      }

      selectMatrixItem(newIndex);
      scrollToSelectedRow();
      wordInput.focus();
      wordInput.select();
    } else if (e.key === 'Delete') {
      // Delete 键：删除当前选中行（不拦截 Backspace，保留文本编辑功能）
      if (selectedMatrixIndex >= 0 && selectedMatrixIndex < matrixList.length) {
        e.preventDefault();
        const deleteIdx = selectedMatrixIndex;
        matrixList.splice(deleteIdx, 1);
        saveMatrixListToStorage();
        renderMatrixList();
        showToast('已删除');

        // 保持选中位置不变，如果超出范围则选中最后一项
        if (matrixList.length === 0) {
          selectedMatrixIndex = -1;
        } else if (deleteIdx >= matrixList.length) {
          selectedMatrixIndex = matrixList.length - 1;
          selectMatrixItem(selectedMatrixIndex);
        } else {
          selectedMatrixIndex = deleteIdx;
          selectMatrixItem(selectedMatrixIndex);
        }
        scrollToSelectedRow();
        wordInput.focus();
        wordInput.select();
      }
    }
  }

  function scrollToSelectedRow(highlightFlash = false) {
    if (selectedMatrixIndex < 0) return;
    const rows = matrixListBody.querySelectorAll('tr');
    const targetRow = rows[selectedMatrixIndex];
    if (targetRow) {
      targetRow.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
      if (highlightFlash) {
        targetRow.classList.remove('highlight-flash');
        void targetRow.offsetWidth; // 触发 reflow 以重新开始动画
        targetRow.classList.add('highlight-flash');
        targetRow.addEventListener('animationend', () => {
          targetRow.classList.remove('highlight-flash');
        }, { once: true });
      }
    }
  }

  wordInput.addEventListener('keydown', handleWordInputKeydown);
  leftInput.addEventListener('keydown', handleParamEnterKey);
  rightInput.addEventListener('keydown', handleParamEnterKey);

  // 提交/更新按钮点击事件
  const submitWordBtn = document.getElementById('md-submitWordBtn');
  if (submitWordBtn) {
    submitWordBtn.addEventListener('click', function () {
      addOrUpdateMatrixItem();
    });
  }

  function resetCanvas() {
    [canvasOriginal, canvasBinary].forEach((cvs, idx) => {
      const ctx = idx === 0 ? ctxOriginal : ctxBinary;
      const wrapper = cvs.parentElement;
      const logical = getCanvasLogicalSize(cvs, wrapper);
      const metrics = ensureCanvasResolution(cvs, logical.width, logical.height);
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, cvs.width, cvs.height);
      ctx.setTransform(metrics.scaleX, 0, 0, metrics.scaleY, 0, 0);
      ctx.fillStyle = '#c1b7ab';
      ctx.font = '14px "Space Grotesk", "Noto Sans SC", sans-serif';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText('请先导入图片，然后在画布上拖动框选。', logical.width / 2, logical.height / 2);
    });
  }

  // 更新主图尺寸显示
  function updateImageSizeInfo() {
    const sizeInfo = document.getElementById('md-imageSizeInfo');
    if (sizeInfo) {
      if (img) {
        sizeInfo.textContent = `(${img.width} × ${img.height})`;
      } else {
        sizeInfo.textContent = '';
      }
    }
  }

  function setCanvasSizeForImage(w, h) {
    requestAnimationFrame(() => {
      const wrappers = document.querySelectorAll('.matrix-canvas-wrapper');
      wrappers.forEach((wrapper, idx) => {
        const cvs = idx === 0 ? canvasOriginal : canvasBinary;
        const logical = getCanvasLogicalSize(cvs, wrapper);
        ensureCanvasResolution(cvs, logical.width, logical.height);
      });

      if (img) {
        drawOriginal();
        renderBinaryOverlayOnly();
      }
    });
    view.scale = 1;
    view.offsetX = 0;
    view.offsetY = 0;
    updateZoomUI();
    updateImageSizeInfo();
  }

  let resizeTimeout;
  window.addEventListener('resize', () => {
    clearTimeout(resizeTimeout);
    resizeTimeout = setTimeout(() => {
      resizeCanvasToWrapper();
    }, 100);
  });

  function handleFile(file) {
    if (!file) return;
    const reader = new FileReader();
    reader.onload = (e) => {
      const image = new Image();
      image.onload = () => {
        img = image;
        sourceCanvas = document.createElement('canvas');
        sourceCanvas.width = img.width;
        sourceCanvas.height = img.height;
        const sctx = sourceCanvas.getContext('2d');
        sctx.imageSmoothingEnabled = false;
        sctx.drawImage(img, 0, 0);
        setCanvasSizeForImage(image.naturalWidth, image.naturalHeight);
        selection = null;
        metaSelection = null;
        closeColorPickPopover();
        drawOriginal();
        recomputeBinary();
        clearOutputs();
        updateSelectionRecordUI();
      };
      image.src = e.target.result;
    };
    reader.readAsDataURL(file);
  }

  function clearOutputs() {
    state = { bits: '', grid: [], width: 0, height: 0, bitHeight: 0, matchCount: 0, left: 0, right: 0, onesInBitHeight: 0 };
    lineField.value = '';
    leftInput.value = rightInput.value = 0;
    statSelection.textContent = '未选区';
    statBitsLen.textContent = '0';
    const bitPreviewCanvas = document.getElementById('md-bitPreviewCanvas');
    const bitPreviewText = document.getElementById('md-bitPreviewText');
    if (bitPreviewCanvas && bitPreviewText) {
      bitPreviewCanvas.style.display = 'none';
      bitPreviewText.style.display = 'block';
      bitPreviewText.textContent = '等待选区...';
    }
  }

  function drawOriginal() {
    if (!img) {
      resetCanvas();
      return;
    }
    const logical = getCanvasLogicalSize(canvasOriginal);
    const metrics = ensureCanvasResolution(canvasOriginal, logical.width, logical.height);
    const w = logical.width;
    const h = logical.height;
    ctxOriginal.setTransform(1, 0, 0, 1, 0, 0);
    ctxOriginal.clearRect(0, 0, canvasOriginal.width, canvasOriginal.height);
    ctxOriginal.setTransform(metrics.scaleX, 0, 0, metrics.scaleY, 0, 0);

    const centerX = w / 2;
    const centerY = h / 2;
    const imgW = img.width * view.scale;
    const imgH = img.height * view.scale;
    const drawX = centerX - imgW / 2 + view.offsetX;
    const drawY = centerY - imgH / 2 + view.offsetY;

    ctxOriginal.imageSmoothingEnabled = false;
    ctxOriginal.drawImage(img, drawX, drawY, imgW, imgH);
    drawHoverMarker(ctxOriginal, canvasOriginal);
  }

  function drawBinaryOverlay() {
    if (!img) return;
    if (selection && selection.w > 0 && selection.h > 0) {
      ctxBinary.save();

      const logical = getCanvasLogicalSize(canvasBinary);
      const w = logical.width;
      const h = logical.height;
      const centerX = w / 2;
      const centerY = h / 2;
      const imgW = img.width * view.scale;
      const imgH = img.height * view.scale;
      const baseX = centerX - imgW / 2 + view.offsetX;
      const baseY = centerY - imgH / 2 + view.offsetY;

      ctxBinary.strokeStyle = 'rgba(227,95,74,0.9)';
      ctxBinary.lineWidth = 1.2;
      ctxBinary.setLineDash([6, 4]);
      ctxBinary.fillStyle = 'rgba(227, 95, 74, 0.12)';

      const selX = baseX + selection.x * view.scale;
      const selY = baseY + selection.y * view.scale;
      const selW = selection.w * view.scale;
      const selH = selection.h * view.scale;

      ctxBinary.fillRect(selX, selY, selW, selH);
      ctxBinary.strokeRect(selX, selY, selW, selH);

      // 绘制调整手柄（角落和边缘中点）
      ctxBinary.setLineDash([]);
      ctxBinary.fillStyle = '#ffffff';
      ctxBinary.strokeStyle = 'rgba(227,95,74,1)';
      ctxBinary.lineWidth = 1.5;

      const handleScreenSize = Math.max(6, Math.min(10, 8 / view.scale));
      const handles = [
        { x: selX, y: selY },                                    // nw
        { x: selX + selW / 2, y: selY },                        // n
        { x: selX + selW, y: selY },                            // ne
        { x: selX + selW, y: selY + selH / 2 },                 // e
        { x: selX + selW, y: selY + selH },                     // se
        { x: selX + selW / 2, y: selY + selH },                 // s
        { x: selX, y: selY + selH },                            // sw
        { x: selX, y: selY + selH / 2 }                         // w
      ];

      handles.forEach(h => {
        ctxBinary.beginPath();
        ctxBinary.rect(h.x - handleScreenSize / 2, h.y - handleScreenSize / 2, handleScreenSize, handleScreenSize);
        ctxBinary.fill();
        ctxBinary.stroke();
      });

      ctxBinary.restore();
    }
  }

  // 在画布上绘制鼠标所在像素的红框高亮
  function drawHoverMarker(ctx, cvs) {
    if (!img || !hoverPixel) return;

    const logical = getCanvasLogicalSize(cvs);
    const w = logical.width;
    const h = logical.height;
    const centerX = w / 2;
    const centerY = h / 2;
    const imgW = img.width * view.scale;
    const imgH = img.height * view.scale;
    const baseX = centerX - imgW / 2 + view.offsetX;
    const baseY = centerY - imgH / 2 + view.offsetY;

    const px = hoverPixel.x;
    const py = hoverPixel.y;

    // 将图像坐标转换为画布坐标
    const drawX = baseX + px * view.scale;
    const drawY = baseY + py * view.scale;

    // 保证在低缩放时也能看见高亮框
    const size = Math.max(view.scale, 4);

    ctx.save();
    ctx.setLineDash([4, 2]);
    ctx.strokeStyle = 'rgba(227, 95, 74, 0.95)';
    ctx.lineWidth = 1.6;
    ctx.strokeRect(drawX - 0.5, drawY - 0.5, size, size);
    ctx.restore();
  }

  function getCanvasPointFromClient(clientX, clientY, cvs) {
    const canvasTarget = cvs || canvasBinary;
    const rect = canvasTarget.getBoundingClientRect();
    return {
      x: clientX - rect.left,
      y: clientY - rect.top
    };
  }

  function getImagePointFromClient(clientX, clientY, cvs) {
    const canvasTarget = cvs || canvasBinary;
    const canvasPoint = getCanvasPointFromClient(clientX, clientY, canvasTarget);
    if (!img) {
      return { x: 0, y: 0, rawX: 0, rawY: 0 };
    }

    const logical = getCanvasLogicalSize(canvasTarget);
    const w = logical.width;
    const h = logical.height;
    const centerX = w / 2;
    const centerY = h / 2;
    const imgW = img.width * view.scale;
    const imgH = img.height * view.scale;
    const baseX = centerX - imgW / 2 + view.offsetX;
    const baseY = centerY - imgH / 2 + view.offsetY;

    const rawX = (canvasPoint.x - baseX) / view.scale;
    const rawY = (canvasPoint.y - baseY) / view.scale;
    return {
      x: clamp(Math.floor(rawX), 0, img.width - 1),
      y: clamp(Math.floor(rawY), 0, img.height - 1),
      rawX,
      rawY
    };
  }

  function getCanvasPoint(evt, cvs) {
    return getImagePointFromClient(evt.clientX, evt.clientY, cvs || canvasBinary);
  }

  function getTouchDistance(t0, t1) {
    const dx = t1.clientX - t0.clientX;
    const dy = t1.clientY - t0.clientY;
    return Math.sqrt(dx * dx + dy * dy);
  }

  function getTouchCenterOnCanvas(t0, t1, cvs) {
    const p0 = getCanvasPointFromClient(t0.clientX, t0.clientY, cvs);
    const p1 = getCanvasPointFromClient(t1.clientX, t1.clientY, cvs);
    return {
      x: (p0.x + p1.x) / 2,
      y: (p0.y + p1.y) / 2
    };
  }

  // 检测鼠标是否在选框的调整手柄上
  function getResizeHandle(canvasX, canvasY) {
    if (!selection || selection.w <= 0 || selection.h <= 0 || !img) return null;

    const logical = getCanvasLogicalSize(canvasBinary);
    const w = logical.width;
    const h = logical.height;
    const centerX = w / 2;
    const centerY = h / 2;
    const imgW = img.width * view.scale;
    const imgH = img.height * view.scale;
    const baseX = centerX - imgW / 2 + view.offsetX;
    const baseY = centerY - imgH / 2 + view.offsetY;

    const selX = baseX + selection.x * view.scale;
    const selY = baseY + selection.y * view.scale;
    const selW = selection.w * view.scale;
    const selH = selection.h * view.scale;

    const tolerance = Math.max(8, HANDLE_SIZE);

    // 定义手柄位置
    const handles = [
      { name: 'nw', x: selX, y: selY },
      { name: 'n', x: selX + selW / 2, y: selY },
      { name: 'ne', x: selX + selW, y: selY },
      { name: 'e', x: selX + selW, y: selY + selH / 2 },
      { name: 'se', x: selX + selW, y: selY + selH },
      { name: 's', x: selX + selW / 2, y: selY + selH },
      { name: 'sw', x: selX, y: selY + selH },
      { name: 'w', x: selX, y: selY + selH / 2 }
    ];

    for (const handle of handles) {
      if (Math.abs(canvasX - handle.x) <= tolerance && Math.abs(canvasY - handle.y) <= tolerance) {
        return handle.name;
      }
    }

    return null;
  }

  // 根据手柄类型获取对应的光标样式
  function getResizeCursor(handle) {
    const cursors = {
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

  function setBinaryCursor(cursor) {
    canvasBinary.style.cursor = cursor;
  }

  // 检测鼠标是否在 meta 选框的调整手柄上
  function getMetaResizeHandle(canvasX, canvasY) {
    if (!metaSelection || metaSelection.w <= 0 || metaSelection.h <= 0 || !img) return null;

    const logical = getCanvasLogicalSize(canvasBinary);
    const w = logical.width;
    const h = logical.height;
    const centerX = w / 2;
    const centerY = h / 2;
    const imgW = img.width * view.scale;
    const imgH = img.height * view.scale;
    const baseX = centerX - imgW / 2 + view.offsetX;
    const baseY = centerY - imgH / 2 + view.offsetY;

    const selX = baseX + metaSelection.x * view.scale;
    const selY = baseY + metaSelection.y * view.scale;
    const selW = metaSelection.w * view.scale;
    const selH = metaSelection.h * view.scale;

    const tolerance = Math.max(8, HANDLE_SIZE);

    const handles = [
      { name: 'nw', x: selX, y: selY },
      { name: 'n', x: selX + selW / 2, y: selY },
      { name: 'ne', x: selX + selW, y: selY },
      { name: 'e', x: selX + selW, y: selY + selH / 2 },
      { name: 'se', x: selX + selW, y: selY + selH },
      { name: 's', x: selX + selW / 2, y: selY + selH },
      { name: 'sw', x: selX, y: selY + selH },
      { name: 'w', x: selX, y: selY + selH / 2 }
    ];

    for (const handle of handles) {
      if (Math.abs(canvasX - handle.x) <= tolerance && Math.abs(canvasY - handle.y) <= tolerance) {
        return handle.name;
      }
    }

    return null;
  }

  // 检测点是否在 meta 选框内部
  function isPointInMetaSelection(canvasX, canvasY) {
    if (!metaSelection || metaSelection.w <= 0 || metaSelection.h <= 0 || !img) return false;

    const logical = getCanvasLogicalSize(canvasBinary);
    const w = logical.width;
    const h = logical.height;
    const centerX = w / 2;
    const centerY = h / 2;
    const imgW = img.width * view.scale;
    const imgH = img.height * view.scale;
    const baseX = centerX - imgW / 2 + view.offsetX;
    const baseY = centerY - imgH / 2 + view.offsetY;

    const selX = baseX + metaSelection.x * view.scale;
    const selY = baseY + metaSelection.y * view.scale;
    const selW = metaSelection.w * view.scale;
    const selH = metaSelection.h * view.scale;

    return canvasX >= selX && canvasX <= selX + selW && canvasY >= selY && canvasY <= selY + selH;
  }

  // 绘制 meta 选框（蓝色）
  function drawMetaSelectionBox() {
    if (!metaSelection || metaSelection.w <= 0 || metaSelection.h <= 0 || !img) return;

    const logical = getCanvasLogicalSize(canvasBinary);
    const w = logical.width;
    const h = logical.height;
    const centerX = w / 2;
    const centerY = h / 2;
    const imgW = img.width * view.scale;
    const imgH = img.height * view.scale;
    const baseX = centerX - imgW / 2 + view.offsetX;
    const baseY = centerY - imgH / 2 + view.offsetY;

    ctxBinary.save();

    const selX = baseX + metaSelection.x * view.scale;
    const selY = baseY + metaSelection.y * view.scale;
    const selW = metaSelection.w * view.scale;
    const selH = metaSelection.h * view.scale;

    // 绘制填充和边框（蓝色）
    ctxBinary.strokeStyle = 'rgba(60,150,222,0.9)';
    ctxBinary.lineWidth = 1.2;
    ctxBinary.setLineDash([6, 4]);
    ctxBinary.fillStyle = 'rgba(60, 150, 222, 0.12)';
    ctxBinary.fillRect(selX, selY, selW, selH);
    ctxBinary.strokeRect(selX, selY, selW, selH);

    // 绘制调整手柄
    ctxBinary.setLineDash([]);
    ctxBinary.fillStyle = '#ffffff';
    ctxBinary.strokeStyle = 'rgba(60,150,222,1)';
    ctxBinary.lineWidth = 1.5;

    const handleScreenSize = Math.max(6, Math.min(10, 8));
    const handles = [
      { x: selX, y: selY },
      { x: selX + selW / 2, y: selY },
      { x: selX + selW, y: selY },
      { x: selX + selW, y: selY + selH / 2 },
      { x: selX + selW, y: selY + selH },
      { x: selX + selW / 2, y: selY + selH },
      { x: selX, y: selY + selH },
      { x: selX, y: selY + selH / 2 }
    ];

    handles.forEach(handle => {
      ctxBinary.beginPath();
      ctxBinary.rect(handle.x - handleScreenSize / 2, handle.y - handleScreenSize / 2, handleScreenSize, handleScreenSize);
      ctxBinary.fill();
      ctxBinary.stroke();
    });

    ctxBinary.restore();
  }

  // 更新选区记录 UI
  function updateSelectionRecordUI() {
    const shiftCoordEl = document.getElementById('md-shiftSelectionCoord');
    const metaCoordEl = document.getElementById('md-metaSelectionCoord');

    if (shiftCoordEl) {
      if (selection && selection.w > 0 && selection.h > 0) {
        shiftCoordEl.textContent = formatRect({ x: selection.x, y: selection.y, w: selection.w, h: selection.h });
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

  // ==================== 编辑选区弹窗相关 ====================
  let editSelectionType = null; // 'shift' or 'meta'
  const editSelectionModal = document.getElementById('md-editSelectionModal');
  const editSelectionTitle = document.getElementById('md-editSelectionTitle');
  const editSelectionInput = document.getElementById('md-editSelectionInput');
  const closeEditSelectionModalBtn = document.getElementById('md-closeEditSelectionModal');
  const editSelectionCancelBtn = document.getElementById('md-editSelectionCancelBtn');
  const editSelectionConfirmBtn = document.getElementById('md-editSelectionConfirmBtn');
  MatrixHelpers.bindModalBackdropClose(editSelectionModal);
  MatrixHelpers.bindModalEscClose(editSelectionModal, editSelectionCancelBtn);

  function showEditSelectionDialog(selType) {
    editSelectionType = selType;
    const sel = selType === 'shift' ? selection : metaSelection;
    editSelectionTitle.textContent = selType === 'shift' ? '编辑 Shift 框' : '编辑 Meta 框';
    editSelectionInput.value = formatRect(sel && sel.w > 0 && sel.h > 0 ? { x: sel.x, y: sel.y, w: sel.w, h: sel.h } : null);
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

    const newValue = editSelectionInput.value.trim();
    const parts = newValue.split(',').map(s => s.trim());
    if (parts.length !== 4) {
      showToast('格式不正确，应为: left, top, right, bottom');
      return;
    }

    let left = parseInt(parts[0], 10);
    let top = parseInt(parts[1], 10);
    let right = parseInt(parts[2], 10);
    let bottom = parseInt(parts[3], 10);

    if (isNaN(left) || isNaN(top) || isNaN(right) || isNaN(bottom)) {
      showToast('坐标必须是数字');
      return;
    }

    if (!img) {
      showToast('请先打开或截取一张图片');
      return;
    }

    if (left > right) { const tmp = left; left = right; right = tmp; }
    if (top > bottom) { const tmp = top; top = bottom; bottom = tmp; }

    left = clamp(left, 0, img.width - 1);
    top = clamp(top, 0, img.height - 1);
    right = clamp(right, 0, img.width);
    bottom = clamp(bottom, 0, img.height);

    const w = right - left;
    const h = bottom - top;
    if (w <= 0 || h <= 0) {
      showToast('区域无效，宽度和高度必须大于0');
      return;
    }

    const newSel = { x: left, y: top, w, h };
    if (editSelectionType === 'shift') {
      selection = newSel;
      renderBinaryOverlayOnly();
      processSelection();
    } else {
      metaSelection = newSel;
      renderBinaryOverlayOnly();
    }

    hideEditSelectionModal();
    updateSelectionRecordUI();
    showToast('已更新区域');
  }

  if (closeEditSelectionModalBtn) {
    closeEditSelectionModalBtn.addEventListener('click', hideEditSelectionModal);
  }
  if (editSelectionCancelBtn) {
    editSelectionCancelBtn.addEventListener('click', hideEditSelectionModal);
  }
  if (editSelectionConfirmBtn) {
    editSelectionConfirmBtn.addEventListener('click', confirmEditSelection);
  }
  if (editSelectionInput) {
    editSelectionInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        confirmEditSelection();
      }
    });
  }

  // 获取画布坐标（不转换为图像坐标）
  function getCanvasCoord(evt, cvs) {
    const canvasTarget = cvs || canvasBinary;
    const rect = canvasTarget.getBoundingClientRect();
    return {
      x: evt.clientX - rect.left,
      y: evt.clientY - rect.top
    };
  }

  // 记录当前鼠标悬停的像素坐标（图像坐标系），返回是否发生变化
  function updateHoverPixel(evt, cvs) {
    if (!img) return false;
    if (colorPickState.open) return false;
    const { x, y } = getCanvasPoint(evt, cvs || canvasBinary);
    const changed = !hoverPixel || hoverPixel.x !== x || hoverPixel.y !== y;
    hoverPixel = { x, y };
    return changed;
  }

  function clearHoverPixel() {
    if (colorPickState.open) return;
    if (!hoverPixel) return;
    hoverPixel = null;
    drawOriginal();
    renderBinaryOverlayOnly();
  }

  function readSourceColorAtImagePoint(x, y) {
    if (!sourceCanvas || !img) return null;
    const sampleX = clamp(Math.floor(x), 0, img.width - 1);
    const sampleY = clamp(Math.floor(y), 0, img.height - 1);
    const pixel = sourceCanvas.getContext('2d').getImageData(sampleX, sampleY, 1, 1).data;
    return {
      x: sampleX,
      y: sampleY,
      r: pixel[0],
      g: pixel[1],
      b: pixel[2]
    };
  }

  function sampleColorAtImagePoint(clientX, clientY, x, y) {
    return openColorPickPopoverAt(clientX, clientY, x, y);
  }

  function sampleColorDirectAtImagePoint(x, y) {
    const sampled = readSourceColorAtImagePoint(x, y);
    if (!sampled) return false;
    const baseHex = rgbToHex(sampled.r, sampled.g, sampled.b);
    if (!addColorRange(baseHex, defaultTolerance)) return false;
    recomputeBinary();
    return true;
  }

  function sampleColorDirectAt(evt, cvs) {
    const coord = getImagePointFromClient(evt.clientX, evt.clientY, cvs || canvasOriginal);
    if (coord.rawX < 0 || coord.rawX >= img.width || coord.rawY < 0 || coord.rawY >= img.height) {
      showToast('采样点超出图像范围');
      return false;
    }
    return sampleColorDirectAtImagePoint(coord.x, coord.y);
  }

  function sampleColorAt(evt, cvs) {
    const coord = getImagePointFromClient(evt.clientX, evt.clientY, cvs || canvasOriginal);
    if (coord.rawX < 0 || coord.rawX >= img.width || coord.rawY < 0 || coord.rawY >= img.height) {
      showToast('采样点超出图像范围');
      return false;
    }
    return sampleColorAtImagePoint(evt.clientX, evt.clientY, coord.x, coord.y);
  }

  function onMouseDown(evt) {
    if (!img) return;
    const isMeta = navigator.platform.match('Mac') ? evt.metaKey : evt.ctrlKey;
    const isArmedShift = armedInteractionMode === 'select-shift';
    const isArmedMeta = armedInteractionMode === 'select-meta';
    const effectiveMeta = isMeta || isArmedMeta;
    const effectiveShift = evt.shiftKey || isArmedShift;
    const effectiveAlt = evt.altKey;
    
    if (effectiveAlt && evt.button === 0) {
      if (evt.target === canvasBinary) {
        sampleColorDirectAt(evt, canvasBinary);
        return;
      }
    }

    // 检查是否点击在 shift 选框的调整手柄上（左键，无修饰键）
    if (evt.button === 0 && !effectiveShift && !effectiveAlt && !effectiveMeta && evt.target === canvasBinary && selection) {
      const coord = getCanvasCoord(evt, canvasBinary);
      const handle = getResizeHandle(coord.x, coord.y);
      if (handle) {
        resizeDragging = true;
        resizeHandle = handle;
        const { x, y } = getCanvasPoint(evt, canvasBinary);
        resizeStart = {
          x, y,
          selX: selection.x,
          selY: selection.y,
          selW: selection.w,
          selH: selection.h
        };
        return;
      }
    }

    // 检查是否点击在 meta 选框的调整手柄上（左键 + Meta）
    if (evt.button === 0 && !effectiveShift && !effectiveAlt && effectiveMeta && evt.target === canvasBinary && metaSelection) {
      const coord = getCanvasCoord(evt, canvasBinary);
      const handle = getMetaResizeHandle(coord.x, coord.y);
      if (handle) {
        metaResizeDragging = true;
        metaResizeHandle = handle;
        const { x, y } = getCanvasPoint(evt, canvasBinary);
        metaResizeStart = {
          x, y,
          selX: metaSelection.x,
          selY: metaSelection.y,
          selW: metaSelection.w,
          selH: metaSelection.h
        };
        return;
      }
    }

    // Meta+右键移动 meta 框
    if (evt.button === 2 && effectiveMeta && !effectiveAlt && !effectiveShift && metaSelection && metaSelection.w > 0 && metaSelection.h > 0 && evt.target === canvasBinary) {
      const coord = getCanvasCoord(evt, canvasBinary);
      if (isPointInMetaSelection(coord.x, coord.y)) {
        metaMoveBoxDragging = true;
        const { x, y } = getCanvasPoint(evt, canvasBinary);
        metaMoveBoxStart = { x, y, selX: metaSelection.x, selY: metaSelection.y };
        setBinaryCursor('grabbing');
        return;
      }
    }

    // Meta+左键创建 meta 框选
    if (effectiveMeta && !effectiveAlt && !effectiveShift && evt.button === 0 && evt.target === canvasBinary) {
      metaDragging = true;
      const { x, y } = getCanvasPoint(evt, canvasBinary);
      metaDragStart = { x, y };
      metaSelection = { x, y, w: 0, h: 0 };
      renderBinaryOverlayOnly();
      return;
    }

    if (!effectiveShift && !effectiveMeta && evt.button === 0) {
      panDragging = true;
      panMoved = false;
      panDragCanvas = evt.target;
      panStart = { x: evt.clientX, y: evt.clientY, offsetX: view.offsetX, offsetY: view.offsetY };
      if (evt.target === canvasBinary) setBinaryCursor('grabbing');
      if (evt.target === canvasOriginal) canvasOriginal.style.cursor = 'grabbing';
      return;
    }
    if (evt.button === 2 && !effectiveMeta && selection && evt.target === canvasBinary) {
      moveBoxDragging = true;
      const { x, y } = getCanvasPoint(evt, canvasBinary);
      moveBoxStart = { x, y, selX: selection.x, selY: selection.y };
      setBinaryCursor('grabbing');
      return;
    }
    if (effectiveShift && !effectiveMeta && !effectiveAlt && evt.button === 0 && evt.target === canvasBinary) {
      dragging = true;
      const { x, y } = getCanvasPoint(evt, canvasBinary);
      dragStart = { x, y };
      selection = { x, y, w: 0, h: 0 };
      renderBinaryOverlayOnly();
    }
  }

  function onMouseMove(evt) {
    if (!img) return;
    const isMeta = navigator.platform.match('Mac') ? evt.metaKey : evt.ctrlKey;
    const effectiveMeta = isMeta || armedInteractionMode === 'select-meta';

    const currentCanvas = (evt.target === canvasOriginal) ? canvasOriginal : canvasBinary;
    const hoverChanged = updateHoverPixel(evt, currentCanvas);

    if (evt.target === canvasBinary) {
      // 更新光标样式（仅在没有拖拽操作时）
      if (!panDragging && !moveBoxDragging && !dragging && !resizeDragging && 
          !metaDragging && !metaResizeDragging && !metaMoveBoxDragging) {
        const coord = getCanvasCoord(evt, canvasBinary);
        const shiftHandle = getResizeHandle(coord.x, coord.y);
        const metaHandle = effectiveMeta ? getMetaResizeHandle(coord.x, coord.y) : null;
        if (shiftHandle || metaHandle) {
          setBinaryCursor(getResizeCursor(shiftHandle || metaHandle));
        } else {
          setBinaryCursor('crosshair');
        }
      }
    }

    if (panDragging) {
      if (evt.target === canvasBinary) {
        setBinaryCursor('grabbing');
      } else if (evt.target === canvasOriginal) {
        canvasOriginal.style.cursor = 'grabbing';
      }
      const dx = evt.clientX - panStart.x;
      const dy = evt.clientY - panStart.y;
      if (!panMoved) {
        if (Math.abs(dx) <= MOUSE_PAN_CLICK_THRESHOLD && Math.abs(dy) <= MOUSE_PAN_CLICK_THRESHOLD) {
          return;
        }
        panMoved = true;
      }
      view.offsetX = panStart.offsetX + dx;
      view.offsetY = panStart.offsetY + dy;
      renderBinaryOverlayOnly();
      drawOriginal();
      return;
    }

    // 调整 shift 选框大小
    if (resizeDragging && selection && resizeHandle) {
      setBinaryCursor(getResizeCursor(resizeHandle));
      const { x, y } = getCanvasPoint(evt, canvasBinary);
      const dx = x - resizeStart.x;
      const dy = y - resizeStart.y;

      let newX = resizeStart.selX;
      let newY = resizeStart.selY;
      let newW = resizeStart.selW;
      let newH = resizeStart.selH;

      if (resizeHandle.includes('w')) { newX = resizeStart.selX + dx; newW = resizeStart.selW - dx; }
      if (resizeHandle.includes('e')) { newW = resizeStart.selW + dx; }
      if (resizeHandle.includes('n')) { newY = resizeStart.selY + dy; newH = resizeStart.selH - dy; }
      if (resizeHandle.includes('s')) { newH = resizeStart.selH + dy; }

      if (newW < 0) { newX = newX + newW; newW = -newW; }
      if (newH < 0) { newY = newY + newH; newH = -newH; }

      newX = clamp(newX, 0, img.width - 1);
      newY = clamp(newY, 0, img.height - 1);
      newW = clamp(newW, 1, img.width - newX);
      newH = clamp(newH, 1, img.height - newY);

      selection = { x: Math.floor(newX), y: Math.floor(newY), w: Math.floor(newW), h: Math.floor(newH) };
      renderBinaryOverlayOnly();
      return;
    }

    // 调整 meta 选框大小
    if (metaResizeDragging && metaSelection && metaResizeHandle) {
      setBinaryCursor(getResizeCursor(metaResizeHandle));
      const { x, y } = getCanvasPoint(evt, canvasBinary);
      const dx = x - metaResizeStart.x;
      const dy = y - metaResizeStart.y;

      let newX = metaResizeStart.selX;
      let newY = metaResizeStart.selY;
      let newW = metaResizeStart.selW;
      let newH = metaResizeStart.selH;

      if (metaResizeHandle.includes('w')) { newX = metaResizeStart.selX + dx; newW = metaResizeStart.selW - dx; }
      if (metaResizeHandle.includes('e')) { newW = metaResizeStart.selW + dx; }
      if (metaResizeHandle.includes('n')) { newY = metaResizeStart.selY + dy; newH = metaResizeStart.selH - dy; }
      if (metaResizeHandle.includes('s')) { newH = metaResizeStart.selH + dy; }

      if (newW < 0) { newX = newX + newW; newW = -newW; }
      if (newH < 0) { newY = newY + newH; newH = -newH; }

      newX = clamp(newX, 0, img.width - 1);
      newY = clamp(newY, 0, img.height - 1);
      newW = clamp(newW, 1, img.width - newX);
      newH = clamp(newH, 1, img.height - newY);

      metaSelection = { x: Math.floor(newX), y: Math.floor(newY), w: Math.floor(newW), h: Math.floor(newH) };
      renderBinaryOverlayOnly();
      return;
    }

    // Meta+右键移动 meta 框
    if (metaMoveBoxDragging && metaSelection) {
      setBinaryCursor('grabbing');
      const { x, y } = getCanvasPoint(evt, canvasBinary);
      const dx = x - metaMoveBoxStart.x;
      const dy = y - metaMoveBoxStart.y;
      metaSelection.x = clamp(metaMoveBoxStart.selX + dx, 0, img.width - metaSelection.w);
      metaSelection.y = clamp(metaMoveBoxStart.selY + dy, 0, img.height - metaSelection.h);
      renderBinaryOverlayOnly();
      return;
    }

    // Meta+左键拖拽框选
    if (metaDragging) {
      const { x, y } = getCanvasPoint(evt, canvasBinary);
      metaSelection = normalizeRect(metaDragStart.x, metaDragStart.y, x, y);
      renderBinaryOverlayOnly();
      return;
    }

    if (moveBoxDragging && selection) {
      setBinaryCursor('grabbing');
      const { x, y } = getCanvasPoint(evt, canvasBinary);
      const dx = x - moveBoxStart.x;
      const dy = y - moveBoxStart.y;
      selection.x = clamp(moveBoxStart.selX + dx, 0, img.width - selection.w);
      selection.y = clamp(moveBoxStart.selY + dy, 0, img.height - selection.h);
      renderBinaryOverlayOnly();
      return;
    }
    if (!dragging) {
      // 普通移动时仅重绘高亮框，避免不必要的重算
      if (!panDragging && !moveBoxDragging && !resizeDragging && 
          !metaDragging && !metaResizeDragging && !metaMoveBoxDragging && hoverChanged) {
        drawOriginal();
        renderBinaryOverlayOnly();
      }
      return;
    }
    const { x, y } = getCanvasPoint(evt, canvasBinary);
    selection = normalizeRect(dragStart.x, dragStart.y, x, y);
    renderBinaryOverlayOnly();
  }

  function onMouseUp(evt) {
    if (!img) return;
    if (panDragging) {
      const dragCanvas = panDragCanvas || evt.target;
      const isMac = navigator.platform.match('Mac');
      const hasKeyboardModifier = evt.altKey || evt.shiftKey || (isMac ? evt.metaKey : evt.ctrlKey);
      const shouldOpenPopover = (
        (dragCanvas === canvasOriginal || dragCanvas === canvasBinary) &&
        evt.button === 0 &&
        !panMoved &&
        !hasKeyboardModifier
      );
      panDragging = false;
      panMoved = false;
      panDragCanvas = null;
      if (evt.target === canvasBinary || dragCanvas === canvasBinary) setBinaryCursor('crosshair');
      if (evt.target === canvasOriginal || dragCanvas === canvasOriginal) canvasOriginal.style.cursor = 'crosshair';
      renderBinaryOverlayOnly();
      drawOriginal();
      setBinaryCursor('crosshair');
      canvasOriginal.style.cursor = 'crosshair';
      if (shouldOpenPopover) {
        sampleColorAt(evt, dragCanvas === canvasBinary ? canvasBinary : canvasOriginal);
      }
      return;
    }
    if (resizeDragging) {
      resizeDragging = false;
      resizeHandle = null;
      setBinaryCursor('crosshair');
      renderBinaryOverlayOnly();
      processSelection();
      updateSelectionRecordUI();
      disarmArmedInteractionMode('select-shift');
      return;
    }
    if (metaResizeDragging) {
      metaResizeDragging = false;
      metaResizeHandle = null;
      setBinaryCursor('crosshair');
      renderBinaryOverlayOnly();
      updateSelectionRecordUI();
      disarmArmedInteractionMode('select-meta');
      return;
    }
    if (moveBoxDragging) {
      moveBoxDragging = false;
      setBinaryCursor('crosshair');
      renderBinaryOverlayOnly();
      processSelection();
      updateSelectionRecordUI();
      disarmArmedInteractionMode('select-shift');
      return;
    }
    if (metaMoveBoxDragging) {
      metaMoveBoxDragging = false;
      setBinaryCursor('crosshair');
      renderBinaryOverlayOnly();
      updateSelectionRecordUI();
      disarmArmedInteractionMode('select-meta');
      return;
    }
    if (metaDragging) {
      metaDragging = false;
      const { x, y } = getCanvasPoint(evt, canvasBinary);
      metaSelection = normalizeRect(metaDragStart.x, metaDragStart.y, x, y);
      renderBinaryOverlayOnly();
      updateSelectionRecordUI();
      setBinaryCursor('crosshair');
      disarmArmedInteractionMode('select-meta');
      return;
    }
    if (!dragging) return;
    dragging = false;
    const { x, y } = getCanvasPoint(evt, canvasBinary);
    selection = normalizeRect(dragStart.x, dragStart.y, x, y);
    renderBinaryOverlayOnly();
    processSelection();
    updateSelectionRecordUI();
    setBinaryCursor('crosshair');
    canvasOriginal.style.cursor = 'crosshair';
    disarmArmedInteractionMode('select-shift');
  }

  function beginTouchPan(touch, canvasTarget, suppressTap, tapAction) {
    touchPanState.active = true;
    touchPanState.moved = !!suppressTap;
    touchPanState.tapAction = tapAction || 'none';
    touchPanState.canvas = canvasTarget;
    touchPanState.startX = touch.clientX;
    touchPanState.startY = touch.clientY;
    touchPanState.startOffsetX = view.offsetX;
    touchPanState.startOffsetY = view.offsetY;
  }

  function beginTouchPinch(t0, t1, canvasTarget) {
    const pinchCanvas = canvasTarget || canvasBinary;
    const logical = getCanvasLogicalSize(pinchCanvas);
    const center = getTouchCenterOnCanvas(t0, t1, pinchCanvas);
    touchPinchState.active = true;
    touchPinchState.canvas = pinchCanvas;
    touchPinchState.startDistance = Math.max(1, getTouchDistance(t0, t1));
    touchPinchState.startScale = view.scale;
    touchPinchState.startOffsetX = view.offsetX;
    touchPinchState.startOffsetY = view.offsetY;
    touchPinchState.startCenterDX = center.x - logical.width / 2;
    touchPinchState.startCenterDY = center.y - logical.height / 2;
  }

  function beginTouchSelection(touch, target, canvasTarget) {
    if (!touch || !img) return false;
    const coord = getImagePointFromClient(touch.clientX, touch.clientY, canvasTarget);
    if (coord.rawX < 0 || coord.rawX >= img.width || coord.rawY < 0 || coord.rawY >= img.height) {
      return false;
    }

    touchSelectionState.active = true;
    touchSelectionState.target = target;
    touchSelectionState.startX = coord.x;
    touchSelectionState.startY = coord.y;
    if (target === 'shift') {
      dragging = true;
      dragStart = { x: coord.x, y: coord.y };
      selection = { x: coord.x, y: coord.y, w: 0, h: 0 };
    } else {
      metaDragging = true;
      metaDragStart = { x: coord.x, y: coord.y };
      metaSelection = { x: coord.x, y: coord.y, w: 0, h: 0 };
    }
    renderBinaryOverlayOnly();
    return true;
  }

  function updateTouchSelection(touch, canvasTarget) {
    if (!touchSelectionState.active || !touch || !img) return;
    const coord = getImagePointFromClient(touch.clientX, touch.clientY, canvasTarget);
    const rect = normalizeRect(touchSelectionState.startX, touchSelectionState.startY, coord.x, coord.y);
    if (touchSelectionState.target === 'shift') {
      selection = rect;
    } else {
      metaSelection = rect;
    }
    renderBinaryOverlayOnly();
  }

  function finalizeTouchSelection() {
    if (!touchSelectionState.active) return;
    const target = touchSelectionState.target;
    touchSelectionState.active = false;
    dragging = false;
    metaDragging = false;
    if (target === 'shift') {
      if (selection && (selection.w <= 0 || selection.h <= 0)) {
        selection = null;
      }
      if (selection && selection.w > 0 && selection.h > 0) {
        processSelection();
      }
      disarmArmedInteractionMode('select-shift');
    } else {
      if (metaSelection && (metaSelection.w <= 0 || metaSelection.h <= 0)) {
        metaSelection = null;
      }
      disarmArmedInteractionMode('select-meta');
    }
    updateSelectionRecordUI();
    renderBinaryOverlayOnly();
  }

  function resetTouchStates() {
    touchPanState.active = false;
    touchPanState.moved = false;
    touchPanState.tapAction = 'none';
    touchPanState.canvas = null;
    touchPinchState.active = false;
    touchPinchState.canvas = null;
    if (touchSelectionState.active) {
      if (touchSelectionState.target === 'shift' && selection && (selection.w <= 0 || selection.h <= 0)) {
        selection = null;
      }
      if (touchSelectionState.target === 'meta' && metaSelection && (metaSelection.w <= 0 || metaSelection.h <= 0)) {
        metaSelection = null;
      }
    }
    touchSelectionState.active = false;
    dragging = false;
    metaDragging = false;
  }

  function handleCanvasTouchStart(evt) {
    if (!img) return;
    const canvasTarget = evt.currentTarget === canvasOriginal ? canvasOriginal : canvasBinary;
    if (evt.touches.length >= 2) {
      if (touchSelectionState.active) {
        finalizeTouchSelection();
      }
      touchPanState.active = false;
      touchPanState.moved = true;
      touchPanState.tapAction = 'none';
      touchPanState.canvas = null;
      beginTouchPinch(evt.touches[0], evt.touches[1], canvasTarget);
      evt.preventDefault();
      return;
    }

    if (evt.touches.length === 1) {
      touchPinchState.active = false;
      touchPinchState.canvas = null;

      if (canvasTarget === canvasBinary &&
        (armedInteractionMode === 'select-shift' || armedInteractionMode === 'select-meta')) {
        const selectTarget = armedInteractionMode === 'select-shift' ? 'shift' : 'meta';
        if (!beginTouchSelection(evt.touches[0], selectTarget, canvasTarget)) {
          beginTouchPan(evt.touches[0], canvasTarget, false, 'color-picker');
        }
      } else if (canvasTarget === canvasOriginal && armedInteractionMode === 'sample-alt') {
        beginTouchPan(evt.touches[0], canvasTarget, false, 'sample-alt');
      } else {
        beginTouchPan(evt.touches[0], canvasTarget, false, 'color-picker');
      }
      evt.preventDefault();
    }
  }

  function handleCanvasTouchMove(evt) {
    if (!img) return;
    const canvasTarget = evt.currentTarget === canvasOriginal ? canvasOriginal : canvasBinary;

    if (touchSelectionState.active) {
      if (evt.touches.length >= 2) {
        finalizeTouchSelection();
        beginTouchPinch(evt.touches[0], evt.touches[1], canvasTarget);
        evt.preventDefault();
        return;
      }
      if (evt.touches.length === 1) {
        updateTouchSelection(evt.touches[0], canvasTarget);
        evt.preventDefault();
        return;
      }
    }

    if (evt.touches.length >= 2) {
      if (!touchPinchState.active) {
        beginTouchPinch(evt.touches[0], evt.touches[1], canvasTarget);
      }

      const distance = Math.max(1, getTouchDistance(evt.touches[0], evt.touches[1]));
      const scaleFactor = distance / Math.max(1, touchPinchState.startDistance);
      const newScale = clamp(touchPinchState.startScale * scaleFactor, 0.1, 20);
      const pinchCanvas = touchPinchState.canvas || canvasTarget;
      const logical = getCanvasLogicalSize(pinchCanvas);
      const center = getTouchCenterOnCanvas(evt.touches[0], evt.touches[1], pinchCanvas);
      const centerDX = center.x - logical.width / 2;
      const centerDY = center.y - logical.height / 2;
      const scaleRatio = newScale / Math.max(0.0001, touchPinchState.startScale);

      view.offsetX = (touchPinchState.startOffsetX - touchPinchState.startCenterDX) * scaleRatio + centerDX;
      view.offsetY = (touchPinchState.startOffsetY - touchPinchState.startCenterDY) * scaleRatio + centerDY;
      view.scale = newScale;

      touchPanState.active = false;
      touchPanState.moved = true;
      touchPanState.tapAction = 'none';
      touchPanState.canvas = null;
      updateZoomUI();
      renderBinaryOverlayOnly();
      drawOriginal();
      evt.preventDefault();
      return;
    }

    if (evt.touches.length === 1) {
      const touch = evt.touches[0];
      const defaultTapAction = (canvasTarget === canvasOriginal && armedInteractionMode === 'sample-alt')
        ? 'sample-alt'
        : 'color-picker';
      if (touchPinchState.active) {
        touchPinchState.active = false;
        touchPinchState.canvas = null;
        beginTouchPan(touch, canvasTarget, true, defaultTapAction);
      }
      if (!touchPanState.active) {
        beginTouchPan(touch, canvasTarget, false, defaultTapAction);
      }

      const dx = touch.clientX - touchPanState.startX;
      const dy = touch.clientY - touchPanState.startY;
      if (Math.abs(dx) > TOUCH_PAN_THRESHOLD || Math.abs(dy) > TOUCH_PAN_THRESHOLD) {
        touchPanState.moved = true;
      }
      view.offsetX = touchPanState.startOffsetX + dx;
      view.offsetY = touchPanState.startOffsetY + dy;
      renderBinaryOverlayOnly();
      drawOriginal();
      evt.preventDefault();
    }
  }

  function handleCanvasTouchEnd(evt) {
    if (!img) return;
    const canvasTarget = evt.currentTarget === canvasOriginal ? canvasOriginal : canvasBinary;

    if (touchSelectionState.active) {
      if (evt.touches.length === 0) {
        finalizeTouchSelection();
      } else if (evt.touches.length === 1) {
        finalizeTouchSelection();
        beginTouchPan(evt.touches[0], canvasTarget, true, 'none');
      }
      evt.preventDefault();
      return;
    }

    if (evt.touches.length >= 2) {
      beginTouchPinch(evt.touches[0], evt.touches[1], canvasTarget);
      evt.preventDefault();
      return;
    }

    if (touchPinchState.active && evt.touches.length < 2) {
      touchPinchState.active = false;
      touchPinchState.canvas = null;
    }

    if (evt.touches.length === 1) {
      beginTouchPan(evt.touches[0], canvasTarget, true, 'none');
      evt.preventDefault();
      return;
    }

    if (touchPanState.active) {
      const shouldTap = !touchPanState.moved;
      const endTouch = evt.changedTouches && evt.changedTouches.length
        ? evt.changedTouches[evt.changedTouches.length - 1]
        : null;
      const tapAction = touchPanState.tapAction;
      const panCanvas = touchPanState.canvas || canvasTarget;
      touchPanState.active = false;
      touchPanState.moved = false;
      touchPanState.tapAction = 'none';
      touchPanState.canvas = null;

      if (shouldTap && endTouch && (tapAction === 'sample-alt' || tapAction === 'color-picker')) {
        const coord = getImagePointFromClient(endTouch.clientX, endTouch.clientY, panCanvas);
        if (coord.rawX >= 0 && coord.rawX < img.width && coord.rawY >= 0 && coord.rawY < img.height) {
          const opened = sampleColorAtImagePoint(endTouch.clientX, endTouch.clientY, coord.x, coord.y);
          if (opened && tapAction === 'sample-alt') {
            disarmArmedInteractionMode('sample-alt');
          }
        } else {
          showToast('采样点超出图像范围');
        }
      }
    }

    setBinaryCursor('crosshair');
    canvasOriginal.style.cursor = 'crosshair';
    evt.preventDefault();
  }

  function handleCanvasTouchCancel(evt) {
    resetTouchStates();
    setBinaryCursor('crosshair');
    canvasOriginal.style.cursor = 'crosshair';
    clearHoverPixel();
    clearMagnifier();
    evt.preventDefault();
  }

  function processSelection() {
    if (!selection || selection.w <= 0 || selection.h <= 0 || !binaryMask) return;
    const { x, y, w, h } = selection;
    if (w === 0 || h === 0) return;
    const bitHeight = h;
    const grid = Array.from({ length: bitHeight }, () => new Uint8Array(w));
    let matchCount = 0;

    for (let row = 0; row < h; row++) {
      for (let col = 0; col < w; col++) {
        const maskVal = binaryMask[(y + row) * img.width + (x + col)];
        if (maskVal === 1) {
          matchCount++;
          grid[row][col] = 1;
        }
      }
    }

    const leftCols = 0;
    const rightCols = 0;

    const flatBits = [];
    for (let col = 0; col < w; col++) {
      for (let row = 0; row < bitHeight; row++) {
        flatBits.push(grid[row][col]);
      }
    }
    let bits = '';
    for (let i = 0; i < flatBits.length; i += 4) {
      const b0 = flatBits[i] ? 8 : 0;
      const b1 = flatBits[i + 1] ? 4 : 0;
      const b2 = flatBits[i + 2] ? 2 : 0;
      const b3 = flatBits[i + 3] ? 1 : 0;
      const val = b0 + b1 + b2 + b3;
      bits += val.toString(16).toUpperCase();
    }

    state = {
      bits,
      grid,
      width: w,
      height: h,
      bitHeight,
      matchCount,
      left: leftCols,
      right: rightCols,
      onesInBitHeight: matchCount
    };

    leftInput.value = leftCols;
    rightInput.value = rightCols;
    statSelection.textContent = `${w} × ${h}`;
    statBitsLen.textContent = bits.length;
    renderGrid(grid, { resetView: true });

    updateLine();
  }

  let bitPreviewScale = 1;
  let bitPreviewOffset = { x: 0, y: 0 };
  let bitPreviewDragging = false;
  let bitPreviewDragStart = { x: 0, y: 0, offsetX: 0, offsetY: 0 };
  let bitPreviewTouchPanState = {
    active: false,
    moved: false,
    startX: 0,
    startY: 0,
    startOffsetX: 0,
    startOffsetY: 0
  };
  let bitPreviewTouchPinchState = {
    active: false,
    startDistance: 1,
    startScale: 1,
    startOffsetX: 0,
    startOffsetY: 0,
    startCenterDX: 0,
    startCenterDY: 0
  };
  const BIT_PREVIEW_TOUCH_PAN_THRESHOLD = 6;
  const BIT_PREVIEW_PIXEL = 8;
  const BIT_PREVIEW_GRID = 1;

  function getBitPreviewCanvasEl() {
    return document.getElementById('md-bitPreviewCanvas');
  }

  function applyBitPreviewTransform() {
    const bitPreviewCanvas = getBitPreviewCanvasEl();
    if (!bitPreviewCanvas || bitPreviewCanvas.style.display === 'none') return;
    bitPreviewCanvas.style.transform = `translate(${bitPreviewOffset.x}px, ${bitPreviewOffset.y}px) scale(${bitPreviewScale})`;
  }

  function getBitPreviewTouchDistance(t0, t1) {
    const dx = t1.clientX - t0.clientX;
    const dy = t1.clientY - t0.clientY;
    return Math.sqrt(dx * dx + dy * dy);
  }

  function getBitPreviewTouchCenter(t0, t1, container) {
    const rect = container.getBoundingClientRect();
    return {
      x: (t0.clientX + t1.clientX) / 2 - rect.left,
      y: (t0.clientY + t1.clientY) / 2 - rect.top
    };
  }

  function beginBitPreviewTouchPan(touch, suppressTap) {
    bitPreviewTouchPanState.active = true;
    bitPreviewTouchPanState.moved = !!suppressTap;
    bitPreviewTouchPanState.startX = touch.clientX;
    bitPreviewTouchPanState.startY = touch.clientY;
    bitPreviewTouchPanState.startOffsetX = bitPreviewOffset.x;
    bitPreviewTouchPanState.startOffsetY = bitPreviewOffset.y;
  }

  function beginBitPreviewTouchPinch(t0, t1, container) {
    const center = getBitPreviewTouchCenter(t0, t1, container);
    bitPreviewTouchPinchState.active = true;
    bitPreviewTouchPinchState.startDistance = Math.max(1, getBitPreviewTouchDistance(t0, t1));
    bitPreviewTouchPinchState.startScale = bitPreviewScale;
    bitPreviewTouchPinchState.startOffsetX = bitPreviewOffset.x;
    bitPreviewTouchPinchState.startOffsetY = bitPreviewOffset.y;
    bitPreviewTouchPinchState.startCenterDX = center.x - container.clientWidth / 2;
    bitPreviewTouchPinchState.startCenterDY = center.y - container.clientHeight / 2;
  }

  function resetBitPreviewTouchStates() {
    bitPreviewTouchPanState.active = false;
    bitPreviewTouchPanState.moved = false;
    bitPreviewTouchPinchState.active = false;
  }

  function renderGrid(grid, options = {}) {
    const bitPreviewCanvas = document.getElementById('md-bitPreviewCanvas');
    const bitPreviewText = document.getElementById('md-bitPreviewText');
    const bitPreviewContainer = document.getElementById('md-bitPreview');

    if (!grid || grid.length === 0 || grid[0].length === 0) {
      bitPreviewCanvas.style.display = 'none';
      bitPreviewText.style.display = 'block';
      bitPreviewText.textContent = '暂无数据';
      return;
    }

    const rows = grid.length;
    const cols = grid[0].length;
    const pixelSize = BIT_PREVIEW_PIXEL;
    const gridLineWidth = BIT_PREVIEW_GRID;

    bitPreviewCanvas.width = cols * pixelSize + (cols + 1) * gridLineWidth;
    bitPreviewCanvas.height = rows * pixelSize + (rows + 1) * gridLineWidth;

    const resetView = options.resetView === true;
    if (resetView) {
      const containerWidth = bitPreviewContainer.clientWidth - 20;  // padding: 10px * 2
      const containerHeight = bitPreviewContainer.clientHeight - 20;
      const scaleX = containerWidth / bitPreviewCanvas.width;
      const scaleY = containerHeight / bitPreviewCanvas.height;
      const fitScale = Math.min(scaleX, scaleY, 1);
      bitPreviewOffset = { x: 0, y: 0 };
      bitPreviewScale = fitScale;
    }

    applyBitPreviewTransform();
    bitPreviewCanvas.style.transformOrigin = 'center';

    const ctx = bitPreviewCanvas.getContext('2d');
    ctx.imageSmoothingEnabled = false;

    ctx.fillStyle = '#1e293b';
    ctx.fillRect(0, 0, bitPreviewCanvas.width, bitPreviewCanvas.height);

    for (let row = 0; row < rows; row++) {
      for (let col = 0; col < cols; col++) {
        const x = col * (pixelSize + gridLineWidth) + gridLineWidth;
        const y = row * (pixelSize + gridLineWidth) + gridLineWidth;

        if (grid[row][col] === 1) {
          ctx.fillStyle = '#e0e7ff';
        } else {
          ctx.fillStyle = '#334155';
        }
        ctx.fillRect(x, y, pixelSize, pixelSize);
      }
    }

    bitPreviewCanvas.style.display = 'block';
    bitPreviewText.style.display = 'none';
  }

  function refreshStateFromGrid() {
    if (!state.grid || !state.grid.length || !state.grid[0].length) return;

    const rows = state.grid.length;
    const cols = state.grid[0].length;
    const bits = gridToBits(state.grid);

    let matchCount = 0;
    for (let r = 0; r < rows; r++) {
      const row = state.grid[r];
      for (let c = 0; c < cols; c++) {
        if (row[c]) matchCount++;
      }
    }

    state.bits = bits;
    state.width = cols;
    state.height = rows;
    state.bitHeight = rows;
    state.matchCount = matchCount;
    state.onesInBitHeight = matchCount;

    statSelection.textContent = `${cols} × ${rows}`;
    statBitsLen.textContent = bits.length;

    renderGrid(state.grid);
    updateLine();
  }

  function getBitPreviewCellFromEvent(evt) {
    const bitPreviewCanvas = document.getElementById('md-bitPreviewCanvas');
    if (!bitPreviewCanvas || bitPreviewCanvas.style.display === 'none') return null;
    if (!state.grid || !state.grid.length || !state.grid[0].length) return null;

    const rect = bitPreviewCanvas.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) return null;

    const scaleX = bitPreviewCanvas.width / rect.width;
    const scaleY = bitPreviewCanvas.height / rect.height;
    const x = (evt.clientX - rect.left) * scaleX;
    const y = (evt.clientY - rect.top) * scaleY;

    const rows = state.grid.length;
    const cols = state.grid[0].length;
    const totalW = cols * BIT_PREVIEW_PIXEL + (cols + 1) * BIT_PREVIEW_GRID;
    const totalH = rows * BIT_PREVIEW_PIXEL + (rows + 1) * BIT_PREVIEW_GRID;

    if (x < 0 || y < 0 || x > totalW || y > totalH) return null;

    const stepX = BIT_PREVIEW_PIXEL + BIT_PREVIEW_GRID;
    const stepY = BIT_PREVIEW_PIXEL + BIT_PREVIEW_GRID;

    const cellX = x - BIT_PREVIEW_GRID;
    const cellY = y - BIT_PREVIEW_GRID;
    if (cellX < 0 || cellY < 0) return null;

    const col = Math.floor(cellX / stepX);
    const row = Math.floor(cellY / stepY);

    if (col < 0 || col >= cols || row < 0 || row >= rows) return null;

    const offsetX = cellX - col * stepX;
    const offsetY = cellY - row * stepY;
    if (offsetX >= BIT_PREVIEW_PIXEL || offsetY >= BIT_PREVIEW_PIXEL) {
      return null; // 点击在网格线或边界上
    }

    return { row, col };
  }

  function toggleBitPreviewCell(evt) {
    const cell = getBitPreviewCellFromEvent(evt);
    if (!cell) return;
    const { row, col } = cell;
    state.grid[row][col] = state.grid[row][col] ? 0 : 1;
    refreshStateFromGrid();
  }

  function buildLine() {
    if (!state.bits) return '';
    const word = wordInput.value || '?';
    const left = Number(leftInput.value) || 0;
    const right = Number(rightInput.value) || 0;
    const match = state.matchCount || 0;
    const height = state.height || 0;
    const width = state.width || 0;
    // 导出使用规范化（无 @ 压缩）
    const normalizedBits = normalizeBits(state.bits);
    return `${normalizedBits}$${word}$${left}.${right}.${match}$${height}.${width}`;
  }

  function updateLine() {
    const line = buildLine();
    lineField.value = line;
  }

  function copyToClipboard(selector) {
    const el = document.querySelector(selector);
    if (!el) return;
    const text = el.value || el.textContent || '';
    if (!text) return;
    copyWithToast(text, '已拷贝到剪贴板');
  }

  function recomputeBinary() {
    if (!img) {
      resetCanvas();
      return;
    }
    const w = img.width;
    const h = img.height;
    if (!binaryCanvas) binaryCanvas = document.createElement('canvas');
    binaryCanvas.width = w;
    binaryCanvas.height = h;
    const offCtx = binaryCanvas.getContext('2d');
    offCtx.imageSmoothingEnabled = false;
    if (!sourceCanvas) {
      sourceCanvas = document.createElement('canvas');
      sourceCanvas.width = w;
      sourceCanvas.height = h;
      const sctx = sourceCanvas.getContext('2d');
      sctx.imageSmoothingEnabled = false;
      sctx.drawImage(img, 0, 0);
    }
    const sctx = sourceCanvas.getContext('2d');
    sctx.imageSmoothingEnabled = false;
    const tmpSrc = sctx.getImageData(0, 0, w, h);
    const dstData = offCtx.createImageData(w, h);
    // 只使用启用的颜色范围
    const enabledRanges = getEnabledColorRanges();
    const useColorRange = enabledRanges.length > 0;
    binaryMask = new Uint8Array(w * h);

    const isHit = (r, g, b, a) => {
      if (a === 0) return false;
      if (!useColorRange) return false;
      for (const item of enabledRanges) {
        const [br, bg, bb] = item.base;
        const [tr, tg, tb] = item.tol;
        if (Math.abs(r - br) <= tr && Math.abs(g - bg) <= tg && Math.abs(b - bb) <= tb) {
          return true;
        }
      }
      return false;
    };

    for (let i = 0; i < w * h; i++) {
      const idx = i * 4;
      const r = tmpSrc.data[idx], g = tmpSrc.data[idx + 1], b = tmpSrc.data[idx + 2], a = tmpSrc.data[idx + 3];
      const on = isHit(r, g, b, a);
      binaryMask[i] = on ? 1 : 0;
      const v = on ? 255 : 0;
      dstData.data[idx] = dstData.data[idx + 1] = dstData.data[idx + 2] = v;
      dstData.data[idx + 3] = 255;
    }
    offCtx.putImageData(dstData, 0, 0);
    binaryImageData = dstData;
    renderBinaryOverlayOnly();
    if (selection) processSelection();
    // 更新拆分按钮状态（延迟执行以确保函数已定义）
    setTimeout(() => {
      if (typeof updateSplitButtonState === 'function') updateSplitButtonState();
    }, 0);
  }

  function renderBinaryOverlayOnly() {
    if (!img) {
      resetCanvas();
      return;
    }
    const logical = getCanvasLogicalSize(canvasBinary);
    const metrics = ensureCanvasResolution(canvasBinary, logical.width, logical.height);
    const w = logical.width;
    const h = logical.height;
    ctxBinary.setTransform(1, 0, 0, 1, 0, 0);
    ctxBinary.clearRect(0, 0, canvasBinary.width, canvasBinary.height);
    ctxBinary.setTransform(metrics.scaleX, 0, 0, metrics.scaleY, 0, 0);

    if (binaryCanvas) {
      const centerX = w / 2;
      const centerY = h / 2;
      const imgW = img.width * view.scale;
      const imgH = img.height * view.scale;
      const drawX = centerX - imgW / 2 + view.offsetX;
      const drawY = centerY - imgH / 2 + view.offsetY;

      ctxBinary.imageSmoothingEnabled = false;
      ctxBinary.drawImage(binaryCanvas, drawX, drawY, imgW, imgH);
    }
    drawBinaryOverlay();
    drawMetaSelectionBox();
    drawHoverMarker(ctxBinary, canvasBinary);
  }

  function handleWheel(evt) {
    if (!img) return;
    evt.preventDefault();
    const delta = evt.deltaY < 0 ? 1.1 : 0.9;
    const oldScale = view.scale;
    const newScale = clamp(view.scale * delta, 0.1, 20);

    const target = evt.target === canvasOriginal ? canvasOriginal : canvasBinary;
    const logical = getCanvasLogicalSize(target);
    ensureCanvasResolution(target, logical.width, logical.height);
    const rect = target.getBoundingClientRect();
    const w = logical.width;
    const h = logical.height;
    const mouseX = evt.clientX - rect.left;
    const mouseY = evt.clientY - rect.top;

    const centerX = w / 2;
    const centerY = h / 2;
    const mouseDX = mouseX - centerX;
    const mouseDY = mouseY - centerY;

    const scaleRatio = newScale / oldScale;

    view.offsetX = (view.offsetX - mouseDX) * scaleRatio + mouseDX;
    view.offsetY = (view.offsetY - mouseDY) * scaleRatio + mouseDY;
    view.scale = newScale;

    updateZoomUI();
    renderBinaryOverlayOnly();
    drawOriginal();
  }

  // Event wiring
  canvasBinary.addEventListener('mousedown', onMouseDown);
  canvasBinary.addEventListener('mousemove', onMouseMove);
  canvasBinary.addEventListener('mouseup', onMouseUp);
  canvasBinary.addEventListener('mouseleave', () => {
    panDragging = false;
    panMoved = false;
    panDragCanvas = null;
    moveBoxDragging = false;
    if (resizeDragging) {
      resizeDragging = false;
      resizeHandle = null;
      setBinaryCursor('crosshair');
      renderBinaryOverlayOnly();
      processSelection();
    }
    if (dragging) {
      dragging = false;
      renderBinaryOverlayOnly();
      processSelection();
    }
    setBinaryCursor('crosshair');
    clearHoverPixel();
  });
  canvasBinary.addEventListener('wheel', handleWheel, { passive: false });
  canvasBinary.addEventListener('contextmenu', (evt) => evt.preventDefault());
  [canvasOriginal, canvasBinary].forEach((cvs) => {
    cvs.addEventListener('touchstart', handleCanvasTouchStart, { passive: false });
    cvs.addEventListener('touchmove', handleCanvasTouchMove, { passive: false });
    cvs.addEventListener('touchend', handleCanvasTouchEnd, { passive: false });
    cvs.addEventListener('touchcancel', handleCanvasTouchCancel, { passive: false });
  });

  // Enter 键聚焦到文字输入框，以及 Ctrl/Meta+V 粘贴图片
  document.addEventListener('keydown', (evt) => {
    if (evt.key === 'Escape' && colorPickState.open) {
      evt.preventDefault();
      closeColorPickPopover();
      return;
    }

    // Ctrl/Meta+V：粘贴剪贴板图片
    const isMac = navigator.platform.match('Mac');
    const ctrlOrMeta = isMac ? evt.metaKey : evt.ctrlKey;
    if (ctrlOrMeta && evt.key.toLowerCase() === 'v') {
      // 检查当前焦点是否在输入框中（不拦截输入框中的粘贴）
      const activeEl = document.activeElement;
      const isInInput = activeEl && (activeEl.tagName === 'INPUT' || activeEl.tagName === 'TEXTAREA');
      if (!isInInput) {
        // 检查是否支持 Clipboard API（需要安全上下文）
        if (navigator.clipboard && navigator.clipboard.read && window.isSecureContext) {
          evt.preventDefault();
          handleClipboardPaste();
          return;
        }
        // 非安全上下文，不调用 preventDefault，让 paste 事件正常触发
      }
    }

    // Ctrl/Meta+Z：撤销偏色列表取样操作
    if (ctrlOrMeta && evt.key.toLowerCase() === 'z' && !evt.shiftKey) {
      const activeEl = document.activeElement;
      const isInInput = activeEl && (activeEl.tagName === 'INPUT' || activeEl.tagName === 'TEXTAREA');
      if (!isInInput) {
        evt.preventDefault();
        undoColorRange();
        return;
      }
    }

    if (evt.key === 'Enter' && !evt.shiftKey && !evt.ctrlKey && !evt.altKey && !evt.metaKey) {
      // 检查当前焦点不在输入框中
      const activeEl = document.activeElement;
      const isInInput = activeEl && (activeEl.tagName === 'INPUT' || activeEl.tagName === 'TEXTAREA');

      if (!isInInput && selection && selection.w > 0 && selection.h > 0 && state.bits) {
        // 检查选区是否有效（非全黑且非全白）
        const totalPixels = state.width * state.height;
        const whitePixels = state.matchCount || 0;
        const isAllBlack = whitePixels === 0;
        const isAllWhite = whitePixels === totalPixels;

        if (!isAllBlack && !isAllWhite) {
          evt.preventDefault();
          wordInput.focus();
          wordInput.select();
          return;
        }
      }
    }
  });

  // 待粘贴的图片 Blob（用于确认后加载）
  let pendingPasteBlob = null;

  // 粘贴确认弹窗相关元素
  const pasteConfirmModal = document.getElementById('md-pasteConfirmModal');
  const closePasteConfirmModal = document.getElementById('md-closePasteConfirmModal');
  const pasteConfirmCancelBtn = document.getElementById('md-pasteConfirmCancelBtn');
  const pasteConfirmBtn = document.getElementById('md-pasteConfirmBtn');

  function showPasteConfirmModal(blob) {
    pendingPasteBlob = blob;
    openModal(pasteConfirmModal);
  }

  function hidePasteConfirmModal() {
    closeModal(pasteConfirmModal);
    pendingPasteBlob = null;
  }

  if (closePasteConfirmModal) {
    closePasteConfirmModal.addEventListener('click', hidePasteConfirmModal);
  }
  if (pasteConfirmCancelBtn) {
    pasteConfirmCancelBtn.addEventListener('click', hidePasteConfirmModal);
  }
  if (pasteConfirmBtn) {
    pasteConfirmBtn.addEventListener('click', () => {
      if (pendingPasteBlob) {
        loadImageFromBlob(pendingPasteBlob);
      }
      hidePasteConfirmModal();
    });
  }
  if (pasteConfirmModal) {
    MatrixHelpers.bindModalBackdropClose(pasteConfirmModal);
    MatrixHelpers.bindModalEscClose(pasteConfirmModal, document.getElementById('md-pasteConfirmCancelBtn'));
  }

  // 从剪贴板粘贴图片
  function handleClipboardPaste() {
    navigator.clipboard.read().then((clipboardItems) => {
      for (let i = 0; i < clipboardItems.length; i++) {
        const item = clipboardItems[i];
        // 查找图片类型
        let imageType = null;
        for (let j = 0; j < item.types.length; j++) {
          if (item.types[j].startsWith('image/')) {
            imageType = item.types[j];
            break;
          }
        }
        if (imageType) {
          item.getType(imageType).then((blob) => {
            if (img) {
              // 已有图片，显示确认弹窗
              showPasteConfirmModal(blob);
            } else {
              // 没有图片，直接加载
              loadImageFromBlob(blob);
            }
          }).catch((err) => {
            console.warn('获取剪贴板图片失败:', err);
            showToast('获取剪贴板图片失败');
          });
          return;
        }
      }
      showToast('剪贴板中没有图片');
    }).catch((err) => {
      console.warn('读取剪贴板失败:', err);
      showToast('无法读取剪贴板，请使用 Ctrl+V 重试');
    });
  }

  // 从 Blob 加载图片
  function loadImageFromBlob(blob) {
    const reader = new FileReader();
    reader.onload = (e) => {
      const image = new Image();
      image.onload = () => {
        img = image;
        sourceCanvas = document.createElement('canvas');
        sourceCanvas.width = img.width;
        sourceCanvas.height = img.height;
        const sctx = sourceCanvas.getContext('2d');
        sctx.imageSmoothingEnabled = false;
        sctx.drawImage(img, 0, 0);
        setCanvasSizeForImage(image.naturalWidth, image.naturalHeight);
        selection = null;
        metaSelection = null;
        closeColorPickPopover();
        drawOriginal();
        recomputeBinary();
        clearOutputs();
        updateSelectionRecordUI();
        showToast('已从剪贴板粘贴图片');
      };
      image.src = e.target.result;
    };
    reader.readAsDataURL(blob);
  }

  // 监听 paste 事件（作为备用方案）
  document.addEventListener('paste', (evt) => {
    // 检查当前焦点是否在输入框中（不拦截输入框中的粘贴）
    const activeEl = document.activeElement;
    const isInInput = activeEl && (activeEl.tagName === 'INPUT' || activeEl.tagName === 'TEXTAREA');
    if (isInInput) return;

    const items = evt.clipboardData && evt.clipboardData.items;
    if (!items) return;

    for (let i = 0; i < items.length; i++) {
      if (items[i].type.indexOf('image') !== -1) {
        const blob = items[i].getAsFile();
        if (blob) {
          evt.preventDefault();
          if (img) {
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

  canvasOriginal.addEventListener('mousedown', (evt) => {
    if (!img) return;
    const isMac = navigator.platform.match('Mac');
    const effectiveShift = evt.shiftKey;
    const effectiveMeta = isMac ? evt.metaKey : evt.ctrlKey;
    if (evt.altKey && evt.button === 0) {
      sampleColorDirectAt(evt, canvasOriginal);
      return;
    }
    if (!effectiveShift && !effectiveMeta && evt.button === 0) {
      panDragging = true;
      panMoved = false;
      panDragCanvas = canvasOriginal;
      panStart = { x: evt.clientX, y: evt.clientY, offsetX: view.offsetX, offsetY: view.offsetY };
    }
  });
  canvasOriginal.addEventListener('mousemove', onMouseMove);
  canvasOriginal.addEventListener('mouseup', onMouseUp);
  canvasOriginal.addEventListener('mouseleave', () => {
    panDragging = false;
    panMoved = false;
    panDragCanvas = null;
    moveBoxDragging = false;
    if (dragging) {
      dragging = false;
      renderBinaryOverlayOnly();
      processSelection();
    }
    canvasOriginal.style.cursor = 'crosshair';
    clearHoverPixel();
  });
  canvasOriginal.addEventListener('wheel', handleWheel, { passive: false });

  // 放大镜功能
  const magnifierCanvas = document.getElementById('md-magnifierCanvas');
  const magnifierCtx = magnifierCanvas.getContext('2d');
  const magnifierCoord = document.getElementById('md-magnifierCoord');
  const magnifierSwatch = document.getElementById('md-magnifierSwatch');
  const magnifierHex = document.getElementById('md-magnifierHex');
  const magnifierRgb = document.getElementById('md-magnifierRgb');
  const magnifierZoomInput = document.getElementById('md-magnifierZoom');
  const magnifierZoomLabel = document.getElementById('md-magnifierZoomLabel');
  let magnifierZoomLevel = 10;

  magnifierCtx.imageSmoothingEnabled = false;

  function updateMagnifier(evt, cvs) {
    if (!img || !sourceCanvas) return;

    const rect = cvs.getBoundingClientRect();
    const cx = evt.clientX - rect.left;
    const cy = evt.clientY - rect.top;

    const logical = getCanvasLogicalSize(cvs);
    const w = logical.width;
    const h = logical.height;
    const centerX = w / 2;
    const centerY = h / 2;
    const imgW = img.width * view.scale;
    const imgH = img.height * view.scale;
    const baseX = centerX - imgW / 2 + view.offsetX;
    const baseY = centerY - imgH / 2 + view.offsetY;

    const imgX = Math.floor((cx - baseX) / view.scale);
    const imgY = Math.floor((cy - baseY) / view.scale);

    if (imgX < 0 || imgX >= img.width || imgY < 0 || imgY >= img.height) {
      magnifierCoord.textContent = '超出范围';
      magnifierHex.textContent = '0x------';
      magnifierRgb.textContent = '--';
      magnifierSwatch.style.background = '#888';
      magnifierCtx.clearRect(0, 0, magnifierCanvas.width, magnifierCanvas.height);
      return;
    }

    magnifierCoord.textContent = `(${imgX}, ${imgY})`;

    const sctx = sourceCanvas.getContext('2d');
    const pixel = sctx.getImageData(imgX, imgY, 1, 1).data;
    const hex = rgbToHex(pixel[0], pixel[1], pixel[2]);
    magnifierHex.textContent = `0x${hex}`;
    magnifierRgb.textContent = `${pixel[0]}, ${pixel[1]}, ${pixel[2]}`;
    magnifierSwatch.style.background = `rgb(${pixel[0]}, ${pixel[1]}, ${pixel[2]})`;

    const canvasSize = magnifierCanvas.width;
    const pixelCount = Math.floor(canvasSize / magnifierZoomLevel) | 1;
    const halfPixels = Math.floor(pixelCount / 2);
    const totalSize = pixelCount * magnifierZoomLevel;
    const offset = Math.floor((canvasSize - totalSize) / 2);

    magnifierCtx.fillStyle = '#e8e8e8';
    magnifierCtx.fillRect(0, 0, canvasSize, canvasSize);

    magnifierCtx.fillStyle = '#ffffff';
    for (let py = 0; py < pixelCount; py++) {
      for (let px = 0; px < pixelCount; px++) {
        if ((px + py) % 2 === 0) {
          magnifierCtx.fillRect(offset + px * magnifierZoomLevel, offset + py * magnifierZoomLevel, magnifierZoomLevel, magnifierZoomLevel);
        }
      }
    }

    const batchSrcX = Math.max(0, imgX - halfPixels);
    const batchSrcY = Math.max(0, imgY - halfPixels);
    const batchSrcX2 = Math.min(img.width, imgX + halfPixels + 1);
    const batchSrcY2 = Math.min(img.height, imgY + halfPixels + 1);
    const batchW = batchSrcX2 - batchSrcX;
    const batchH = batchSrcY2 - batchSrcY;
    const batchData = (batchW > 0 && batchH > 0) ? sctx.getImageData(batchSrcX, batchSrcY, batchW, batchH).data : null;
    for (let dy = -halfPixels; dy <= halfPixels; dy++) {
      for (let dx = -halfPixels; dx <= halfPixels; dx++) {
        const srcX = imgX + dx;
        const srcY = imgY + dy;

        if (srcX >= 0 && srcX < img.width && srcY >= 0 && srcY < img.height) {
          const bIdx = ((srcY - batchSrcY) * batchW + (srcX - batchSrcX)) * 4;
          magnifierCtx.fillStyle = `rgba(${batchData[bIdx]}, ${batchData[bIdx + 1]}, ${batchData[bIdx + 2]}, ${batchData[bIdx + 3] / 255})`;
          const drawX = offset + (dx + halfPixels) * magnifierZoomLevel;
          const drawY = offset + (dy + halfPixels) * magnifierZoomLevel;
          magnifierCtx.fillRect(drawX, drawY, magnifierZoomLevel, magnifierZoomLevel);
        }
      }
    }

    const centerDrawX = offset + halfPixels * magnifierZoomLevel;
    const centerDrawY = offset + halfPixels * magnifierZoomLevel;
    magnifierCtx.strokeStyle = 'rgba(227, 95, 74, 0.9)';
    magnifierCtx.lineWidth = 2;
    magnifierCtx.strokeRect(centerDrawX, centerDrawY, magnifierZoomLevel, magnifierZoomLevel);

    if (magnifierZoomLevel >= 8) {
      magnifierCtx.strokeStyle = 'rgba(0, 0, 0, 0.1)';
      magnifierCtx.lineWidth = 0.5;
      for (let i = 0; i <= pixelCount; i++) {
        magnifierCtx.beginPath();
        magnifierCtx.moveTo(offset + i * magnifierZoomLevel, offset);
        magnifierCtx.lineTo(offset + i * magnifierZoomLevel, offset + totalSize);
        magnifierCtx.stroke();
        magnifierCtx.beginPath();
        magnifierCtx.moveTo(offset, offset + i * magnifierZoomLevel);
        magnifierCtx.lineTo(offset + totalSize, offset + i * magnifierZoomLevel);
        magnifierCtx.stroke();
      }
    }
  }

  function clearMagnifier() {
    magnifierCoord.textContent = '--';
    magnifierHex.textContent = '0x------';
    magnifierRgb.textContent = '--';
    magnifierSwatch.style.background = '#888';
    magnifierCtx.clearRect(0, 0, magnifierCanvas.width, magnifierCanvas.height);
  }

  canvasOriginal.addEventListener('mousemove', (evt) => {
    updateMagnifier(evt, canvasOriginal);
  });
  canvasOriginal.addEventListener('mouseleave', clearMagnifier);

  canvasBinary.addEventListener('mousemove', (evt) => {
    updateMagnifier(evt, canvasBinary);
  });
  canvasBinary.addEventListener('mouseleave', clearMagnifier);

  magnifierZoomInput.addEventListener('input', () => {
    magnifierZoomLevel = Number(magnifierZoomInput.value);
    magnifierZoomLabel.textContent = `${magnifierZoomLevel}x`;
  });

  // 点阵预览缩放和拖动控制
  const bitPreviewContainer = document.getElementById('md-bitPreview');

  bitPreviewContainer.addEventListener('wheel', (evt) => {
    const bitPreviewCanvas = document.getElementById('md-bitPreviewCanvas');
    if (bitPreviewCanvas.style.display === 'none') return;

    evt.preventDefault();
    const delta = evt.deltaY < 0 ? 1.1 : 0.9;
    bitPreviewScale = clamp(bitPreviewScale * delta, 0.02, 10);
    applyBitPreviewTransform();
  }, { passive: false });

  bitPreviewContainer.addEventListener('mousedown', (evt) => {
    const bitPreviewCanvas = document.getElementById('md-bitPreviewCanvas');
    if (bitPreviewCanvas.style.display === 'none') return;

    if (evt.altKey && evt.button === 0) {
      evt.preventDefault();
      toggleBitPreviewCell(evt);
      return;
    }

    bitPreviewDragging = true;
    bitPreviewDragStart = {
      x: evt.clientX,
      y: evt.clientY,
      offsetX: bitPreviewOffset.x,
      offsetY: bitPreviewOffset.y
    };
    bitPreviewContainer.style.cursor = 'grabbing';
  });

  bitPreviewContainer.addEventListener('mousemove', (evt) => {
    if (!bitPreviewDragging) return;

    const dx = evt.clientX - bitPreviewDragStart.x;
    const dy = evt.clientY - bitPreviewDragStart.y;
    bitPreviewOffset.x = bitPreviewDragStart.offsetX + dx;
    bitPreviewOffset.y = bitPreviewDragStart.offsetY + dy;
    applyBitPreviewTransform();
  });

  bitPreviewContainer.addEventListener('mouseup', () => {
    bitPreviewDragging = false;
    bitPreviewContainer.style.cursor = 'crosshair';
  });

  bitPreviewContainer.addEventListener('mouseleave', () => {
    bitPreviewDragging = false;
    bitPreviewContainer.style.cursor = 'crosshair';
  });

  bitPreviewContainer.addEventListener('touchstart', (evt) => {
    const bitPreviewCanvas = getBitPreviewCanvasEl();
    if (!bitPreviewCanvas || bitPreviewCanvas.style.display === 'none') return;

    if (evt.touches.length >= 2) {
      bitPreviewTouchPanState.active = false;
      bitPreviewTouchPanState.moved = true;
      beginBitPreviewTouchPinch(evt.touches[0], evt.touches[1], bitPreviewContainer);
      evt.preventDefault();
      return;
    }

    if (evt.touches.length === 1) {
      bitPreviewTouchPinchState.active = false;
      beginBitPreviewTouchPan(evt.touches[0], false);
      evt.preventDefault();
    }
  }, { passive: false });

  bitPreviewContainer.addEventListener('touchmove', (evt) => {
    const bitPreviewCanvas = getBitPreviewCanvasEl();
    if (!bitPreviewCanvas || bitPreviewCanvas.style.display === 'none') return;

    if (evt.touches.length >= 2) {
      if (!bitPreviewTouchPinchState.active) {
        beginBitPreviewTouchPinch(evt.touches[0], evt.touches[1], bitPreviewContainer);
      }
      const distance = Math.max(1, getBitPreviewTouchDistance(evt.touches[0], evt.touches[1]));
      const scaleFactor = distance / Math.max(1, bitPreviewTouchPinchState.startDistance);
      const newScale = clamp(bitPreviewTouchPinchState.startScale * scaleFactor, 0.02, 10);
      const center = getBitPreviewTouchCenter(evt.touches[0], evt.touches[1], bitPreviewContainer);
      const centerDX = center.x - bitPreviewContainer.clientWidth / 2;
      const centerDY = center.y - bitPreviewContainer.clientHeight / 2;
      const scaleRatio = newScale / Math.max(0.0001, bitPreviewTouchPinchState.startScale);

      bitPreviewOffset.x = (bitPreviewTouchPinchState.startOffsetX - bitPreviewTouchPinchState.startCenterDX) * scaleRatio + centerDX;
      bitPreviewOffset.y = (bitPreviewTouchPinchState.startOffsetY - bitPreviewTouchPinchState.startCenterDY) * scaleRatio + centerDY;
      bitPreviewScale = newScale;
      bitPreviewTouchPanState.active = false;
      bitPreviewTouchPanState.moved = true;
      applyBitPreviewTransform();
      evt.preventDefault();
      return;
    }

    if (evt.touches.length === 1) {
      const touch = evt.touches[0];
      if (bitPreviewTouchPinchState.active) {
        bitPreviewTouchPinchState.active = false;
        beginBitPreviewTouchPan(touch, true);
      }
      if (!bitPreviewTouchPanState.active) {
        beginBitPreviewTouchPan(touch, false);
      }
      const dx = touch.clientX - bitPreviewTouchPanState.startX;
      const dy = touch.clientY - bitPreviewTouchPanState.startY;
      if (Math.abs(dx) > BIT_PREVIEW_TOUCH_PAN_THRESHOLD || Math.abs(dy) > BIT_PREVIEW_TOUCH_PAN_THRESHOLD) {
        bitPreviewTouchPanState.moved = true;
      }
      bitPreviewOffset.x = bitPreviewTouchPanState.startOffsetX + dx;
      bitPreviewOffset.y = bitPreviewTouchPanState.startOffsetY + dy;
      applyBitPreviewTransform();
      evt.preventDefault();
    }
  }, { passive: false });

  bitPreviewContainer.addEventListener('touchend', (evt) => {
    const bitPreviewCanvas = getBitPreviewCanvasEl();
    if (!bitPreviewCanvas || bitPreviewCanvas.style.display === 'none') return;

    if (evt.touches.length >= 2) {
      beginBitPreviewTouchPinch(evt.touches[0], evt.touches[1], bitPreviewContainer);
      evt.preventDefault();
      return;
    }
    if (evt.touches.length === 1) {
      beginBitPreviewTouchPan(evt.touches[0], true);
      bitPreviewTouchPinchState.active = false;
      evt.preventDefault();
      return;
    }
    resetBitPreviewTouchStates();
    evt.preventDefault();
  }, { passive: false });

  bitPreviewContainer.addEventListener('touchcancel', (evt) => {
    resetBitPreviewTouchStates();
    evt.preventDefault();
  }, { passive: false });

  // 在画布区域支持拖放图片
  const canvasWrappers = document.querySelectorAll('.matrix-canvas-wrapper');
  canvasWrappers.forEach(wrapper => {
    wrapper.addEventListener('dragover', (evt) => {
      evt.preventDefault();
      wrapper.classList.add('drag-over');
    });
    wrapper.addEventListener('dragleave', () => {
      wrapper.classList.remove('drag-over');
    });
    wrapper.addEventListener('drop', (evt) => {
      evt.preventDefault();
      wrapper.classList.remove('drag-over');
      const file = evt.dataTransfer.files && evt.dataTransfer.files[0];
      if (file && file.type.startsWith('image/')) {
        handleFile(file);
      }
    });
  });

  wordInput.addEventListener('input', updateLine);
  [leftInput, rightInput].forEach(el => {
    el.addEventListener('input', updateLine);
  });

  document.querySelectorAll('[data-copy]').forEach(btn => {
    btn.addEventListener('click', () => copyToClipboard(btn.dataset.copy));
  });

  // "二值化"按钮：同步文本框到列表（添加新的，取消勾选文本框中没有的）
  setColorRangeBtn.addEventListener('click', () => {
    syncColorRangesFromText();
  });

  // "适应选区"按钮：将选区收缩到仅包含目标点的最小边界
  const fitSelectionBtn = document.getElementById('md-fitSelectionBtn');

  /**
   * 执行选区适应操作
   * @param {boolean} isWhiteMode - 是否为白底模式（白底模式下寻找黑点边界）
   */
  function performFitSelection(isWhiteMode) {
    const { x: selX, y: selY, w: selW, h: selH } = selection;

    // 找到选区内目标点的边界
    // 黑底模式：寻找白点（binaryMask === 1）
    // 白底模式：寻找黑点（binaryMask === 0）
    const targetValue = isWhiteMode ? 0 : 1;
    let minX = Infinity, maxX = -Infinity;
    let minY = Infinity, maxY = -Infinity;
    let hasTargetPixel = false;

    for (let row = 0; row < selH; row++) {
      for (let col = 0; col < selW; col++) {
        const imgX = selX + col;
        const imgY = selY + row;
        const maskIdx = imgY * img.width + imgX;
        if (binaryMask[maskIdx] === targetValue) {
          hasTargetPixel = true;
          if (col < minX) minX = col;
          if (col > maxX) maxX = col;
          if (row < minY) minY = row;
          if (row > maxY) maxY = row;
        }
      }
    }

    if (!hasTargetPixel) {
      showToast(isWhiteMode ? '选区内没有黑点' : '选区内没有白点');
      return;
    }

    // 计算新的选区（相对于原图的坐标）
    const newX = selX + minX;
    const newY = selY + minY;
    const newW = maxX - minX + 1;
    const newH = maxY - minY + 1;

    // 检查是否有变化
    if (newX === selX && newY === selY && newW === selW && newH === selH) {
      showToast('选区已是最小边界');
      return;
    }

    // 更新选区
    selection = { x: newX, y: newY, w: newW, h: newH };
    renderBinaryOverlayOnly();
    processSelection();
    const modeText = isWhiteMode ? '（白底模式）' : '';
    showToast(`选区已适应${modeText}：${selW}×${selH} → ${newW}×${newH}`);
  }

  fitSelectionBtn.addEventListener('click', () => {
    if (!selection || selection.w <= 0 || selection.h <= 0) {
      showToast('请先框选一个区域');
      return;
    }
    if (!binaryMask || !img) {
      showToast('请先进行二值化');
      return;
    }

    // 检测是否为白底
    if (detectWhiteBackground(selection)) {
      // 弹出选择框让用户选择底色模式
      showBgModeModal('fitSelection', (isWhiteMode) => {
        performFitSelection(isWhiteMode);
      });
    } else {
      // 默认黑底模式
      performFitSelection(false);
    }
  });

  // ========== 拆分点阵功能 ==========
  const splitMatrixBtn = document.getElementById('md-splitMatrixBtn');
  const splitMatrixModal = document.getElementById('md-splitMatrixModal');
  const closeSplitMatrixModal = document.getElementById('md-closeSplitMatrixModal');
  const splitMatrixCancelBtn = document.getElementById('md-splitMatrixCancelBtn');
  const splitMatrixConfirmBtn = document.getElementById('md-splitMatrixConfirmBtn');
  const splitRunColInput = document.getElementById('md-splitRunCol');
  const splitMaxHeightInput = document.getElementById('md-splitMaxHeight');

  // 更新拆分按钮的启用状态
  function updateSplitButtonState() {
    if (!splitMatrixBtn) return;
    const hasValidSelection = selection && selection.w > 0 && selection.h > 0 && binaryMask && img;
    splitMatrixBtn.disabled = !hasValidSelection;
  }

  // 在选区变化时更新按钮状态
  const originalProcessSelection = processSelection;
  processSelection = function() {
    originalProcessSelection.apply(this, arguments);
    updateSplitButtonState();
  };

  // 显示拆分弹窗
  function showSplitMatrixModal() {
    if (!selection || selection.w <= 0 || selection.h <= 0) {
      showToast('请先框选一个区域');
      return;
    }
    if (!binaryMask || !img) {
      showToast('请先进行二值化');
      return;
    }

    // 检测是否为白底
    if (detectWhiteBackground(selection)) {
      // 弹出选择框让用户选择底色模式
      showBgModeModal('splitMatrix', (isWhiteMode) => {
        splitWhiteMode = isWhiteMode;
        openModal(splitMatrixModal);
      });
    } else {
      // 默认黑底模式
      splitWhiteMode = false;
      openModal(splitMatrixModal);
    }
  }

  // 隐藏拆分弹窗
  function hideSplitMatrixModal() {
    closeModal(splitMatrixModal);
  }

  /**
   * 从二值化选区提取 0/1 矩阵
   * @param {Object} sel - 选区 {x, y, w, h}
   * @returns {Uint8Array[]} 二维数组，1 表示白点（黑点判定为 RGB(0,0,0)，这里 binaryMask 中 1=命中色）
   */
  function extractBinaryMatrix(sel) {
    const { x, y, w, h } = sel;
    const matrix = [];
    for (let row = 0; row < h; row++) {
      const rowData = new Uint8Array(w);
      for (let col = 0; col < w; col++) {
        const maskIdx = (y + row) * img.width + (x + col);
        rowData[col] = binaryMask[maskIdx] === 1 ? 1 : 0;
      }
      matrix.push(rowData);
    }
    return matrix;
  }

  /**
   * 紧致裁剪矩阵：去除上下左右全为背景色的行和列
   * @param {Uint8Array[]} matrix - 二维矩阵
   * @param {number} maxHeight - 最大高度限制，0 表示不限制
   * @param {boolean} isWhiteMode - 是否为白底模式（白底模式下内容是 0，黑底模式下内容是 1）
   * @returns {{ matrix: Uint8Array[], minRow: number, minCol: number }} 裁剪后的矩阵和偏移
   */
  function trimMatrix(matrix, maxHeight = 0, isWhiteMode = false) {
    if (!matrix || matrix.length === 0 || matrix[0].length === 0) {
      return { matrix: [], minRow: 0, minCol: 0 };
    }

    const rows = matrix.length;
    const cols = matrix[0].length;

    // 找出所有内容点的边界
    // 黑底模式：内容是 1（白点）
    // 白底模式：内容是 0（黑点）
    const contentValue = isWhiteMode ? 0 : 1;
    let minRow = rows, maxRow = -1, minCol = cols, maxCol = -1;
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        if (matrix[r][c] === contentValue) {
          if (r < minRow) minRow = r;
          if (r > maxRow) maxRow = r;
          if (c < minCol) minCol = c;
          if (c > maxCol) maxCol = c;
        }
      }
    }

    // 没有任何内容点
    if (maxRow < 0) {
      return { matrix: [], minRow: 0, minCol: 0 };
    }

    // 应用高度限制
    let endRow = maxRow + 1;
    if (maxHeight > 0 && (endRow - minRow) > maxHeight) {
      endRow = minRow + maxHeight;
    }

    // 提取紧致矩阵
    const trimmedMatrix = [];
    for (let r = minRow; r < endRow; r++) {
      const newRow = new Uint8Array(maxCol - minCol + 1);
      for (let c = minCol; c <= maxCol; c++) {
        newRow[c - minCol] = matrix[r][c];
      }
      trimmedMatrix.push(newRow);
    }

    return { matrix: trimmedMatrix, minRow, minCol };
  }

  /**
   * 检查某一列是否为分隔列（全为背景色）
   * @param {Uint8Array[]} matrix - 二维矩阵
   * @param {number} col - 列索引
   * @param {boolean} isWhiteMode - 是否为白底模式（白底模式下分隔列全为 1，黑底模式下全为 0）
   * @returns {boolean}
   */
  function isColumnEmpty(matrix, col, isWhiteMode = false) {
    // 黑底模式：分隔列是全 0（黑色），内容列有 1（白色）
    // 白底模式：分隔列是全 1（白色），内容列有 0（黑色）
    const contentValue = isWhiteMode ? 0 : 1;
    for (let r = 0; r < matrix.length; r++) {
      if (matrix[r][col] === contentValue) return false;
    }
    return true;
  }

  /**
   * 按列扫描分割矩阵
   * @param {Uint8Array[]} matrix - 已紧致裁剪的二维矩阵
   * @param {number} runCol - 连续空列阈值
   * @param {boolean} isWhiteMode - 是否为白底模式
   * @returns {Uint8Array[][]} 分割后的子矩阵数组
   */
  function splitMatrixByColumns(matrix, runCol, isWhiteMode = false) {
    if (!matrix || matrix.length === 0 || matrix[0].length === 0) {
      return [];
    }

    const cols = matrix[0].length;
    const subMatrices = [];
    let start = 0;

    while (start < cols) {
      // 跳过起始位置的空列
      while (start < cols && isColumnEmpty(matrix, start, isWhiteMode)) {
        start++;
      }
      if (start >= cols) break;

      // 找到下一个分隔点（连续 runCol 个空列）
      let curr = start;
      let splitPoint = -1;

      while (curr < cols) {
        // 检查从 curr 开始是否有连续 runCol 个空列
        let emptyCount = 0;
        let checkCol = curr;
        while (checkCol < cols && isColumnEmpty(matrix, checkCol, isWhiteMode)) {
          emptyCount++;
          checkCol++;
        }

        if (emptyCount >= runCol) {
          // 找到分隔点
          splitPoint = curr;
          break;
        } else if (emptyCount > 0) {
          // 有空列但不够 runCol，跳过继续
          curr = checkCol;
        } else {
          // 非空列，继续前进
          curr++;
        }
      }

      // 确定子矩阵的结束位置
      let end;
      if (splitPoint >= 0) {
        end = splitPoint;
      } else {
        end = cols;
      }

      // 提取子矩阵的列范围 [start, end)
      if (end > start) {
        const width = end - start;
        // 检查宽度是否大于 runCol（过滤噪声）
        if (width > runCol || splitPoint < 0) {
          const subMatrix = [];
          for (let r = 0; r < matrix.length; r++) {
            const row = new Uint8Array(width);
            for (let c = 0; c < width; c++) {
              row[c] = matrix[r][start + c];
            }
            subMatrix.push(row);
          }
          subMatrices.push(subMatrix);
        }
      }

      // 移动到分隔点之后继续
      if (splitPoint >= 0) {
        start = splitPoint + runCol;
      } else {
        break;
      }
    }

    return subMatrices;
  }

  /**
   * 将子矩阵转换为点阵数据并添加到列表
   * @param {Uint8Array[]} matrix - 子矩阵
   * @param {boolean} isWhiteMode - 是否为白底模式
   * @returns {Object|null} 解析后的点阵对象
   */
  function subMatrixToMatrixItem(matrix, isWhiteMode = false) {
    // 再次紧致裁剪（去掉子矩阵自身的空白）
    const { matrix: trimmed } = trimMatrix(matrix, 0, isWhiteMode);
    if (!trimmed || trimmed.length === 0 || trimmed[0].length === 0) {
      return null;
    }

    const rows = trimmed.length;
    const cols = trimmed[0].length;

    // 计算 bits（列优先编码）
    const flatBits = [];
    for (let col = 0; col < cols; col++) {
      for (let row = 0; row < rows; row++) {
        flatBits.push(trimmed[row][col] ? 1 : 0);
      }
    }

    // 补齐到 4 的倍数
    while (flatBits.length % 4 !== 0) {
      flatBits.push(0);
    }

    let bits = '';
    for (let i = 0; i < flatBits.length; i += 4) {
      const b0 = flatBits[i] ? 8 : 0;
      const b1 = flatBits[i + 1] ? 4 : 0;
      const b2 = flatBits[i + 2] ? 2 : 0;
      const b3 = flatBits[i + 3] ? 1 : 0;
      bits += (b0 + b1 + b2 + b3).toString(16).toUpperCase();
    }

    // 计算 matchCount
    let matchCount = 0;
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        if (trimmed[r][c]) matchCount++;
      }
    }

    // 构建 line（word 设为 ?）
    const word = '?';
    const left = 0;
    const right = 0;
    const line = `${bits}$${word}$${left}.${right}.${matchCount}$${rows}.${cols}`;

    return parseMatrixLine(line);
  }

  // 拆分点阵的白底模式状态
  let splitWhiteMode = false;

  /**
   * 执行拆分操作
   * @param {boolean} isWhiteMode - 是否为白底模式
   */
  function performSplitMatrix(isWhiteMode = false) {
    const runCol = Math.max(1, parseInt(splitRunColInput.value) || 1);
    const maxHeight = Math.max(0, parseInt(splitMaxHeightInput.value) || 0);

    // 1. 提取二值化选区矩阵
    const rawMatrix = extractBinaryMatrix(selection);

    // 2. 预裁剪（限高去上下空白）
    const { matrix: trimmedMatrix } = trimMatrix(rawMatrix, maxHeight, isWhiteMode);
    if (!trimmedMatrix || trimmedMatrix.length === 0) {
      showToast('选区内没有有效内容');
      return;
    }

    // 3. 再次紧致裁剪（去左右空白）- trimMatrix 已经处理了
    // 4. 按列扫描分割
    const subMatrices = splitMatrixByColumns(trimmedMatrix, runCol, isWhiteMode);

    if (subMatrices.length === 0) {
      showToast('未能拆分出任何点阵');
      return;
    }

    // 5. 转换并添加到列表
    let addedCount = 0;
    let skippedCount = 0;

    for (const subMatrix of subMatrices) {
      const item = subMatrixToMatrixItem(subMatrix, isWhiteMode);
      if (!item) {
        skippedCount++;
        continue;
      }

      // 检查是否已存在相同的 bits
      const existingIndex = matrixList.findIndex(m => m.bits === item.bits);
      if (existingIndex >= 0) {
        // 已存在，跳过或更新（这里选择跳过）
        skippedCount++;
      } else {
        matrixList.push(item);
        addedCount++;
      }
    }

    saveMatrixListToStorage();
    renderMatrixList();
    hideSplitMatrixModal();

    if (addedCount > 0) {
      // 选中第一个新添加的
      selectedMatrixIndex = matrixList.length - addedCount;
      selectMatrixItem(selectedMatrixIndex);
      scrollToSelectedRow(true);
    }

    const modeText = isWhiteMode ? '（白底模式）' : '';
    let message = `拆分完成${modeText}：添加 ${addedCount} 个点阵`;
    if (skippedCount > 0) {
      message += `，跳过 ${skippedCount} 个`;
    }
    showToast(message);
  }

  // 绑定事件
  if (splitMatrixBtn) {
    splitMatrixBtn.addEventListener('click', showSplitMatrixModal);
  }
  if (closeSplitMatrixModal) {
    closeSplitMatrixModal.addEventListener('click', hideSplitMatrixModal);
  }
  if (splitMatrixCancelBtn) {
    splitMatrixCancelBtn.addEventListener('click', hideSplitMatrixModal);
  }
  if (splitMatrixConfirmBtn) {
    splitMatrixConfirmBtn.addEventListener('click', () => performSplitMatrix(splitWhiteMode));
  }
  if (splitMatrixModal) {
    MatrixHelpers.bindModalBackdropClose(splitMatrixModal);
    MatrixHelpers.bindModalEscClose(splitMatrixModal, splitMatrixCancelBtn);
  }

  // 初始化按钮状态
  updateSplitButtonState();

  // ========== 底色模式选择功能 ==========
  const bgModeModal = document.getElementById('md-bgModeModal');
  const bgModeTitle = document.getElementById('md-bgModeTitle');
  const closeBgModeModal = document.getElementById('md-closeBgModeModal');
  const bgModeBlackBtn = document.getElementById('md-bgModeBlackBtn');
  const bgModeWhiteBtn = document.getElementById('md-bgModeWhiteBtn');

  // 底色模式回调函数
  let bgModeCallback = null;
  let bgModeOperation = ''; // 'fitSelection' 或 'splitMatrix'

  /**
   * 检测选区边缘是否为白底（二值化后的白点比例）
   * @param {Object} sel - 选区 {x, y, w, h}
   * @param {number} threshold - 白点比例阈值，默认 0.85 (85%)
   * @returns {boolean} 是否可能为白底
   */
  function detectWhiteBackground(sel, threshold = 0.85) {
    if (!binaryMask || !img || !sel || sel.w <= 2 || sel.h <= 2) {
      return false;
    }

    const { x, y, w, h } = sel;
    let edgeWhiteCount = 0;
    let edgeTotalCount = 0;

    // 检查四条边缘
    // 上边缘
    for (let col = 0; col < w; col++) {
      const maskIdx = y * img.width + (x + col);
      if (binaryMask[maskIdx] === 1) edgeWhiteCount++;
      edgeTotalCount++;
    }
    // 下边缘
    for (let col = 0; col < w; col++) {
      const maskIdx = (y + h - 1) * img.width + (x + col);
      if (binaryMask[maskIdx] === 1) edgeWhiteCount++;
      edgeTotalCount++;
    }
    // 左边缘（不含角点）
    for (let row = 1; row < h - 1; row++) {
      const maskIdx = (y + row) * img.width + x;
      if (binaryMask[maskIdx] === 1) edgeWhiteCount++;
      edgeTotalCount++;
    }
    // 右边缘（不含角点）
    for (let row = 1; row < h - 1; row++) {
      const maskIdx = (y + row) * img.width + (x + w - 1);
      if (binaryMask[maskIdx] === 1) edgeWhiteCount++;
      edgeTotalCount++;
    }

    if (edgeTotalCount === 0) return false;
    return (edgeWhiteCount / edgeTotalCount) >= threshold;
  }

  /**
   * 显示底色模式选择弹窗
   * @param {string} operation - 操作类型 'fitSelection' 或 'splitMatrix'
   * @param {Function} callback - 回调函数，参数为 isWhiteMode (boolean)
   */
  function showBgModeModal(operation, callback) {
    bgModeOperation = operation;
    bgModeCallback = callback;

    if (operation === 'fitSelection') {
      bgModeTitle.textContent = '选区适应 - 选择底色模式';
    } else if (operation === 'splitMatrix') {
      bgModeTitle.textContent = '拆分点阵 - 选择底色模式';
    } else {
      bgModeTitle.textContent = '选择底色模式';
    }

    openModal(bgModeModal);
  }

  function hideBgModeModal() {
    closeModal(bgModeModal);
    bgModeCallback = null;
    bgModeOperation = '';
  }

  function handleBgModeSelection(isWhiteMode) {
    const callback = bgModeCallback;
    hideBgModeModal();
    if (callback) {
      callback(isWhiteMode);
    }
  }

  // 绑定底色模式弹窗事件
  if (closeBgModeModal) {
    closeBgModeModal.addEventListener('click', hideBgModeModal);
  }
  if (bgModeBlackBtn) {
    bgModeBlackBtn.addEventListener('click', () => handleBgModeSelection(false));
  }
  if (bgModeWhiteBtn) {
    bgModeWhiteBtn.addEventListener('click', () => handleBgModeSelection(true));
  }
  if (bgModeModal) {
    MatrixHelpers.bindModalBackdropClose(bgModeModal);
  }

  // 全选按钮
  selectAllColorsBtn.addEventListener('click', () => {
    colorRanges.forEach(c => c.enabled = true);
    renderColorRanges();
    saveColorRangesToStorage();
    recomputeBinary();
  });

  // 反选按钮
  deselectAllColorsBtn.addEventListener('click', () => {
    colorRanges.forEach(c => c.enabled = !c.enabled);
    renderColorRanges();
    saveColorRangesToStorage();
    recomputeBinary();
  });

  // 清空列表按钮
  clearColorListBtn.addEventListener('click', () => {
    if (colorRanges.length === 0) {
      showToast('列表已为空');
      return;
    }
    saveColorRangeUndoState();
    colorRanges = [];
    renderColorRanges();
    saveColorRangesToStorage();
    recomputeBinary();
    showToast('已清空（⌘/Ctrl+Z 撤销）');
  });

  zoomRange.addEventListener('input', () => {
    if (!img) return;
    const percent = Number(zoomRange.value);
    const oldScale = view.scale;
    const newScale = clamp(percent / 100, 0.1, 20);

    const scaleRatio = newScale / oldScale;

    view.offsetX = view.offsetX * scaleRatio;
    view.offsetY = view.offsetY * scaleRatio;
    view.scale = newScale;

    updateZoomUI();
    renderBinaryOverlayOnly();
    drawOriginal();
  });

  // 工具栏按钮事件
  document.getElementById('md-open').addEventListener('click', () => {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = 'image/*';
    input.style.display = 'none';
    input.addEventListener('change', (evt) => {
      handleFile(evt.target.files[0]);
    });
    input.click();
  });

  document.getElementById('md-rotate').addEventListener('click', () => {
    // 向左旋转90度
    if (!img) {
      showToast('请先打开或截取一张图片');
      return;
    }
    const tempCanvas = document.createElement('canvas');
    const tempCtx = tempCanvas.getContext('2d');
    tempCanvas.width = img.height;
    tempCanvas.height = img.width;
    tempCtx.translate(0, tempCanvas.height);
    tempCtx.rotate(-Math.PI / 2);
    tempCtx.drawImage(img, 0, 0);
    const rotatedImg = new Image();
    rotatedImg.crossOrigin = 'anonymous';
    rotatedImg.src = tempCanvas.toDataURL('image/png');
    rotatedImg.onload = () => {
      img = rotatedImg;
      sourceCanvas = document.createElement('canvas');
      sourceCanvas.width = img.width;
      sourceCanvas.height = img.height;
      const sctx = sourceCanvas.getContext('2d');
      sctx.imageSmoothingEnabled = false;
      sctx.drawImage(img, 0, 0);

      view.scale = 1;
      view.offsetX = 0;
      view.offsetY = 0;
      updateZoomUI();

      setCanvasSizeForImage(img.width, img.height);
      selection = null;
      metaSelection = null;
      closeColorPickPopover();
      drawOriginal();
      recomputeBinary();
      clearOutputs();
      updateSelectionRecordUI();
      showToast('已向左旋转90°');
    };
  });

  // 截图旋转方向 (0=Home在下, 1=Home在右, 2=Home在左, 3=Home在上)
  let snapshotOrient = 0;
  // 远程截图设置
  let remoteSnapshotEnabled = false;
  let remoteHost = '';
  let remotePort = 46952;

  // File System Access API 相关（与 picker.html 共用配置）
  const fileSystemAccessSupported = 'showDirectoryPicker' in window;
  let savePathEnabled = false;
  let saveDirectoryHandle = null;
  let savePathName = '';

  // 从本地存储加载设置
  function loadSnapshotSettings() {
    try {
      const saved = localStorage.getItem('matrix_dict_snapshot_settings');
      if (saved) {
        const settings = JSON.parse(saved);
        snapshotOrient = settings.orient || 0;
        remoteSnapshotEnabled = settings.remoteEnabled || false;
        remoteHost = settings.remoteHost || '';
        remotePort = settings.remotePort || 46952;
      }
      // 尝试从 picker 的设置中加载保存路径配置（共用配置）
      const pickerSaved = localStorage.getItem('picker_snapshot_settings');
      if (pickerSaved) {
        const pickerSettings = JSON.parse(pickerSaved);
        savePathEnabled = pickerSettings.savePathEnabled || false;
        savePathName = pickerSettings.savePathName || '';
      }
    } catch (e) {
      console.warn('加载截图设置失败', e);
    }
  }

  // 保存设置到本地存储
  function saveSnapshotSettings() {
    try {
      localStorage.setItem('matrix_dict_snapshot_settings', JSON.stringify({
        orient: snapshotOrient,
        remoteEnabled: remoteSnapshotEnabled,
        remoteHost: remoteHost,
        remotePort: remotePort
      }));
      // 同时保存到 picker 的设置中（共用配置）
      const pickerSaved = localStorage.getItem('picker_snapshot_settings');
      let pickerSettings = {};
      if (pickerSaved) {
        pickerSettings = JSON.parse(pickerSaved);
      }
      pickerSettings.savePathEnabled = savePathEnabled;
      pickerSettings.savePathName = savePathName;
      localStorage.setItem('picker_snapshot_settings', JSON.stringify(pickerSettings));
    } catch (e) {
      console.warn('保存截图设置失败', e);
    }
  }

  // 使用 File System Access API 保存图片
  async function saveImageToFileSystem(blob, filename) {
    if (!saveDirectoryHandle) {
      return false;
    }
    try {
      // 验证权限
      let permission = await saveDirectoryHandle.queryPermission({ mode: 'readwrite' });
      if (permission !== 'granted') {
        permission = await saveDirectoryHandle.requestPermission({ mode: 'readwrite' });
        if (permission !== 'granted') {
          showToast('文件夹访问权限已被拒绝');
          return false;
        }
      }
      // 创建文件并写入
      const fileHandle = await saveDirectoryHandle.getFileHandle(filename, { create: true });
      const writable = await fileHandle.createWritable();
      await writable.write(blob);
      await writable.close();
      return true;
    } catch (e) {
      console.error('保存图片到文件系统失败', e);
      return false;
    }
  }

  // 通用保存图片函数
  async function saveImageFile(blob, filename) {
    if (savePathEnabled && saveDirectoryHandle && fileSystemAccessSupported) {
      const success = await saveImageToFileSystem(blob, filename);
      if (success) {
        showToast('图片已保存到: ' + savePathName + '/' + filename);
        return;
      }
      // 如果保存失败，回退到下载方式
    }
    // 传统下载方式
    const url = window.URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = filename;
    link.click();
    window.URL.revokeObjectURL(url);
  }

  // 初始化加载设置
  loadSnapshotSettings();

  // 设置弹窗元素
  const settingsModal = document.getElementById('md-settingsModal');
  const snapshotOrientBtns = document.getElementById('md-snapshotOrientBtns');
  const remoteSnapshotEnabledCheckbox = document.getElementById('md-remoteSnapshotEnabled');
  const remoteSnapshotSettings = document.getElementById('md-remoteSnapshotSettings');
  const remoteHostInput = document.getElementById('md-remoteHost');
  const remotePortInput = document.getElementById('md-remotePort');
  const settingsCancelBtn = document.getElementById('md-settingsCancelBtn');
  const settingsSaveBtn = document.getElementById('md-settingsSaveBtn');
  const closeSettingsModal = document.getElementById('md-closeSettingsModal');

  // File System Access API 设置元素
  const savePathSettingWrapper = document.getElementById('md-savePathSettingWrapper');
  const savePathEnabledCheckbox = document.getElementById('md-savePathEnabled');
  const savePathSettingsDiv = document.getElementById('md-savePathSettings');
  const savePathDisplay = document.getElementById('md-savePathDisplay');
  const selectSavePathBtn = document.getElementById('md-selectSavePathBtn');

  // 如果浏览器支持 File System Access API，显示设置选项
  if (fileSystemAccessSupported && savePathSettingWrapper) {
    savePathSettingWrapper.style.display = 'block';
  }

  // File System Access API 设置事件
  if (savePathEnabledCheckbox) {
    savePathEnabledCheckbox.addEventListener('change', () => {
      savePathSettingsDiv.style.display = savePathEnabledCheckbox.checked ? 'block' : 'none';
    });
  }

  if (selectSavePathBtn) {
    selectSavePathBtn.addEventListener('click', async () => {
      try {
        saveDirectoryHandle = await window.showDirectoryPicker({
          mode: 'readwrite'
        });
        savePathName = saveDirectoryHandle.name;
        savePathDisplay.value = savePathName;
        showToast('已选择文件夹: ' + savePathName);
      } catch (e) {
        if (e.name !== 'AbortError') {
          console.error('选择文件夹失败', e);
          showToast('选择文件夹失败');
        }
      }
    });
  }

  // 方向按钮组点击事件
  let selectedOrient = snapshotOrient;
  snapshotOrientBtns.addEventListener('click', (e) => {
    const btn = e.target.closest('.matrix-orient-btn');
    if (!btn) return;
    // 移除所有按钮的 active 状态
    snapshotOrientBtns.querySelectorAll('.matrix-orient-btn').forEach(b => {
      b.classList.remove('active');
      b.style.background = '';
      b.style.color = '';
      b.style.borderColor = '';
      b.style.boxShadow = '';
    });
    // 设置当前按钮为 active
    btn.classList.add('active');
    btn.style.background = 'linear-gradient(120deg, var(--md-ink) 0%, #5aabe8 100%)';
    btn.style.color = '#fff';
    btn.style.borderColor = 'transparent';
    btn.style.boxShadow = '0 8px 20px rgba(60,150,222,0.25)';
    selectedOrient = parseInt(btn.dataset.orient, 10);
  });

  // 切换远程截图设置显示
  remoteSnapshotEnabledCheckbox.addEventListener('change', () => {
    remoteSnapshotSettings.style.display = remoteSnapshotEnabledCheckbox.checked ? 'block' : 'none';
  });

  // 更新方向按钮组的选中状态
  function updateOrientBtnsState(orient) {
    snapshotOrientBtns.querySelectorAll('.matrix-orient-btn').forEach(btn => {
      const isActive = parseInt(btn.dataset.orient, 10) === orient;
      btn.classList.toggle('active', isActive);
      if (isActive) {
        btn.style.background = 'linear-gradient(120deg, var(--md-ink) 0%, #5aabe8 100%)';
        btn.style.color = '#fff';
        btn.style.borderColor = 'transparent';
        btn.style.boxShadow = '0 8px 20px rgba(60,150,222,0.25)';
      } else {
        btn.style.background = '';
        btn.style.color = '';
        btn.style.borderColor = '';
        btn.style.boxShadow = '';
      }
    });
  }

  // 打开设置弹窗
  document.getElementById('md-set').addEventListener('click', () => {
    // 填充当前设置值
    selectedOrient = snapshotOrient;
    updateOrientBtnsState(snapshotOrient);
    remoteSnapshotEnabledCheckbox.checked = remoteSnapshotEnabled;
    remoteSnapshotSettings.style.display = remoteSnapshotEnabled ? 'block' : 'none';
    remoteHostInput.value = remoteHost;
    remotePortInput.value = remotePort;
    // File System Access API 设置状态
    if (savePathEnabledCheckbox) {
      savePathEnabledCheckbox.checked = savePathEnabled;
      savePathSettingsDiv.style.display = savePathEnabled ? 'block' : 'none';
      savePathDisplay.value = savePathName || '未选择保存路径';
    }
    openModal(settingsModal);
  });

  // 关闭设置弹窗
  function closeSettingsModalFn() {
    closeModal(settingsModal);
  }
  closeSettingsModal.addEventListener('click', closeSettingsModalFn);
  settingsCancelBtn.addEventListener('click', closeSettingsModalFn);
  MatrixHelpers.bindModalBackdropClose(settingsModal);
  MatrixHelpers.bindModalEscClose(settingsModal, settingsCancelBtn);

  // 保存设置
  settingsSaveBtn.addEventListener('click', () => {
    snapshotOrient = selectedOrient;
    remoteSnapshotEnabled = remoteSnapshotEnabledCheckbox.checked;
    remoteHost = remoteHostInput.value.trim();
    remotePort = parseInt(remotePortInput.value, 10) || 46952;
    // 保存 File System Access API 设置
    if (savePathEnabledCheckbox) {
      savePathEnabled = savePathEnabledCheckbox.checked;
      // 如果启用但没有选择文件夹，提示用户
      if (savePathEnabled && !saveDirectoryHandle) {
        showToast('请先选择保存文件夹');
        return;
      }
    }
    saveSnapshotSettings();
    closeSettingsModalFn();
    showToast('设置已保存');
  });

  document.getElementById('md-snapshot').addEventListener('click', () => {
    // 构建截图URL
    let snapshotUrl;
    if (remoteSnapshotEnabled && remoteHost) {
      // 从远程设备截图
      snapshotUrl = 'http://' + remoteHost + ':' + remotePort + '/snapshot?ext=png&orient=' + snapshotOrient + '&t=' + (new Date().getTime()).toString();
    } else {
      // 从本机设备截图
      snapshotUrl = '/snapshot?ext=png&orient=' + snapshotOrient + '&t=' + (new Date().getTime()).toString();
    }

    const newImg = new Image();
    newImg.crossOrigin = 'anonymous';
    newImg.src = snapshotUrl;
    newImg.onload = () => {
      img = newImg;
      sourceCanvas = document.createElement('canvas');
      sourceCanvas.width = img.width;
      sourceCanvas.height = img.height;
      const sctx = sourceCanvas.getContext('2d');
      sctx.imageSmoothingEnabled = false;
      sctx.drawImage(img, 0, 0);

      view.scale = 1;
      view.offsetX = 0;
      view.offsetY = 0;
      updateZoomUI();

      setCanvasSizeForImage(img.width, img.height);
      selection = null;
      metaSelection = null;
      drawOriginal();
      recomputeBinary();
      clearOutputs();
      updateSelectionRecordUI();
      showToast('截图成功');
    };
    newImg.onerror = () => {
      showToast('截图失败，请确保设备端服务正常');
    };
  });

  document.getElementById('md-clear').addEventListener('click', () => {
    img = null;
    selection = null;
    metaSelection = null;
    sourceCanvas = null;
    binaryCanvas = null;
    binaryMask = null;
    closeColorPickPopover();
    view = { scale: 1, offsetX: 0, offsetY: 0 };
    updateZoomUI();
    updateImageSizeInfo();
    resetCanvas();
    clearOutputs();
    updateSelectionRecordUI();
    showToast('图片已关闭');
  });

  // 自定义代码模板功能
  const customTplKeys = ['tpl1', 'tpl2', 'tpl3', 'tpl4', 'tpl5', 'tpl6'];
  const customTemplatesDefault = {
    tpl1: {
      name: 'OCR',
      code: '-- 引入 dm 库\nlocal dm = require("dm")\n-- 当前使用 0 号字库\ndm.UseDict(0)\n-- 加载 0 号字库，将字库列表填入双方括号内\ndm.LoadDict(0, [[\n\n]])\n-- 使用字库识别指定区域文字\nlocal text, boxes = dm.Ocr($metaRect.left, $metaRect.top, $metaRect.right, $metaRect.bottom, "$colorRange", 0.98)\nnLog(\'识别结果\', text, boxes)',
      coreLine: 'local text, boxes = dm.Ocr($metaRect.left, $metaRect.top, $metaRect.right, $metaRect.bottom, "$colorRange", 0.98)'
    },
    tpl2: {
      name: 'FindStr',
      code: '-- 引入 dm 库\nlocal dm = require("dm")\n-- 当前使用 0 号字库\ndm.UseDict(0)\n-- 加载 0 号字库，将字库列表填入双方括号内\ndm.LoadDict(0, [[\n\n]])\n-- 使用字库找字指定区域文字\nlocal found, x, y, boxes = dm.FindStr($metaRect.left, $metaRect.top, $metaRect.right, $metaRect.bottom, "$word", "$colorRange", 0.98)\nnLog(\'找字结果\', found, x, y, boxes)',
      coreLine: 'local found, x, y, boxes = dm.FindStr($metaRect.left, $metaRect.top, $metaRect.right, $metaRect.bottom, "$word", "$colorRange", 0.98)'
    },
    tpl3: {
      name: 'FindMatrix',
      code: '-- 引入 dm 库\nlocal dm = require("dm")\n-- 使用点阵找字指定区域文字\nlocal found, x, y, text, boxes = dm.FindMatrix($metaRect.left, $metaRect.top, $metaRect.right, $metaRect.bottom, "$matrix"\n, "$colorRange", 0.98)\nnLog(\'找矩阵结果\', found, x, y, text, boxes)',
      coreLine: 'local found, x, y, text, boxes = dm.FindMatrix($metaRect.left, $metaRect.top, $metaRect.right, $metaRect.bottom, "$matrix"\n, "$colorRange", 0.98)'
    },
    tpl4: { name: '自定义 1', code: '', coreLine: '$metaRect.left, $metaRect.top, $metaRect.right, $metaRect.bottom, "$matrix", "$colorRange", 0.98' },
    tpl5: { name: '自定义 2', code: '', coreLine: '"$matrix", "$colorRange", 0.98' },
    tpl6: { name: '自定义 3', code: '', coreLine: '"$colorRange", 0.98' }
  };

  let customTemplates = JSON.parse(JSON.stringify(customTemplatesDefault));

  function loadCustomTemplates() {
    try {
      const saved = localStorage.getItem('matrix_dict_custom_templates');
      if (saved) {
        const cfg = JSON.parse(saved);
        for (const key of customTplKeys) {
          if (cfg[key]) {
            if (cfg[key].name !== undefined) customTemplates[key].name = cfg[key].name;
            if (cfg[key].code !== undefined) customTemplates[key].code = cfg[key].code;
            if (cfg[key].coreLine !== undefined) customTemplates[key].coreLine = cfg[key].coreLine;
          }
        }
      }
    } catch (e) {
      console.warn('加载自定义模板失败', e);
    }
  }

  function saveCustomTemplates() {
    try {
      localStorage.setItem('matrix_dict_custom_templates', JSON.stringify(customTemplates));
    } catch (e) {
      console.warn('保存自定义模板失败', e);
    }
  }

  loadCustomTemplates();

  // 更新按钮文字
  const customTplBtns = { tpl1: customTpl1Btn, tpl2: customTpl2Btn, tpl3: customTpl3Btn, tpl4: customTpl4Btn, tpl5: customTpl5Btn, tpl6: customTpl6Btn };
  function updateCustomTplBtnLabels() {
    for (const key of customTplKeys) {
      customTplBtns[key].textContent = customTemplates[key].name || customTemplatesDefault[key].name;
    }
  }
  updateCustomTplBtnLabels();

  // 模板变量替换
  function buildMdTemplateVars() {
    let shiftLeft = 0, shiftTop = 0, shiftRight = 0, shiftBottom = 0;
    if (selection && selection.w > 0 && selection.h > 0) {
      shiftLeft = Math.round(selection.x);
      shiftTop = Math.round(selection.y);
      shiftRight = Math.round(selection.x + selection.w);
      shiftBottom = Math.round(selection.y + selection.h);
    }
    let metaLeft = 0, metaTop = 0, metaRight = 0, metaBottom = 0;
    if (metaSelection && metaSelection.w > 0 && metaSelection.h > 0) {
      metaLeft = Math.round(metaSelection.x);
      metaTop = Math.round(metaSelection.y);
      metaRight = Math.round(metaSelection.x + metaSelection.w);
      metaBottom = Math.round(metaSelection.y + metaSelection.h);
    }
    const colorRangeValue = colorRangeText.value.trim() || '';
    const matrixValue = lineField.value.trim() || '';
    const matrixListValue = matrixList.map(function (m) { return m.line; }).join('\n');
    const wordValue = wordInput.value.trim() || '';
    return {
      '$shiftRect.left': String(shiftLeft),
      '$shiftRect.top': String(shiftTop),
      '$shiftRect.right': String(shiftRight),
      '$shiftRect.bottom': String(shiftBottom),
      '$metaRect.left': String(metaLeft),
      '$metaRect.top': String(metaTop),
      '$metaRect.right': String(metaRight),
      '$metaRect.bottom': String(metaBottom),
      '$colorRange': colorRangeValue,
      '$matrixList': matrixListValue,
      '$matrix': matrixValue,
      '$word': wordValue
    };
  }

  function applyMdTemplate(template) {
    const vars = buildMdTemplateVars();
    // 按 key 长度降序排列，防止 $matrix 误替换 $matrixList
    const keys = Object.keys(vars).sort(function (a, b) { return b.length - a.length; });
    let result = template;
    for (let i = 0; i < keys.length; i++) {
      result = result.split(keys[i]).join(vars[keys[i]]);
    }
    return result;
  }

  // 弹窗交互
  let currentCustomTplKey = 'tpl1';

  function refreshCustomTplPreview() {
    const tpl = customTemplates[currentCustomTplKey];
    const codeResult = tpl.code ? applyMdTemplate(tpl.code) : '';
    const coreLineResult = tpl.coreLine ? applyMdTemplate(tpl.coreLine) : '';
    if (codeResult) {
      customTplPreview.value = codeResult;
    } else {
      customTplPreview.value = coreLineResult;
    }
  }

  function openCustomTplModal(tplKey) {
    currentCustomTplKey = tplKey;
    const tpl = customTemplates[tplKey];
    customTplNameInput.value = tpl.name || '';
    customTplCode.value = tpl.code || '';
    customTplCoreLine.value = tpl.coreLine || '';
    refreshCustomTplPreview();
    openModal(customTplModal);
  }

  customTpl1Btn.addEventListener('click', function () { openCustomTplModal('tpl1'); });
  customTpl2Btn.addEventListener('click', function () { openCustomTplModal('tpl2'); });
  customTpl3Btn.addEventListener('click', function () { openCustomTplModal('tpl3'); });
  customTpl4Btn.addEventListener('click', function () { openCustomTplModal('tpl4'); });
  customTpl5Btn.addEventListener('click', function () { openCustomTplModal('tpl5'); });
  customTpl6Btn.addEventListener('click', function () { openCustomTplModal('tpl6'); });

  customTplNameInput.addEventListener('input', function () {
    customTemplates[currentCustomTplKey].name = customTplNameInput.value;
    updateCustomTplBtnLabels();
    saveCustomTemplates();
  });

  customTplCode.addEventListener('input', function () {
    customTemplates[currentCustomTplKey].code = customTplCode.value;
    refreshCustomTplPreview();
    saveCustomTemplates();
  });

  customTplCoreLine.addEventListener('input', function () {
    customTemplates[currentCustomTplKey].coreLine = customTplCoreLine.value;
    refreshCustomTplPreview();
    saveCustomTemplates();
  });

  customTplCopyCode.addEventListener('click', function () {
    const tpl = customTemplates[currentCustomTplKey];
    const text = tpl.code ? applyMdTemplate(tpl.code) : applyMdTemplate(tpl.coreLine || '');
    copyWithToast(text, '代码已拷贝到剪贴板');
  });

  customTplCopyCoreLine.addEventListener('click', function () {
    const tpl = customTemplates[currentCustomTplKey];
    const text = applyMdTemplate(tpl.coreLine || '');
    copyWithToast(text, '核心行已拷贝到剪贴板');
  });

  closeCustomTplModal.addEventListener('click', function () {
    closeModal(customTplModal);
  });

  // 点击弹窗外部关闭
  MatrixHelpers.bindModalBackdropClose(customTplModal);
  MatrixHelpers.bindModalEscClose(customTplModal);

  // 保存点阵图像弹窗相关
  const saveBitImageModal = document.getElementById('md-saveBitImageModal');
  const closeSaveBitImageModalBtn = document.getElementById('md-closeSaveBitImageModal');
  const saveBitImageBtn = document.getElementById('md-saveBitImageBtn');
  const saveBitImageCancelBtn = document.getElementById('md-saveBitImageCancelBtn');
  const saveBitImageConfirmBtn = document.getElementById('md-saveBitImageConfirmBtn');
  const saveBitImageCopyAndSaveBtn = document.getElementById('md-saveBitImageCopyAndSaveBtn');
  const saveBitImagePreviewImg = document.getElementById('md-saveBitImagePreviewImg');
  const saveBitImageFilenameInput = document.getElementById('md-saveBitImageFilename');
  const saveBitImageCodeTemplateInput = document.getElementById('md-saveBitImageCodeTemplate');
  const saveBitImageGeneratedCodeArea = document.getElementById('md-saveBitImageGeneratedCode');

  // 当前点阵图像数据
  let currentBitImageData = {
    canvas: null,      // 用于预览的 canvas
    dataUrl: '',       // 预览用的 dataUrl
    blob1bit: null     // 1-bit PNG Blob（用于保存，体积更小）
  };

  // 默认代码模板
  const defaultBitImageCodeTemplate = '$imgFileBaseName = image.load_file(XXT_HOME_PATH.."/res/$imgFileBaseName.png")';

  // 从 localStorage 加载代码模板（与 picker 共用）
  function loadBitImageCodeTemplate() {
    try {
      const saved = localStorage.getItem('picker_save_region_code_template');
      if (saved) {
        return saved;
      }
    } catch (e) {
      console.warn('加载代码模板失败', e);
    }
    return defaultBitImageCodeTemplate;
  }

  // 保存代码模板到 localStorage（与 picker 共用）
  function saveBitImageCodeTemplate(template) {
    try {
      localStorage.setItem('picker_save_region_code_template', template);
    } catch (e) {
      console.warn('保存代码模板失败', e);
    }
  }

  // 根据文件名和模板生成代码
  function generateBitImageCodeFromTemplate(filename, template) {
    if (!template) return '';
    // 移除 .png 后缀用于替换
    const name = filename.replace(/\.png$/i, '');
    return template.split('$imgFileBaseName').join(name);
  }

  // 更新生成的代码
  function updateBitImageGeneratedCode() {
    if (!saveBitImageFilenameInput || !saveBitImageCodeTemplateInput || !saveBitImageGeneratedCodeArea) return;
    const filename = saveBitImageFilenameInput.value.trim() || 'matrix_' + Date.now();
    const template = saveBitImageCodeTemplateInput.value;
    const code = generateBitImageCodeFromTemplate(filename, template);
    saveBitImageGeneratedCodeArea.value = code;
  }

  // 初始化代码模板
  if (saveBitImageCodeTemplateInput) {
    saveBitImageCodeTemplateInput.value = loadBitImageCodeTemplate();

    // 监听模板变化，更新生成的代码并保存模板
    saveBitImageCodeTemplateInput.addEventListener('input', () => {
      saveBitImageCodeTemplate(saveBitImageCodeTemplateInput.value);
      updateBitImageGeneratedCode();
    });
  }

  // 监听文件名变化，更新生成的代码
  if (saveBitImageFilenameInput) {
    saveBitImageFilenameInput.addEventListener('input', updateBitImageGeneratedCode);
  }

  // 创建点阵图像画布
  function createBitImageCanvas() {
    if (!state.grid || !state.grid.length || !state.grid[0].length) {
      return null;
    }

    const exportCanvas = document.createElement('canvas');
    const rows = state.grid.length;
    const cols = state.grid[0].length;

    // 原始尺寸：宽度 = 列数，高度 = 行数
    exportCanvas.width = cols;
    exportCanvas.height = rows;

    const ctx = exportCanvas.getContext('2d');
    ctx.imageSmoothingEnabled = false;

    // 绘制黑色背景
    ctx.fillStyle = '#000000';
    ctx.fillRect(0, 0, cols, rows);

    // 绘制白色点阵（1 = 白色像素）
    ctx.fillStyle = '#FFFFFF';
    for (let row = 0; row < rows; row++) {
      for (let col = 0; col < cols; col++) {
        if (state.grid[row][col] === 1) {
          ctx.fillRect(col, row, 1, 1);
        }
      }
    }

    return exportCanvas;
  }

  // 创建 1-bit 索引色 PNG（极小体积的二值图）
  // 使用手工构建 PNG 文件结构，调色板只包含黑白两色
  function create1BitPNG(width, height, grid) {
    // PNG 文件结构:
    // - PNG 签名 (8 bytes)
    // - IHDR chunk (图像头部)
    // - PLTE chunk (调色板: 黑、白)
    // - IDAT chunk (图像数据)
    // - IEND chunk (结束标记)

    // CRC32 查找表
    const crcTable = [];
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) {
        c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      crcTable[n] = c;
    }
    function crc32(data) {
      let crc = 0xFFFFFFFF;
      for (let i = 0; i < data.length; i++) {
        crc = crcTable[(crc ^ data[i]) & 0xFF] ^ (crc >>> 8);
      }
      return (crc ^ 0xFFFFFFFF) >>> 0;
    }

    // 写入 4 字节大端整数
    function writeUint32BE(arr, offset, value) {
      arr[offset] = (value >>> 24) & 0xFF;
      arr[offset + 1] = (value >>> 16) & 0xFF;
      arr[offset + 2] = (value >>> 8) & 0xFF;
      arr[offset + 3] = value & 0xFF;
    }

    // 创建 chunk
    function createChunk(type, data) {
      const typeBytes = new Uint8Array([type.charCodeAt(0), type.charCodeAt(1), type.charCodeAt(2), type.charCodeAt(3)]);
      const length = data.length;
      const chunk = new Uint8Array(4 + 4 + length + 4);
      writeUint32BE(chunk, 0, length);
      chunk.set(typeBytes, 4);
      chunk.set(data, 8);
      const crcData = new Uint8Array(4 + length);
      crcData.set(typeBytes, 0);
      crcData.set(data, 4);
      writeUint32BE(chunk, 8 + length, crc32(crcData));
      return chunk;
    }

    // PNG 签名
    const signature = new Uint8Array([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

    // IHDR: 宽度(4) + 高度(4) + 位深(1) + 颜色类型(1) + 压缩(1) + 滤波(1) + 隔行(1)
    const ihdrData = new Uint8Array(13);
    writeUint32BE(ihdrData, 0, width);
    writeUint32BE(ihdrData, 4, height);
    ihdrData[8] = 1;  // 位深度: 1 bit
    ihdrData[9] = 3;  // 颜色类型: 3 = 索引色（调色板）
    ihdrData[10] = 0; // 压缩方法: 0 = deflate
    ihdrData[11] = 0; // 滤波方法: 0
    ihdrData[12] = 0; // 隔行扫描: 0 = 无
    const ihdrChunk = createChunk('IHDR', ihdrData);

    // PLTE: 调色板（黑=0, 白=1）
    const plteData = new Uint8Array([
      0x00, 0x00, 0x00,  // 索引 0: 黑色
      0xFF, 0xFF, 0xFF   // 索引 1: 白色
    ]);
    const plteChunk = createChunk('PLTE', plteData);

    // 准备原始图像数据（每行带 filter byte）
    const bytesPerRow = Math.ceil(width / 8);
    const rawData = new Uint8Array(height * (1 + bytesPerRow));
    let rawIdx = 0;
    for (let y = 0; y < height; y++) {
      rawData[rawIdx++] = 0; // filter type: None
      for (let byteIdx = 0; byteIdx < bytesPerRow; byteIdx++) {
        let byte = 0;
        for (let bit = 0; bit < 8; bit++) {
          const x = byteIdx * 8 + bit;
          if (x < width && grid[y][x] === 1) {
            byte |= (0x80 >> bit);
          }
        }
        rawData[rawIdx++] = byte;
      }
    }

    // 使用 pako 进行 zlib 压缩（最高压缩等级）
    // 如果 pako 可用则使用真正的 deflate 压缩，否则回退到存储块
    function zlibCompress(data) {
      // 优先使用 pako 进行真正的 deflate 压缩
      if (typeof pako !== 'undefined' && pako.deflate) {
        try {
          return pako.deflate(data, { level: 9 });
        } catch (e) {
          console.warn('pako 压缩失败，回退到存储块模式:', e);
        }
      }

      // 回退：存储块（无压缩）
      const maxBlockSize = 65535;
      const numBlocks = Math.ceil(data.length / maxBlockSize);
      const output = [];
      output.push(0x78, 0x01); // zlib header

      for (let i = 0; i < numBlocks; i++) {
        const start = i * maxBlockSize;
        const end = Math.min(start + maxBlockSize, data.length);
        const blockData = data.slice(start, end);
        const len = blockData.length;
        const isLast = (i === numBlocks - 1);

        output.push(isLast ? 0x01 : 0x00); // BFINAL + BTYPE=00 (stored)
        output.push(len & 0xFF);
        output.push((len >> 8) & 0xFF);
        output.push((~len) & 0xFF);
        output.push(((~len) >> 8) & 0xFF);
        for (let j = 0; j < blockData.length; j++) {
          output.push(blockData[j]);
        }
      }

      // Adler-32 checksum
      let a = 1, b = 0;
      for (let i = 0; i < data.length; i++) {
        a = (a + data[i]) % 65521;
        b = (b + a) % 65521;
      }
      const adler = ((b << 16) | a) >>> 0;
      output.push((adler >> 24) & 0xFF);
      output.push((adler >> 16) & 0xFF);
      output.push((adler >> 8) & 0xFF);
      output.push(adler & 0xFF);

      return new Uint8Array(output);
    }

    const compressedData = zlibCompress(rawData);
    const idatChunk = createChunk('IDAT', compressedData);

    // IEND
    const iendChunk = createChunk('IEND', new Uint8Array(0));

    // 合并所有 chunks
    const totalLength = signature.length + ihdrChunk.length + plteChunk.length + idatChunk.length + iendChunk.length;
    const png = new Uint8Array(totalLength);
    let offset = 0;
    png.set(signature, offset); offset += signature.length;
    png.set(ihdrChunk, offset); offset += ihdrChunk.length;
    png.set(plteChunk, offset); offset += plteChunk.length;
    png.set(idatChunk, offset); offset += idatChunk.length;
    png.set(iendChunk, offset);

    return new Blob([png], { type: 'image/png' });
  }

  // 打开保存点阵图像弹窗
  function openSaveBitImageModal() {
    if (!state.grid || !state.grid.length || !state.grid[0].length) {
      showToast('暂无点阵数据可保存');
      return;
    }

    // 创建点阵图像（用于预览）
    currentBitImageData.canvas = createBitImageCanvas();
    if (!currentBitImageData.canvas) {
      showToast('生成图像失败');
      return;
    }
    currentBitImageData.dataUrl = currentBitImageData.canvas.toDataURL('image/png');

    // 创建 1-bit PNG Blob（用于保存，体积更小）
    const rows = state.grid.length;
    const cols = state.grid[0].length;
    currentBitImageData.blob1bit = create1BitPNG(cols, rows, state.grid);

    // 设置预览图（原图很小，这里使用 CSS 放大显示）
    saveBitImagePreviewImg.src = currentBitImageData.dataUrl;
    saveBitImagePreviewImg.style.minWidth = Math.max(currentBitImageData.canvas.width * 4, 100) + 'px';
    saveBitImagePreviewImg.style.minHeight = Math.max(currentBitImageData.canvas.height * 4, 50) + 'px';

    // 生成默认文件名
    const word = wordInput.value.trim();
    let defaultFilename;
    if (word) {
      // 有文字时，直接用文字作为文件名
      const safeWord = word.replace(/[\\/:*?"<>|]/g, '_');
      defaultFilename = safeWord;
    } else {
      // 没有文字时，使用 matrix_ 前缀和时间戳
      defaultFilename = `matrix_${getReadableTimestamp()}`;
    }
    saveBitImageFilenameInput.value = defaultFilename;

    // 更新生成的代码
    updateBitImageGeneratedCode();

    openModal(saveBitImageModal);

    // 聚焦到输入框并选中文本
    setTimeout(() => {
      saveBitImageFilenameInput.focus();
      saveBitImageFilenameInput.select();
    }, 100);
  }

  // 关闭弹窗
  function closeSaveBitImageModal() {
    closeModal(saveBitImageModal);
  }

  // DataURL 转 Blob
  function dataURLtoBlob(dataURL) {
    const arr = dataURL.split(',');
    const mime = arr[0].match(/:(.*?);/)[1];
    const bstr = atob(arr[1]);
    let n = bstr.length;
    const u8arr = new Uint8Array(n);
    while (n--) {
      u8arr[n] = bstr.charCodeAt(n);
    }
    return new Blob([u8arr], { type: mime });
  }

  // 保存图像
  async function doSaveBitImage() {
    if (!currentBitImageData.blob1bit) {
      showToast('没有可保存的图像');
      return;
    }
    let filename = saveBitImageFilenameInput.value.trim();
    if (!filename) {
      filename = 'matrix_' + getReadableTimestamp();
    }
    // 移除可能已经添加的 .png 后缀
    filename = filename.replace(/\.png$/i, '');

    // 使用 1-bit PNG Blob（体积更小）
    closeSaveBitImageModal();
    await saveImageFile(currentBitImageData.blob1bit, filename + '.png');
  }

  // 拷贝代码并保存图像
  async function doCopyCodeAndSaveBitImage() {
    if (!currentBitImageData.blob1bit) {
      showToast('没有可保存的图像');
      return;
    }
    let filename = saveBitImageFilenameInput.value.trim();
    if (!filename) {
      filename = 'matrix_' + getReadableTimestamp();
    }
    // 移除可能已经添加的 .png 后缀
    filename = filename.replace(/\.png$/i, '');

    // 获取生成的代码
    const code = saveBitImageGeneratedCodeArea.value;

    // 拷贝代码到剪贴板
    if (code) {
      await copyWithToast(code, '代码已拷贝到剪贴板');
    }

    // 使用 1-bit PNG Blob（体积更小）
    closeSaveBitImageModal();
    await saveImageFile(currentBitImageData.blob1bit, filename + '.png');

    if (code) {
      showToast('代码已拷贝，图像已保存');
    }
  }

  // 绑定事件
  if (saveBitImageBtn) {
    saveBitImageBtn.addEventListener('click', openSaveBitImageModal);
  }
  if (closeSaveBitImageModalBtn) {
    closeSaveBitImageModalBtn.addEventListener('click', closeSaveBitImageModal);
  }
  if (saveBitImageCancelBtn) {
    saveBitImageCancelBtn.addEventListener('click', closeSaveBitImageModal);
  }
  if (saveBitImageConfirmBtn) {
    saveBitImageConfirmBtn.addEventListener('click', doSaveBitImage);
  }
  if (saveBitImageCopyAndSaveBtn) {
    saveBitImageCopyAndSaveBtn.addEventListener('click', doCopyCodeAndSaveBitImage);
  }
  MatrixHelpers.bindModalBackdropClose(saveBitImageModal);
  MatrixHelpers.bindModalEscClose(saveBitImageModal, document.getElementById('md-saveBitImageCancelBtn'));
  // 支持回车键保存
  if (saveBitImageFilenameInput) {
    saveBitImageFilenameInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        doSaveBitImage();
      }
    });
  }

  loadLayoutModeFromStorage();
  loadColorRangesFromStorage();
  loadDefaultToleranceFromStorage();
  loadMatrixListFromStorage();

  // 选区记录 UI 事件处理
  const shiftSelectionCoord = document.getElementById('md-shiftSelectionCoord');
  const metaSelectionCoord = document.getElementById('md-metaSelectionCoord');
  const clearShiftSelectionBtn = document.getElementById('md-clearShiftSelection');
  const clearMetaSelectionBtn = document.getElementById('md-clearMetaSelection');

  // 为选区记录项添加右键菜单
  const selectionListItems = document.querySelectorAll('.matrix-selection-list .matrix-selection-item');
  if (selectionListItems[0]) {
    selectionListItems[0].addEventListener('contextmenu', (e) => {
      e.preventDefault();
      showSelectionContextMenu(e, 'shift');
    });
  }
  if (selectionListItems[1]) {
    selectionListItems[1].addEventListener('contextmenu', (e) => {
      e.preventDefault();
      showSelectionContextMenu(e, 'meta');
    });
  }

  if (shiftSelectionCoord) {
    shiftSelectionCoord.addEventListener('click', () => {
      const text = shiftSelectionCoord.textContent;
      if (text && text !== '0, 0, 0, 0') {
        copyWithToast(text, '已拷贝 "' + text + '" 到剪贴板');
      }
    });
  }

  if (metaSelectionCoord) {
    metaSelectionCoord.addEventListener('click', () => {
      const text = metaSelectionCoord.textContent;
      if (text && text !== '0, 0, 0, 0') {
        copyWithToast(text, '已拷贝 "' + text + '" 到剪贴板');
      }
    });
  }

  if (clearShiftSelectionBtn) {
    clearShiftSelectionBtn.addEventListener('click', () => {
      selection = null;
      renderBinaryOverlayOnly();
      updateSelectionRecordUI();
      clearOutputs();
      showToast('已清除 Shift 框');
    });
  }

  if (clearMetaSelectionBtn) {
    clearMetaSelectionBtn.addEventListener('click', () => {
      metaSelection = null;
      renderBinaryOverlayOnly();
      updateSelectionRecordUI();
      showToast('已清除 Meta 框');
    });
  }

  // 初始化选区记录 UI
  updateSelectionRecordUI();
}
