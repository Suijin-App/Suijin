---
phase: 5
title: Migration bản cài Mercury đang có
status: pending
depends_on: [3]
---

# Phase 5: Migration bản cài Mercury đang có

> Mercury chưa phát hành, nên phần này chỉ phục vụ máy dev. Vẫn làm bằng code (có test), để dữ liệu thật trên máy không bị mất. Có thể bỏ bước 8 (thông báo đổi tên) nếu muốn gọn.

## Mục tiêu
Lần đầu chạy Sevinda trên máy đã có Mercury: dữ liệu và cài đặt được chuyển sang, helper cũ được dọn gọn gàng, không mất gì và không để lại process mồ côi.

## Việc làm (một lần, khi khởi động, trước khi mở database)

1. **Thư mục dữ liệu**:
   - Điều kiện: `Application Support/Sevinda` chưa có và `Application Support/Mercury` có.
   - Backup trước, theo quy tắc của repo: copy `Mercury` sang `Mercury.backup-<ngày>`.
   - Chuyển `Mercury` sang `Sevinda` bằng `moveItem`, cùng ổ nên đây là thao tác atomic.
   - Đổi tên `mercury.sqlite` (cùng `-wal`/`-shm`) thành `sevinda.sqlite`.
   - Giữ quyền 700/600.
   - Sửa các đường dẫn tuyệt đối đã lưu trong DB nếu có trỏ vào `Application Support/Mercury`. Cần kiểm tra các bảng account (profile dir) và setting. Làm bằng một migration GRDB mới (`v7_rename_paths`); migrator vốn đã backup DB trước khi chạy.
2. **Defaults**:
   - Đọc `UserDefaults(suiteName: "com.tekmium.mercury")` rồi copy các key app dùng (`fileTree.expandedFolders`, thứ tự tab, cài đặt cửa sổ…) sang domain mới.
   - Không xoá domain cũ ngay, để còn rollback được.
3. **Theme và cài đặt có giá trị chứa tên cũ**: `mercury-light` → `sevinda-light`, `mercury-dark` → `sevinda-dark`.
4. **Helper PTY cũ** (`com.tekmium.mercury.ptyhost`), theo quyết định ở phase 1. Khuyến nghị cách (b):
   - Kết nối helper cũ qua XPC: Mach service cũ, requirement là app Mercury cũ cùng Team ID. Nếu kết nối không được thì bỏ qua bước này.
   - Liệt kê session. Gửi SIGHUP/terminate cho các session thuộc data root vừa migrate, đúng quy tắc "không để process mồ côi" của repo.
   - Đánh dấu các record đó là ended, để người dùng thấy màn "Session Ended" có nút Start Again.
   - Unregister LaunchAgent cũ. SMAppService chỉ unregister được dịch vụ của chính bundle đó, nên nếu không được thì hướng dẫn người dùng gỡ ở System Settings › Login Items.
   - Không giết helper nếu nó còn host session của data root khác.
5. **Skill đã cài vào Claude** (chỉ khi người dùng đã bật toggle ở Settings › Agents): xoá `~/.claude/skills/mercury-orchestration` và cài `sevinda-orchestration`. Đây là ngoại lệ đã được ghi trong Privacy policy. Nếu toggle đang tắt thì không đụng tới `~/.claude`.
6. **Thư mục tạm** `mercury-orch-*`: cứ để hệ thống tự dọn, helper mới tạo `sevinda-orch-*`.
7. **Managed account**: profile dir chuyển theo thư mục dữ liệu ở bước 1.
   - Kiểm tra item Keychain do Mercury tự tạo cho account được quản lý, nếu có: tên service và access group có chữ Mercury không.
   - Nếu có thì copy sang tên mới, giữ item cũ cho tới khi xác nhận xong. Không bao giờ đụng item `Claude Code-credentials` mặc định.
8. **Thông báo một lần**: banner hoặc sheet nhỏ "Mercury is now Sevinda — your workspaces and settings came along."

## Test
- Unit test với một thư mục `Application Support` giả: có Mercury, không có Sevinda → chuyển đúng, DB mở được, đường dẫn trong DB được sửa, backup tồn tại.
- Chạy lại lần hai là no-op (idempotent).
- Đã có cả hai thư mục → không ghi đè, ghi log cảnh báo.
- Kiểm tra map defaults và theme.
- Chạy thật trên máy dev: bản Mercury có dữ liệu thật → mở Sevinda → kiểm tra workspace, account, pane layout, cài đặt.

## Xong khi
- Mọi test ở trên qua. Trên máy dev không còn process `MercuryPTYHost`, và Login Items không còn mục Mercury.

## Rollback
- Xoá `Application Support/Sevinda`, đổi tên `Mercury.backup-<ngày>` về lại `Mercury`, mở lại bản Mercury cũ. Defaults domain cũ vẫn còn nguyên.
