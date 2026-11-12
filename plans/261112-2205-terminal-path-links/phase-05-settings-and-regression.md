---
phase: 5
title: Cài đặt, hồi quy, hiệu năng
status: pending
depends_on: [4]
---

# Phase 5: Cài đặt và kiểm chứng

## Cài đặt (Settings › Terminal)
- **Highlight file paths:** mặc định bật. Tắt thì không quét, không vẽ overlay, không có hành vi click mới. Menu chuột phải cũng trở về như cũ.
- **Open paths with:** ⌘-Click (mặc định) hoặc Click.
- Thêm vào `ShortcutCatalog` nhóm Mouse: "Open a path or link — ⌘-click" và "Path actions — right-click". Test chống lệch giữa danh sách phím tắt và code hiện có vẫn phải qua.
- Onboarding: nếu bước Sessions đang nói "⌘-click a path" thì sửa lại cho khớp.

## Hồi quy
Chạy app thật trên dữ liệu tạm, mỗi mục ghi pass/fail vào báo cáo:
- [ ] Bôi chọn bằng kéo, double-click chọn từ, triple-click chọn dòng, Shift-click mở rộng vùng chọn
- [ ] ⌘C/⌘V, cảnh báo paste nhiều dòng
- [ ] TUI có mouse reporting (vim với `:set mouse=a`, htop, Codex): click và cuộn vẫn tới chương trình
- [ ] ⌘-click link web và link OSC 8
- [ ] ⌘F
- [ ] Click để focus pane, kéo header pane, ⇧⌘↩ phóng to pane
- [ ] Metal bật và tắt; chuyển tab ẩn rồi hiện lại
- [ ] Phát lại scrollback lúc khởi động không chậm hơn
- [ ] Tắt "Highlight file paths" thì mọi thứ y như trước

## Hiệu năng
So với baseline, tức commit ngay trước phase 1:
- Feed liên tục `yes | head -c 50M` và một build log dài: thời gian chạy và CPU của main thread.
- Mỗi lượt quét: đo bằng `os_signpost`, phải ≤ 2 ms.
- Footprint khi có 4 pane đang mở.

## Xong khi
- `scripts/ci-local.sh` xanh, không có cảnh báo.
- Checklist hồi quy pass hết.
- Có số đo hiệu năng trong báo cáo.
- Có ảnh chụp highlight, hover, menu và popover, ở chế độ sáng và tối.
- Commit theo từng phase, không push.
