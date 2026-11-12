# Phase 5 — Kéo-thả đổi vị trí (mượt, rõ ràng)

## Tương tác
1. Nhấn giữ + kéo **header** của pane (con trỏ openHand → closedHand). Bóng kéo = ảnh thu nhỏ header (logo + tên).
2. Pane nguồn mờ 50 % tại chỗ (biết mình đang kéo gì).
3. Rê lên pane đích: chia pane thành **5 vùng** — 4 dải cạnh (25 % mỗi phía) và **giữa**.
   - Cạnh: **khung xem trước** Liquid Glass tô accent phủ đúng nửa pane phía đó + nhãn nhỏ "Place left/right/above/below".
   - Giữa: khung phủ cả pane + nhãn "Swap".
   - Đổi vùng có animation 120 ms (spring), không nhấp nháy.
4. Thả → layout chuyển (animation `.snappy` 250 ms, các pane trượt tới vị trí mới, tỉ lệ cũ giữ khi có thể).
5. Esc / thả ngoài vùng / thả lên chính nó → không đổi gì, pane nguồn trở lại bình thường.
6. Thả lên **thanh tab** → "Move to New Tab" (vùng tab bar sáng lên khi rê vào).

## Cài đặt
- Payload riêng `UTType.mercuryPane` (khác payload kéo tab) → không xung đột kéo tab; kéo tab không nhận pane và ngược lại (trừ thả pane lên tab bar có chủ đích).
- Mỗi pane dùng `DropDelegate` để biết vị trí con trỏ → vùng; overlay xem trước vẽ trong `PaneTreeView` bằng `matchedGeometryEffect`/frame của pane đích.
- Thao tác model: `moving(_:to:edge:)`; giữ focus ở pane vừa kéo.
- **Tương đương bàn phím/menu** (accessibility + người không thích kéo): Move Pane ⌃⌥⌘←→↑↓ (đổi chỗ với pane bên cạnh), menu header "Move Pane ▸ Left/Right/Up/Down / to New Tab".
- VoiceOver: header là phần tử kéo được với hành động "Move left/right/up/down".

## Kiểm tra
Probe app thật (sự kiện chuột tổng hợp, cửa sổ key): kéo pane sang cạnh trái/phải/trên/dưới/giữa của pane khác → cây layout đúng;
Esc huỷ; kéo lên tab bar → tab mới. Ghi video ngắn (screencapture -v cửa sổ Mercury) để soát độ mượt.
