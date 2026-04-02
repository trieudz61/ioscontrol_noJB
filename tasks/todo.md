# 📋 IOSControl Rebuild — Todo

> Rebuild từ đầu, từ đơn giản → phức tạp

---

## Phase 1: Theos Skeleton + HID Touch ✅ VERIFIED ON DEVICE

- [x] Makefile, control, plist
- [x] Entitlements.plist (full XXTouch entitlements — 60+ keys)
- [x] Cấu trúc TrollStore App (main.m, AppDelegate, Info.plist)
- [x] Standalone Daemon (`IOSControlDaemon.m`) — posix_spawn() architecture
- [x] src/IOSControl.h
- [x] HID touch dispatch (IOHIDEvent) hoạt động từ daemon process
- [x] Volume Down keyboard listener (IOHIDEventSystemClient callback)
- [x] Daemon survives app kills (memorystatus_control + SIGTERM ignore + CFRunLoopRun)
- [x] SenderID auto-capture từ real touch events
- [x] `make package` → `IOSControlApp.tipa` OK
- [x] Watchdog: tự kill daemon khi xoá app (dùng `_NSGetExecutablePath` + `access()` check mỗi 5s)
- [x] `/api/kill` endpoint: kill daemon thủ công (không cần reboot!)

### Files Phase 1:

- `Makefile` — Theos Application + daemon compile + tipa packaging
- `main.m` / `AppDelegate.m/.h` — App launcher, posix_spawn daemon
- `IOSControlDaemon.m` — Standalone daemon (HID, touch, keyboard, watchdog)
- `Entitlements.plist` — Full XXTouch entitlements
- `Resources/Info.plist` — UIBackgroundModes
- `Resources/silence.wav` — Silent audio (backup, không cần thiết với daemon)

---

## Phase 2: HTTP Server + REST API ✅ VERIFIED ON DEVICE

- [x] Thêm HTTP server vào daemon (tách file `ICHTTPServer.h/m`)
- [x] Routes: /api/tap, /api/swipe, /api/longpress, /api/touch, /api/status, /api/log
- [x] CORS headers + JSON response
- [x] Wire routes → touch functions trong daemon
- [x] Verify: curl tests từ Mac ✅

---

## Phase 3: Screen Capture ✅ VERIFIED ON DEVICE

- [x] `ICScreenCapture.h/m` — Screen capture module
- [x] Primary: `UIGetScreenImage()` (private UIKit API, dlsym) — fullscreen native resolution
- [x] Fallback: `_UICreateScreenUIImageWithRotation()` → CGImage
- [x] Fallback 2: `CARenderServerRenderDisplay` vào IOSurface 1080x1920 (chỉ 87%, dùng khi UIKit fail)
- [x] JPEG encoding qua ImageIO framework
- [x] `GET /api/screen?quality=0.8` → Binary JPEG stream
- [x] `GET /api/screen/color?x=100&y=200` → JSON `{r, g, b, hex}`
- [x] Verify: browser test fullscreen ✅

---

## Phase 4: Web IDE Frontend ✅ VERIFIED BUILD

- [x] static/index.html + style.css + app.js — complete rewrite
- [x] Premium dark theme: glassmorphism, gradients, micro-animations
- [x] Live screen tab (JPEG polling + Canvas auto-fit + FPS counter)
- [x] Touch control (Click/Drag → /api/touch REST + ripple indicator)
- [x] Color picker (Alt+Click → hex + RGB, auto-copy clipboard)
- [x] Screen bottom bar: FPS, coordinates, resolution display
- [x] Script editor tab (Lua placeholder, run/stop buttons, output panel)
- [x] Console (Log) tab — filter buttons (All/Info/Warn/Error), pause/clear
- [x] Files tab — placeholder with "Coming Soon" badge
- [x] Settings tab — 4 sections: Device Info, Screen Capture, Touch Control, About
- [x] Keyboard shortcuts: Ctrl+1/2/3 tabs, Ctrl+S, Ctrl+Enter, R rotate, Escape
- [x] Shortcuts modal dialog
- [x] Loading overlay with spinner on startup
- [x] Snackbar with icon types (info/success/error)
- [x] Responsive: persistent drawer ≥960px, overlay drawer <960px
- [x] Drawer: gradient header, active item left accent bar
- [x] ICHTTPServer.m version bump 0.3.0 → 0.4.0
- [x] Verify: `make clean && make package` → tipa build OK ✅

