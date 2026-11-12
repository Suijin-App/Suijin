---
title: "Mercury — native macOS agent orchestrator"
description: "App native macOS (Swift 6, SwiftUI/AppKit) chạy nhiều coding agent Claude Code và Codex song song, mỗi agent một git worktree, có quản lý nhiều tài khoản và xem diff native."
status: pending
priority: P1
effort: 37d
branch: main
tags: [feature, macos, swift, terminal, infra]
blockedBy: []
blocks: []
created: 2026-11-11
---

# Mercury — native macOS agent orchestrator

## Overview

Mercury là sản phẩm riêng, lấy ý tưởng từ Orca (Electron, MIT) nhưng viết native: SwiftUI/AppKit, Liquid Glass thật trên macOS 26+, fallback macOS 15. Chỉ chạy local. Terminal dùng SwiftTerm; design system (copy vào `Packages/MercuryUI`) và lớp bọc terminal tái dùng từ Capstio (`~/Works/Capstio`). Cơ chế tài khoản Claude/Codex port từ Orca: mỗi tài khoản một `CLAUDE_CONFIG_DIR` / `CODEX_HOME`.

## Quyết định đã chốt

- Sản phẩm riêng, không phải module của Capstio. Brand color riêng. Ký dưới Tekmium (`com.tekmium.mercury`).
- UI chỉ tiếng Anh (vẫn dùng String Catalog).
- Chỉ local: không SSH, không remote host, không cloud VM.
- Terminal: SwiftTerm (bản có renderer Metal, ≥ 1.12), bọc sau protocol `TerminalEngine`.
- Diff viewer native bằng TextKit 2, không WKWebView.
- macOS 15+ có fallback; Liquid Glass thật (`.glassEffect`, `.buttonStyle(.glass)`) trên macOS 26+, không giả lập glass.
- Hỗ trợ cả repo git (có worktree, diff) lẫn thư mục thường (agent chạy thẳng trong thư mục, không có worktree/diff). Code dùng chung không giả định có git.
- State lưu bằng GRDB (SQLite). Git gọi qua CLI. Phát hành Developer ID + notarize + Sparkle.

## Non-goals (bản đầu)

Remote/SSH, app mobile, ghi chú theo dòng trên diff, diff hai cột, commit/PR từ app, orchestration coordinator → worker, tích hợp GitHub/Linear, plugin, trình duyệt tích hợp, Mac App Store (app không sandbox được).

## Phases

| # | Phase | Effort | Phụ thuộc |
|---|-------|--------|-----------|
| 1 | [Nền tảng dự án và design system](./phase-01-foundation.md) | 3d | — |
| 2 | [Khung app và lưu trạng thái](./phase-02-app-shell-and-state.md) | 4d | 1 |
| 3 | [Terminal engine](./phase-03-terminal-engine.md) | 5d | 2 |
| 4 | [Worktree và phiên agent](./phase-04-worktrees-and-agent-sessions.md) | 5d | 3 |
| 5 | [Tài khoản Claude](./phase-05-claude-accounts.md) | 6d | 4 |
| 6 | [Tài khoản Codex](./phase-06-codex-accounts.md) | 4d | 5 |
| 7 | [PTY host helper giữ phiên sống](./phase-07-pty-host-helper.md) | 5d | 3, 4 |
| 8 | [Diff viewer native](./phase-08-native-diff-viewer.md) | 3d | 4 |
| 9 | [Quy trình phát hành](./phase-09-release-pipeline.md) | 2d | 1–8 |

## Acceptance criteria (toàn plan)

- [x] Thêm một repo git, tạo worktree mới từ app, mở Claude Code hoặc Codex trong worktree đó.
- [x] Thêm một thư mục thường (không có git) và chạy agent trong đó.
- [x] Chạy ít nhất 5 agent song song mà UI vẫn mượt (cuộn terminal, đổi tab không giật).
- [ ] Thêm ≥ 2 tài khoản Claude và ≥ 2 tài khoản Codex, đổi tài khoản không cần đăng xuất, không đụng vào login gốc `~/.claude` / `~/.codex`.
- [ ] Thanh trạng thái hiện usage 5 giờ / 7 ngày của tài khoản đang chọn.
- [x] Thoát app rồi mở lại, phiên agent vẫn chạy và gắn lại được.
- [x] Xem diff của worktree với highlight cú pháp.
- [ ] Build Release ký Developer ID, notarize, cập nhật qua Sparkle.
- [x] Giao diện đạt quy tắc native-first và Liquid Glass thật, kiểm bằng ảnh chụp offscreen sáng/tối, cửa sổ hẹp/rộng.

