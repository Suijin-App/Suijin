---
phase: 2
title: Định danh & build
depends_on: [1]
status: pending
---

# Phase 2 — Định danh & build

## Bối cảnh

Đổi mọi định danh mà hệ điều hành và hệ thống build nhìn thấy: tên sản phẩm, bundle ID, Mach service, LaunchAgent, UTType, entitlements, script phát hành. Sau phase này app **chưa build được** vì code vẫn import module tên cũ; đó là trạng thái dự kiến và phase 3 đóng lại khoảng hở đó.

## Yêu cầu

- Mọi `com.tekmium.sevinda*` thành `com.tekmium.suijin*`.
- `PRODUCT_NAME` của bốn target đổi theo bảng tên ở `plan.md`.
- Tên file LaunchAgent plist đổi theo Mach service, vì `SMAppService.agent(plistName:)` đọc theo đúng tên file.

## File đụng tới

| File | Nội dung đổi |
|---|---|
| `project.yml` | `name:`, `PRODUCT_NAME` (app, ptyhost, cli, apptests), `PRODUCT_BUNDLE_IDENTIFIER` cả bốn, đường dẫn `Helpers/SevindaPTYHost`, `Tools/SevindaCLI`, tên file LaunchAgent trong `sources`/`copyFiles` |
| `App/Info.plist` | `CFBundleName`, `CFBundleDisplayName`, UTType `com.tekmium.sevinda.pane`, mọi chuỗi mô tả quyền có tên app |
| `App/Resources/LaunchAgents/com.tekmium.sevinda.ptyhost.plist` | `git mv` sang `com.tekmium.suijin.ptyhost.plist`; `Label` và `MachServices` bên trong |
| `App/*.entitlements`, `Helpers/SevindaPTYHost/*.entitlements` | Mọi app group, keychain group, temporary exception có tên cũ |
| `Packages/SevindaPTYProtocol/Sources/SevindaPTYProtocol/PTYHostProtocol.swift` | `defaultMachServiceName`, `machServiceOverrideEnv`, `launchAgentPlist` |
| `scripts/make-dmg.sh`, `scripts/release-notarize.sh`, `scripts/ci-local.sh`, `scripts/bootstrap.sh` | Tên `.app`, tên DMG, biến `SEVINDA_SIGNING_IDENTITY` / `SEVINDA_NOTARY_PROFILE`, đường dẫn build |

## Các bước

1. `git mv` file LaunchAgent plist sang tên mới trước, để diff của `project.yml` khớp với file có thật.
2. Sửa `project.yml`, chạy `scripts/bootstrap.sh` để sinh lại `Suijin.xcodeproj`. Xoá `Sevinda.xcodeproj` cũ nếu bootstrap không tự thay.
3. Sửa Info.plist và entitlements.
4. Sửa `PTYHostConstants` — đây là nơi duy nhất định nghĩa Mach service và tên plist, nếu lệch thì helper không đăng ký được.
5. Sửa bốn script trong `scripts/`.
6. Chưa chạy CI. Build sẽ đỏ cho tới hết phase 3.

## Kiểm chứng

```
git grep -n "com\.tekmium\.sevinda" -- ':!plans' ':!App/Migration' ':!AppTests'
```
chỉ còn kết quả trong code migration (sẽ thêm ở phase 5) và test của nó.

```
ls App/Resources/LaunchAgents/
xcodebuild -list -project Suijin.xcodeproj
```
tên scheme và target phải là Suijin.

## Rủi ro

Mach service, `Label` trong plist và tên file plist phải trùng nhau tuyệt đối. Lệch một chỗ thì helper không khởi động được và mọi terminal chết ngay lúc chạy, không báo lỗi lúc build.

## Rollback

`git checkout -- project.yml App/Info.plist App/Resources/LaunchAgents scripts/` rồi chạy lại `scripts/bootstrap.sh`.
