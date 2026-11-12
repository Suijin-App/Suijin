---
phase: 3
title: "Commit và push"
status: pending
priority: P1
effort: "4d"
dependencies: []
---

# Phase 3: Commit và push

## Goal

Từ màn diff của một worktree: stage/unstage file, viết hoặc để agent soạn commit message, commit, rồi push lên remote.

## Key insights (từ Orca)

- Orca soạn commit message bằng cách chạy agent CLI ở chế độ không tương tác, và ép **chỉ đọc**: với Claude thì thêm `--settings` có luật `permissions.deny`, với Codex thì giới hạn sandbox và tắt plugin/MCP (`src/main/text-generation/source-control-read-only-policy.ts`).
- Agent chạy với đúng tài khoản đang chọn của worktree (env patch từ plan 1 phase 5–6).

## Architecture

- `MercuryGit` thêm: `git status --porcelain=v2 -z`, `git add -- <paths>`, `git restore --staged -- <paths>`, `git commit -F <file>`, `git push` (tự `--set-upstream origin <branch>` nếu branch chưa có upstream).
- Package `MercuryAgents` thêm `HeadlessTextGenerator`:
  - Claude: `claude -p` với prompt qua stdin, ở chế độ chỉ đọc. Cờ chính xác (`--permission-mode`, `--disallowedTools` hoặc `--settings`) phải xác minh với `claude --help` của bản đang cài (2.1.322). [UNVERIFIED]
  - Codex: `codex exec` với sandbox chỉ đọc. Cờ chính xác phải xác minh với `codex exec --help` (0.166.0). [UNVERIFIED]
  - Đầu vào: `git diff --cached` (cắt bớt theo ngân sách ký tự), vài commit gần nhất để bắt chước phong cách.
  - Có timeout và huỷ được; lỗi thì để người dùng tự viết.
- UI: danh sách file Staged/Changes (`List` có checkbox), ô commit message, nút "Generate", "Commit", "Push". Trạng thái ahead/behind trên toolbar.
- Lỗi git (hook pre-commit fail, push bị từ chối) hiện nguyên văn output trong sheet có thể cuộn.

## Files to create / modify

- Create: `Packages/MercuryGit/Sources/MercuryGit/{Status,Staging,Commit,Push}.swift` + tests trên repo tạm (có remote bare để test push).
- Create: `Packages/MercuryAgents/Sources/MercuryAgents/{HeadlessTextGenerator,ReadOnlyAgentPolicy,CommitMessagePrompt}.swift`.
- Create: `App/Features/SourceControl/{SourceControlPanel,CommitComposer,PushButton}.swift`.

## Tasks & steps

1. Đọc `claude --help`, `codex exec --help`; ghi cờ chỉ đọc đã xác minh vào phase này.
2. Git status/stage/commit/push, kèm test với remote bare.
3. `HeadlessTextGenerator` cho Claude và Codex; test rằng agent không sửa được file (chạy trên repo tạm, so hash cây thư mục trước/sau).
4. UI source control.
5. Workspace `folder`: ẩn panel, hiện `ContentUnavailableView` kèm nút "Initialize Git".

## Verification

- Test `MercuryGit` pass, gồm push lên remote bare.
- Soạn message bằng Claude và bằng Codex; repo không bị sửa (hash trước/sau trùng).
- Hook pre-commit fail thì thấy output lỗi, không mất message đang viết.

## Security

- Prompt soạn commit có thể chứa code; chỉ gửi qua agent CLI của chính người dùng, không qua dịch vụ nào khác.

## Verified flags

Xác minh ngày 2026-11-11 với `claude --help` (Claude Code 2.1.322) và `codex exec --help` / `codex --help` (codex-cli 0.166.0). Code: `Packages/MercuryAgents/Sources/MercuryAgents/ReadOnlyAgentPolicy.swift`.

Claude (`claude -p`, prompt qua stdin, text ra stdout):

| Cờ | Tác dụng |
|----|----------|
| `-p --output-format text` | Chạy không tương tác, in câu trả lời rồi thoát |
| `--tools ""` | Không có built-in tool nào (không Bash/Edit/Write/WebFetch…) |
| `--disallowedTools Bash,Edit,Write,MultiEdit,NotebookEdit,WebFetch,WebSearch,Task,mcp__*` | Chặn lại lần nữa phòng khi setting/phiên bản sau thêm tool |
| `--strict-mcp-config` (không kèm `--mcp-config`) | Không MCP server nào chạy |
| `--settings '{"disableAllHooks":true}'` | Hook của người dùng (có thể chạy script/ghi file) bị tắt |
| `--permission-mode dontAsk` | Gì không được phép thì bị từ chối, không hỏi |
| `--no-session-persistence` | Không ghi transcript vào thư mục config của tài khoản |
| `--disable-slash-commands` | Không gọi skill/command |

Codex (`codex [--no-daemon] exec … -`, prompt qua stdin, câu trả lời cuối ghi vào file `-o`):

| Cờ | Tác dụng |
|----|----------|
| `--sandbox read-only` + `-c approval_policy="never"` | Lệnh model chạy không ghi được; ghi cần duyệt thì bị từ chối |
| `--ignore-user-config`, `--ignore-rules` | Không nạp `config.toml` (MCP, `notify`, hooks, profile) và execpolicy rules; đăng nhập vẫn lấy từ `CODEX_HOME` |
| `-c features.plugins=false -c features.apps=false` | Không nạp plugin/app connector (theo Orca) |
| `--ephemeral` | Không ghi file session |
| `--skip-git-repo-check`, `--color never` | Chạy cả ở checkout chưa trust; output sạch |
| `--output-last-message <file>` | Lấy đúng câu trả lời cuối |
| `--no-daemon` (cờ top-level, đặt trước `exec`) | Chỉ khi `SettingKey.codexNoDaemon == "true"` |

Kiểm chứng thật (`MERCURY_HEADLESS_SMOKE=1 swift test --package-path Packages/MercuryAgents --filter HeadlessReadOnlySmokeTests`): repo tạm, diff một dòng, mỗi agent chạy 2 lần (prompt commit thật + prompt bảo agent tạo `PWNED.txt`, sửa README, `git commit`). Hash SHA-256 toàn bộ cây (kể cả `.git`) trước/sau trùng nhau cho cả hai. Câu trả lời: Claude "docs: expand README greeting to \"hello world\"" / "None of them worked: no file, shell, or git tools are available"; Codex "Update README greeting to hello world" / "None worked: … blocked by the read-only sandbox".
