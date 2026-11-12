---
phase: 4
title: "Pull request"
status: pending
priority: P2
effort: "3d"
dependencies: [3]
---

# Phase 4: Pull request

## Goal

Tạo PR GitHub cho branch của worktree ngay trong app, với title và body do agent soạn, rồi theo dõi trạng thái PR và checks.

## Architecture

- Dùng `gh` CLI của người dùng, không tự giữ token GitHub:
  - Kiểm tra: `gh auth status`. Chưa đăng nhập thì hướng dẫn chạy `gh auth login` trong một terminal của app.
  - Tạo: push branch (phase 3) rồi `gh pr create --title <t> --body-file <f> --base <base> --head <branch>`; tuỳ chọn `--draft`.
  - Đọc: `gh pr view <branch> --json number,url,state,isDraft,reviewDecision,mergeStateStatus` và `gh pr checks <branch> --json name,state,link`.
- Soạn title/body bằng `HeadlessTextGenerator` (phase 3), đầu vào là danh sách commit và diff so với base (cắt theo ngân sách).
- Theo dõi: làm mới khi mở worktree, khi bấm làm mới, và định kỳ với chu kỳ dài (ví dụ 2 phút) chỉ cho worktree đang hiển thị. Theo `AGENTS.md` của Orca, không poll dày.
- UI: nút "Create Pull Request" trên toolbar worktree; badge trạng thái PR ở sidebar; inspector hiện danh sách checks kèm link mở trình duyệt.
- Remote không phải GitHub: ẩn chức năng PR, giải thích lý do.

## Files to create / modify

- Create: `Packages/MercuryGit/Sources/MercuryGit/GitHubCLI.swift` (chạy `gh`, parse JSON) + tests parse với JSON mẫu viết tay.
- Create: `Packages/MercuryAgents/Sources/MercuryAgents/PullRequestPrompt.swift`.
- Create: `App/Features/SourceControl/{CreatePullRequestSheet,PullRequestStatusView,ChecksList}.swift`.

## Tasks & steps

1. Wrapper `gh` và parse JSON, kèm test.
2. Sheet tạo PR: base branch, draft, title/body có nút "Generate".
3. Badge và inspector trạng thái PR, checks.
4. Xử lý lỗi: chưa cài `gh`, chưa đăng nhập, remote không phải GitHub, PR đã tồn tại (mở PR đó thay vì tạo mới).

## Verification

- Test parse pass.
- Trên một repo thử nghiệm: tạo PR draft từ app, URL mở đúng, trạng thái checks cập nhật sau khi làm mới.
- Thiếu `gh` hoặc chưa đăng nhập thì có hướng dẫn rõ, không crash.

## Verification notes

Xác minh ngày 2026-11-11 với `gh` 2.92.0 (`gh pr view --help`, `gh pr checks --help`, `gh pr create --help`, `gh auth status --help`):

- `gh auth status --active --hostname <host> --json hosts`: luôn exit 0 khi có `--json`; app chỉ decode `host`, `login`, `state`, `active` (không đọc token). Trên máy này: đã đăng nhập `github.com` (chỉ kiểm tra để báo khả dụng, không in token).
- `gh pr view <branch> --json number,url,title,state,isDraft,reviewDecision,mergeStateStatus,headRefName,baseRefName`; không có PR thì stderr "no pull requests found" (exit 1) → coi là "chưa có PR".
- `gh pr checks <number> --json name,state,bucket,link,workflow`: exit 8 = đang chạy, exit 1 = có check fail, cả hai vẫn in JSON; "no checks reported" → danh sách rỗng. `bucket` ∈ pass/fail/pending/skipping/cancel.
- `gh pr create --title … --body-file <file> --base … --head … [--draft]`; PR đã tồn tại thì gh in "already exists" kèm URL → app mở PR đó.
- Env: `GH_PROMPT_DISABLED=1`, `GH_NO_UPDATE_NOTIFIER=1`, `GH_SPINNER_DISABLED=1`, `NO_COLOR=1`, `GH_PAGER=cat`; biến `GIT_*` trỏ repo khác bị bỏ như `GitRunner`. Timeout 30 s.
- Không tạo PR thật: wrapper và parse được test bằng JSON viết tay và script `gh` giả (`Packages/MercuryGit/Tests/MercuryGitTests/GitHubCLITests.swift`); ảnh chụp UI dùng `gh` giả qua `MERCURY_GH_PATH` (chỉ bản DEBUG).
- Bước Verification "tạo PR draft từ app trên repo thử nghiệm" chưa chạy với GitHub thật (theo yêu cầu không tạo PR thật).
