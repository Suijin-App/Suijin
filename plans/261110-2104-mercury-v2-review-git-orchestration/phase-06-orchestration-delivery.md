---
phase: 6
title: "Orchestration: đánh thức và chuyển tin"
status: pending
priority: P1
effort: "5d"
dependencies: [5]
---

# Phase 6: Orchestration — đánh thức và chuyển tin

## Goal

Tin nhắn (câu hỏi của worker, kết quả `done`, tin `send`) được đưa đến agent nhận **đúng lúc agent kết thúc lượt**, không phải poll, và không chen vào giữa lúc agent đang làm.

## Key insights

- Orca: worker đang chạy nhận `send` khi hết lượt hiện tại; coordinator kết thúc lượt sau khi giao việc và được đánh thức khi có tin. Orca cấm agent tự poll hay chạy script theo dõi.
- Muốn biết "hết lượt" phải có tín hiệu từ agent: Claude Code có hook `Stop` (plan 1 phase 4 đã cài hook vào profile Mercury). Codex có cơ chế `notify` trong `config.toml`. Cấu trúc payload chính xác của Codex phải xác minh với bản 0.166.0. [UNVERIFIED]

## Architecture

- **Phát hiện hết lượt**:
  - Claude: hook `Stop` (và `Notification` khi chờ quyền) gọi `mercury hook stop` kèm session token; broker đánh dấu phiên "rảnh".
  - Codex: `notify` trong `config.toml` của `CODEX_HOME` do Mercury quản lý gọi `mercury hook codex-notify`.
  - Dự phòng: không có output trong N giây và con trỏ đứng ở prompt. Chỉ dùng để hiện cảnh báo, không tự giao tin.
- **Giao tin**: khi phiên nhận đang rảnh và có tin chưa giao, broker ghi vào PTY của phiên đó bằng bracketed paste rồi gửi Enter. Nội dung có tiêu đề rõ (`[Mercury] Worker fix-x finished: …`) và nhắc lệnh trả lời nếu là câu hỏi.
- **Escalation**: worker kết thúc lượt cuối hoặc process thoát mà chưa gọi `done` thì tạo tin `escalation` cho coordinator, kèm lý do (exit code, trạng thái cuối).
- **Người dùng đang gõ**: nếu người dùng vừa gõ vào phiên trong vài giây gần nhất, hoãn giao tin để không trộn vào chữ của họ.
- **Thông báo macOS** khi coordinator cần người dùng quyết định (câu hỏi không tự trả lời được).

## Files to create / modify

- Create: `Helpers/MercuryPTYHost/Orchestration/{TurnTracker,MessageDelivery,Escalation}.swift`.
- Modify: `Packages/MercuryAgents/Sources/MercuryAgents/ClaudeHooks.swift` (thêm `Stop` gọi `mercury hook`).
- Create: `Packages/MercuryAccounts/Sources/MercuryAccounts/Codex/CodexNotifyConfig.swift` (ghi `notify` vào `config.toml` của home do Mercury quản lý, không đụng `~/.codex/config.toml`).
- Tests: `TurnTrackerTests`, `MessageDeliveryTests` (hoãn khi đang gõ, giao khi rảnh, không giao hai lần).

## Tasks & steps

1. Xác minh cơ chế `notify` của Codex 0.166.0; ghi kết quả vào phase này.
2. Hook Claude `Stop` và Codex `notify` nối tới broker.
3. Hàng đợi giao tin theo phiên, giao đúng một lần, lưu trạng thái đã giao.
4. Escalation khi worker dừng mà không `done`.
5. Thông báo macOS và badge trên sidebar.

## Verification

- Test giao tin pass.
- Kịch bản đầu cuối: coordinator Claude giao 2 worker (một Codex, một Claude) ở hai worktree mới rồi kết thúc lượt. Một worker gọi `ask`, coordinator được đánh thức, `reply`, worker tiếp tục. Cả hai gọi `done`; coordinator được đánh thức và tóm tắt kết quả cho người dùng. Không có lệnh poll nào trong transcript.
- Giết process một worker: coordinator nhận `escalation`.
- Thoát app giữa chừng: tin vẫn được giao vì broker nằm trong helper.

## Verified

Bước 1 — cơ chế `notify` của Codex 0.166.0 (`codex-cli 0.166.0`, 2026-11-11), chạy thật `codex exec -c 'notify=["<script>","hook","codex-notify"]' "..."`:

- Codex gọi chương trình `notify` sau mỗi lượt, truyền **một đối số JSON ở cuối argv** (sau các đối số đã cấu hình): `{"type":"agent-turn-complete","thread-id":"…","turn-id":"…","cwd":"…","client":"codex_exec","input-messages":["…"],"last-assistant-message":"…"}`.
- Chương trình chạy với env của phiên Codex (thấy được `MERCURY_SESSION_TOKEN`), cwd là thư mục làm việc, chạy ngoài sandbox.
- `-c notify=[…]` ghi đè giá trị trong `config.toml` cho riêng lần chạy đó, nên Mercury **không ghi `config.toml` nào** (cả `~/.codex` lẫn home do Mercury quản lý, vốn bị config mirror ghi lại). `notify` của chính người dùng (máy này có một cái) được nối tiếp sau hook của Mercury với cùng payload (`CodexNotifyConfig`).
- Sandbox mặc định `workspace-write` của Codex **chặn kết nối Unix socket** (`codex sandbox -- nc -U …` thất bại; chỉ qua được với `network_access=true` hoặc `--allow-unix-socket`) nhưng cho ghi vào `$TMPDIR`. Vì vậy CLI có đường dự phòng: thư mục spool `$TMPDIR/mercury-orch-<hash>/spool` (700) mà broker quét.
- Codex 0.166.0 vẫn chuyển `MERCURY_SESSION_TOKEN` (tên chứa TOKEN) vào lệnh shell của nó (kiểm bằng `env | grep MERCURY_` trong `codex exec`).
- Skill: Codex đọc `$CODEX_HOME/skills/<tên>/SKILL.md` (kiểm bằng `codex debug prompt-input`); Claude nạp skill từ `--plugin-dir <dir>` (kiểm bằng `claude --plugin-dir … plugin details mercury`).
