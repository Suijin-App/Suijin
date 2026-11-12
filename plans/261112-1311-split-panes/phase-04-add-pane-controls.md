# Phase 4 — Thêm pane: nút, menu, phím, Settings

- **Nút title bar** (Liquid Glass, cạnh nút +): icon `rectangle.split.2x1`; click = Split Right với agent theo Settings;
  menu (chevron/nhấn giữ): Split Right ⌘D, Split Down ⇧⌘D, mỗi mục có submenu agent (Same as Focused / Claude Code / Codex / Shell, kèm tài khoản nếu có).
  Mờ + tooltip "A tab holds up to 10 panes" khi đủ 10; ẩn khi tab là Changes/file.
- **Settings › Agents › "New pane runs"**: Same as focused pane (mặc định) / Shell / Claude Code / Codex; khoá `panes.defaultAgent`.
- **Menu chuột phải** (tab, session row, header pane): Split Right/Down, Move Pane to New Tab, Close Pane, Close Other Panes.
- **Session menu**: Split Right ⌘D, Split Down ⇧⌘D, Close Pane ⌘W, Zoom Pane ⇧⌘↩, Equalize ⌃⌘=, Focus Pane ⌥⌘←→↑↓, Move Pane ⌃⌥⌘←→↑↓.
- Pane mới chèn **cạnh pane đang focus** (không phải luôn ở cuối), nhận focus ngay.
- Sidebar: session thuộc layout gom dưới tab (icon `rectangle.split.2x1`, thụt lề); click → chọn tab + focus pane.

## Kiểm tra
Test: agent theo Settings/submenu, chèn đúng cạnh, chặn ở 10; ảnh nút/menu; phím tắt không trùng (rà `MercuryCommands`, `TerminalKeyRouting`).
