# Phase 3 — Container pane

## UI
- `PaneTreeView`: đệ quy theo `PaneNode`; split = `NSSplitView` representable (native divider, cursor, kéo mượt,
  double-click → chia đều), báo tỉ lệ về model (debounce lưu), tôn trọng min 160×90 pt mỗi pane.
- Mỗi pane: `TerminalPane` + **header mỏng** (chỉ khi tab có ≥ 2 pane): logo agent, tên, chấm trạng thái, nút ✕ (đóng pane),
  nút ⤢ (zoom/thu nhỏ), vùng kéo (toàn header, con trỏ openHand). Header hiện rõ khi hover hoặc pane focus, mờ khi không.
- Pane focus: viền accent mảnh + header đậm; pane khác hơi giảm độ tương phản (không làm mờ chữ).
- Zoom pane (⇧⌘↩ / ⤢): pane đó chiếm toàn view, badge "1 of N" trên header để quay lại.
- Equalize (⌃⌘=): chia đều toàn cây.
- Điều hướng focus: ⌥⌘←→↑↓ sang pane bên cạnh (`neighbor(of:direction:)`).
- Màn "ended"/"reconnecting" hiển thị trong đúng ô pane.

## Tránh xung đột
- Kéo vạch chia: PTY resize đã coalesced (120 ms) — giữ; Metal bật/tắt theo window không đổi.
- Kéo chọn text trong terminal không bị header bắt (header là vùng riêng phía trên).
- Focus sau click sidebar/tab chọn **pane focus đã lưu** của tab.

## File
`App/Features/Terminal/PaneTreeView.swift`, `PaneSplitView.swift` (NSSplitView representable), `PaneHeader.swift`, sửa `SessionTabsView.swift`
(thay `SplitTerminalView`), `TerminalPane.swift`, `MercuryApp.swift` (menu Session: Close Pane, Zoom Pane, Equalize, Focus Pane ←→↑↓).

## Kiểm tra
Ảnh app thật 2/4/10 pane sáng/tối; resize lưu lại sau mở app; zoom/equalize; điều hướng focus bằng phím.
