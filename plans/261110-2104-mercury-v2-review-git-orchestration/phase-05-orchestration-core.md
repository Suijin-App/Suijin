---
phase: 5
title: "Orchestration: lõi và CLI"
status: pending
priority: P1
effort: "7d"
dependencies: []
---

# Phase 5: Orchestration — lõi và CLI

## Goal

Agent trong Mercury dùng được lệnh `mercury` để khởi động agent worker (cùng hoặc khác loại, ở worktree hiện tại hoặc worktree mới), nhắn tin, hỏi/trả lời, và báo hoàn thành. Toàn bộ trạng thái lưu bền.

## Key insights (từ Orca, `skill-guides/orchestration.md`)

- Coordinator khởi động worker: `worker-start --spec "<task>" --worktree current|new-child --agent codex`, rồi **kết thúc lượt**. Không poll; Orca tự đánh thức coordinator khi có tin.
- Worker nhận prompt có phần mở đầu chứa Task ID và Dispatch ID. Worker hỏi bằng `ask` rồi kết thúc lượt; báo xong bằng `worker_done`.
- Nhắn tin: `send --to dispatch:<id>`; worker đang chạy thì nhận khi hết lượt hiện tại, worker đã xong thì nhận như một Task tiếp theo.
- Coordinator trả lời câu hỏi bằng `reply --id <message_id>`.
- Có `inbox`, `worker-list`, `escalation` khi worker dừng mà không gọi `worker_done`.
- Orca hướng dẫn agent bằng một skill đi kèm, nạp theo đúng phiên bản CLI (`skills get orchestration`).

## Architecture

- **Broker nằm trong PTY host helper** (plan 1 phase 7): helper luôn sống khi còn phiên, sở hữu terminal của mọi agent, nên có thể nhận lệnh CLI và đưa tin vào terminal kể cả khi app đang đóng.
- **IPC**: Unix domain socket trong `~/Library/Application Support/Mercury/` (quyền 600) với giao thức JSON theo dòng. Mỗi phiên agent được cấp `MERCURY_SESSION_ID` và `MERCURY_SESSION_TOKEN` qua env; broker xác định ai gọi bằng token, không tin tham số tự khai.
- **CLI `mercury`**: một executable Swift nhỏ nằm trong app bundle. App thêm nó vào `PATH` của các terminal nó mở (không cài vào `/usr/local/bin` nếu người dùng không đồng ý).
- **Lệnh bản đầu**:
  - `mercury worker start --spec <text|@file> --agent claude|codex [--worktree current|new --name <n>] [--account <id>]`
  - `mercury send --to <dispatch> --body <text>`
  - `mercury ask --body <text>` (worker), `mercury reply --id <msg> --body <text>` (coordinator)
  - `mercury done --status success|failed --summary <text>` (worker)
  - `mercury worker list`, `mercury inbox`
  - `mercury skills get orchestration` in hướng dẫn khớp phiên bản
  - Mọi lệnh có `--json`.
- **Dữ liệu** (GRDB, migration mới): `orch_run`, `orch_task`, `orch_dispatch` (task ↔ phiên worker), `orch_message` (loại `send` | `question` | `reply` | `done` | `escalation`, trạng thái đã giao hay chưa).
- **Skill cho agent**: file `SKILL.md` của Mercury được cài vào thư mục skills của các profile tài khoản Mercury quản lý. Chỉ cài vào `~/.claude/skills` khi người dùng đồng ý trong Settings.
- **UI**: trong sidebar, worker hiện lồng dưới coordinator; inspector hiện spec, trạng thái, tin nhắn.

## Files to create

- `Tools/MercuryCLI/{main,Commands,SocketClient}.swift` (target mới trong `project.yml`).
- `Packages/MercuryPTYProtocol/Sources/MercuryPTYProtocol/OrchestrationProtocol.swift`.
- `Helpers/MercuryPTYHost/Orchestration/{Broker,CallerIdentity,DispatchStore}.swift`.
- `Packages/MercuryCore/Sources/MercuryCore/Orchestration/{Run,Task,Dispatch,Message}.swift` + migration.
- `Resources/Skills/mercury-orchestration/SKILL.md` (tiếng Anh, viết cho agent đọc).
- `App/Features/Orchestration/{WorkerTreeView,DispatchInspector}.swift`.

## Tasks & steps

1. Giao thức socket, xác thực theo token phiên, kèm test.
2. Model và migration orchestration, kèm test chuyển trạng thái (đang chạy → hỏi → được trả lời → xong / thất bại / escalation).
3. CLI `mercury` với các lệnh trên; `--json` ổn định.
4. `worker start`: tạo worktree nếu cần (plan 1 phase 4), chọn tài khoản, khởi động agent với prompt có phần mở đầu chứa Task/Dispatch ID và cách gọi `ask`/`done`.
5. Skill orchestration và cách cài vào profile.
6. UI cây worker và inspector.

## Verification

- Test broker, CLI và chuyển trạng thái pass.
- Gọi `mercury` từ một terminal không phải của Mercury (không có token) thì bị từ chối.
- Từ một phiên Claude: `mercury worker start --agent codex --worktree new --name fix-x --spec "..."` tạo worktree, chạy Codex với đúng tài khoản, và hiện worker trong sidebar.

## Security

- Token phiên chỉ nằm trong env của phiên đó, không log. Socket quyền 600, chỉ user hiện tại.
- Worker không được gửi lệnh nhân danh coordinator; broker kiểm vai trò theo token.

## Risks

- Agent không đọc skill hoặc dùng sai lệnh. Giảm rủi ro bằng thông báo lỗi của CLI có gợi ý lệnh đúng, như Orca làm (`command-suggestion.ts`).