## Kết quả triển khai (2026-11-11)

Đã code xong cả 9 phase. `scripts/ci-local.sh` xanh: 279 test package, 14 test app chạy trong app đã ký, không có cảnh báo biên dịch trong code Mercury, comment toàn tiếng Anh.

Bằng chứng cho từng tiêu chí đã đánh dấu:
- Worktree và thư mục thường: `AppTests/SessionFlowTests` tạo repo và worktree thật, khớp `git worktree list`, đổi `folder` → `git` sau `git init`. `AppTests/AgentSmokeTests` (bật bằng `TEST_RUNNER_MERCURY_AGENT_SMOKE=1`) chạy `claude` 2.1.322 và `codex` 0.166.0 thật qua PTY host; hook SessionStart của Claude ghi vào file sự kiện (quyền 600).
- Chạy song song: `AppTests/LoadTests` mở 10 terminal hiển thị cùng lúc, mỗi cái xả 400.000 dòng. Main thread chậm nhất 26 ms, bộ nhớ app 191 MB (bản Debug). Trước khi thêm bộ lập lịch có ngân sách thời gian và cơ chế ack giữa app và helper, con số là 50 s và 1,6 GB.
- Giữ phiên: test khởi động lại model gắn lại phiên kèm scrollback. Trên app thật, `kill -9` app thì helper và shell vẫn sống; mở lại thì app gắn lại.
- Diff và giao diện: ảnh chụp cửa sổ thật (`screencapture -l`), sáng/tối, hẹp/rộng. Ảnh chụp offscreen bỏ sót thanh bên và từng giấu một lỗi gutter vẽ đè chữ, nên mọi kiểm tra giao diện về sau phải chụp cửa sổ thật.

Còn mở, cần người dùng:
- Tài khoản và usage: logic có test trên thư mục tạm, nhưng chưa đăng nhập tài khoản thật. Cần thêm 2 tài khoản Claude và 2 tài khoản Codex rồi kiểm `/status` và thanh usage.
- Phát hành: dry-run ký Developer ID chạy thành công. Notarize thật, tạo khoá Sparkle, profile notarytool, chốt feed URL (`https://mercury.tekmium.com/appcast.xml` đang là chỗ giữ chỗ) và test cập nhật 0.1.0 → 0.1.1 cần người dùng đồng ý.

Quyết định của người dùng (2026-11-11): chưa chạy các bước phát hành (khoá Sparkle, notarize), để kiểm tài khoản thật sau, chưa commit. Feed URL sẽ đổi khỏi `mercury.tekmium.com` nhưng chưa có URL mới; cần cập nhật `SUFeedURL` trong `App/Info.plist` và `docs/release-process.md` khi có.

Hợp đồng giữa các package: `contracts.md`. Báo cáo từng phần: `plans/reports/*-261111-*.md`.

## Tham chiếu

- Orca (MIT), bản clone tạm: `/private/tmp/claude-501/-Users-vudev-Self-Works/d6ff3461-65f9-47e9-9351-560d6d375c15/scratchpad/repo/orca` — có thể bị xoá; clone lại từ `https://github.com/stablyai/orca`.
- Capstio: `~/Works/Capstio` (`Packages/CapstioUI`, `App/Features/Terminal`, `project.yml`, `docs/release-process.md`, `CLAUDE.md`).

## Validation Log

### Session 1 — 2026-11-11
- Design system: copy CapstioUI vào `Mercury/Packages/MercuryUI` (không làm package dùng chung). Chấp nhận hai bên lệch nhau.
- Ký/phát hành: team Tekmium như Capstio, bundle id `com.tekmium.mercury`.
- Giữ phiên: mọi terminal (agent và shell thường) chạy qua PTY helper và sống sót khi thoát app.
- Ngôn ngữ UI: chỉ tiếng Anh.
- Yêu cầu thêm giữa chừng: hỗ trợ cả repo git lẫn thư mục thường (phase 2, 4, 8).

### Verification Results
- Claims checked: 12 (đường dẫn Capstio, SwiftTerm tag/Metal/plugin, file Orca, tên Keychain, endpoint usage, toolchain máy)
- Verified: 11 | Failed: 0 | Unverified: 1 (chi tiết cấu trúc `auth.json` và chia sẻ `sessions/` của Codex, phase 6 bước 1 sẽ xác minh)
- Tier: Full (9 phases)

### Whole-Plan Consistency Sweep
- Đã thay khái niệm "repository" bằng "workspace" (git | folder) ở phase 2, 4, 8 và plan.md.
- Đã bỏ "package dùng chung" và "chốt ở validation" khỏi phase 1, 7. Không còn mâu thuẫn.
