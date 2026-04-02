# 📋 Decisions Log — IOSControl

> Ghi lại các quyết định thiết kế quan trọng. Antigravity đọc file này để không lặp lại thảo luận cũ.
> Cập nhật: 2026-04-02 19:44

## Quyết định

| #   | Ngày       | Quyết định                                                              | Lý do                                                                                                                | Ảnh hưởng                               |
| --- | ---------- | ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| 1   | 2026-04-01 | Sử dụng symlink tới global skills thay vì copy                          | Duy trì 1 nguồn duy nhất, cập nhật tự động                                                                          | `.agents/skills/`, `.agents/workflows/` |
| 2   | 2026-04-01 | Daemon binary riêng biệt, spawn qua `posix_spawn()`                     | Giống XXTouch ReportCrash. App UI chỉ là launcher, daemon sống sót khi app bị kill                                  | `IOSControlDaemon.m` là binary riêng    |
| 3   | 2026-04-01 | Copy 60+ entitlements trực tiếp từ XXTouch binary                       | Nguồn chính xác nhất cho HID, BackBoard, IOSurface, memorystatus trên non-jailbreak                                 | `Entitlements.plist`                    |
| 4   | 2026-04-01 | **`UIGetScreenImage()` cho Screen Capture** (KHÔNG dùng CARenderServer) | CARenderServer crop/crash/white tùy kích thước surface. `UIGetScreenImage()` (UIKit private, dlsym) → fullscreen.    | `ICScreenCapture.m`                     |
| 5   | 2026-04-01 | Watchdog dùng `_NSGetExecutablePath` + `access()` check 5s              | Khi TrollStore xoá app, directory bị xoá → daemon `exit(0)`. Kết hợp `/api/kill` cho update thủ công.               | Không cần reboot khi update!            |
| 6   | 2026-04-01 | Frame cache TTL 200ms + semaphore guard cho screen capture              | Ngăn thread pile-up khi nhiều client gọi /api/screen đồng thời → Jetsam kill                                         | `ICHTTPServer.m` gCachedFrame           |
| 7   | 2026-04-02 | IOHIDEvent dispatch phải trên main queue (KHÔNG dùng concurrent)         | IOHIDEvent APIs không thread-safe. gDispatchClient trên concurrent queue → crash                                     | `dispatch_async(main_queue, ...)`       |
| 8   | 2026-04-02 | WebSocket cho touch/key events, HTTP polling cho screen capture         | Decoupled: WS events fire-and-forget, screen capture không block touch. Tránh latency khi screen capture chậm.       | `ICHTTPServer.m` WS handler             |
| 9   | 2026-04-02 | `CFBridgingRelease()` cho `_UICreateScreenUIImageWithRotation`          | Không dùng `(__bridge id)` → UIImage ~10MB leaked mỗi frame → Jetsam kill ở 100MB                                    | `ICScreenCapture.m` memory management   |
| 10  | 2026-04-02 | Unicode text → IPC clipboard paste (daemon→app→Cmd+V)                   | HID keyboard chỉ nhận ASCII. Unicode (tiếng Việt) phải qua clipboard. Daemon ghi file → Darwin notif → App set UIPasteboard → Daemon dispatch Cmd+V | `ICKeyInput.m` + `AppDelegate.m` IPC    |
| 11  | 2026-04-02 | ICToastService — standalone UIApp với BackBoard bootstrap                | Daemon không có UIWindow context. Cần process riêng `posix_spawn` từ App, bootstrap UIKit qua `BKSDisplayServicesStart` + `UIApplicationInitialize` + `UIApplicationInstantiateSingleton` | `ICToastService.m`                      |
| 12  | 2026-04-02 | `IOHIDEventSystemClientCreateWithType(type=Admin)` cho keyboard events  | `IOHIDEventSystemClientCreate(type=0)` KHÔNG dispatch được keyboard/button events tới SpringBoard. Must use type=Admin (2) | `IOSControlDaemon.m` gKeyboardDispatchClient |
| 13  | 2026-04-02 | Home button = Consumer Menu `{0x0C, 0x40}` (KHÔNG phải AppleVendor)     | iPhone 8 physical Home button bị SpringBoard block khi dùng AppleVendor event. Consumer Menu hoạt động đúng.          | `IOSControlDaemon.m` ic_pressKey        |
| 14  | 2026-04-02 | App-side watchdog 3s poll + respawn on FIRST miss                       | XXTouch pattern: host app supervises daemon. `applicationDidBecomeActive` cũng check + respawn ngay.                  | `AppDelegate.m` daemonWatchdog          |
| 15  | 2026-04-02 | Toast fallback: UNUserNotificationCenter (local notification banner)    | Khi ICToastService không khả dụng, daemon post Darwin notif → App nhận → UNUserNotification banner. Hoạt động cả khi app foreground. | `AppDelegate.m` + `ICLuaStdlib.m`       |
