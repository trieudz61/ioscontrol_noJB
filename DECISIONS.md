# 📋 Decisions Log — IOSControl

> Ghi lại các quyết định thiết kế quan trọng. Antigravity đọc file này để không lặp lại thảo luận cũ.

## Quyết định

| #   | Ngày       | Quyết định                                                              | Lý do                                                                                                                                                           | Ảnh hưởng                               |
| --- | ---------- | ----------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| 1   | 2026-04-01 | Sử dụng symlink tới global skills thay vì copy                          | Duy trì 1 nguồn duy nhất, cập nhật tự động                                                                                                                      | `.agents/skills/`, `.agents/workflows/` |
| 2   | 2026-04-01 | Daemon binary riêng biệt, spawn qua `posix_spawn()`                     | Giống XXTouch ReportCrash. App UI chỉ là launcher, daemon sống sót khi app bị kill.                                                                             | `IOSControlDaemon.m` là binary riêng    |
| 3   | 2026-04-01 | Copy 60+ entitlements trực tiếp từ XXTouch binary                       | Nguồn chính xác nhất cho HID, BackBoard, IOSurface, memorystatus trên non-jailbreak                                                                             | `Entitlements.plist`                    |
| 4   | 2026-04-01 | **`UIGetScreenImage()` cho Screen Capture** (KHÔNG dùng CARenderServer) | CARenderServer crop/crash/white tùy kích thước surface. `UIGetScreenImage()` (private UIKit, dlsym) → `CGImageRef` fullscreen ở native resolution, zero config. | `ICScreenCapture.m`                     |
| 5   | 2026-04-01 | Watchdog dùng `_NSGetExecutablePath` + `access()` check 5s              | Khi TrollStore xoá app, directory bị xoá → `access(path)` fails → daemon `exit(0)`. Kết hợp `/api/kill` endpoint cho update thủ công.                           | Không cần reboot khi update daemon nữa! |
