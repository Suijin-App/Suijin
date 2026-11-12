---
phase: 3
title: "Terminal engine"
status: pending
priority: P1
effort: "5d"
dependencies: [2]
---

# Phase 3: Terminal engine

## Goal

Terminal local nhanh, có tab và split, chạy shell của người dùng trong thư mục worktree, bọc sau protocol `TerminalEngine`.

## Key insights

- Capstio dùng SwiftTerm 1.11.2 qua SSH: `CapstioTerminalView: TerminalView` trong `~/Works/Capstio/App/Features/Terminal/SSHTerminalView.swift`. Thư mục này có khoảng 3.200 dòng: paste guard, key routing, split, tab, theme, shell integration, command history.
- SwiftTerm có `LocalProcessTerminalView` (`Sources/SwiftTerm/Mac/MacLocalTerminalView.swift`) để chạy PTY local.
- Tag SwiftTerm hiện có: 1.12 → 1.20, và 1.99.0–1.99.3 (ngày 2026-11-10 vẫn đang commit). Bản mới có `Apple/Metal/` và build-tool plugin `SwiftTermBuildInfoPlugin`, nên `xcodebuild` cần `-skipPackagePluginValidation` hoặc trust plugin, và cần Metal Toolchain.
- Claude Code và Codex là TUI vẽ lại liên tục; hiệu năng render là rủi ro chính.

## Architecture

- Package `MercuryTerminal`:
  - `protocol TerminalEngine` gồm start(command, cwd, env), write, resize, onOutput, onExit, terminate.
  - `SwiftTermEngine` hiện thực bằng `LocalProcess` + `TerminalView`.
- Ở phase này PTY nằm trong process app. Phase 7 chuyển PTY sang helper mà không đổi protocol.
- Shell integration: tự sinh `ZDOTDIR` của Mercury, source `.zshrc` của người dùng rồi mới thêm hàm của Mercury. Bash dùng `--rcfile`. Fish để sau.
- Shell được mở dưới dạng login shell để có đúng `PATH` (nvm, Homebrew).

## Files to create / modify

- `Mercury/Packages/MercuryTerminal/Sources/MercuryTerminal/{TerminalEngine,SwiftTermEngine,ShellLaunch,ShellIntegration}.swift`.
- `Mercury/App/Features/Terminal/` — port từ Capstio: `TerminalTabsView`, `SplitTerminalView`, `PasteGuard`, `TerminalKeyRouting`, `TerminalTheme`, `TerminalThemePicker`, `TerminalSessionModel` (bỏ phần SSH).

## Tasks & steps

1. Spike 1 ngày: build SwiftTerm bản mới nhất ổn định với Xcode 27. Đo FPS và CPU khi chạy `claude` cùng một lệnh xả output lớn (ví dụ `yes | head -n 2000000`). Chọn và **ghim chính xác** một version; ghi lý do vào `project.yml` như Capstio làm.
2. Định nghĩa `TerminalEngine` và viết `SwiftTermEngine`.
3. Port lớp bọc terminal từ Capstio; thay nguồn SSH bằng PTY local.
4. Tab và split theo từng worktree; mở terminal mới thì `cwd` là worktree.
5. Thu hồi process khi đóng tab: SIGHUP, chờ, rồi SIGKILL nếu cần; không để process mồ côi.

## Verification

- Mở 10 terminal, chạy lệnh xả output lớn ở cả 10; UI không đứng, CPU app ở mức chấp nhận được (ghi số đo vào plan).
- Paste nhiều dòng thì paste guard hỏi xác nhận.
- Đóng tab thì `ps` không còn process con.
- `vim`, `htop`, `claude` hiển thị đúng; gõ tiếng Việt bằng bộ gõ hệ thống đúng.

## Risks

- SwiftTerm 1.99.x có thể là bản tiền 2.0 với API thay đổi. Cách giảm rủi ro: ghim version, mọi chỗ gọi SwiftTerm nằm sau `TerminalEngine`.
- Nếu hiệu năng không đạt, có thể cân nhắc libghostty sau, chỉ thay phần hiện thực protocol.
