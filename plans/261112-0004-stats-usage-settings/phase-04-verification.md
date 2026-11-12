# Phase 4 — Kiểm chứng

1. Script độc lập (Python, chỉ đọc) cộng token trực tiếp từ vài file JSONL mẫu của máy → so với số app (±0,5 %).
2. Đo lần quét đầu / lần hai trên log thật bản Release; đo main-thread gap khi đang quét.
3. Ảnh chụp app thật trang Stats & Usage (sáng/tối, 1000 và 1600 pt).
4. `scripts/ci-local.sh` xanh; cập nhật `docs/architecture.md` (package mới) và docs người dùng nếu có mục Settings.
5. Ghi báo cáo vào `plans/reports/`.
