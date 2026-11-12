---
phase: 6
title: Kiểm chứng & phát hành
status: pending
depends_on: [2, 3, 4, 5]
---

# Phase 6: Kiểm chứng & phát hành

## Grep gate
```sh
git grep -n -i mercury -- . ':!plans' \
  | grep -v -E 'Migration|LegacyMercury|mercury\.backup|com\.tekmium\.mercury(\.ptyhost)?"' 
```
Lệnh này chỉ được phép trả về các chỗ trong danh sách "Ngoại lệ" của `plan.md`. Đặt code migration vào một file riêng, ví dụ `LegacyMercuryMigration.swift`, để lọc cho dễ.

Kiểm tra thêm tên file và thư mục: `git ls-files | grep -i mercury` phải chỉ còn file migration, file test và lịch sử trong `plans/`.

## Build & test
- [x] Xoá `DerivedData` và các thư mục `Packages/*/.build`. Chạy `scripts/bootstrap.sh`.
- [x] `scripts/ci-local.sh`: xanh, không cảnh báo.
- [x] Test migration ở phase 5 qua.

## Chạy thật
1. **Cài mới**, dùng `MERCURY_DATA_ROOT`… giờ là `SEVINDA_DATA_ROOT` trỏ vào thư mục trống:
   - Onboarding hiện "Welcome to Sevinda".
   - Menu, About, Legal ghi Sevinda.
   - Mở shell, chia pane, kéo-thả pane, mở file, xem diff.
   - Helper mới `SevindaPTYHost` chạy và terminal mở được.
2. **Nâng cấp**, trên bản sao dữ liệu Mercury thật đã backup ở phase 1:
   - Mở Sevinda: workspace, account, pane layout, cài đặt còn nguyên.
   - Session cũ được xử lý đúng theo quyết định ở phase 1.
   - Có thông báo đổi tên. Helper cũ đã được dọn.
3. **CLI và skill**: trong terminal Sevinda, `sevinda help` chạy được. Agent dùng được skill `sevinda-orchestration`.
4. **Ảnh chụp**: welcome, About, Settings, menu app, ở chế độ sáng và tối, cửa sổ 1000×640 và ~1400. Tự xem lại toàn bộ.

## Phát hành
- [x] Chưa có tên miền: không phát hành Sparkle. Ghi một việc riêng "bật cập nhật cho Sevinda khi có tên miền" (DNS, appcast, downloads, `SUFeedURL`, legal text).
- [ ] Ký và notarize bằng script đã đổi tên ở phase 2. Kiểm tra `spctl -a -vv Sevinda.app` và `stapler validate`.
- [x] Release notes: "Mercury is now Sevinda".
- [ ] Push và tag chỉ khi được anh duyệt.

## Đổi tên thư mục repo (bước cuối, sau khi mọi thứ đã merge)
1. Thoát Xcode và mọi phiên Claude Code đang mở repo. Dừng app Debug và helper Debug đang chạy từ repo.
2. `mv ~/Self-Works/Mercury ~/Self-Works/Sevinda`, rồi `scripts/bootstrap.sh` để tạo lại project. Xoá DerivedData cũ của Mercury.
3. **Memory của Claude Code** được lưu theo đường dẫn project: `~/.claude/projects/-Users-vudev-Self-Works-Mercury/memory`. Chép thư mục `memory/` sang `~/.claude/projects/-Users-vudev-Self-Works-Sevinda/memory`, để ghi chú và quy tắc đã học không bị mất. Thư mục project mới chỉ có sau khi mở Claude Code ở đường dẫn mới một lần.
4. Sửa các đường dẫn tuyệt đối còn trỏ tới `Self-Works/Mercury` (git grep sau khi đổi, ví dụ trong docs hay script).
5. Nếu sau này tạo remote GitHub thì đặt tên repo là `Sevinda`.
6. Chạy lại `scripts/ci-local.sh` ở đường dẫn mới.

## Xong khi
Đạt đủ các tiêu chí trong `plan.md`.

## Kết quả (2026-11-12)
- Ký Developer ID cho app và `SevindaPTYHost` qua `scripts/release-notarize.sh --dry-run`: được. Chưa notarize vì máy chưa có keychain profile `sevinda-notary`.
- `ci-local.sh` xanh (9 package, app 124 test), không cảnh báo; test thời gian `TerminalFeedSchedulerTests` (giới hạn 50 ms) thỉnh thoảng đỏ khi máy tải nặng, chạy riêng thì xanh.
- Còn lại cho anh: đổi tên thư mục repo và chép memory (mục cuối), tạo profile notary, push/tag.
