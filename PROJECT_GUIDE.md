# 📘 Project Guide — IOSControl Daemon

> File này giúp Antigravity hiểu nhanh project khi bắt đầu conversation mới.
> **Luôn đọc file này trước khi bắt đầu code.**

## 🎯 Mục đích

Daemon iOS chạy ngầm trên TrollStore (non-jailbroken), cung cấp:

- **HID touch injection** (tap, swipe, longpress) từ xa qua HTTP
- **Screen capture** fullscreen qua private UIKit API
- **REST API** cho mọi thao tác — Web IDE frontend sắp tới

## 🏗️ Cấu trúc thư mục

```
.
├── IOSControlDaemon.m    — Daemon chính (HID, keyboard, watchdog, persistence)
├── ICHTTPServer.h/m      — HTTP Server (POSIX sockets + CFRunLoop)
├── ICScreenCapture.h/m   — Screen capture (UIGetScreenImage + CARenderServer fallback)
├── AppDelegate.m/h       — App UI launcher (posix_spawn daemon)
├── main.m                — App entry point
├── src/IOSControl.h      — Shared header (public API declarations)
├── Makefile              — Theos build + daemon compile + tipa packaging
├── Entitlements.plist    — 60+ entitlements (copied from XXTouch)
├── Resources/            — Info.plist, silence.wav
├── tasks/todo.md         — Roadmap & checklist
├── tasks/lessons.md      — Lessons learned (QUAN TRỌNG!)
├── PROJECT_GUIDE.md      — File này
├── DECISIONS.md          — Quyết định thiết kế
└── xxtouch_extracted/    — XXTouch .tipa đã giải nén (reference binary)
```

## 📦 Tech Stack

- **Objective-C / C**: Core logic daemon
- **POSIX Sockets & CFRunLoop**: HTTP Server zero-dependency
- **IOKit & IOHID**: Touch injection low-level
- **UIKit private API** (`UIGetScreenImage`): Screen capture fullscreen
- **ImageIO**: JPEG encoding
- **TrollStore**: Deployment (.tipa package)

## 🔄 Flow chính

```
App (AppDelegate) → posix_spawn() → IOSControlDaemon
  ↓
Daemon starts:
  1. Anti-Jetsam (memorystatus_control)
  2. HID symbols loaded (dlsym IOKit)
  3. SenderID capture (IOHIDEventSystemClient callback)
  4. Keyboard listener (Volume Down trigger)
  5. Watchdog timer (auto-exit khi app bị xoá, check mỗi 5s)
  6. HTTP Server on port 46952
  7. Screen capture init (UIGetScreenImage + fallbacks)
  8. CFRunLoopRun() — chạy mãi mãi
```

## 🌐 Device Info

| Key           | Value                        |
| ------------- | ---------------------------- |
| **iPhone IP** | `192.168.1.119`              |
| **Port**      | `46952`                      |
| **API Base**  | `http://192.168.1.119:46952` |

## 🔌 API Endpoints

| Method | Path              | Mô tả                           |
| ------ | ----------------- | ------------------------------- |
| GET    | /api/status       | JSON: version, pid, screen size |
| GET    | /api/log          | Daemon log buffer               |
| GET    | /api/screen       | JPEG screenshot (?quality=0.8)  |
| GET    | /api/screen/color | JSON {r,g,b,hex} (?x=100&y=200) |
| POST   | /api/tap          | Tap tại {x, y}                  |
| POST   | /api/swipe        | Swipe {x1,y1,x2,y2,duration}    |
| POST   | /api/longpress    | Long press {x, y, duration}     |
| POST   | /api/touch        | Raw multi-touch events array    |
| GET    | /api/kill         | **Kill daemon** (exit 0)        |

## ⚙️ Cách build & deploy

```bash
# Build
cd /Users/trieudz/Desktop/Test
make clean && make package

# Serve .tipa cho iPhone tải
python3 -m http.server 8080
# → iPhone Safari: http://<MAC_IP>:8080/IOSControlApp.tipa

# Update daemon (KHÔNG CẦN REBOOT):
curl http://192.168.1.119:46952/api/kill   # Kill daemon cũ
# Install .tipa mới qua TrollStore
# Mở app → daemon mới tự spawn

# Test
curl http://192.168.1.119:46952/api/status
curl -o test.jpg http://192.168.1.119:46952/api/screen
```

## 🚧 Trạng thái hiện tại

- ✅ **Phase 1**: Daemon + HID Touch + Persistence
- ✅ **Phase 2**: HTTP Server + REST API
- ✅ **Phase 3**: Screen Capture (UIGetScreenImage) + Color Sampling
- 🔲 **Phase 4**: Web IDE Frontend (chưa bắt đầu)
- 🔲 **Phase 5-7**: Lua, OCR, Advanced features

## 📅 Cập nhật lần cuối

2026-04-01 12:00
