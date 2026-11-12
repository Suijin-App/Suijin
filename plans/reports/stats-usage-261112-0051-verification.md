# Stats & Usage — kiểm chứng (phase 4)

## Đối chiếu số liệu (Claude, script độc lập `count_usage.py`, chỉ đọc)
| Khoảng | Script | App (Overview gồm cả Codex) |
|---|---|---|
| All | 18,19 B token, 59 ngày | Claude 18,19 B |
| 30 ngày | 12,39 B token, 29 ngày | 12,4 B, 29 ngày |
| 7 ngày | 2,52 B token, 7 ngày | — |
Chênh lệch nhỏ do các session đang chạy ghi thêm log giữa hai lần đo.

## Hiệu năng
Lần quét đầu 1,84 s (Release) / < 6 s (Debug); lần sau 16 ms; đọc cache khi mở lại 92 ms.

## Sửa trong phase 4
- "Cache share" hiển thị ">99%" thay vì làm tròn lên 100% khi chưa đủ 100%.
- Test ưu tiên phát lại scrollback của tab đang xem: đo thứ tự chunk bằng `chunkObserver` thay vì poll (hết flaky).

## Giới hạn còn lại
- Log Codex nén `.jsonl.zst` chưa đọc (cần bộ giải zstd).
- Thời gian agent làm việc có thể dư ~8 s/lượt; không tính lúc Mercury đóng.
- Chi phí là ước tính theo giá API niêm yết (bảng giá lấy từ Orca, 2026-11-12).
