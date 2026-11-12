# Phase 1 — Package `MercuryUsage`

## Mục tiêu
Package Swift thuần (không import app), test được, đọc log Claude/Codex và trả về số liệu tổng hợp.

## File (tạo mới)
- `Packages/MercuryUsage/Package.swift`, `Sources/MercuryUsage/`, `Tests/MercuryUsageTests/`; thêm vào `project.yml` + `docs/architecture.md` (đồ thị package).
- `UsageSources.swift` — tìm thư mục log: Claude `~/.claude/projects`, `$CLAUDE_CONFIG_DIR/projects`, `<accountHome>/projects` của tài khoản Mercury; Codex `~/.codex/sessions`, `$CODEX_HOME/sessions`, `<accountHome>/sessions`. Nhận danh sách home từ app (không tự đọc DB).
- `JSONLTailReader.swift` — đọc từ offset, chỉ xử lý dòng hoàn chỉnh; checkpoint = (inode, size, offset, mtime); file bị cắt/thay (inode khác hoặc size < offset) → quét lại từ 0.
- `ClaudeRecordParser.swift` — record `type == "assistant"` có `message.usage`: input, output, cache_read, cache_creation (tách 5m/1h nếu có), model, sessionId, cwd, timestamp; dedupe theo `message.id + requestId` (giữ bản đầy đủ nhất, như Orca).
- `CodexRecordParser.swift` + `CodexTokenDelta.swift` — event `token_count` (tổng tích luỹ) → delta theo session; model từ `turn_context`.
- `ModelPricing.swift` — bảng giá Claude/Codex port từ Orca (ghi nguồn + ngày), giá cache read/write; model lạ → chi phí nil (hiển thị "n/a").
- `UsageAggregate.swift` — theo ngày (lịch local), theo provider, model, project (cwd → tên thư mục), số session, số turn.
- `UsageStore.swift` (actor) — quét song song có giới hạn, lưu cache JSON `<dataRoot>/usage/cache.json` (checkpoint + bucket ngày, **không** lưu text), `refresh(progress:)`.

## Các bước
1. Viết parser + test với fixture JSONL tự tạo (không dùng log thật trong test).
2. Tail reader + checkpoint + test (append, cắt file, thay file, dòng dở).
3. Pricing + aggregation + test tính tay.
4. Store: cache, refresh tăng dần, huỷ được; test trên thư mục tạm.
5. Đo trên log thật của máy (chỉ đọc) bằng một executable/test bị tắt mặc định: thời gian lần đầu, lần hai.

## Kiểm tra
`swift test --package-path Packages/MercuryUsage`; không warning; comment lint.

## Rủi ro
Định dạng log đổi giữa phiên bản CLI → parser bỏ qua dòng lạ, đếm số dòng bỏ qua để báo trong UI. Bảng giá lỗi thời → ghi ngày, chi phí là "ước tính".
