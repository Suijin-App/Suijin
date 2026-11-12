---
phase: 4
title: "Worktree và phiên agent"
status: pending
priority: P1
effort: "5d"
dependencies: [3]
---

# Phase 4: Worktree và phiên agent

## Goal

Từ một repo, tạo worktree với branch mới, rồi chạy Claude Code hoặc Codex trong đó. Mỗi phiên có trạng thái rõ ràng (đang chạy, chờ input, xong, lỗi).

## Architecture

- Package `MercuryGit`: wrapper `git` CLI qua `Process`, chỉ dùng output dạng máy đọc được (`--porcelain`, `-z`).
  - `git worktree add -b <branch> <path> <base>`, `git worktree list --porcelain`, `git worktree remove`, `git worktree prune`.
  - Thư mục worktree mặc định: `<repo>/../<repo>-worktrees/<branch>`, cho phép đổi trong Settings.
- Package `MercuryAgents`:
  - Danh mục agent: `claude`, `codex` (đường dẫn binary dò từ login shell `PATH`; máy dev hiện có `~/.local/bin/claude` 2.1.322 và `~/.local/bin/codex` 0.166.0).
  - `AgentLaunchSpec` gồm binary, args, cwd và env patch. Env patch về tài khoản do phase 5–6 cung cấp.
- Trạng thái agent:
  - Bản đầu: dựa vào process (đang chạy/thoát, exit code) và thời gian không có output.
  - Claude Code hooks (như `src/main/claude/hook-service.ts` của Orca) để biết chính xác "chờ input". Cài hook vào profile của Mercury, không sửa `~/.claude/settings.json` của người dùng.
- Thông báo macOS (`UserNotifications`) khi agent chờ input hoặc kết thúc.

## Files to create

- `Mercury/Packages/MercuryGit/Sources/MercuryGit/{GitRunner,Worktree,Branch}.swift` + tests dùng repo tạm.
- `Mercury/Packages/MercuryAgents/Sources/MercuryAgents/{AgentCatalog,AgentLaunchSpec,AgentStatus,ClaudeHooks}.swift`.
- `Mercury/App/Features/Worktrees/{NewWorktreeSheet,WorktreeRow,WorktreeInspector}.swift`.

## Tasks & steps

1. `MercuryGit` + test với repo tạo trong thư mục tạm.
2. Sheet tạo worktree: tên branch, base branch, agent chọn sẵn, prompt đầu tiên (tuỳ chọn).
3. Chạy agent trong terminal của worktree qua `TerminalEngine`.
4. Trạng thái agent trên sidebar (SF Symbol + màu token).
5. Xoá worktree: cảnh báo nếu còn thay đổi chưa commit; dừng phiên trước khi xoá thư mục.
6. Hook Claude cho trạng thái "chờ input", kèm thông báo.

## Verification

- `swift test --package-path Packages/MercuryGit` pass.
- Tạo 5 worktree, mỗi worktree một agent; trạng thái hiện đúng; thông báo hiện khi agent hỏi.
- Xoá worktree không để lại process hay thư mục mồ côi; `git worktree list` khớp với sidebar.
- Thêm một thư mục thường (không có `.git`), chạy 2 agent trong đó; trạng thái và thông báo vẫn đúng; không có nút tạo worktree.

## Folder workspace (thư mục không phải git)
<!-- Updated: user request - support both git repos and plain folders -->

- Workspace loại `folder` không có worktree. Agent chạy thẳng trong thư mục đó.
- Có thể mở nhiều phiên trong cùng thư mục. App cảnh báo rằng các agent sẽ sửa chung file vì không có cách ly.
- Mọi code dùng chung (sidebar, phiên, trạng thái, tài khoản) chạy theo khái niệm "workspace", không giả định có git. Chỉ phần tạo/xoá worktree mới cần `kind == git`.
- Khi đã hỗ trợ được: nếu người dùng chạy `git init` trong thư mục, app nhận ra và đổi workspace sang loại `git` (kiểm khi mở app và khi thư mục đổi).

## Risks

- Hai agent cùng sửa một thư mục thường có thể đè nhau. Giảm rủi ro bằng cảnh báo rõ trong UI, không chặn.
