# 📋 IOSControl Rebuild — Todo

> Rebuild từ đầu, từ đơn giản → phức tạp
> Cập nhật: 2026-04-02 19:44

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

> UITabBarController + 4 tabs + dark mode + purple accent.

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

## 🐛 Phase 11: Bug Fixes

### ✅ FIXED (8 bugs)

| Bug | Tình trạng | Mô tả | Fix |
|-----|-----------|-------|-----|
| BUG-1 | ✅ FIXED | `sys.toast`/`sys.alert` — daemon không có UIWindow | IPC Darwin Notification + UNUserNotificationCenter + ICToastService |
| BUG-2 | ✅ FIXED | `/api/app/list` trả về empty trên TrollStore | Fallback scan `/var/containers/Bundle/Application/` |
| BUG-3 | ✅ FIXED | ICScriptsViewController "New Script" không mở editor | SFSafariViewController tới script_edit.html#<name> |
| BUG-5 | ✅ FIXED | `http.get/post` HTTPS fail (ATS) | `NSAllowsArbitraryLoads=YES` trong Info.plist |
| BUG-7 | ✅ FIXED | Device model raw string ("iPhone10,1") | `uname().machine` → lookup table 40+ models |
| BUG-10 | ✅ FIXED | Daemon bị kill không tự restart | setsid + memorystatus + App watchdog 3s |
| BUG-11 | ✅ FIXED | Home/Lock button không hoạt động | Consumer Menu `{0x0C, 0x40}` + Admin client |
| BUG-12 | ✅ FIXED | Unicode text (Tiếng Việt) qua `key.input_text()` | IPC clipboard paste: daemon→app→Cmd+V |
| BUG-13 | ✅ FIXED | Không truyền phím PC → iPhone qua Web IDE | WS keydown → phím iPhone ánh xạ |

### 🟡 NEEDS TESTING (chưa verify on device)

| Bug | Mô tả | Test cần làm |
|-----|-------|-------------|
| BUG-1 | Toast notification | `sys.toast("hello")` → banner hiển thị mọi màn hình |
| BUG-2 | App list | `app.list()` → có apps |
| BUG-3 | New Script editor | Tap New → editor mở |
| BUG-5 | HTTPS requests | `http.get("https://httpbin.org/get")` → status 200 |
| BUG-7 | Device model name | Device Info tab hiện tên đẹp |
| BUG-10 | Daemon respawn | Kill daemon → app tự respawn trong ~10s |

### 🔴 OPEN BUGS

| Bug | Priority | Mô tả | Action needed |
|-----|----------|-------|---------------|
| BUG-4 | 🟡 MEDIUM | Console duplicate log lines | Track `_lastLogLength`, chỉ append phần mới |
| BUG-6 | ✅ NOT A BUG | Color Picker /api/screen route | Route hoạt động đúng, không cần fix |
| BUG-8 | 🟢 LOW | `screen.get_size()` trả 0,0 khi chưa capture | Init gScreenW/gScreenH từ UIScreen khi daemon start |
| BUG-9 | 🟢 LOW | Color Picker touch scroll conflict trên iPhone | `preventDefault()` + `pointerId` API |

---

## 🗓️ Phase 12: IDE Refactoring + Bug Fixes + New APIs ✅ (Build #97, v0.5.1)

> Cập nhật: 2026-04-02 23:10 — pushed to git

### 12a: Web IDE Inline Refactoring ✅

- [x] Move Script Editor lên đầu drawer (trên Live Screen)
- [x] Xoá tab Files → chuyển File Browser thành sidebar trong Script Editor
- [x] Xoá Matrix Dict khỏi drawer
- [x] Inline toàn bộ 5 Tools vào IDE qua iframe (lazy-load `data-src`)
  - [x] Color Picker, App List, Device Control, API Docs, Template Maker
  - [x] Không mở tab mới nữa, tất cả load trong IDE
- [x] Fix copy/paste trên HTTP (execCommand fallback)

### 12b: UI Bug Fixes ✅

- [x] Fix CodeMirror gutter (số dòng) đè code — `margin-left: 48px`
- [x] Fix Clear Log button — gửi `DELETE /api/system/log` tới backend
- [x] Fix Settings Screen Capture controls — quality/interval was hardcoded `40`/`150ms`, now reads `config.quality`/`config.interval`

### 12c: Backend Bug Fixes ✅

- [x] **Fix `app.kill()`** — removed broken `terminateApplicationWithBundleID:` (silently failed), new: SIGTERM→SIGKILL via PID + `killall -9` via `posix_spawn`
- [x] **Fix `app.is_running()` crash** — removed broken `performSelector` on non-existent LSWorkspace selectors, new: PID-based check via `findPidForBundleID`
- [x] **Fix `app.frontmost()` crash** — removed broken `SBApplicationController` calls, new: `dlopen` SpringBoardServices + `SBSCopyFrontmostApplicationDisplayIdentifier`

### 12d: Performance ✅

- [x] **Optimize `screen.find_image()`** — 2-phase pyramid: coarse scan stride=4 + sample every 4th pixel (~256x faster), then refine ±8px at full resolution. Expected: seconds → ~100-300ms on iPhone 8
- [x] Added timing logs: `✅ [findImage] Match 95.2% at (375, 667) in 180ms`

### 12e: New Lua APIs ✅

- [x] `touch.tap_image(path [, threshold])` — find template + tap center
- [x] `touch.tap_text(text)` — OCR find + tap location
- [x] Autocomplete hints updated in Script Editor

---

## 🗓️ Tiếp theo (chưa plan)

### Ưu tiên cao
- [ ] Test toàn bộ BUG fixes đã implement trên device
- [ ] Fix BUG-4: Console duplicate log lines
- [ ] Verify `app.kill` / `app.is_running` / `app.frontmost` hoạt động

### Ưu tiên trung bình
- [ ] Fix BUG-8: screen.get_size() init (trả 0,0 khi chưa capture)
- [ ] Fix BUG-9: Picker touch scroll conflict trên iPhone
- [ ] Thêm Lua API: `sys.home()`, `sys.lock()` (đã có ic_pressKey, cần expose)

### Nice to have
- [ ] Script encryption 9f
- [ ] Daemon microservices 10e
- [ ] CI/CD pipeline (auto build + push)
- [ ] OTA update mechanism

