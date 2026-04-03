# 📘 Project Guide — IOSControl (non-JB via TrollStore)

> File này giúp hiểu nhanh project khi bắt đầu conversation mới.
> **Luôn đọc file này trước khi bắt đầu code.**
> Cập nhật lần cuối: **2026-04-03**

## 🎯 Mục đích

**IOSControl** là một iOS automation framework chạy trên **TrollStore (non-jailbroken)**, cung cấp:

- **HID Touch/Key injection** (tap, swipe, longpress, keyboard) từ xa qua HTTP/WebSocket
- **Screen capture** fullscreen qua private UIKit API (`UIGetScreenImage`)
- **Lua 5.4 scripting engine** với full API bindings (touch, screen, OCR, app control, network)
- **Web IDE** — premium dark-theme SPA với live screen, code editor, tools
- **Native iPhone App** — UITabBarController 4 tabs (Scripts, Console, Device, Settings)
- **Toast service** — Global notification overlay via ICToastService daemon process

## 🏗️ Kiến trúc tổng quan

```
┌──────────────────────────────────────────────────────────────┐
│                   IOSControlApp (.tipa)                     │
│                                                              │
│  ┌─────────────┐    posix_spawn()    ┌──────────────────┐  │
│  │  AppDelegate │ ──────────────────▶ │ IOSControlDaemon  │  │
│  │  (UIKit App) │◀── watchdog 3s ────│   (Port 46952)   │  │
│  │  UITabBar 4T │    /api/status     │  HTTP/WS/HID/Lua │  │
│  └──────┬──────┘                     └──────┬─────────┘  │
│         │                                     │            │
│         │ IPC (Darwin Notification)           │            │
│         ▼                                     │            │
│  ┌──────────────┐                             │            │
│  │ICToastService│  Global Toast Overlay        │            │
│  │(UIKit daemon)│  via BackBoard bootstrap      │            │
│  └──────────────┘  (watchdog respawn 3s)       │            │
│                                                              │
│  ┌──────────────────────────────────────────────────────────┤
│  │ Modules (trong IOSControlDaemon binary):                │
│  │  ICHTTPServer.m    — HTTP/WS server (POSIX+CFRunLoop)   │
│  │  ICScreenCapture.m — UIGetScreenImage + JPEG encoding   │
│  │  ICLuaEngine.m     — Lua 5.4 VM + script execution     │
│  │  ICLuaStdlib.m     — json/base64/regex/http/sys APIs    │
│  │  ICVision.m        — OCR + find_color pixel scanning    │
│  │  ICScriptManager.m — Script file CRUD                    │
│  │  ICAppControl.m   — LSApplicationWorkspace wrapper     │
│  │  ICKeyInput.m     — IOHIDEvent keyboard dispatch       │
│  └─────────────────────────────────────────────────────────┘
│                                                              │
│  static/ (Web IDE)                                          │
│  ├── index.html + style.css + app.js — Main SPA (Lucide)  │
│  ├── script_edit.html — CodeMirror Lua editor + autocomplete│
│  ├── picker.html — Color picker tool                        │
│  ├── matrix_dict.html — Matrix dict code generator          │
│  ├── applist.html — App list/launch/kill                    │
│  ├── xxtouch_service.html — Device & service control        │
│  └── api_docs.html — Full API reference                     │
│                                                              │
│  Tweak.xm (legacy SpringBoard injection — NOT compiled)     │
└──────────────────────────────────────────────────────────────┘
```

## 📦 Cấu trúc thư mục

