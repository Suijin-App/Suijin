---
title: Split panes — tối đa 10 pane mỗi tab, lưu lại, kéo-thả đổi vị trí
created: 2026-11-12
status: in-progress
base-commit: f16f167
---

# Split panes

## Kết quả mong muốn
Một tab có thể chứa **1–10 pane terminal** xếp ngang/dọc lồng nhau. Người dùng:
- thêm pane bằng **nút nhỏ trên title bar**, ⌘D (phải) / ⇧⌘D (dưới), menu chuột phải;
- chọn **agent của pane mới** theo Settings (giống pane đang focus / Shell / Claude Code / Codex), và có thể chọn khác ngay lúc thêm;
- **resize** bằng vạch chia, **đóng riêng** từng pane (✕ trên header pane hoặc ⌘W chỉ đóng pane đang focus);
- **kéo-thả đổi vị trí** pane mượt và rõ: kéo header pane → vùng thả hiện trên pane đích (trái/phải/trên/dưới/giữa) với khung xem trước, thả là layout chuyển động tới vị trí mới;
- mở lại app thì **bố cục, kích thước, pane focus đều được giữ**.

## Quyết định của người dùng (2026-11-12)
- Pane mới mặc định chạy **giống pane đang focus** (đổi được trong Settings và từng lần qua menu nút split).
- Thả vào **giữa** pane khác = **hoán đổi** hai pane (giữ kích thước); thả vào cạnh = đặt bên cạnh.
- Sidebar: session cùng tab **gom dưới một hàng tab** (icon split + số pane), pane thụt lề; click pane → focus pane đó.
- Làm ngay, commit theo từng phase.

## Hiện trạng (đã đọc code, commit f16f167)
- `AppModel.splits: [UUID: TerminalSplit]` — tối đa 1 pane phụ/tab, chỉ trong bộ nhớ (mất khi mở lại).
- `SplitTerminalView` dùng `HSplitView`/`VSplitView`; không lưu tỉ lệ; pane phụ luôn là shell (`SessionActions.split`).
- `focusedPane[tab]` chỉ cập nhật qua `MercuryTerminalView.onFocus`; ⌘W → `closeActive` → `activeSession` dựa vào nó.
- **Bug**: ⌘W đóng cả tab thay vì pane đang focus (pane chính đóng → pane phụ tách thành tab riêng). Nghi do các đường focus mới
  (`SidebarClickFocus`, `FocusingContainer`, `focusActiveTerminalAfterClick`) đặt first responder mà không cập nhật `focusedPane`,
  hoặc `onFocus` không bắn khi click pane đã là first responder. Phải tái hiện bằng test trước khi sửa (phase 1).

## Ràng buộc
- Native trước: vạch chia dùng `NSSplitView` (qua representable) để có resize hệ thống, con trỏ, double-click cân bằng; chỉ phần
  vùng thả/khung xem trước là custom (không có control hệ thống) — ghi lý do trong comment.
- Liquid Glass thật cho nút title bar, header pane (khi hover), khung xem trước; sáng/tối; accessibility đầy đủ.
- Không phá các luồng đã có: kéo-thả **tab** (payload khác loại), chọn text trong terminal (chỉ kéo từ header), focus sau click sidebar,
  ⌘W cho tab file, xác nhận đóng agent đang chạy, resize PTY gộp (coalesced) khi kéo vạch, orchestration worker.
- Migration DB mới phải backup trước (cơ chế backup tự động đã có — giữ nguyên).
- Hiệu năng: 10 pane hiển thị cùng lúc phải mượt (Metal mỗi pane ~25–40 MB; pane ẩn đã trả GPU); kéo-thả 60 fps.

## Phím tắt (đã rà xung đột 2026-11-12)
Đang dùng trong app: ⌘T ⌥⌘T ⌘N ⌘W ⇧⌘O ⌥⌘I ⌥⇧⌘G ⌘D ⇧⌘D ⌘0 ⌘= ⌘- ⇧⌘[ ⇧⌘] ⌘, ⌘↩. Mới: ⇧⌘↩ (zoom pane), ⌃⌘= (equalize),
⌥⌘←→↑↓ (focus pane), ⌃⌥⌘←→↑↓ (move pane) — không trùng. Các tổ hợp mũi tên phải đi qua `TerminalKeyRouting` để Mercury bắt
trước terminal (không gửi chuỗi escape vào agent).

## Ngoài phạm vi
Kéo pane sang **tab khác** hoặc **cửa sổ khác** (chỉ "Move Pane to New Tab" qua menu); broadcast input nhiều pane; layout mẫu đặt sẵn.

## Tiêu chí chấp nhận
- [ ] ⌘W chỉ đóng pane đang focus; test tái hiện bug trước khi sửa, sau sửa xanh.
- [ ] Thêm tới 10 pane bằng nút/⌘D/⇧⌘D/menu; pane thứ 11 bị chặn với lời giải thích (tooltip + nút mờ).
- [ ] Settings có "New pane runs": Same as focused pane (mặc định) / Shell / Claude Code / Codex; menu của nút cho chọn khác từng lần.
- [ ] Resize mượt, tỉ lệ được lưu; double-click vạch chia → chia đều; "Equalize Panes".
- [ ] Đóng pane bằng ✕ header/⌘W/menu; còn 1 pane thì tab trở lại bình thường.
- [ ] Kéo header pane: vùng thả 5 hướng + khung xem trước + animation; thả ngoài/huỷ (Esc) không đổi gì; có cách bàn phím/menu tương đương.
- [ ] Mở lại app: bố cục, tỉ lệ, pane focus khôi phục; session đã chết hiện màn "ended" trong đúng ô.
- [ ] Sidebar: session trong cùng tab hiển thị gom dưới tab; click → chọn tab + focus đúng pane.
- [ ] Test model/persistence/command; probe kéo-thả và ⌘W trên app thật; ảnh chụp 1/2/4/10 pane sáng/tối; CI xanh.

## Phase
| # | Phase | File | Phụ thuộc |
|---|---|---|---|
| 1 | Sửa bug ⌘W đóng cả tab (tái hiện → sửa) | [phase-01-close-focused-pane.md](phase-01-close-focused-pane.md) | — |
| 2 | Mô hình layout pane + lưu DB + khôi phục | [phase-02-pane-layout-model.md](phase-02-pane-layout-model.md) | 1 |
| 3 | Container pane: NSSplitView lồng nhau, header, focus, resize, đóng | [phase-03-pane-container-ui.md](phase-03-pane-container-ui.md) | 2 |
| 4 | Thêm pane: nút title bar, menu, phím tắt, Settings agent | [phase-04-add-pane-controls.md](phase-04-add-pane-controls.md) | 3 |
| 5 | Kéo-thả đổi vị trí (vùng thả, xem trước, animation, bàn phím) | [phase-05-drag-rearrange.md](phase-05-drag-rearrange.md) | 3 |
| 6 | Kiểm chứng: test, probe app thật, ảnh, hiệu năng 10 pane, CI | [phase-06-verification.md](phase-06-verification.md) | 4, 5 |

Phase 4 và 5 làm song song được (file tách riêng; chỉ cùng dùng API layout của phase 2).
