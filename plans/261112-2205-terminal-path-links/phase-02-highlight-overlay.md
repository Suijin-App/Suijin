---
phase: 2
title: Lớp highlight và hover
status: done
depends_on: [1]
---

# Phase 2: Highlight

## Mục tiêu
Path đã xác minh tồn tại có một gạch chân mờ màu accent. Khi rê chuột vào thì gạch chân đậm hơn và con trỏ thành bàn tay. Không sửa buffer của terminal, không làm chậm feed.

## File
- Mới: `Packages/SevindaTerminal/Sources/SevindaTerminal/TerminalLinkOverlay.swift`. Đây là NSView hoặc CALayer gắn trên `SevindaTerminalView`, dưới caret.
  - `hitTest` trả nil để không nhận click. Cuộn, chọn chữ và focus pane giữ nguyên.
  - Ghi comment giải thích vì sao cần view riêng: SwiftTerm không có API trang trí dải ô.
- Sửa: `SevindaTerminalView.swift`.
  - Cung cấp danh sách dòng đang hiện, kèm cờ wrap, cho detector.
  - Báo khi nội dung đổi (đã có `rangeChanged`) và khi cuộn (`scrolled`).
- Sửa: `TerminalPane.swift`. Nối detector với resolver và đẩy kết quả vào overlay.

## Cách quét
- Debounce: quét sau khoảng 120 ms kể từ lần nội dung đổi cuối, và ngay khi cuộn xong.
- Bỏ qua lúc `isReplayingScrollback`, lúc view không nằm trong window, và lúc tab bị ẩn.
- Giới hạn: chỉ quét các dòng đang hiện, tối đa 2 ms trên main thread để lấy chữ. Phần kiểm tra file tồn tại chạy ngoài main thread. Kết quả quay về main thread rồi mới vẽ.
- Tính toạ độ: ô (row, col) → rect, dựa trên kích thước ô của font hiện tại. Khi font, kích thước hoặc theme đổi thì tính lại.
- Dòng bị wrap: vẽ gạch chân trên từng đoạn của từng dòng.

## Hover
- Tracking area hoặc cơ chế mouseMoved sẵn có của SwiftTerm. Không bật `acceptsMouseMovedEvents` thêm lần nữa nếu SwiftTerm đã bật.
- Rê vào match: gạch chân đậm, con trỏ bàn tay, và hiện tooltip là path đầy đủ đã resolve (hữu ích khi path trên màn là path tương đối).
- Khi TUI đang bật mouse reporting: vẫn highlight, nhưng chỉ hiện con trỏ bàn tay khi giữ ⌘, đúng quy tắc click ở phase 3.

## Không được hỏng
- Metal renderer: overlay phải nằm trên MTKView. Khi Metal bị gỡ lúc tab ẩn và gắn lại lúc tab hiện, overlay cũng phải theo.
- Khung tìm kiếm ⌘F, caret, vùng chọn: overlay không che các thứ này.
- Cảm giác cuộn: overlay chỉ cập nhật sau khi cuộn xong, hoặc dịch theo offset, không vẽ lại liên tục.

## Test và đo
- Test đơn vị: chuyển đổi ô → rect; debounce không quét khi feed liên tục (mô phỏng 1000 chunk).
- Đo: chạy `yes | head -c 50M` và một build log dài. CPU của main thread không tăng đáng kể so với baseline, và không quét lượt nào giữa lúc output đang chảy.

## Xong khi
Highlight hiện đúng trên shell, Claude Code và Codex, cả chế độ sáng và tối, cả bật lẫn tắt Metal. Chụp ảnh bằng window id, chỉ chụp khi app đang active.
