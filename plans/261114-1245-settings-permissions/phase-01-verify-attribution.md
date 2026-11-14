---
phase: 1
title: Xác minh cách macOS tính quyền
depends_on: []
status: pending
---

# Phase 1 — Xác minh cách macOS tính quyền

## Bối cảnh

Agent và shell không chạy trong tiến trình app mà chạy dưới `SuijinPTYHost`, một LaunchAgent do launchd khởi động, có `AssociatedBundleIdentifiers = com.tekmium.suijin`. Chưa ai kiểm chứng TCC tính quyền truy cập file của các tiến trình con đó cho `Suijin.app` hay cho `SuijinPTYHost`. Viết code kiểm tra trước khi biết điều này là đoán.

Phase này chỉ thử nghiệm và ghi kết quả. Không sửa code sản phẩm.

## Câu hỏi phải trả lời

1. Khi một shell trong Suijin đọc thư mục được bảo vệ, hộp thoại của macOS ghi tên app nào, và mục nào xuất hiện trong System Settings › Privacy & Security › Files and Folders / Full Disk Access?
2. Bật Full Disk Access cho `Suijin.app` thì shell trong Suijin có đọc được không? Nếu không, phải bật cho mục nào?
3. Phép thử nào cho kết quả đúng ở cả hai trạng thái (đã cấp, chưa cấp) mà không làm hiện hộp thoại?
4. Phép thử chạy trong tiến trình app có cho cùng kết quả với phép thử chạy trong helper không?

## Các bước

1. Dùng bản build Debug hiện tại, chưa cấp Full Disk Access cho Suijin. Mở một shell trong Suijin và chạy:
   ```
   ls ~/Library/Mail
   ls ~/Library/Safari
   ls ~/Library/Application\ Support/com.apple.TCC
   ls ~/Desktop
   ```
   Ghi lại: lệnh nào bị từ chối, lệnh nào làm hiện hộp thoại, hộp thoại ghi tên gì.
2. Mở System Settings › Privacy & Security, ghi lại mục nào vừa xuất hiện và dưới tên gì.
3. Bật Full Disk Access cho `Suijin.app`, mở shell mới, chạy lại bước 1. Nếu vẫn bị chặn, thử bật cho helper (kéo file `Suijin.app/Contents/MacOS/SuijinPTYHost` vào danh sách) và chạy lại.
4. Thử phép kiểm tra từ tiến trình app bằng một đoạn Swift tạm (không commit): `FileManager.default.isReadableFile(atPath:)` và thử mở file thật trên các đường dẫn ở bước 1. So với kết quả của shell ở cùng trạng thái.
5. Ghi kết quả vào mục "Kết quả" bên dưới và chốt quyết định D4 trong `plan.md`.

## Kết quả

Thử ngày 2026-11-14 trên macOS 27.2.1, bản Debug trong DerivedData, chưa cấp Full Disk Access.

- **Cả hai nơi đều bị chặn như nhau.** Tiến trình app và một tiến trình do helper khởi động đều nhận lỗi "Operation not permitted" khi liệt kê `~/Library/Safari`, `~/Library/Mail`, `~/Library/Messages`.
- **Phép thử cũ không dùng được.** `~/Library/Application Support/com.apple.TCC/TCC.db` không báo "bị từ chối" mà báo "không tồn tại" khi chưa có quyền, nên không phân biệt được với máy không có file đó.
- **Phép thử được chọn:** liệt kê lần lượt ba thư mục trên; thư mục đầu tiên tồn tại quyết định kết quả. Liệt kê được là đã cấp; thấy thư mục nhưng không liệt kê được là chưa cấp; không thư mục nào tồn tại là không rõ.
- **Nơi chạy phép thử (chốt D4):** trong một tiến trình do helper khởi động qua lệnh `spawn` sẵn có, rồi đọc mã thoát từ `listSessions`. Đó đúng là cách agent và shell chạy, nên kết quả khớp với thứ agent thực sự đọc được, bất kể macOS ghi quyền dưới tên nào. Cách này không thêm lệnh XPC, không đổi `protocolVersion`, và chạy được với helper cũ. Khi helper không dùng được (session chạy trong app) thì thử ngay trong app.
- **Chưa xác minh được:** macOS ghi quyền dưới tên `Suijin.app` hay `SuijinPTYHost` trong danh sách Full Disk Access. Nhật ký TCC không đọc được nếu không có quyền quản trị, và bật quyền thì cần người dùng thao tác trong System Settings. Tình huống 7 của phase 4 sẽ trả lời câu này.
- **Trang System Settings:** `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles`; nếu macOS không nhận thì mở System Settings chung.

## Tiêu chí xong

- Bốn câu hỏi trên có câu trả lời dựa trên thử nghiệm thật, không phải suy luận.
- D4 trong `plan.md` được chốt: kiểm tra trong app, hay thêm một lệnh XPC để helper tự kiểm tra.

## Rủi ro

Bản Debug ký bằng Apple Development và nằm trong DerivedData; TCC ghi nhận theo chữ ký và đường dẫn, nên kết quả có thể khác bản Release cài trong `/Applications`. Ghi rõ bản nào được thử; nếu kết quả phụ thuộc vào điều đó thì thử lại trên bản Release trước khi đóng phase 4.

## Rollback

Không có gì để rollback. Thu hồi các quyền vừa cấp trong System Settings nếu muốn máy trở lại trạng thái ban đầu.
