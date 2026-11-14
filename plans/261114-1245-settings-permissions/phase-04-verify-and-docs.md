---
phase: 4
title: Kiểm chứng và tài liệu
depends_on: [3]
status: pending
---

# Phase 4 — Kiểm chứng và tài liệu

## Bối cảnh

Trạng thái quyền chỉ đúng hay sai trên máy thật. Test tự động chứng minh phần ánh xạ; phần còn lại phải thử tay.

## Cổng kiểm tra

### 1. CI

```
scripts/bootstrap.sh
scripts/ci-local.sh
```

Xanh toàn bộ, không cảnh báo trình biên dịch trong code của dự án. Đóng Xcode trước khi chạy.

### 2. Thử tay trên máy thật

| # | Tình huống | Kết quả phải thấy |
|---|---|---|
| 1 | Notifications chưa từng hỏi (bundle ID mới hoặc `tccutil reset`) | Dòng ghi "Not asked", nút "Allow…" làm hiện hộp thoại hệ thống |
| 2 | Bấm Allow trong hộp thoại | Dòng chuyển sang "Allowed", nút biến mất, không phải mở lại Settings |
| 3 | Tắt Notifications cho Suijin trong System Settings, quay lại app | Dòng chuyển sang "Not allowed", nút "Open System Settings" mở đúng trang Notifications của Suijin |
| 4 | Tắt Suijin trong Login Items, quay lại app | Dòng Background helper ghi "Not allowed", nút mở đúng trang Login Items |
| 5 | Bật lại trong Login Items | Dòng chuyển về "Allowed" |
| 6 | Chưa cấp Full Disk Access | Dòng ghi "Not allowed" với huy hiệu trung tính và chữ "Optional" |
| 7 | Cấp Full Disk Access theo đúng mục phase 1 đã xác định, quay lại app | Dòng chuyển sang "Allowed"; một shell mới trong Suijin đọc được thư mục trước đó bị chặn |
| 8 | Thu hồi Full Disk Access | Dòng trở lại "Not allowed" |
| 9 | Helper phiên bản cũ còn chạy session (nếu phase 2 thêm lệnh XPC) | Dòng Full Disk Access ghi "Unknown" kèm lý do, app không treo, không crash |

Tình huống 7 là phép thử quyết định: trạng thái trên màn hình phải khớp với việc agent thực sự đọc được hay không.

### 3. Bản Release

Nếu phase 1 ghi nhận kết quả có thể khác giữa bản Debug và bản Release, lặp lại tình huống 6–8 trên bản Release cài trong `/Applications`.

## Tài liệu

| File | Sửa gì |
|---|---|
| `CHANGELOG.md` | Thêm một dòng cho section Permissions. Sửa dòng "Sevinda is now Suijin": bỏ chữ "Accessibility", vì app không dùng quyền đó |
| `README.md` | Bảng Settings, dòng General: thêm "permissions". Nếu có ảnh mới thì chụp theo cách các ảnh hiện có |
| `docs/architecture.md` | Một đoạn ngắn: quyền nào app phụ thuộc, tiến trình nào bị TCC tính quyền (kết quả phase 1), và phép thử Full Disk Access |

## Tiêu chí xong

- Cả ba cổng kiểm tra đạt.
- Tám tiêu chí hoàn thành trong `plan.md` được đối chiếu từng mục.
- Không tài liệu nào còn nói Suijin cần Accessibility.

## Rủi ro

Thử tay có bước `tccutil reset`, bước này xoá quyết định quyền của app trên máy đang thử. Chỉ chạy cho bundle ID của Suijin, không chạy dạng reset toàn bộ.

## Rollback

Hoàn nguyên các file tài liệu. Code đã có rollback ở phase 2 và 3.
