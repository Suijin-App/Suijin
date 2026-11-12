# Phase 6 — Kiểm chứng

1. Test: PaneLayout (cây), store/migration, commands (⌘W, giới hạn 10, agent mới), restore sau relaunch.
2. Probe app thật: ⌘W từng pane; kéo-thả 5 vùng; resize rồi relaunch giữ tỉ lệ; sidebar click focus đúng pane.
3. Ảnh chụp 1/2/4/10 pane, header hover, khung xem trước khi kéo, sáng/tối, 1000/1600 pt.
4. Hiệu năng: 10 pane đang in output — main-thread gap < 100 ms, RAM theo Resource Manager; kéo vạch chia không giật.
5. `scripts/ci-local.sh` xanh; cập nhật docs (phím tắt, Settings) nếu có tài liệu người dùng.
6. Commit theo phase (Conventional Commits, không trailer AI).
