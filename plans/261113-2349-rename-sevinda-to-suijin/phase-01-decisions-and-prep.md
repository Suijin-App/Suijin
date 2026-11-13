---
phase: 1
title: Quyết định & chuẩn bị
depends_on: []
status: pending
---

# Phase 1 — Quyết định & chuẩn bị

## Bối cảnh

Trước khi đụng vào 3.058 chỗ trong 356 file, phải chốt ba thứ: bảng tên cuối cùng, chiến lược migration, và một điểm lùi an toàn. Lần đổi Mercury → Sevinda cho thấy phần tốn thời gian nhất không phải đổi chữ mà là xử lý bản cài cũ.

## Quyết định cần chốt

### Q1. Có giữ đường migration từ Mercury không?

Hiện có `App/Migration/LegacyMercuryMigration.swift` chuyển dữ liệu Mercury → Sevinda. Sau khi đổi sang Suijin, có ba lựa chọn:

| Lựa chọn | Nội dung | Đánh đổi |
|---|---|---|
| **A (khuyến nghị)** | Xoá hẳn đường Mercury, chỉ viết migration Sevinda → Suijin | Code gọn nhất. Mercury chưa từng phát hành, và bản cài Mercury duy nhất từng tồn tại là máy dev — đã chuyển sang Sevinda rồi, nên đường đó là code chết |
| B | Đổi tên thành migration tổng quát, nhận cả hai nguồn cũ | Phủ được máy nào còn kẹt ở Mercury, nhưng gấp đôi số nhánh phải test |
| C | Giữ nguyên Mercury → Sevinda rồi nối thêm Sevinda → Suijin | Chạy hai lần liên tiếp, dễ sai thứ tự, khó nhất để kiểm chứng |

Mặc định của plan này là **A**. Nếu bạn còn máy nào đang chạy bản Mercury thì chọn B.

### Q2. Session đang chạy trong helper cũ xử lý thế nào?

Hai cách, giống hệt lần trước:

- **Nối lại**: helper mới tiếp quản PTY đang mở. Giữ được công việc dở nhưng phức tạp và khó test.
- **Kết thúc có thông báo**: đánh dấu session là "Session Ended" kèm nút Start Again. Đây là cách `LegacyMercuryMigration` đang làm và đã chạy ổn.

Mặc định của plan này là **kết thúc có thông báo**.

### Q3. Đổi thư mục repo ngay hay để cuối?

Thư mục hiện là `~/Self-Works/Mercury`, lệch cả tên cũ lẫn tên mới. Đổi thành `~/Self-Works/Suijin` làm hỏng đường dẫn tuyệt đối trong Xcode recents, DerivedData, `.claude/` và mọi worktree đang mở. Plan này để việc đó ở **bước cuối phase 6**.

## Việc phải làm

1. ~~Trả lời Q1, Q2, Q3~~ — đã xong, xem "Quyết định đã chốt" ở cuối file. Phần Q1–Q3 phía trên giữ lại làm căn cứ cho lựa chọn.
2. Tạo nhánh riêng: `git switch -c rename/suijin`.
3. Chốt sạch cây làm việc trước khi bắt đầu — hiện có thay đổi chưa commit của phần icon và thư mục `brand/` chưa track. Quyết định commit hay stash, không để lẫn vào diff đổi tên.
4. Sao lưu dữ liệu thật trước khi test migration:
   ```
   cp -R ~/Library/Application\ Support/Sevinda \
         ~/Library/Application\ Support/Sevinda.backup-$(date +%Y%m%d-%H%M)
   defaults export com.tekmium.sevinda ~/Desktop/sevinda-defaults-backup.plist
   ```
5. Ghi lại danh sách quyền đang cấp cho Sevinda (Full Disk Access, Accessibility, Notifications) để biết phải cấp lại gì sau khi đổi bundle ID.
6. Đóng Xcode. Hai lần build hỏng gần đây là do Xcode và dòng lệnh cùng ghi vào một DerivedData.

## File đụng tới

Không sửa file nguồn nào ở phase này. Chỉ tạo nhánh và file backup ngoài repo.

## Kiểm chứng

- `git status` sạch trên nhánh `rename/suijin`.
- Thư mục backup tồn tại và mở được bằng `sqlite3 <backup>/sevinda.sqlite .tables`.
- Ba câu hỏi đã có câu trả lời ghi trong file này.

## Rủi ro

Bỏ qua bước backup rồi mới phát hiện migration sai ở phase 5 là mất dữ liệu thật: workspace, account đã đăng nhập, lịch sử session.

## Rollback

`git switch main && git branch -D rename/suijin`.

## Quyết định đã chốt

Chốt ngày 2026-11-13.

- **Q1 — Đường migration từ Mercury: xoá hẳn (lựa chọn A).** Mercury chưa từng phát hành và bản cài Mercury duy nhất từng tồn tại đã chuyển sang Sevinda, nên nhánh đó là code chết. Quyết định Q4 bên dưới đi xa hơn: không chỉ bỏ nhánh Mercury mà **xoá luôn toàn bộ `LegacyMercuryMigration.swift` và test của nó**, không đổi tên thành migration Sevinda → Suijin.
- **Q2 — Session đang chạy: theo khuôn cũ**, tức đánh dấu "Session Ended" kèm nút Start Again thay vì cố nối lại PTY. Quyết định bổ sung cùng ngày làm câu này gần như không còn tác dụng: dữ liệu sẽ bị xoá sạch nên không còn bản ghi session nào để hiển thị. Việc duy nhất còn lại là kết thúc tử tế các session mà helper Sevinda đang chạy trước khi gỡ nó.
- **Q4 — Dữ liệu cũ: xoá sạch, chỉ giữ tài khoản.** Suijin bắt đầu với thư mục trắng; riêng hai profile Claude đang đăng nhập và hai dòng `managed_account` được mang sang để không phải đăng nhập lại. Workspace, worktree, session, pane layout, usage, hooks và cài đặt đều bỏ. Vì chỉ một máy cần chuyển, việc này làm bằng script chạy tay, **không nhúng code migration vào app**.
- **Q3 — Thư mục repo: đổi sau cùng.** `~/Self-Works/Mercury` thành `~/Self-Works/Suijin` ở bước cuối phase 6, sau khi mọi cổng kiểm tra đã xanh.
