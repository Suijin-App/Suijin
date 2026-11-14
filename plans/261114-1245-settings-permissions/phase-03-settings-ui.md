---
phase: 3
title: Giao diện trong Settings
depends_on: [2]
status: pending
---

# Phase 3 — Giao diện trong Settings

## Bối cảnh

Đưa model của phase 2 lên màn hình, theo đúng quy tắc UI trong `CLAUDE.md`: component hệ thống, Liquid Glass thật, chữ tiếng Anh qua String Catalog, có trạng thái rỗng và lỗi, không làm rộng cửa sổ.

## Thiết kế

Một `Section` tên **Permissions** trong `GeneralSettings`, đặt ngay sau section Sessions. Ba dòng, mỗi dòng là một `LabeledContent`:

```
Permissions
┌──────────────────────────────────────────────────────────────────────┐
│ Notifications                              ● Allowed                 │
│ Banners when an agent waits for input or finishes.                   │
├──────────────────────────────────────────────────────────────────────┤
│ Background helper                    ● Not allowed  [Open Login Items]│
│ Keeps sessions running after you quit Suijin.                        │
├──────────────────────────────────────────────────────────────────────┤
│ Full Disk Access                 ○ Not allowed  [Open System Settings]│
│ Optional. Lets agents read folders macOS protects without asking     │
│ for each one.                                                        │
└──────────────────────────────────────────────────────────────────────┘
Suijin never changes these itself. Grant or revoke them in System Settings.
```

- **Huy hiệu trạng thái:** SF Symbol kèm chữ, không chỉ dựa vào màu. `checkmark.circle.fill` (Allowed), `xmark.circle.fill` (Not allowed), `questionmark.circle` (Not asked / Unknown).
- **Nút chỉ hiện khi có việc để làm.** Quyền đã cấp thì không có nút.
- **Notifications chưa hỏi:** nút "Allow…" gọi hộp thoại hệ thống. Đã từ chối: nút "Open System Settings".
- **Full Disk Access ghi rõ "Optional"** và dùng huy hiệu trung tính khi chưa cấp, không dùng màu cảnh báo: thiếu nó không phải lỗi.
- **Trạng thái Unknown** kèm một câu lý do ngắn từ model.
- Dòng cảnh báo Login Items hiện có trong section Sessions được rút thành một câu ngắn trỏ xuống section Permissions, để không nói cùng một điều ở hai nơi.

## File đụng tới

| File | Nội dung |
|---|---|
| `App/Features/Settings/Permissions/PermissionsSection.swift` (mới) | Section và một view dòng dùng chung |
| `App/Features/Settings/SettingsView.swift` | Chèn section vào `GeneralSettings`; rút gọn cảnh báo trong Sessions |
| `App/Resources/Localizable.xcstrings` | Chuỗi mới, do Xcode sinh khi build |
| `AppTests/ScreenshotTests.swift` hoặc một file test ảnh riêng | Render section ở các trạng thái |

## Các bước

1. Viết view dòng nhận: tiêu đề, mô tả, trạng thái, nhãn nút và hành động tuỳ chọn. Thêm `accessibilityLabel` gộp tên quyền và trạng thái.
2. Viết `PermissionsSection` dùng `PermissionsModel`; gọi `refresh()` khi section xuất hiện.
3. Chèn vào `GeneralSettings`, rút gọn cảnh báo cũ.
4. Thêm test ảnh với model giả ở ba tổ hợp: tất cả đã cấp; tất cả chưa cấp; lẫn lộn có một Unknown. Render hẹp và rộng, sáng và tối (`SUIJIN_SCREENSHOTS`).
5. Xem từng ảnh. Sửa mọi chỗ bị cắt chữ, lệch hàng hoặc nút đẩy rộng cột.
6. Build để Xcode sinh key vào String Catalog; kiểm tra không có key mồ côi.

## Kiểm chứng

- Ảnh render đã được xem ở cả bốn biến thể, không có chữ bị cắt ở độ rộng hẹp.
- `Tools/comment-lint/comment-lint.py` xanh.
- Mở app thật: section hiện đúng trạng thái của máy; bấm từng nút mở đúng nơi.
- VoiceOver đọc được tên quyền, trạng thái và nút của từng dòng.

## Rủi ro

- Nhãn nút dài ("Open System Settings") cộng huy hiệu có thể đẩy rộng dòng ở cửa sổ hẹp. Nếu vậy, cho nút xuống dòng dưới mô tả thay vì thu nhỏ chữ.
- Tự vẽ huy hiệu bằng nền bo tròn giả kính là vi phạm quy tắc Liquid Glass của repo. Chỉ dùng `Label` với SF Symbol và màu hệ thống.

## Rollback

Xoá file section mới và hoàn nguyên `SettingsView.swift` cùng String Catalog.
