---
title: "Mục Permissions trong Settings"
description: "Hiện trạng thái từng quyền macOS mà Suijin phụ thuộc và cho người dùng cấp hoặc mở đúng trang System Settings."
status: pending
priority: P2
effort: 1.5d
branch: feat/settings-permissions
tags: [settings, permissions, macos, ui]
blockedBy: []
blocks: []
created: 2026-11-14
---

# Mục Permissions trong Settings

## Tình trạng (2026-11-14)

Phase 1–3 đã làm xong trên nhánh `feat/settings-permissions`; phần tài liệu của phase 4 cũng xong. D1 và D2 theo mặc định của plan (section trong General, không liệt kê Accessibility).

**Còn lại, cần người thao tác trên máy:** chín tình huống thử tay ở phase 4 (cấp và thu hồi quyền trong System Settings), trong đó tình huống 7 xác nhận phải bật Full Disk Access cho mục nào.

## Kết quả mong muốn

Người dùng mở Settings và thấy ngay Suijin đang có những quyền hệ thống nào, thiếu quyền nào, thiếu thì hỏng gì, và bấm một nút là cấp được hoặc tới đúng trang System Settings. Không còn phải đoán vì sao thông báo không hiện hay vì sao agent bị chặn đọc file.

## Hiện trạng (khảo sát 2026-11-14)

- **Settings chưa có giao diện quyền nào.** Thứ duy nhất gần giống là một dòng cảnh báo trong General › Sessions khi helper chưa được duyệt (`SettingsView.swift`, dùng `model.runtimes.hostProblem`).
- **Notifications:** app có xin quyền (`App/Shell/UserNotifier.swift`, `requestAuthorization`) nhưng không hiện trạng thái. Người dùng từ chối một lần là thông báo im lặng mãi, không có chỗ nào báo.
- **Background helper (Login Items):** helper đăng ký qua `SMAppService.agent` (`PTYHostClient.register()`), có trạng thái `requiresApproval`. Plist có `AssociatedBundleIdentifiers = com.tekmium.suijin`.
- **Full Disk Access / Files and Folders:** app không sandbox và không gọi API nào để kiểm tra. Agent và shell chạy dưới helper, nên khi chúng đụng tới Desktop, Documents, Downloads hay dữ liệu app khác, macOS tính quyền cho Suijin.
- **Accessibility: app không dùng.** Không có `AXIsProcessTrusted`, `AXUIElement` hay `CGEvent` nào trong `App/`, `Packages/`, `Helpers/`, `Tools/`. Suijin hiện không cần quyền này.
- `CHANGELOG.md` đang bảo người dùng cấp lại "Full Disk Access, Accessibility and Notifications". Chữ Accessibility ở đó là nói quá.

## Quyết định thiết kế

| # | Quyết định | Lựa chọn của plan | Lý do |
|---|---|---|---|
| D1 | Đặt ở đâu | **Một section "Permissions" trong trang General** | Settings đã có 7 tab; thêm tab thứ 8 làm thanh tab chật ở cửa sổ hẹp. Section này cũng gom luôn dòng cảnh báo Login Items đang nằm lẻ |
| D2 | Có liệt kê Accessibility không | **Không** | App không dùng. Liệt kê một quyền không dùng là dạy người dùng cấp quyền thừa. Nếu sau này có tính năng cần thì thêm một dòng |
| D3 | Full Disk Access | **Có, là quyền "nên có", không bắt buộc** | Thiếu nó app vẫn chạy; agent chỉ bị hỏi quyền từng thư mục hoặc bị chặn ở vài nơi |
| D4 | Kiểm tra Full Disk Access ở tiến trình nào | **Trong một tiến trình do helper khởi động** (chốt ở phase 1) | Đó là cách agent chạy, nên kết quả khớp với thứ agent đọc được; không cần thêm lệnh XPC |

D1 và D2 là lựa chọn mặc định của plan; đổi được trước khi làm phase 3 mà không ảnh hưởng phase 1 và 2.

## Các quyền sẽ hiển thị

