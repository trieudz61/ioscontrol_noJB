# 📘 Project Guide — IOSControl (non-JB via TrollStore)

> File này giúp Antigravity hiểu nhanh project khi bắt đầu conversation mới.
> **Luôn đọc file này trước khi bắt đầu code.**
> Cập nhật lần cuối: **2026-04-02 19:44**

## 🎯 Mục đích

**IOSControl** là một iOS automation framework chạy trên **TrollStore (non-jailbroken)**, cung cấp:

- **HID Touch/Key injection** (tap, swipe, longpress, keyboard) từ xa qua HTTP/WebSocket
- **Screen capture** fullscreen qua private UIKit API (`UIGetScreenImage`)
- **Lua 5.4 scripting engine** với full API bindings (touch, screen, OCR, app control, network)
- **Web IDE** — premium dark-theme SPA với live screen, code editor, tools
- **Native iPhone App** — UITabBarController 4 tabs (Scripts, Console, Device, Settings)
- **Toast service** — Global notification overlay via IPC + UNUserNotificationCenter

## 🏗️ Kiến trúc tổng quan

```
┌──────────────────────────────────────────────────────┐
│              IOSControlApp (.tipa)                     │
│                                                        │
│  ┌─────────────┐    posix_spawn()    ┌──────────────┐ │
│  │  AppDelegate │ ──────────────────▶│IOSControlDaemon│ │
│  │  (UIKit App) │◀── watchdog 3s ───│  (Port 46952) │ │
│  │  UITabBar 4T │    /api/status     │  HTTP/WS/HID  │ │
│  └──────┬──────┘                    └──────┬────────┘ │
│         │                                   │          │
│         │ IPC (Darwin Notification)         │          │
│         ▼                                   │          │
│  ┌──────────────┐                          │          │
│  │ICToastService│  Global Toast Overlay     │          │
│  │(UIKit daemon)│  via BackBoard bootstrap  │          │
│  └──────────────┘                          │          │
│                                             │          │
│  ┌──────────────────────────────────────────┘          │
│  │ Modules:                                            │
│  │  ICHTTPServer.m  — HTTP/WS server (POSIX+CFRunLoop) │
│  │  ICScreenCapture — UIGetScreenImage + JPEG encoding │
│  │  ICLuaEngine.m   — Lua 5.4 VM + script execution   │
│  │  ICLuaStdlib.m   — json/base64/regex/http/sys APIs  │
│  │  ICVision.m      — OCR + find_color pixel scanning  │
│  │  ICScriptManager  — Script file CRUD (list/read/    │
│  │                     write/delete)                    │
│  │  ICAppControl.m  — LSApplicationWorkspace wrapper   │
│  │  ICKeyInput.m    — IOHIDEvent keyboard dispatch     │
│  └─────────────────────────────────────────────────────│
│                                                        │
│  static/ (Web IDE)                                     │
│  ├── index.html + style.css + app.js — Main SPA        │
│  ├── script_edit.html — CodeMirror Lua editor          │
│  ├── picker.html — Color picker tool                   │
│  ├── matrix_dict.html — Matrix dict code generator     │
│  ├── applist.html — App list/launch/kill               │
│  └── xxtouch_service.html — Device & service control   │
│                                                        │
│  Tweak.xm (legacy SpringBoard injection — NOT in use)  │
└──────────────────────────────────────────────────────┘
```

## 📦 Cấu trúc thư mục

