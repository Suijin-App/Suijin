---
phase: 2
title: Mô hình trạng thái quyền
depends_on: [1]
status: pending
---

# Phase 2 — Mô hình trạng thái quyền

## Bối cảnh

Tách phần "đọc trạng thái" khỏi phần "vẽ giao diện" để test được mà không cần hệ thống thật, và để test host không bao giờ làm hiện hộp thoại xin quyền.

## Yêu cầu

- Một kiểu trạng thái dùng chung cho mọi quyền: `allowed`, `denied`, `notDetermined`, `unknown`.
- `unknown` là kết quả hợp lệ. Không bao giờ quy `unknown` thành `allowed`.
- Trạng thái tự làm mới khi app được kích hoạt lại (`NSApplication.didBecomeActiveNotification`), vì người dùng cấp quyền ở System Settings rồi quay lại.
- Mỗi nguồn trạng thái là một closure tiêm vào, để test thay bằng giá trị giả.
- Trong test host (`UserNotifier.isTestHost`), không gọi `requestAuthorization` và không chạy phép thử Full Disk Access trên máy thật trừ khi test tiêm vào.

## File đụng tới

| File | Nội dung |
|---|---|
| `App/Features/Settings/Permissions/PermissionsModel.swift` (mới) | `@Observable @MainActor` model: ba trạng thái, `refresh()`, các hành động `requestNotifications()`, `openNotificationSettings()`, `openLoginItems()`, `openFullDiskAccessSettings()` |
| `App/Features/Settings/Permissions/PermissionProbes.swift` (mới) | Ba phép đọc thật: notifications, helper, full disk access |
| `App/Shell/UserNotifier.swift` | Thêm hàm đọc trạng thái (`authorizationStatus`), để model không gọi thẳng `UNUserNotificationCenter` ở hai nơi |
| `Packages/SuijinTerminal/Sources/SuijinTerminal/PTYHostClient.swift` | Thêm một hàm đọc `SMAppService.agent(...).status` mà không đăng ký, trả về kiểu riêng của package |
| `Packages/SuijinPTYProtocol/...` và `Helpers/SuijinPTYHost` | **Chỉ khi phase 1 kết luận helper phải tự kiểm tra:** thêm một lệnh XPC trả về kết quả phép thử |
| `AppTests/PermissionsModelTests.swift` (mới) | Test ánh xạ trạng thái và làm mới |

## Các bước

1. Viết kiểu trạng thái và model với các closure tiêm vào; chưa nối nguồn thật.
2. Viết test trước cho: ánh xạ từng trạng thái hệ thống sang bốn giá trị; `refresh()` gọi lại cả ba nguồn; nguồn ném lỗi cho ra `unknown`.
3. Nối nguồn Notifications: `notDetermined` → `notDetermined`; `denied` → `denied`; `authorized`/`provisional` → `allowed`.
4. Nối nguồn helper: `enabled` → `allowed`; `requiresApproval` → `denied`; `notRegistered`/`notFound` → `unknown` kèm lý do.
5. Nối nguồn Full Disk Access theo kết quả phase 1. Nếu cần lệnh XPC: tăng `protocolVersion` theo cơ chế tương thích sẵn có và xử lý helper cũ trả lời "không biết lệnh" thành `unknown`.
6. Đăng ký làm mới khi app được kích hoạt lại; huỷ đăng ký khi model bị giải phóng.
7. Các hành động mở System Settings: dùng `SMAppService.openSystemSettingsLoginItems()` cho Login Items; với hai trang còn lại dùng đường dẫn chốt ở phase 1, và nếu `NSWorkspace.open` trả về thất bại thì mở System Settings chung.

## Kiểm chứng

```
scripts/ci-local.sh packages
scripts/ci-local.sh app
```

- Test mới xanh.
- Chạy toàn bộ app test: không có hộp thoại xin quyền nào hiện trên màn hình.

## Rủi ro

- Tăng `protocolVersion` trong khi helper cũ còn chạy session: app mới phải nói chuyện được với helper cũ. Thử đúng tình huống đó, không chỉ thử với helper mới.
- `PTYHostClient.register()` có tác dụng phụ (đăng ký). Hàm đọc trạng thái mới phải thuần đọc.

## Rollback

Xoá hai file mới và hoàn nguyên các file đã sửa. Nếu đã tăng `protocolVersion` thì hoàn nguyên cả hai phía cùng lúc.
