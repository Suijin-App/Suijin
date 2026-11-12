---
phase: 3
title: Click để mở
status: done
depends_on: [2]
---

# Phase 3: Click để mở

## Mục tiêu
**Mặc định ⌘-click** vào path hoặc URL đã xác minh thì mở. Path mở trong app, URL mở bằng trình duyệt. Click trơn chỉ mở khi người dùng chọn chế độ "Click" trong Settings. Khi đó áp dụng bộ máy trạng thái bên dưới. Bôi chọn chữ và mouse reporting của TUI vẫn chạy như cũ.

## Thiết kế
- Can thiệp trong `SevindaTerminalView`: override `mouseDown`/`mouseUp`, rồi gọi `super` ở mọi nhánh mà path không xử lý.
  - Lúc mouseDown: ghi lại vị trí và match tại ô đó, sau đó vẫn gọi `super` để SwiftTerm làm việc bình thường (bắt đầu chọn chữ, gửi sự kiện cho TUI…).
  - Lúc mouseUp, nếu thoả hết các điều kiện sau thì mở path:
    - `clickCount == 1`;
    - chuột không dịch quá ngưỡng (khoảng 3 pt);
    - không có vùng chọn mới được tạo;
    - không có modifier nào khác ngoài ⌘;
    - match ở mouseDown trùng match ở mouseUp, và đã được xác minh;
    - chương trình **không** bật mouse reporting, hoặc người dùng đang giữ ⌘.
  - Khi đó gọi `onOpenPath(resolvedPath)`.
- Gom về một đường mở duy nhất: thêm `onOpenPath`, hoặc dùng lại `onOpenLink` với path đã resolve, rồi đi tới `AppModel.openTerminalLink`. Hàm này đã xử lý file viewer, thư mục (cây file), `:line` và Finder fallback.
  - Bổ sung: mở file ở đúng dòng `line` nếu viewer code hỗ trợ cuộn tới dòng. Nếu chưa có thì thêm hàm `scrollTo(line:)` trong code viewer.
- ⌘-click giữ hành vi cũ, nhưng path cũng đi qua resolver để có cùng cwd.
- Theo cài đặt "Open paths with: ⌘-Click" thì click trơn không mở gì, chỉ ⌘-click mới mở.

## Rủi ro và cách chặn
- **Mất thao tác bôi chọn bằng một click:** SwiftTerm vẫn nhận mouseDown/Up đầy đủ, ta chỉ thêm hành động sau mouseUp, và chỉ khi không có vùng chọn.
- **Click để focus pane** (pane khác đang có focus): click đầu tiên vào pane chưa focus chỉ focus thôi, không mở path. Click thứ hai mới mở. Tránh mở nhầm khi người dùng chỉ định chuyển pane.
- **Double-click:** mouseUp của click thứ nhất phải chờ hết `NSEvent.doubleClickInterval`, nếu không thì double-click chọn từ sẽ mở nhầm file. Có thể dời việc mở bằng một work item và huỷ nếu click thứ hai tới. SwiftTerm đã có cơ chế tương tự (`pendingSemanticClick`), nên tham khảo để không đụng nhau.
- **Kéo header pane:** sự kiện chuột xảy ra ở header, không vào terminal, nên không ảnh hưởng.

## Test
- Test đơn vị cho bộ máy trạng thái click (bảng ở `plan.md`): click đơn, kéo, double-click, có vùng chọn, mouse reporting có và không có ⌘, pane chưa focus, chế độ cài đặt ⌘-Click.
- Chạy app thật (dữ liệu tạm):
  - shell: `ls`, `git status`, `echo` path tuyệt đối và tương đối;
  - path có `:line`;
  - thư mục;
  - file ảnh;
  - file không xem được (phải ra Finder fallback).

## Xong khi
Mọi dòng trong bảng hành vi đều đúng, test xanh.
