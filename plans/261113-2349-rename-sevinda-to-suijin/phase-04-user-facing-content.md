---
phase: 4
title: Nội dung người dùng thấy
depends_on: [3]
status: pending
---

# Phase 4 — Nội dung người dùng thấy

## Bối cảnh

Phase 3 cố tình bỏ qua `docs/` và String Catalog vì hai chỗ đó cần đọc từng câu chứ không thay máy móc. Đây cũng là nơi quyết định người dùng nhìn thấy tên mới có tự nhiên không, hay chỉ là chữ "Sevinda" bị thay thô.

## Phạm vi

| Nhóm | Chi tiết |
|---|---|
| String Catalog | `App/Resources/Localizable.xcstrings`, 78 chỗ chứa chữ Sevinda |
| Tài liệu | `README.md`, `CLAUDE.md`, `docs/architecture.md`, `docs/release-process.md`, mọi file còn lại trong `docs/` |
| Trong app | About, Onboarding, Legal (`App/Features/Settings/LegalDocuments.swift`), menu chính, tên cửa sổ |
| CHANGELOG | Thêm một dòng "Sevinda is now Suijin" |

## Các bước

1. **String Catalog.** Key là chính câu tiếng Anh, nên đổi chữ trong code Swift sẽ sinh key mới. Trình tự đúng:
   - sửa chuỗi trong code Swift trước;
   - build để Xcode sinh key mới vào `.xcstrings`;
   - xoá key mồ côi còn chữ Sevinda.

   Hiện chỉ có tiếng Anh nên không mất bản dịch nào.

2. **Legal và About.** `LegalDocuments.swift` có hai câu ghi thẳng đường dẫn `~/Library/Application Support/Sevinda`. Phải khớp với đường dẫn thật sau phase 5, nếu không là nói sai với người dùng về nơi dữ liệu nằm.

3. **CLAUDE.md.** Đổi "Sevinda — repository rules", mục "Sevinda-specific rules", mọi nhắc tới `SevindaPTYHost`, `SevindaUI`, và đường dẫn Application Support.

4. **README và docs.** Đọc lại chứ không `sed`: một số câu nhắc tên app trong ngữ cảnh mô tả sản phẩm, đổi thô sẽ ra câu lủng củng.

5. **Ảnh chụp màn hình** trong `docs/` nếu có hiển thị tên cũ: chụp lại sau khi app chạy được với tên mới.

## Kiểm chứng

```
git grep -i sevinda -- '*.md' '*.xcstrings'
```
chỉ còn dòng trong CHANGELOG và `plans/`.

```
Tools/comment-lint/comment-lint.py
```
vẫn xanh (mọi comment vẫn là tiếng Anh).

Chạy app và mở: menu chính, About, Onboarding, Settings › Legal. Không còn chữ Sevinda trên màn hình.

## Rủi ro

Key mồ côi trong String Catalog không làm build đỏ nhưng tích tụ thành rác và sau này gây nhầm khi thêm ngôn ngữ. Phải dọn ở phase này, không để lại.

## Rollback

`git checkout -- docs/ README.md CLAUDE.md App/Resources/Localizable.xcstrings`.
