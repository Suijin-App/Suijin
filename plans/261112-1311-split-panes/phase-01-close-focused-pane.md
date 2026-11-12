# Phase 1 — ⌘W chỉ đóng pane đang focus

## Tái hiện (bắt buộc trước khi sửa)
1. Test app: tạo tab shell, `split(…)` → 2 pane; đặt first responder vào pane chính bằng **mỗi** đường focus hiện có
   (`window.makeFirstResponder`, `focusActiveTerminalAfterClick`, `FocusingContainer.viewDidMoveToWindow`, click mô phỏng),
   rồi gọi lệnh ⌘W (`MercuryCommands` Close Tab + `handle(.closeTab)` từ terminal); kiểm tra pane nào đóng.
2. Ngược lại với focus ở pane phụ.
3. Ghi lại đường nào làm `focusedPane` lệch với first responder thật.

## Hướng sửa (chọn theo kết quả tái hiện)
- Nguồn sự thật duy nhất cho pane focus = first responder thật: `activeSession` hỏi `mainWindow.firstResponder` (terminal view nào thuộc tab) trước,
  `focusedPane` chỉ là giá trị nhớ khi cửa sổ không key; mọi đường focus mới đi qua một hàm `focusPane(_:)` cập nhật cả hai.
- ⌘W trong pane: đóng pane đó (agent bận → xác nhận như cũ); pane cuối cùng → đóng tab.

## File
`App/Features/Terminal/SessionActions.swift`, `TerminalFocus.swift`, `TerminalPane.swift`, `MercuryApp.swift` (Close Tab), test mới `AppTests/PaneCloseTests.swift`.

## Kiểm tra
Test tái hiện đỏ trước, xanh sau; probe app thật ⌘W với focus từng pane.