---

## Phase 5: Lua Scripting Engine ✅ VERIFIED ON DEVICE

### 5a: Lua VM Core

- [x] Download Lua 5.4.7 source → `lua/` directory (~32 .c/.h files)
- [x] Cập nhật Makefile: LUA_SRCS, -Ilua -DLUA_USE_IOS flags
- [x] `ICLuaEngine.h/m` — fresh state per run, serial queue, interrupt hook
- [x] `ic_luaInit()` gọi trong `IOSControlDaemon.m` main()
- [x] Verify: Lua VM boots OK on device ✅

### 5b: Basic API Bindings

- [x] `sys.log(msg)` → daemon log
- [x] `sys.msleep(ms)` → usleep
- [x] `sys.toast(msg)` → alias sys.log
- [x] `sys.sleep(sec)` → usleep seconds

### 5c: Touch API

- [x] `touch.tap(x, y)` → ic_tap()
- [x] `touch.down/move/up(x, y, finger)`
- [x] `touch.swipe(x1, y1, x2, y2, dur)`
- [x] `touch.long_press(x, y, dur)`

### 5d: Screen API

- [x] `screen.get_color(x, y)` → "#RRGGBB"
- [x] `screen.get_size()` → width, height
- [x] `screen.capture()` → JPEG bytes count

### 5e: HTTP Endpoints + Web IDE

- [x] `POST /api/script/run` — JSON decode + raw fallback
- [x] `POST /api/script/stop` — atomic stop flag
- [x] `GET /api/script/status` — idle/running/error
- [x] Wire Web IDE Run/Stop buttons, output panel, status poll 500ms
- [x] Ctrl+Enter → Run, FAB → Run
- [x] Verify: chạy Lua từ browser ✅ (sys.log xuất hiện trong Device Log)

### Files Phase 5:

- `ICLuaEngine.h/m` — Lua VM engine
- `lua/` — Lua 5.4.7 source (embedded)
- `ICHTTPServer.m` — +3 routes script, version 0.5.0
- `IOSControlDaemon.m` — ic_luaInit() thêm vào main()
- `Makefile` — LUA_SRCS, -DLUA_USE_IOS
- `static/app.js` — Script tab wired
- `static/index.html` — v0.5.0, placeholder updated

---

## Phase 6: OCR + Image Processing ✅ VERIFIED BUILD

- [x] OCR via Apple Vision framework (`ic_ocrScreen` → `VNRecognizeTextRequest`)
- [x] `ic_findColor(r,g,b,tol)` — pixel scan, Chebyshev distance, returns first match
- [x] `ic_findMultiColor(r,g,b,tol,max)` — collect up to N matches
- [x] Lua bindings: `screen.ocr()`, `screen.find_color()`, `screen.find_multi_color()`
- [x] Makefile: `ICVision.m` + `-framework Vision`
- [x] `make clean && make package` → tipa build OK ✅
- [x] Makefile tự khởi động HTTP server port 8080 sau build → in link download kèm IP Mac

---

## Phase 7: XXTouch Core Features API ✅ VERIFIED BUILD

> Phase 7 complete — all APIs wired into daemon + Lua bindings registered.
> New modules: ICScriptManager.h/m, ICAppControl.h/m, ICKeyInput.h/m
> Tipa size: 189KB (was 177KB)

### 7a: Script File Manager

- [x] List scripts (`GET /api/script/list`)
- [x] Read script (`GET /api/script/file?name=`)
- [x] Save script (`PUT /api/script/file?name=`)
- [x] Delete script (`DELETE /api/script/file?name=`)
- [x] Run script by name (`POST /api/script/run`) ← already existed Phase 5

### 7b: App Control

