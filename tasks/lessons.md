# 📝 Lessons Learned — IOSControl Rebuild

> Ghi lại mistakes và patterns để không lặp lại

## General

| # | Ngày | Lesson | Context |
|---|------|--------|---------|
| 1 | 2026-04-01 | Luôn tạo `tasks/todo.md` + `tasks/lessons.md` ngay khi init project | User rules yêu cầu |
| 2 | 2026-04-01 | IOHIDFloat = `double` trên arm64, không phải `float` | Sai calling convention → garbled coordinates |
| 3 | 2026-04-01 | SimulateTouch identity convention: finger index + 2 | `_CreateFingerEvent(..., finger + 2, ...)` |
| 4 | 2026-04-01 | Parent hand event cần `SetIntegerValueWithOptions` flags `-268435456` (0xF0000000) | Không dùng flags → touch events bị ignored |
| 5 | 2026-04-01 | `BKUserEventTimer` wakeup cần thiết trước dispatch | Đặc biệt khi screen đang dimmed |
| 6 | 2026-04-01 | Non-Jailbroken (TrollStore) cần build `.app` + `.tipa`, KHÔNG phải `.deb` tweak | Dùng `application.mk` thay vì `tweak.mk` |
| 7 | 2026-04-01 | Daemon phải là binary riêng biệt, spawn qua `posix_spawn()` | App UI chỉ là launcher. Daemon sống sót khi app bị kill. |
| 8 | 2026-04-01 | `kIOHIDEventTypeKeyboard = 3`, KHÔNG PHẢI 7 | XXTouch Lua source: `local kIOHIDEventTypeKeyboard = 3` |
| 9 | 2026-04-01 | Keyboard field constants: UsagePage=`0x30000`, Usage=`0x30001`, Down=`0x30002` | Đã SAI dùng `0x0007xxxx`. XXTouch Lua dùng 196608/196609/196610 |
| 10 | 2026-04-01 | Entitlements cực kỳ quan trọng cho HID access từ daemon | Thiếu `com.apple.private.hid.client.*` → daemon không nhận HID events |
| 11 | 2026-04-01 | `memorystatus_control(16)` cần entitlement `com.apple.private.memorystatus` | Không có → daemon bị Jetsam kill |
| 12 | 2026-04-01 | `access()` HOẠT ĐỘNG cho watchdog — directory bị xoá khi uninstall app | Ban đầu nghĩ không hoạt động (lesson cũ sai). `_NSGetExecutablePath` + `access()` OK |
| 13 | 2026-04-01 | Copy entitlements trực tiếp từ XXTouch binary (`ldid -e XXTExplorer`) | Nguồn chính xác nhất, 60+ keys |
| 14 | 2026-04-01 | Không cần reboot để update daemon nữa! | `GET /api/kill` → daemon exit(0). Install .tipa mới → mở app → daemon mới spawn. |
| 15 | 2026-04-01 | iPhone IP: `192.168.1.119`, daemon port: `46952` | `http://192.168.1.119:46952/api/...` |
| 16 | 2026-04-01 | **`UIGetScreenImage()` là API đúng cho screen capture** | Private UIKit function (dlsym). Trả CGImageRef fullscreen native resolution. XXTouch import nó. |
| 17 | 2026-04-01 | **CARenderServerRenderDisplay KHÔNG dùng được tin cậy** | Yêu cầu kIOSurfaceIsGlobal + kích thước chính xác. Sai size → crop/white/crash. Tốn cả buổi debug. |
| 18 | 2026-04-01 | `GSMainScreenScaleFactor()` trả về `0.0` trong daemon process | Không có display context. Không dùng được cho daemon. |
| 19 | 2026-04-01 | kIOSurfaceIsGlobal + surface lớn (>1080x1920) = **daemon crash** | Global IOSurface có budget limit. 1242x2208 vượt limit → crash, phải reboot. |
| 20 | 2026-04-01 | Static files phải dùng path `/static/` prefix trong HTML | Daemon serve từ `[bundle]/static/`. Local preview cần `python3 -m http.server` từ project root. |
| 21 | 2026-04-01 | Zero-dependency SPA: chỉ cần Google Fonts + Material Icons CDN | Không dùng React/Vue/framework. Vanilla JS + IIFE pattern. Giữ bundle size nhỏ cho daemon. |
| 22 | 2026-04-01 | `backdrop-filter: blur()` cần `-webkit-` prefix cho iOS Safari | Không có prefix → glass effect không hiển thị trên device browser. |
| 23 | 2026-04-01 | Canvas touch events: phải phân biệt `touchstart/mousedown` bằng feature detect | `'ontouchstart' in window` → dùng touch events, ngược lại dùng mouse events. Không bind cả hai. |
| 24 | 2026-04-01 | FPS counter: đếm frames mỗi giây, reset counter mỗi `setInterval(1000)` | Đặt `state.frameCount++` trong `img.onload`, tính FPS = count/elapsed. |
| 25 | 2026-04-01 | Lua 5.4 có breaking change với `luaL_openlibs` — chỉ load what you need | Dùng `luaL_requiref` thay vì `luaL_openlibs` để tránh size bloat |
| 26 | 2026-04-02 | `posix_spawn()` cần `POSIX_SPAWN_SETPGROUP` để daemon không bị kill khi app suspend | Không có pggroup → daemon bị suspend cùng app |
| 27 | 2026-04-02 | `setsid()` trong daemon sau `posix_spawn` — detach hoàn toàn khỏi parent | Nếu không setsid → daemon nhận SIGTERM khi app quit |
| 28 | 2026-04-02 | Darwin notification names phải unique globally: dùng reverse-domain prefix | `com.ioscontrol.*` — tránh conflict với app khác |
| 29 | 2026-04-02 | **IOHIDEvent dispatch phải trên main queue (KHÔNG dùng concurrent)** | IOHIDEvent APIs không thread-safe. gDispatchClient trên concurrent queue → crash |
| 30 | 2026-04-02 | `CFBridgingRelease()` bắt buộc cho `_UICreateScreenUIImageWithRotation` | `(__bridge id)` → UIImage ~10MB leaked mỗi frame → Jetsam kill ở 100MB |
| 31 | 2026-04-02 | Unicode text → IPC clipboard paste (daemon→app→Cmd+V) | HID keyboard chỉ nhận ASCII. Unicode (tiếng Việt) phải qua clipboard. |
| 32 | 2026-04-02 | `UIApplicationInitialize` cần 2 tham số `(argc, argv)` trong standalone process | Không có → crash ngay khi bootstrap |
| 33 | 2026-04-02 | BackBoard services (`BKSDisplayServicesStart`) cần entitlement `com.apple.backboard.client` | Không có → toast overlay không hoạt động |
| 34 | 2026-04-02 | Consumer page 0x0C (bevInput) cho Home button: usage 0x40 = Menu | KHÔNG dùng AppleVendor (0x01) → SpringBoard block |
| 35 | 2026-04-02 | App watchdog: check `applicationDidBecomeActive` + periodic timer 3s | Trường hợp daemon crash khi app đang foreground, periodic timer cover được |
| 36 | 2026-04-02 | UNUserNotificationCenter: phải `requestAuthorization` trước `present` | Không xin quyền → notification không hiện |
| 37 | 2026-04-03 | CodeMirror autocomplete `replaceText` khi cursor trong dấu ngoặc → cần xử lý đặc biệt | Khi user gõ `sys.toast(` → autocomplete trigger → cần kiểm tra char trước để tránh duplicate |