| Quyền | Thiếu thì sao | Cách biết trạng thái | Nút hành động |
|---|---|---|---|
| Notifications | Không có banner khi agent chờ nhập hoặc xong việc | `UNUserNotificationCenter.notificationSettings()` | Chưa hỏi: "Allow…" (gọi hộp thoại hệ thống). Đã từ chối: "Open System Settings" |
| Background helper | Session chết theo app, không giữ được khi thoát | `SMAppService.agent(...).status` | "Open Login Items" (`SMAppService.openSystemSettingsLoginItems()`) |
| Full Disk Access | Agent bị hỏi quyền từng thư mục hoặc bị chặn | Thử đọc một đường dẫn được TCC bảo vệ (chốt ở phase 1) | "Open System Settings" tới trang Full Disk Access |

Mỗi dòng có: tên quyền, một câu nói thiếu thì mất gì, huy hiệu trạng thái (Allowed / Not allowed / Not asked / Unknown), và một nút.

## Các phase

| # | Phase | Kết quả | File |
|---|---|---|---|
| 1 | Xác minh cách macOS tính quyền | Biết chắc TCC tính quyền file cho app hay helper, và phép thử Full Disk Access nào đáng tin | [phase-01](phase-01-verify-attribution.md) |
| 2 | Mô hình trạng thái quyền | `PermissionsModel` đọc ba trạng thái, tự làm mới khi app được kích hoạt lại, có test | [phase-02](phase-02-permission-model.md) |
| 3 | Giao diện trong Settings | Section Permissions trong General, đúng quy tắc UI của repo, đã xem ảnh render | [phase-03](phase-03-settings-ui.md) |
| 4 | Kiểm chứng và tài liệu | CI xanh, thử tay trên máy thật, sửa README và CHANGELOG | [phase-04](phase-04-verify-and-docs.md) |

Thứ tự: 1 → 2 → 3 → 4. Phase 1 không sửa code sản phẩm; kết quả của nó quyết định phase 2 có cần thêm một lệnh XPC cho helper hay không.

## Tiêu chí hoàn thành

1. Settings › General có section Permissions với ba dòng ở trên; không có dòng Accessibility.
2. Mỗi trạng thái hiển thị đúng với thực tế trên máy: cấp rồi, chưa cấp, chưa hỏi.
3. Cấp hoặc thu hồi quyền trong System Settings rồi quay lại Suijin: trạng thái tự cập nhật, không phải mở lại Settings hay khởi động lại app.
4. Mỗi nút mở đúng hộp thoại hoặc đúng trang System Settings.
5. Dòng cảnh báo Login Items cũ trong section Sessions không còn lặp lại thông tin của section mới.
6. Test host không bao giờ làm hiện hộp thoại xin quyền.
7. `scripts/ci-local.sh` xanh, không cảnh báo; ảnh render hẹp và rộng, sáng và tối đã được xem.
8. `CHANGELOG.md` và `README.md` không còn nói Suijin cần Accessibility.

## Việc không nằm trong plan này

- Thêm bước xin quyền vào Welcome tour.
- Bất kỳ tính năng nào cần Accessibility, Screen Recording, Automation hay Camera/Microphone.
- Tự động cấp quyền hay sửa cơ sở dữ liệu TCC: macOS không cho, và không nên thử.
- Sandbox app.

## Rủi ro chính

- **Kiểm tra Full Disk Access sai tiến trình.** Nếu TCC tính quyền cho helper mà app tự thử đọc file, Settings sẽ báo "Allowed" trong khi agent vẫn bị chặn (hoặc ngược lại). Phase 1 tồn tại để chặn rủi ro này.
- **Phép thử Full Disk Access không có API chính thức.** Đường dẫn dùng để thử có thể đổi theo phiên bản macOS. Trạng thái "Unknown" phải là một kết quả hợp lệ, không được đoán thành Allowed.
- **Thêm lệnh XPC làm lệch phiên bản giao thức** giữa app và helper đang chạy (`protocolVersion` hiện là 3). Nếu phase 1 buộc phải thêm lệnh, làm theo cơ chế tương thích sẵn có và thử trường hợp helper cũ còn sống.
- **Đường dẫn `x-apple.systempreferences:` không phải API công khai** cho mọi trang. Nếu một đường dẫn không mở được, nút phải rơi về mở System Settings chung, không im lặng.

## Câu hỏi còn mở

1. D1: bạn đồng ý đặt trong General, hay muốn một tab Permissions riêng?
2. D2: bạn hỏi về Accessibility. App hiện không dùng nên plan không liệt kê. Bạn có tính năng nào sắp làm cần quyền này không?