- [x] `ICAppControl.h/m` wrapper (LSApplicationWorkspace via ObjC runtime)
- [x] List apps (`GET /api/app/list`)
- [x] Launch app (`POST /api/app/launch`)
- [x] Kill app (`POST /api/app/kill`)
- [x] Frontmost app (`GET /api/app/frontmost`)
- [x] Lua bindings: `app.launch`, `app.kill`, `app.is_running`, `app.frontmost`, `app.list`

### 7c: HID Keyboard Input

- [x] `ICKeyInput.h/m` module (IOHIDEventCreateKeyboardEvent, ASCII→HID mapping)
- [x] Press key (`POST /api/key/press`)
- [x] Input text (`POST /api/key/input`)
- [x] Lua bindings: `key.press`, `key.input_text`

### 7d: Clipboard

- [x] Read/write clipboard (`GET/POST /api/clipboard`) via UIPasteboard runtime
- [x] Lua bindings: `clipboard.read`, `clipboard.write`

### 7e: System Info & Log API

- [x] Device info (`GET /api/device/info`) — model, iOS version, screen, memory, PID
- [x] System log (`GET/DELETE /api/system/log`) — last 8KB, clearable
- [x] Version bumped to 0.7.0

---

## Phase 8: Native iPhone UI ✅ VERIFIED BUILD

> Phụ thuộc Phase 7 complete. UITabBarController + 4 tabs + dark mode + purple accent.