## Architecture Patterns (from XXTouch)

| Pattern | Detail |
|---------|--------|
| **Daemon spawn** | App UI → `posix_spawn()` + `POSIX_SPAWN_SETPGROUP` → daemon binary |
| **Daemon persistence** | `memorystatus_control(16)` + `signal(SIGTERM, ignore)` + `CFRunLoopRun()` |
| **Daemon update** | `GET /api/kill` → exit(0). Watchdog: `access(execPath)` 5s timer → exit khi app bị xoá |
| **HID event listen** | `IOHIDEventSystemClientCreate` → `ScheduleWithRunLoop` → `RegisterEventCallback` |
| **HID event dispatch** | `IOHIDEventCreateDigitizerEvent` → `CreateFingerEvent` → `AppendEvent` → `SystemClientDispatchEvent` |
| **Volume button** | Keyboard event type=3, page=0x0C, usage=0xE9(up)/0xEA(down) |
| **SenderID** | Auto-capture from first real touch via callback, fallback `0x10000027F` |
| **Screen capture** | `UIGetScreenImage()` (primary) → `_UICreateScreenUIImageWithRotation` → CARenderServer (last resort) |
| **Web IDE SPA** | IIFE vanilla JS, drawer nav, tab switching, JPEG polling canvas, XHR REST calls |
| **Static file serve** | `handleStaticFile()` in daemon → MIME detection → serve from `[bundle]/static/` |
| **Toast IPC** | Daemon write `/tmp/ictoast_payload.json` → Darwin notif → ICToastService read + overlay |
| **Unicode text input** | Daemon → IPC file → Darwin notif → App set UIPasteboard → Daemon dispatch Cmd+V |
| **WS keyboard** | PC keydown → WS JSON `{type:"key", key:"a"}` → daemon `ic_pressKeyByName()` |

## 2026-04-02 — IOSControl WS + HID Debug Session

### Bug 1: WS disconnects immediately (select EINVAL)
- `timeval tv = {0, waitMs*1000}` — waitMs=1000 → tv_usec=1,000,000 = INVALID POSIX
- Fix: `tv = {waitMs/1000, (waitMs%1000)*1000}`

### Bug 2: UIImage leak → Jetsam at 100MB
- `(__bridge id)_UICreate...()` — no ownership → UIImage ~10MB leaked each frame
- Fix: `CFBridgingRelease(_UICreate...())`

### Bug 3: IOHIDEvent dispatch not reaching iOS
- `gDispatchClient` scheduled on main run loop but `_SystemClientDispatchEvent` called from background gHIDQueue
- Fix: `dispatch_async(dispatch_get_main_queue(), ^{ dispatchTouch(...) })`
- Rule: IOHIDEvent dispatch must be called from same run loop thread as client

### Pattern: senderID requires 1 physical touch after daemon restart

## 2026-04-03 — Autocomplete + ICToastService Build

### Bug 4: CodeMirror replaceText duplicate signature
- Khi user gõ `sys.toast(` và autocomplete trigger → `replaceText("toast(", ...)` thêm ngoặc → `sys.toast((`
- Fix: Trong `hint` function, check char ngay trước cursor. Nếu là `(` thì strip `func(` → chỉ insert `func`
- Tương tự cho các trường hợp `module.func(` → chỉ insert `module.func` (không thêm ngoặc)

### Bug 5: ICToastService watchdog loop
- Daemon check `kill(toastPid, 0)` mỗi 3s → respawn nếu fails
- Nhưng khi ICToastService bị kill, PID file vẫn còn → check sai
- Fix: Luôn ghi PID mới sau khi spawn thành công; check `kill(pid, 0) == 0` trước khi đọc PID file

### Bug 6: Toast với duration ngắn không kịp hiện
- `sys.toast("hi", 0.5)` → animation fade out quá nhanh → user không kịp thấy
- Fix: Minimum 1.5s visible time trước khi fade out; animation duration = min(duration, 1.5) + fade time