```
.
├── IOSControlDaemon.m       — Daemon chính (HID touch/key, persistence, watchdog)
├── ICHTTPServer.h/m         — HTTP/WebSocket Server (POSIX sockets + CFRunLoop)
├── ICScreenCapture.h/m      — Screen capture (UIGetScreenImage + fallbacks)
├── ICLuaEngine.h/m          — Lua 5.4 VM engine (fresh state per run)
├── ICLuaStdlib.h/m          — Lua stdlib: json/base64/regex/http/sys/timer
├── ICVision.h/m             — OCR (Apple Vision) + findColor pixel scanning
├── ICScriptManager.h/m      — Script file CRUD
├── ICAppControl.h/m         — App launch/kill/list (LSApplicationWorkspace)
├── ICKeyInput.h/m           — HID keyboard input (ASCII→HID + Unicode→clipboard)
├── ICToastService.m         — Global toast overlay (standalone process entry)
├── ICToastService/          — ICToastService sub-bundle source
│   ├── Entitlements.plist
│   └── main.m
├── AppDelegate.m/h          — App UI launcher, daemon watchdog, IPC listeners
├── ICDaemonLauncher.h/m     — posix_spawn() daemon + toast service
├── IC*ViewController.m     — Native UI tabs: Scripts/Console/Device/Settings
├── main.m                   — App entry point
├── src/IOSControl.h         — Shared header (public API declarations)
├── Makefile                 — Theos build + daemon + toast service + tipa
├── Entitlements.plist       — 60+ entitlements (from XXTouch binary)
├── Tweak.xm                 — Legacy SpringBoard tweak (reference, NOT compiled)
├── Resources/               — Info.plist, silence.wav/caf
├── static/                  — Web IDE SPA files
├── lua/                     — Lua 5.4.7 source (59 files, embedded)
├── tasks/                   — todo.md + lessons.md
├── docs/                    — Rebuild_Plan.md + XXTouch_Analysis_v1.3.8.md
├── PROJECT_GUIDE.md         — File này
├── DECISIONS.md             — Quyết định thiết kế
└── xxtouch_extracted/       — XXTouch .tipa giải nén (reference binary)
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
  ↓               → posix_spawn() → ICToastService
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
 12. ICToastService watchdog (3s poll, respawn)
 13. CFRunLoopRun() — chạy mãi mãi
```

## 🌐 Device Info

| Key | Value |
| --- | ----- |
| **iPhone IP** | `192.168.1.119` |
| **Port** | `46952` |
| **API Base** | `http://192.168.1.119:46952` |
| **Device** | iPhone 8 (A11) |

## 🔌 API Endpoints

### Core Control
| Method | Path | Mô tả |
|--------|------|-------|
| GET | /api/status | JSON: version, pid, screen size, senderID |
| GET | /api/log | Daemon log buffer (last 4KB) |
| GET | /api/screen | JPEG screenshot (`?quality=40`) |
| GET | /api/stream | MJPEG stream (`?quality=60&fps=12`) |
| GET | /api/screen/color | JSON {r,g,b,hex} (`?x=100&y=200`) |
| POST | /api/tap | Tap tại {x, y} |
| POST | /api/swipe | Swipe {x1,y1,x2,y2,duration} |
| POST | /api/longpress | Long press {x, y, duration} |
| POST | /api/touch | Raw touch events {action,x,y,finger} |
| POST | /api/key | Key press {key: "HOMEBUTTON"} |
| GET | /api/kill | Kill daemon (exit 0) |

### Script Management
| Method | Path | Mô tả |
|--------|------|-------|
| POST | /api/script/run | Run Lua code (JSON body hoặc raw text) |
| POST | /api/script/stop | Stop running script |
| GET | /api/script/status | idle/running/error + error msg |
| GET | /api/script/list | List saved scripts |
| GET | /api/script/file | Read script (`?name=`) |
| PUT | /api/script/file | Save script (`?name=`), body: code |
| DELETE | /api/script/file | Delete script (`?name=`) |

### App Control
| Method | Path | Mô tả |
|--------|------|-------|
| GET | /api/app/list | List installed apps |
| POST | /api/app/launch | Launch app {bundleID} |
| POST | /api/app/kill | Kill app {bundleID} |
| GET | /api/app/frontmost | Frontmost app bundleID |

### Keyboard & Clipboard
| Method | Path | Mô tả |
|--------|------|-------|
| POST | /api/key/press | HID key {page, usage} |
| POST | /api/key/input | Input text string |
| GET | /api/clipboard | Read clipboard |
| POST | /api/clipboard | Write clipboard {text} |

### System
| Method | Path | Mô tả |
|--------|------|-------|
| GET | /api/device/info | Model, iOS, RAM, PID |
| GET | /api/system/log | Last 8KB log |
| DELETE | /api/system/log | Clear log |

### WebSocket
| Path | Mô tả |
|------|--------|
| /ws | Bidirectional: touch/key events (JSON frames) |