- [x] Change `AppDelegate.m` window root to `UITabBarController`
- [x] Extract daemon `posix_spawn()` to `ICDaemonLauncher.h/m`
- [x] Tab 1: **Scripts** (`ICScriptsViewController.h/m`) — list/run/stop/delete scripts
- [x] Tab 2: **Console** (`ICConsoleViewController.h/m`) — live colorized log, pause/clear
- [x] Tab 3: **Device Info** (`ICDeviceViewController.h/m`) — live cards mỗi 3s
- [x] Tab 4: **Settings** (`ICSettingsViewController.h/m`) — restart/stop/copy URL/open Web IDE
- [x] Force Dark Mode + Purple accent color (#6C63FF)
- [x] Verify: `make package` → tipa build OK ✅

---

## Phase 9: Web IDE Tools Porting (XXTouch Parity) ✅ VERIFIED BUILD

> 5/6 sub-tasks complete. Phase 9f (encryption) deferred as low priority.

### 9a: Script Editor (CodeMirror) ✅

- [x] CodeMirror 5 + Lua mode (`static/script_edit.html`)
- [x] Auto-completion (Lua API hints), syntax highlighting, line numbers
- [x] Search/replace (`Ctrl+F`/`Ctrl+H`), comment toggle (`Ctrl+/`)
- [x] File manager (load/save/new via `/api/script/*`)
- [x] Output panel with run status + Lua log polling

### 9b: Color Picker Tool ✅ (`static/picker.html`)

- [x] Canvas-based screen capture viewer
- [x] Multi-point color picking with swatch list
- [x] Tolerance slider
- [x] Code generation (`find_color` / `find_multi_color`)
- [x] Touch support (mobile)

### 9c: Matrix Dict Tool ✅ (`static/matrix_dict.html`)

- [x] Drag-to-select region on captured screen
- [x] Binary threshold preview (B&W tuning)
- [x] Lua matrix dict code generation

### 9d: App List Helper ✅ (`static/applist.html`)

- [x] Query all installed iOS apps via `/api/app/list`
- [x] Search/filter by name or bundle ID
- [x] Launch / Kill / Copy bundleID with one tap

### 9e: Device & Service Control ✅ (`static/xxtouch_service.html`)

- [x] Live device status (model/iOS/RAM/PID)
- [x] Script start/stop, daemon restart/kill
- [x] Clipboard read/write UI
- [x] System log tail (last 20 lines, auto-refresh)

### 9f: Local Script Encryption (`encript.html`)

- [ ] UI for compiling `.lua` → `.xui` bytecode — deferred (low priority)

---

## Phase 10: Lua Standard Library & Daemons ✅ VERIFIED BUILD

> ICLuaStdlib.h/m — zero-dependency via Foundation + ObjC runtime

### 10a: Data & Utils ✅

- [x] **json.encode(t)** / **json.decode(s)** — NSJSONSerialization
- [x] **base64.encode(s)** / **base64.decode(s)** — NSData base64
- [x] **re.match(s, pat)**, **re.gmatch**, **re.gsub**, **re.test** — NSRegularExpression

### 10b: UI & Dialogs ✅

- [x] **sys.alert(msg [, title])** — UIAlertController via runtime, blocks Lua until OK
- [x] **sys.toast(msg [, dur])** — overlay label via runtime, non-blocking
- [x] **sys.getenv(key)**, **sys.time()**, **sys.date([fmt])** — extensions to sys table

### 10c: Network & Web ✅

- [x] **http.get(url [, headers])** → `{status, body, headers}` — NSURLSession sync
- [x] **http.post(url, body [, ct, headers])** → `{status, body}` — NSURLSession sync

### 10d: System & Threads ✅

- [x] **timer.sleep(ms)** — usleep wrapper
- [x] **timer.now()** → milliseconds since boot (CLOCK_MONOTONIC)

### 10e: Daemon Microservices — deferred (low priority)

- [ ] uiservice-toast / volume-key-control — complex, deferred

---

## 🐛 Phase 11: Bug Fixes (ưu tiên cao → thấp)

### 🔴 BUG-1: sys.toast / sys.alert — daemon không có UIWindow ✅ FIXED

> Fix: Sử dụng IPC (Darwin Notification) kết hợp với UNUserNotificationCenter để hiển thị Toast đè lên trên tất cả Apps qua dạng Local Notification Banner.

- [x] Fix: Cấu hình UNUserNotificationCenter quyền notification trong AppDelegate.
- [x] Fix: Thay thế fallback UIWindow trong daemon bằng IPC (ghi file temp + gửi `com.ioscontrol.showToast`).
- [x] Fix: Lắng nghe IPC ở App và gọi local notification banner.
- [x] Fix: alert dùng `objc_msgSend` IMP cast thay direct selector
- [ ] Test on device: `sys.toast("hello")` → hiển thị banner notification trên mọi màn hình

### 🔴 BUG-2: /api/app/list trả về empty trên TrollStore ✅ FIXED

> Fix: Thêm fs fallback scan `/var/containers/Bundle/Application/` đọc Info.plist

- [x] Fix: Fallback scan `/var/containers/Bundle/Application/`
- [x] Fix: Also try `/private/var/containers/Bundle/Application/`
- [ ] Test on device: `app.list()` → có apps

### 🔴 BUG-3: ICScriptsViewController — "New Script" không mở editor ✅ FIXED

> Fix: Sau khi save → mở SFSafariViewController tới script_edit.html#<name>

- [x] Fix: SFSafariViewController open `http://127.0.0.1:46952/static/script_edit.html#<name>`
- [x] Fix: Auto-append `.lua` extension nếu thiếu
- [ ] Test on device: Tap New → editor mở

### 🟡 BUG-4: ICConsoleViewController polling — duplicate log lines [HIGH]

> Không track lastOffset → mỗi poll lấy toàn bộ log → append lặp

- [ ] Fix: Thêm ivar `NSUInteger _lastLogLength` để chỉ append phần mới
- [ ] Fix: So sánh length trước khi append vào UITextView
- [ ] Test: Log chạy 5s không bị duplicate

### 🟡 BUG-5: http.get/post — HTTPS fail (ATS) ✅ FIXED

> Fix: Thêm `NSAllowsArbitraryLoads=YES` vào `Resources/Info.plist`

- [x] Fix: `NSAllowsArbitraryLoads = YES` trong Info.plist
- [ ] Test on device: `http.get("https://httpbin.org/get")` → status 200

### 🟡 BUG-6: Color Picker — /api/screen route ✅ NOT A BUG

> Route `/api/screen` nhận `query` param đúng cách — không cần fix

- [ ] Fix: Kiểm tra ICHTTPServer.m route `/api/screen` có nhận `quality` query param không
- [ ] Fix: Nếu không → sửa picker.html gọi `/api/screen` (không có query) hoặc thêm param parsing
- [ ] Test: Picker load ảnh thực từ device

### 🟡 BUG-7: Device model raw string ✅ FIXED

> Fix: `uname().machine` → lookup table 40+ models → "iPhone 15 Pro" etc.

- [x] Fix: `uname()` + lookup table (iPhone 11 → 16, SE, Simulator)
- [x] Fix: Thêm `hwID` field vào JSON response
- [ ] Test on device: Device Info tab hiện tên đẹp

### 🟢 BUG-8: screen.get_size() trả 0,0 khi chưa capture [LOW]

> `gScreenW/gScreenH` = 0 cho đến khi có lần capture đầu tiên

- [ ] Fix: Init `gScreenW/gScreenH` từ `UIScreen.mainScreen.bounds` khi daemon start
- [ ] Test: `screen.get_size()` ngay sau boot trả đúng resolution

### 🟢 BUG-9: Color Picker / Matrix Dict — touch scroll conflict trên iPhone [LOW]

> `touchend` và `scroll` conflict → khó chọn màu chính xác

- [ ] Fix: Thêm `preventDefault()` và dùng `pointerId` API thay touch events
- [ ] Test: Chọn màu trên iPhone không bị scroll page

### 🔴 BUG-10: Daemon bị kill không tự restart ✅ FIXED

> Daemon hay bị Jetsam kill, app không tự respawn lại

**Daemon-side hardening:**

- [x] `setsid()` — tách hoàn toàn khỏi parent session (ngăn iOS kill theo parent)
- [x] `memorystatus_control(16)` — disable Jetsam memory limit
- [x] `memorystatus_control(5, priority=10)` — set foreground priority (không bị idle-kill)
- [x] `memorystatus_control(4, dirty=1)` — mark dirty (không bị kill khi idle)
- [x] `setpriority(PRIO_PROCESS, -5)` — boost scheduling priority
- [x] `SIGPIPE/SIGINT/SIGQUIT` → SIG_IGN — ignore thêm signals

**App-side watchdog (XXTouch pattern):**

- [x] `NSTimer` 5s poll `/api/status` từ AppDelegate
- [x] 2 miss liên tiếp → `spawnDaemonWithCompletion:` tự động
- [x] `applicationDidBecomeActive:` → check ngay + respawn nếu chết
- [x] `isRespawning` flag để tránh double-spawn
- [ ] Test: Kill daemon thủ công → app tự respawn trong ~10s

### 🔴 BUG-11: Home/Lock button không hoạt động trên một số dòng iPhone ✅ FIXED

> Nút Home vật lý (như iPhone 8) bị SpringBoard block khi dùng AppleVendor event. Cần gửi đúng Consumer Menu event.

- [x] Fix: Chuyển sang dispatch event `page=0x0C, usage=0x40` cho Home và `0x30` cho Lock.
- [x] Cập nhật: Thêm Lua bindings `sys.home()`, `sys.lock()`, và `key.press()`.

### 🔴 BUG-12: Gõ ký tự Unicode (Tiếng Việt) qua `key.input_text()` bị lỗi ✅ FIXED

> Không thể truyền Unicode text qua HID keyboard event (chỉ nhận ASCII).

- [x] Fix: Phát hiện text Unicode, tự động chuyển hướng qua Clipboard paste.
- [x] Fix: Áp dụng IPC (Inter-Process Communication): Daemon lưu clipboard file tạm -> Gửi Darwin Notification `com.ioscontrol.setPasteboard` -> Main App nhận và thiết lập system clipboard -> Daemon dispatch tổ hợp phím `Cmd+V`.
- [x] Fix: Thêm Delay 400ms và đảm bảo Cmd+V chạy trên `main` thread chống deadlock.

### 🔴 BUG-13: Chưa hỗ trợ truyền phím từ máy tính qua giao diện Web IDE ✅ FIXED

> Người dùng cần gõ phím trực tiếp trên PC và dispatch thành phím trên điện thoại.

- [x] Fix: Bắt sự kiện keydown từ giao diện.
- [x] Fix: Ánh xạ chuẩn Web keycode sang bảng tên phím iPhone.
- [x] Fix: Truyền payload dạng `{ mode: 'key', ... }` hoặc `{ mode: 'text', ... }` qua WS.
- [x] Fix: Cập nhật route xử lý mode JSON trong `ICHTTPServer.m`.
