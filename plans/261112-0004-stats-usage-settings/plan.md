---
title: Stats & Usage trong Settings
created: 2026-11-12
status: done
mode: hard (đã scout Orca + code Mercury)
---

# Stats & Usage trong Settings

## Kết quả mong muốn
Trang **Stats & Usage** mới trong Settings overlay (tab thứ 5), học theo Orca nhưng làm native SwiftUI:

1. **Mercury stats**: agents đã chạy, tổng thời gian agent làm việc, PR đã tạo, "Tracking since <ngày>".
2. **Usage Analytics** (bộ chọn Overview / Claude / Codex, nút refresh, "Updated <giờ>"):
   tổng token, chi phí ước tính, số ngày hoạt động, tỉ lệ cache; heatmap "Daily intensity" (6 tuần gần nhất, ngày cao nhất);
   "Token mix" (input / output / cache read / cache write).
3. **Providers**: mỗi provider một thẻ (Claude, Codex): trạng thái có dữ liệu, model dùng nhiều nhất, project nhiều nhất,
   token, số session, số turn, chi phí.

## Quyết định của người dùng (2026-11-12)
- Nguồn dữ liệu: login gốc (~/.claude, ~/.codex, chỉ đọc) **và** mọi tài khoản Mercury quản lý.
- Khoảng thời gian: picker 7 ngày / 30 ngày (mặc định) / All; heatmap luôn 6 tuần gần nhất.
- Chi phí: hiển thị "Est. cost", tooltip ghi rõ là giá API niêm yết, không phải hoá đơn subscription.
- Thực hiện ngay bằng /ak:cook.

## Ràng buộc
- **Chỉ đọc** log của CLI: `~/.claude/projects/**/*.jsonl` (+ `$CLAUDE_CONFIG_DIR`, + home của từng tài khoản Mercury quản lý),
  `~/.codex/sessions/**/*.jsonl` (+ `$CODEX_HOME`, + home tài khoản Codex quản lý). Không ghi, không đổi tên, không xoá gì ở đó.
- **Chỉ lưu con số**: không lưu nội dung prompt/câu trả lời, không token đăng nhập. Cache tổng hợp nằm trong data root Mercury.
- Log lớn (máy này: Claude 3,5 GB / 477 file, Codex 414 MB / 47 file) → quét **tăng dần** theo checkpoint byte-offset mỗi file,
  chạy ngoài main thread, lần đầu có tiến trình; mở lại Settings chỉ đọc phần mới.
- Native SwiftUI, Swift Charts cho heatmap/thanh; Liquid Glass thật; English UI qua String Catalog; zero warning.
- Migration DB mới phải backup trước (đã có cơ chế backup tự động trước migrate — kiểm lại).

## Ngoài phạm vi
OpenCode/Grok/Muse providers; "Clean up"/disk scan; xuất CSV; đồng bộ cloud; phân bổ chi phí theo worktree (Orca có, để sau).

## Tiêu chí chấp nhận
- [x] Trang hiển thị đúng 3 khối như trên, sáng/tối, cửa sổ hẹp/rộng không vỡ layout (ảnh chụp app thật).
- [x] Số token/chi phí khớp kiểm tra độc lập (script đếm trực tiếp trên vài file JSONL mẫu) ±0,5 %.
- [x] Lần quét đầu trên dữ liệu máy này < 60 s bản Release, không giật UI (main-thread gap < 100 ms); lần mở lại < 1 s.
- [x] Mercury stats tăng đúng khi tạo session agent, khi agent làm việc, khi tạo PR; backfill từ session cũ.
- [x] Test package cho parser/dedupe/pricing/aggregation/checkpoint; test app cho stats; CI local xanh.

## Phase
| # | Phase | File | Phụ thuộc |
|---|---|---|---|
| 1 | Package `MercuryUsage`: quét log, parse, giá, tổng hợp, cache | [phase-01-usage-engine.md](phase-01-usage-engine.md) | — |
| 2 | Mercury stats: sự kiện + migration + backfill | [phase-02-mercury-stats.md](phase-02-mercury-stats.md) | — |
| 3 | UI trang Stats & Usage trong Settings | [phase-03-settings-ui.md](phase-03-settings-ui.md) | 1, 2 |
| 4 | Kiểm chứng: đối chiếu số, hiệu năng, ảnh chụp | [phase-04-verification.md](phase-04-verification.md) | 3 |

Phase 1 và 2 chạy song song được (không chung file).

## Tham khảo Orca (MIT, chỉ đọc)
`/private/tmp/claude-501/-Users-vudev-Self-Works/d6ff3461-65f9-47e9-9351-560d6d375c15/scratchpad/repo/orca/src/`
- `main/claude-usage/`: `transcript-file-discovery.ts`, `transcript-record-parser.ts` (dedupe theo message id + requestId), `claude-model-pricing.ts`, `claude-billable-tokens.ts`, `usage-aggregation.ts`
- `main/codex-usage/`: `codex-session-file-discovery.ts`, `codex-usage-record-parser.ts`, `codex-usage-token-delta.ts` (token tích luỹ → delta), `codex-model-pricing.ts`
- `main/usage/jsonl-file-checkpoint.ts` (checkpoint theo inode + offset), `main/stats/` (agent_start/stop, pr_created)
- UI: `renderer/src/components/stats/StatsPane.tsx`, `UsageOverviewPane.tsx`, `usage-overview-sections.tsx`

## Kết quả (2026-11-12)
- Phase 1–4 xong. `scripts/ci-local.sh` xanh (9 package, 55 test app).
- Quét log thật máy này: lần đầu 1,84 s (Release), lần sau 16 ms; token Claude khớp script đếm độc lập (lệch < 0,003 %).
- Trang Stats & Usage chụp trên app thật sáng/tối, 760/1000/1600 pt; thanh tab Settings chuyển sang chỉ icon khi hẹp.
- Còn mở: log Codex cũ nén `.jsonl.zst` (35 file, ~182 MB) chưa đọc được (macOS không có zstd sẵn, Orca cũng bỏ qua);
  thời gian agent làm việc có thể dư tới ~8 s mỗi lượt (độ trễ phát hiện idle) và không tính lúc Mercury đóng.
- Báo cáo: [../reports/stats-usage-261112-0051-verification.md](../reports/stats-usage-261112-0051-verification.md)