### Static Files
| Path | Mô tả |
|------|--------|
| /static/* | Serve web IDE files |

## 📖 Lua API Reference

### `sys` — System utilities
```lua
sys.log(msg)                         -- daemon log
sys.toast(msg [, duration])          -- toast notification (2s default)
sys.alert(msg [, title])             -- blocking alert dialog
sys.sleep(sec)                        -- sleep seconds
sys.msleep(ms)                        -- sleep milliseconds
sys.getenv(key)                       -- get environment variable
sys.time()                            -- epoch seconds
sys.date([fmt])                       -- date string
```

### `touch` — Touch injection
```lua
touch.tap(x, y)                              -- tap at coordinates
touch.swipe(x1, y1, x2, y2 [, duration])   -- swipe gesture
touch.long_press(x, y [, duration])         -- long press (1s default)
touch.down(x, y [, finger])                 -- touch down
touch.move(x, y [, finger])                 -- touch move
touch.up(x, y [, finger])                   -- touch up
touch.tap_image(path [, threshold, timeout]) -- find image then tap
touch.tap_text(text [, timeout])            -- find text via OCR then tap
```

### `screen` — Screen capture & analysis
```lua
screen.get_size()                           -- → width, height
screen.get_color(x, y)                      -- → "#RRGGBB"
screen.capture()                            -- → byte count (JPEG)
screen.ocr()                               -- → array of recognized strings
screen.find_color(r, g, b [, tolerance])   -- → {x, y} or nil
screen.find_multi_color(r, g, b [, tol, max]) -- → array of {x,y}
screen.find_text(text)                      -- → {x, y} or nil via OCR
screen.find_image(path [, threshold])        -- → {x, y} or nil (placeholder)
```

### `app` — App control
```lua
app.launch(bundleID)       -- launch app
app.kill(bundleID)         -- kill app
app.is_running(bundleID)   -- → boolean
app.frontmost()            -- → bundleID string
app.list()                 -- → array of {bundleID, name, version}
```

### `key` — Keyboard input
```lua
key.press(page, usage)     -- press HID key
key.input_text(text)       -- type text (ASCII via HID, Unicode via clipboard)
```

### `clipboard` — Clipboard
```lua
clipboard.read()           -- → string
clipboard.write(text)       -- → boolean
```

### `json`, `base64`, `re`, `http`, `timer`
```lua
json.encode(t) / json.decode(s)
base64.encode(s) / base64.decode(s)
re.match(s, pat) / re.gmatch(s, pat) / re.gsub(s, pat, rep) / re.test(s, pat)
http.get(url [, headers]) --> {status, body, headers}
http.post(url, body [, ct, headers]) --> {status, body}
timer.sleep(ms) / timer.now()
```

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
  com.ioscontrol.showToast              → UIWindow overlay (windowLevel ~20M)
  (writes /tmp/ictoast_payload.json)

App ──── UNUserNotificationCenter ──▶ iOS
  (fallback toast as local notification banner)
```

## 📊 Trạng thái hiện tại

| Phase | Feature | Status |
|-------|---------|--------|
| Phase 1 | Daemon + HID Touch + Persistence | ✅ VERIFIED ON DEVICE |
| Phase 2 | HTTP Server + REST API | ✅ VERIFIED ON DEVICE |
| Phase 3 | Screen Capture (UIGetScreenImage) | ✅ VERIFIED ON DEVICE |
| Phase 4 | Web IDE Frontend (SPA) | ✅ VERIFIED ON DEVICE |
| Phase 5 | Lua 5.4 Scripting Engine | ✅ VERIFIED ON DEVICE |
| Phase 6 | OCR + Image Processing (Vision) | ✅ VERIFIED BUILD |
| Phase 7 | XXTouch Core Features (App/Key/Clipboard/Scripts) | ✅ VERIFIED ON DEVICE |
| Phase 8 | Native iPhone UI (4 tabs) | ✅ VERIFIED ON DEVICE |
| Phase 9 | Web IDE Tools (Editor/Picker/Matrix/AppList/Service) | ✅ VERIFIED BUILD |
| Phase 10 | Lua Standard Library (json/base64/regex/http/timer) | ✅ VERIFIED BUILD |
| Phase 11 | Bug Fixes (12 bugs) | ✅ ALL FIXED |
| Phase 12 | Web IDE Polish (autocomplete, TXT, Lucide, toast service) | ✅ VERIFIED BUILD |

**Version: 0.5.1** (stable-v0.5.1-working)