```
.
├── IOSControlDaemon.m    — Daemon chính (HID touch/key, persistence, watchdog)
├── ICHTTPServer.h/m      — HTTP/WebSocket Server (POSIX sockets + CFRunLoop)
├── ICScreenCapture.h/m   — Screen capture (UIGetScreenImage + fallbacks)
├── ICLuaEngine.h/m       — Lua 5.4 VM engine (fresh state per run)
├── ICLuaStdlib.h/m       — Lua stdlib: json/base64/regex/http/sys.alert/toast
├── ICVision.h/m          — OCR (Apple Vision) + findColor pixel scanning
├── ICScriptManager.h/m   — Script file CRUD
├── ICAppControl.h/m      — App launch/kill/list (LSApplicationWorkspace)
├── ICKeyInput.h/m        — HID keyboard input (ASCII→HID + Unicode→clipboard)
├── ICToastService.m      — Global toast overlay (standalone process)
├── AppDelegate.m/h       — App UI launcher, daemon watchdog, IPC listeners
├── ICDaemonLauncher.h/m  — posix_spawn() daemon + toast service
├── IC*ViewController.m   — Native UI tabs: Scripts/Console/Device/Settings
├── main.m                — App entry point
├── src/IOSControl.h      — Shared header (public API declarations)
├── Makefile              — Theos build + daemon + toast service + tipa
├── Entitlements.plist    — 60+ entitlements (from XXTouch binary)
├── Tweak.xm              — Legacy SpringBoard tweak (reference, NOT compiled)
├── Resources/            — Info.plist, silence.wav/caf
├── static/               — Web IDE SPA files
├── lua/                  — Lua 5.4.7 source (59 files, embedded)
├── tasks/                — todo.md + lessons.md
├── docs/                 — Rebuild_Plan.md + XXTouch_Analysis_v1.3.8.md
├── PROJECT_GUIDE.md      — File này
├── DECISIONS.md          — Quyết định thiết kế
└── xxtouch_extracted/    — XXTouch .tipa giải nén (reference binary)
```

## 📦 Tech Stack

| Layer | Technology |
|-------|-----------|
| **Language** | Objective-C / C (daemon + app) |
| **HTTP Server** | POSIX Sockets + CFRunLoop (zero dependency) |
| **WebSocket** | Manual upgrade (SHA1 handshake + frame parse) |
| **Touch/Key Injection** | IOKit IOHID private API (dlsym) |
| **Screen Capture** | `UIGetScreenImage()` private UIKit API |
| **Image Encoding** | ImageIO framework (JPEG) |
| **OCR** | Apple Vision framework |
| **Scripting** | Lua 5.4.7 (source embedded) |
| **UI Framework** | UIKit (native) + Vanilla JS SPA (web) |
| **Deployment** | TrollStore (.tipa package) |
| **Build System** | Theos |

## 🔄 Flow chính

```
App (AppDelegate) → posix_spawn() → IOSControlDaemon
  ↓                → posix_spawn() → ICToastService
Daemon starts:
  1. setsid() — detach from parent session
  2. Anti-Jetsam (memorystatus_control: limit/priority/dirty)
  3. Signal hardening (ignore SIGTERM/SIGHUP/SIGPIPE/SIGINT/SIGQUIT)
  4. Process priority boost (setpriority -5)
  5. HID symbols loaded (dlsym IOKit)
  6. SenderID capture (touch + keyboard HW senderID)
  7. Dispatch clients: touch (type=0) + keyboard (type=Admin)
  8. Watchdog timer (auto-exit khi app bị xoá, access() 5s)
  9. HTTP/WS Server on port 46952
 10. Screen capture init (UIGetScreenImage)
 11. Lua 5.4 engine init
 12. CFRunLoopRun() — chạy mãi mãi
```

## 🌐 Device Info

| Key           | Value                        |
| ------------- | ---------------------------- |
| **iPhone IP** | `192.168.1.119`              |
| **Port**      | `46952`                      |
| **API Base**  | `http://192.168.1.119:46952` |
| **Device**    | iPhone 8 (A11)               |

## 🔌 API Endpoints

### Core Control
| Method | Path              | Mô tả                               |
| ------ | ----------------- | ----------------------------------- |
| GET    | /api/status       | JSON: version, pid, screen size      |
| GET    | /api/log          | Daemon log buffer (last 4KB)         |
| GET    | /api/screen       | JPEG screenshot (?quality=40)        |
| GET    | /api/stream       | MJPEG stream (?quality=60&fps=12)    |
| GET    | /api/screen/color | JSON {r,g,b,hex} (?x=100&y=200)     |
| POST   | /api/tap          | Tap tại {x, y}                       |
| POST   | /api/swipe        | Swipe {x1,y1,x2,y2,duration}        |
| POST   | /api/longpress    | Long press {x, y, duration}          |
| POST   | /api/touch        | Raw touch events {action,x,y,finger} |
| POST   | /api/key          | Key press {key: "HOMEBUTTON"}        |
| GET    | /api/kill         | Kill daemon (exit 0)                 |

