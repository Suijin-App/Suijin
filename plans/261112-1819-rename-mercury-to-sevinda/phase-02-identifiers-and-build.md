---
phase: 2
title: Định danh & cấu hình build
status: done
depends_on: [1]
---

# Phase 2: Định danh & cấu hình build

## Mục tiêu
Thay tên sản phẩm, bundle ID và mọi định danh hệ thống ở tầng build và cấu hình, chưa đụng tới code Swift.

## File
- `project.yml`:
  - `name`;
  - các target `Mercury`, `MercuryPTYHost`, `MercuryCLI`, `MercuryAppTests`: đổi tên target, `PRODUCT_NAME`, `PRODUCT_BUNDLE_IDENTIFIER`;
  - đường dẫn source sau khi `git mv` ở phase 3;
  - scheme.
- `App/Info.plist`:
  - `CFBundleName`, `CFBundleDisplayName` (nếu có);
  - `NSHumanReadableCopyright`;
  - `SUFeedURL`: **gỡ bỏ**, vì chưa có tên miền. Kiểm tra `App/Updates/*` để chắc rằng updater hiện "updates not configured" thay vì báo lỗi;
  - `UTExportedTypeDeclarations`: `com.tekmium.sevinda.pane`;
  - các usage description có chữ Mercury.
- `App/Mercury.entitlements` → `App/Sevinda.entitlements` (đổi luôn tham chiếu trong `project.yml`).
- `App/Resources/LaunchAgents/com.tekmium.mercury.ptyhost.plist` → `com.tekmium.sevinda.ptyhost.plist`:
  - `Label`, `BundleProgram` (`Contents/MacOS/SevindaPTYHost`);
  - `MachServices`, `AssociatedBundleIdentifiers`.
- Code đăng ký helper: tìm `SMAppService.agent(plistName:` và chuỗi `com.tekmium.mercury.ptyhost`. Phía app và phía helper phải trùng tên Mach service. Requirement code-signing của kết nối XPC có chứa bundle ID, nên cũng phải đổi.
- `scripts/` (`ci-local.sh`, `bootstrap.sh`, `release-*.sh`, notarize):
  - tên scheme và app;
  - `Mercury.app`, `Mercury-<version>.dmg`;
  - gỡ `MERCURY_DOWNLOAD_BASE_URL`/`mercury.tekmium.com`. Script phát hành chỉ build, ký và notarize, không upload;
  - biến `MERCURY_SIGNING_IDENTITY`, `MERCURY_NOTARY_PROFILE`, `MERCURY_TEAM_ID`, `MERCURY_SPARKLE_ACCOUNT`, `MERCURY_RELEASE_DIR` → `SEVINDA_*`.
- `docs/release-process.md`: phần lệnh, cập nhật cùng lúc với script.
- `Tools/comment-lint`: nếu lint có danh sách đường dẫn cố định.

## Các bước
1. Sửa `project.yml` và các file plist/entitlements ở trên.
2. Đổi tên biến trong script release, và đổi tên profile notary trong Keychain nếu tên profile có chữ Mercury (lệnh `xcrun notarytool store-credentials sevinda ...`).
3. Chưa chạy build: chờ phase 3 xong.

## Xong khi
- `git grep -n -i 'com\.tekmium\.mercury\|PRODUCT_NAME: Mercury\|MERCURY_' -- project.yml App/*.plist App/*.entitlements App/Resources/LaunchAgents scripts docs/release-process.md` không còn kết quả, trừ những chỗ có chủ đích để lại cho migration.

## Rủi ro
- Mach service của app và helper lệch nhau thì terminal không mở được. Phải kiểm tra trong phase 6 bằng cách chạy app thật.
- Requirement code-signing phải khớp với Team ID và bundle ID mới.
