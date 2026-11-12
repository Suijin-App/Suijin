---
phase: 1
title: Quyết định & chuẩn bị
status: pending
---

# Phase 1: Quyết định & chuẩn bị

## Mục tiêu
Chốt mọi quyết định cần trước khi sửa code, rồi tạo nhánh và các bản backup.

## Quyết định cần chốt (đã chốt 2026-11-12: chưa phát hành, chưa có tên miền, có đổi thư mục repo, CLI là `sevinda`, session cũ theo cách (b))
1. **Bảng tên**: xác nhận bảng trong `plan.md`, gồm cách viết hoa:
   - `Sevinda` cho tên hiển thị và type;
   - `sevinda` cho CLI, thư mục và file;
   - `SEVINDA_` cho biến môi trường.
2. **Đã phát hành chưa?**
   - **Chưa** (mới chỉ máy dev): bỏ được phần nâng cấp Sparkle chéo tên. Phase 5 chỉ cần migrate dữ liệu cục bộ.
   - **Rồi**: phải phát hành thêm một bản Mercury cuối, bản này trỏ Sparkle sang feed Sevinda, hoặc hướng dẫn người dùng tải lại. Xem phase 6.
3. **Tên miền và feed Sparkle**: chọn tên miền mới, ví dụ `sevinda.tekmium.com`, kèm đường dẫn appcast và downloads.
   - Giữ khoá ký Sparkle EdDSA cũ (`SUPublicEDKey`) thì người dùng cũ vẫn tin được bản cập nhật mới.
   - Đổi khoá thì phải phát hành lại từ đầu.
4. **Session đang chạy trong helper cũ**:
   - Cách (a): Sevinda nối vào helper cũ một lần để chuyển session sang.
   - Cách (b): đánh dấu session cũ là "đã kết thúc", để người dùng bấm Start Again.
   - Khuyến nghị cách (b), vì đơn giản và an toàn. Session agent có thể khởi động lại được.
5. **Repo**: có đổi tên thư mục `~/Self-Works/Mercury` và remote hay không. Đổi tên thư mục sẽ làm hỏng DerivedData và đường dẫn tuyệt đối trong các script scratch; việc này không ảnh hưởng tới code.

## Chuẩn bị
- [ ] Commit sạch trên `main`. Tạo nhánh `chore/rename-sevinda`.
- [ ] Backup `~/Library/Application Support/Mercury` (copy nguyên thư mục, kèm `mercury.sqlite`).
- [ ] Backup defaults: `defaults export com.tekmium.mercury ~/Desktop/mercury-defaults.plist`.
- [ ] Ghi lại các session đang chạy trong helper (Resource Manager), và lưu những gì cần lưu trước khi làm phase 5.
- [ ] Liệt kê đầy đủ các chỗ cần đổi, lưu vào `plans/reports/rename-inventory.txt`:
  ```sh
  git grep -n -i mercury -- . ':!plans' > plans/reports/rename-inventory.txt
  git ls-files | grep -i mercury > plans/reports/rename-paths.txt
  ```

## Xong khi
- Mọi câu hỏi mở trong `plan.md` đã có câu trả lời và được ghi vào file này.
- Nhánh, các backup và file inventory đã có.

## Rollback
Chưa sửa gì nên không cần.
