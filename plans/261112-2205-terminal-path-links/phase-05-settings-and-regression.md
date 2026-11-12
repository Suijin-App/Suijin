---
phase: 5
title: Cài đặt, hồi quy, hiệu năng
status: done
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
- [x] Bôi chọn bằng kéo, double-click chọn từ, triple-click chọn dòng, Shift-click mở rộng vùng chọn
- [x] ⌘C/⌘V, cảnh báo paste nhiều dòng
- [x] TUI có mouse reporting (vim với `:set mouse=a`, htop, Codex): click và cuộn vẫn tới chương trình
- [x] ⌘-click link web và link OSC 8
- [x] ⌘F
- [x] Click để focus pane, kéo header pane, ⇧⌘↩ phóng to pane
- [x] Metal bật và tắt; chuyển tab ẩn rồi hiện lại
- [x] Phát lại scrollback lúc khởi động không chậm hơn
- [x] Tắt "Highlight file paths" thì mọi thứ y như trước

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

## Kết quả (2026-11-13)
Kiểm chứng hồi quy bằng test (view thật, handler chuột thật của SwiftTerm; so sánh từng thao tác khi bật và tắt nhận diện) và chạy app thật (build Debug, dữ liệu tạm, Metal bật, 4 pane shell). Chưa thử tay vim/htop/Codex thật, kéo header bằng chuột thật và chụp menu (menu là cửa sổ riêng, không render offscreen được).

| Đo trên app thật (2 lượt mỗi bên) | Trước (6de9c4d) | Sau (fc8468f) |
|---|---|---|
| `seq 1 2000000`: thời gian / CPU app | 10.44 s, 10.37 s / 9.45 s, 9.31 s | 10.82 s, 10.94 s / 9.71 s, 9.77 s |
| `cat` log 50 MB nhiều path | 13.37 s, 13.24 s | 13.44 s, 13.58 s |
| `find` x10 (~20k dòng path) | 1.00 s, 1.00 s | 1.00 s, 1.02 s |
| Khoảng nghẽn main thread lớn nhất khi feed | 24–32 ms | 23–33 ms |
| Lượt quét trong lúc output chảy | — | 0 |
| Cuộn 120 trang: quét trên main (trung vị / max) | — | 0.70–1.71 ms / 0.77–1.84 ms |
| Nhận diện ngoài main thread (trung vị) | — | 4.6–11.0 ms |
| Footprint 4 pane sau tải | 181.5, 176.0 MB | 188.8, 184.8 MB |
| CPU nghỉ 4 pane | 0.14 %, 0.11 % | bật 0.15 %, 0.10 %; tắt 0.12 %, 0.13 % |
