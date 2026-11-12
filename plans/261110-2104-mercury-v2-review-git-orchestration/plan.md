---
title: "Mercury V2 — review, git và orchestration"
description: "Thêm bốn tính năng plan 1 đã để sau: ghi chú theo dòng trên diff gửi lại agent, diff hai cột, commit/push/PR từ app, và orchestration coordinator → worker."
status: pending
priority: P2
effort: 26d
branch: main
tags: [feature, macos, swift, git, orchestration]
blockedBy: [261110-2054-mercury-native-agent-orchestrator]
blocks: []
created: 2026-11-11
---

# Mercury V2 — review, git và orchestration

## Overview

Plan này nối tiếp plan 1 (`261110-2054-mercury-native-agent-orchestrator`). Nó thêm đúng bốn tính năng plan 1 đã loại ra: ghi chú theo dòng trên diff gửi lại cho agent, diff hai cột, commit/push/PR từ app, và orchestration để một agent điều phối giao việc cho các agent worker rồi nhận kết quả về. Mọi quyết định của plan 1 vẫn giữ: native Swift, chỉ local, UI tiếng Anh, Liquid Glass thật trên macOS 26+.

## Điều kiện bắt đầu

Plan 1 xong ít nhất các phase 3 (terminal), 4 (worktree và phiên agent), 5–6 (tài khoản), 7 (PTY helper) và 8 (diff viewer).

## Non-goals

Remote/SSH, mobile, tích hợp GitHub Issues/Linear/Jira, gửi CI fail hoặc review comment của PR về cho agent, stack PR, merge từ app, automation theo lịch, ghi chú trên phía bản cũ của diff.

## Phases

| # | Phase | Effort | Phụ thuộc |
|---|-------|--------|-----------|
| 1 | [Ghi chú theo dòng trên diff](./phase-01-diff-line-notes.md) | 4d | plan 1 |
| 2 | [Diff hai cột](./phase-02-side-by-side-diff.md) | 3d | plan 1 |
| 3 | [Commit và push](./phase-03-commit-and-push.md) | 4d | plan 1 |
| 4 | [Pull request](./phase-04-pull-requests.md) | 3d | 3 |
| 5 | [Orchestration: lõi và CLI](./phase-05-orchestration-core.md) | 7d | plan 1 |
| 6 | [Orchestration: đánh thức và chuyển tin](./phase-06-orchestration-delivery.md) | 5d | 5 |

Phase 1–2, 3–4 và 5–6 là ba nhánh độc lập, có thể làm song song.

## Acceptance criteria

- [x] Ghi chú lên một dòng hoặc một khoảng dòng của diff, gửi một lượt nhiều ghi chú vào phiên agent của worktree; agent nhận đúng file, dòng và nội dung.
- [x] Chuyển qua lại giữa diff unified và diff hai cột; hai cột cuộn đồng bộ.
- [x] Stage file, commit với message do agent soạn (chỉ đọc, không sửa file), push lên remote.
- [ ] Tạo PR từ app bằng `gh`, title và body do agent soạn; xem trạng thái PR và checks.
- [x] Một agent Claude điều phối khởi động worker Codex ở worktree mới bằng `mercury` CLI, worker báo kết quả, và coordinator được đánh thức để báo lại cho người dùng mà không phải poll.
- [ ] Mọi chức năng mới chạy được với workspace `folder` ở mức có thể (ghi chú, orchestration), và ẩn hoặc giải thích rõ chức năng cần git.

## Kết quả triển khai (2026-11-11)

Ba nhánh làm song song (A: phase 1–2, B: phase 3–4, C: phase 5–6), cộng một lượt đo và sửa hiệu năng. `scripts/ci-local.sh` xanh: 427 test package, 26 test app, không cảnh báo. Báo cáo: `plans/reports/v2-branch-{a,b,c}-261111-1226.md`, `plans/reports/perf-261111-1556-ui-responsiveness.md`.

- Ghi chú diff: gửi 5 ghi chú vào Claude thật, Claude nhận thành một lần dán, không tự chạy dòng nào.
- Commit: `claude -p` và `codex exec` chạy thật trên repo tạm, băm cả cây (gồm `.git`) trước/sau trùng nhau. Push thử với remote bare.
- Orchestration: chạy đầu cuối với Claude coordinator và Codex worker thật trên data root tạm; worker hỏi, coordinator trả lời, worker `done`, coordinator được đánh thức, không poll; giết worker thì có escalation. App mới tương thích ngược với helper giao thức 2.
- Còn mở: tạo PR thật trên GitHub chưa thử (chỉ test parse với `gh` giả, theo yêu cầu không tạo PR thật). Worker Claude ở worktree mới vẫn dừng ở hộp thoại trust của Claude. Thư mục `folder` dùng được orchestration và trình xem file, nhưng ghi chú diff cần git.

## Tham chiếu Orca

- Ghi chú diff: `src/shared/diff-comment-types.ts`, `src/shared/diff-comments-format.ts`, `src/renderer/src/components/diff-comments/`.
- Soạn commit/PR: `src/main/text-generation/` (đặc biệt `source-control-read-only-policy.ts`).
- Orchestration: `skill-guides/orchestration.md`, `src/cli/handlers/orchestration/`.

## Validation Log

### Session 1 — 2026-11-11
- Gửi ghi chú diff: chỉ dán vào prompt, người dùng tự nhấn Enter; tự gửi là tuỳ chọn trong Settings. Khớp phase 1.
- Broker orchestration: nằm trong PTY host helper. Khớp phase 5–6.
- CLI `mercury`: chỉ dùng trong terminal do Mercury mở, không cài vào hệ thống. Khớp phase 5.
- Pull request: chỉ GitHub qua `gh`. Khớp phase 4.

### Verification Results
- Claims checked: 9 (file Orca về ghi chú diff, định dạng gửi, chính sách chỉ đọc khi soạn commit, hướng dẫn orchestration, phiên bản `claude`/`codex` trên máy)
- Verified: 6 | Failed: 0 | Unverified: 3 (cờ chỉ đọc của `claude -p` và `codex exec`, cơ chế `notify` của Codex; phase 3 bước 1 và phase 6 bước 1 sẽ xác minh)
- Tier: Full (6 phases)

### Whole-Plan Consistency Sweep
- Các câu trả lời trùng với nội dung đã viết; không phải sửa phase nào. Không còn mâu thuẫn.