### Script Management
| Method | Path                   | Mô tả                |
| ------ | ---------------------- | -------------------- |
| POST   | /api/script/run        | Run Lua code         |
| POST   | /api/script/stop       | Stop running script  |
| GET    | /api/script/status     | Script status        |
| GET    | /api/script/list       | List saved scripts   |
| GET    | /api/script/file       | Read script (?name=) |
| PUT    | /api/script/file       | Save script (?name=) |
| DELETE | /api/script/file       | Delete script        |

### App Control
| Method | Path               | Mô tả              |
| ------ | ------------------ | ------------------- |
| GET    | /api/app/list      | List installed apps  |
| POST   | /api/app/launch    | Launch app           |
| POST   | /api/app/kill      | Kill app             |
| GET    | /api/app/frontmost | Frontmost app        |

### Keyboard & Clipboard
| Method | Path             | Mô tả                |
| ------ | ---------------- | -------------------- |
| POST   | /api/key/press   | HID key {page,usage} |
| POST   | /api/key/input   | Input text string    |
| GET    | /api/clipboard   | Read clipboard       |
| POST   | /api/clipboard   | Write clipboard      |

### System
| Method | Path             | Mô tả              |
| ------ | ---------------- | ------------------- |
| GET    | /api/device/info | Model, iOS, RAM, PID |
| GET    | /api/system/log  | Last 8KB log         |
| DELETE | /api/system/log  | Clear log            |

### WebSocket
| Path | Mô tả |
|------|--------|
| /ws  | Bidirectional: touch/key events (JSON frames) |

## ⚙️ Cách build & deploy

```bash
# Build
cd /Users/trieudz/Desktop/Test
make clean && make package

# → IOSControlApp.tipa (tự mở server 8080)
# → iPhone Safari: http://<MAC_IP>:8080/IOSControlApp.tipa

# Update daemon (KHÔNG CẦN REBOOT):
curl http://192.168.1.119:46952/api/kill   # Kill daemon cũ
# Install .tipa mới qua TrollStore
# Mở app → daemon tự spawn

# Test
curl http://192.168.1.119:46952/api/status
curl -o test.jpg http://192.168.1.119:46952/api/screen
```

## 🔑 IPC Architecture

```
Daemon ──── Darwin Notification ─────▶ App
  com.ioscontrol.setPasteboard          → UIPasteboard.generalPasteboard
  (writes /tmp/ioscontrol_paste_text.txt)

Daemon ──── Darwin Notification ─────▶ ICToastService
  com.ioscontrol.showToast              → UIWindow overlay (windowLevel 20M)
  (writes /tmp/ioscontrol_toast_text.txt)

App ──── UNUserNotificationCenter ──▶ iOS
  (fallback toast as local notification banner)
```

## 📊 Trạng thái hiện tại

- ✅ **Phase 1**: Daemon + HID Touch + Persistence
- ✅ **Phase 2**: HTTP Server + REST API
- ✅ **Phase 3**: Screen Capture (UIGetScreenImage)
- ✅ **Phase 4**: Web IDE Frontend (SPA)
- ✅ **Phase 5**: Lua 5.4 Scripting Engine
- ✅ **Phase 6**: OCR + Image Processing (Vision)
- ✅ **Phase 7**: XXTouch Core Features (App/Key/Clipboard/Scripts)
- ✅ **Phase 8**: Native iPhone UI (4 tabs)
- ✅ **Phase 9**: Web IDE Tools (Editor/Picker/Matrix/AppList/Service)
- ✅ **Phase 10**: Lua Standard Library (json/base64/regex/http/timer)
- 🔧 **Phase 11**: Bug fixes (8 fixed, 4 open)
- 🔲 **Phase 12**: (chưa plan)
