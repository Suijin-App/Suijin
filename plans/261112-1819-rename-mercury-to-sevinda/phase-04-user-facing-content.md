---
phase: 4
title: Nội dung người dùng nhìn thấy
status: done
depends_on: [3]
---

# Phase 4: Nội dung người dùng nhìn thấy

## Mục tiêu
Mọi chữ người dùng nhìn thấy đều ghi "Sevinda": UI, menu, thông báo, onboarding, About, Legal, tài liệu.

## Phạm vi
- **Chuỗi UI trong Swift**:
  - `Text("…Mercury…")` và `String(localized:)`, ví dụ "Welcome to Mercury", "Keep sessions running after quitting Mercury", "Quit Mercury", các thông báo lỗi và mô tả trong Settings.
  - Menu app: tên lấy từ `PRODUCT_NAME`. Kiểm tra lại "About/Hide/Quit Sevinda".
- **String Catalog** (`App/Resources/Localizable.xcstrings` và catalog trong các package): key chính là câu tiếng Anh, khoảng 52 key có chữ Mercury.
  - Sau khi sửa code, build rồi chạy `xcrun xcstringstool sync … --stringsdata …` để key mới xuất hiện.
  - Xoá các key cũ đã thành stale.
  - Đối chiếu bằng diff danh sách key, giống cách đã làm cho tab About.
- **Onboarding** (`App/Features/Onboarding/OnboardingTour.swift`): tiêu đề "Welcome to Sevinda", mô tả, và menu Help › "Welcome to Sevinda".
- **Ảnh onboarding** (`Assets.xcassets/Onboarding*.imageset`):
  - Kiểm tra trong ảnh có chữ "Mercury" không, ví dụ tiêu đề cửa sổ hay đường dẫn.
  - Nếu có, chụp lại bằng quy trình cũ: app active, cửa sổ ~1000×640, dữ liệu demo, kiểm tra quyền riêng tư.
- **About/Legal** (`AboutSettings.swift`, `LegalDocuments.swift`):
  - Đổi tên ứng dụng và câu mô tả.
  - Terms và Privacy: đổi tên, đường dẫn `~/Library/Application Support/Sevinda`, tên miền cập nhật mới, tên skill.
  - Đổi ngày "Effective" sang ngày phát hành bản đổi tên.
  - Cập nhật `plans/reports/about-legal-draft-*.md`, hoặc viết bản nháp mới.
- **Skill** `sevinda-orchestration/SKILL.md`: tên, mô tả, các lệnh `sevinda …`.
- **Thông báo hệ thống, notification, tiêu đề cửa sổ phụ** (ví dụ Design Gallery, nếu còn).
- **Tài liệu**: `README.md`, `CLAUDE.md` (dòng đầu "Mercury — repository rules" và mọi đoạn mô tả), `docs/architecture.md`, `docs/release-process.md`, `docs/brand/`.
- **Memory của Claude Code** trong `~/.claude/projects/...Mercury.../memory`: cập nhật các ghi chú nhắc tới tên app. Chỉ sửa nội dung, không đổi thư mục project.

## Xong khi
- `git grep -n -i mercury -- App Packages docs README.md CLAUDE.md` chỉ còn chuỗi migration.
- Chụp lại và tự xem các màn hình: welcome, About, Settings › General, menu app, ở chế độ sáng và tối.

## Rủi ro
- Quên catalog của từng package (nếu có `Resources/Localizable.xcstrings` trong package), làm chuỗi hiện ra dưới dạng key thô.
- Ảnh onboarding cũ còn chữ Mercury: soát kỹ từng ảnh.
