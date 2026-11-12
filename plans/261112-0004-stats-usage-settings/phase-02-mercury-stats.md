# Phase 2 — Mercury stats

## Mục tiêu
Đếm: agents đã chạy (session agent tạo ra), thời gian agent làm việc (tổng các đoạn `working`), PR đã tạo, ngày bắt đầu theo dõi.

## File
- `Packages/MercuryCore/Sources/MercuryCore/Migrations+Stats.swift` — migration `v5_stats`: bảng `stat_counter(key TEXT PRIMARY KEY, value INTEGER)` và `stat_pr(url TEXT PRIMARY KEY, createdAt)`. Backup DB trước migrate (kiểm tra cơ chế hiện có).
- `Packages/MercuryCore/Sources/MercuryCore/StatsStore.swift` — `increment(_:by:)`, `recordPullRequest(url:)` (dedupe theo URL), `stats()`.
- App: `App/Features/Terminal/SessionRuntime.swift` (session agent bắt đầu → +1; tracker `working` bật/tắt → cộng thời lượng, kể cả khi app thoát giữa chừng thì chốt lúc thoát), `App/Features/SourceControl/SourceControlModel.swift` (`createPullRequest` thành công → ghi URL).
- Backfill một lần: `agentsSpawned` = số session record có agent ≠ shell; `trackingSince` = createdAt sớm nhất; thời gian làm việc không backfill được (ghi chú trong UI "since <ngày cập nhật>").

## Kiểm tra
Test MercuryCore cho migration + store; test app: tạo session agent giả → đếm tăng; PR trùng URL không đếm 2 lần.
