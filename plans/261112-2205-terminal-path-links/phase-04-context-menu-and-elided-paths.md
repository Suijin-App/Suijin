---
phase: 4
title: Menu chuột phải và path bị cắt
status: done
depends_on: [3]
---

# Phase 4: Menu chuột phải và path bị cắt

## Mục tiêu
Chuột phải lên một path thì hiện các hành động liên quan tới path đó. Với path bị cắt, người dùng tìm được path đầy đủ và mở ngay trong tab mới.

## Menu
- Override `menu(for:)` trong `SevindaTerminalView`:
  - Nếu chuột phải đúng vào một match, thêm nhóm mục cho path ở đầu menu.
  - Sau nhóm đó là menu terminal hiện có. Kiểm tra SwiftTerm có menu mặc định không, và đang có những mục nào.
- Với path đầy đủ, đã xác minh:
  - **Open** (`↩`): mở trong viewer, hoặc hiện trong cây file nếu là thư mục.
  - **Open in New Tab**: luôn mở tab viewer mới, kể cả khi file đã mở ở tab khác.
  - **Open With Default App**
  - **Reveal in File Tree**: mở inspector ở tab Files.
  - **Show in Finder**: đã chốt giữ, là lựa chọn chủ động của người dùng.
  - **Copy Path**, **Copy Relative Path** (so với gốc worktree), **Copy Path with Line** (nếu có `:line`).
- Với path bị cắt (elided):
  - **Find Full Path…**: mở popover, neo tại vị trí chuột.
    - Trong lúc tìm: hiện tiến trình.
    - Có ứng viên: hiện danh sách gồm path đầy đủ, rút gọn theo gốc worktree, và icon file. Chọn một mục rồi nhấn Open thì mở trong tab mới. Chỉ có đúng một ứng viên thì vẫn hiện để xác nhận, kèm nút Open.
    - Không có ứng viên: dùng ContentUnavailableView "No matching file in this workspace".
  - **Copy Text**: copy nguyên chuỗi đang hiển thị.
- URL web: **Open Link**, **Copy Link**.
- Path chưa xác minh (không tồn tại): chỉ có Copy Text. Không có mục mở nào.
- Nhãn ngắn gọn, có icon SF Symbols, chuỗi đưa vào String Catalog.

## Mouse reporting
- Khi TUI bật mouse reporting và chuột phải đúng vào một match: hiện menu path, không gửi chuột phải vào chương trình.
- Chuột phải chỗ khác: giữ nguyên hành vi hiện tại.

## Test
- `menu(for:)` dựng đúng các mục cho từng loại: full, elided, không tồn tại, thư mục.
- Find Full Path với repo tạm:
  - 0 ứng viên;
  - 1 ứng viên;
  - nhiều ứng viên, xếp hạng đúng;
  - thư mục thường không phải git;
  - giới hạn số mục duyệt được tôn trọng.
- Chạy app thật: chụp menu và popover bằng window id, ở chế độ sáng và tối.

## Xong khi
Menu và popover hoạt động như trên, không ảnh hưởng tới menu Copy/Paste vốn có.
