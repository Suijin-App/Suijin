---
phase: 3
title: Code — package, module, type, env
depends_on: [2]
status: pending
---

# Phase 3 — Code: package, module, type, env

## Bối cảnh

Phần lớn trong 3.058 chỗ nằm ở đây. Việc này cơ học nhưng phải đúng thứ tự: đổi tên thư mục trước, rồi mới đổi chữ trong nội dung file, nếu không `git` mất dấu lịch sử và diff thành không đọc nổi.

## Phạm vi

| Nhóm | Số lượng | Đổi thành |
|---|---|---|
| Package | 9 thư mục `Packages/Sevinda*` | `Packages/Suijin*` |
| C target | `CSevindaPTY`, `CSevindaTerminalPTY` | `CSuijinPTY`, `CSuijinTerminalPTY` |
| Helper | `Helpers/SevindaPTYHost` | `Helpers/SuijinPTYHost` |
| CLI | `Tools/SevindaCLI`, binary `sevinda` | `Tools/SuijinCLI`, binary `suijin` |
| Type | `SevindaSpacing` 229, `SevindaStore` 132, `SevindaColor` 119, `SevindaTerminalView` 47, `SevindaRadius` 20, `SevindaPTYHostKit` 15 | tiền tố `Suijin` |
| Env var | ~40 `SEVINDA_*` | `SUIJIN_*` |

## Các bước

1. **Đổi tên thư mục bằng `git mv`**, từng package một, kèm cả thư mục `Sources/<Tên>` bên trong:
   ```
   git mv Packages/SevindaCore Packages/SuijinCore
   git mv Packages/SuijinCore/Sources/SevindaCore Packages/SuijinCore/Sources/SuijinCore
   git mv Packages/SuijinCore/Tests/SevindaCoreTests Packages/SuijinCore/Tests/SuijinCoreTests
   ```
   Lặp cho 9 package, helper, CLI và hai C target.

2. **Sửa `Package.swift` của từng package**: `name`, `products`, `targets`, `dependencies` trỏ sang tên mới.

3. **Đổi chữ trong nội dung file.** Chạy trên toàn repo trừ các vùng loại trừ:
   ```
   git grep -lI -e Sevinda -e sevinda -e SEVINDA -- \
     ':!plans' ':!docs' ':!*.xcstrings' \
     | xargs sed -i '' -e 's/Sevinda/Suijin/g' -e 's/sevinda/suijin/g' -e 's/SEVINDA/SUIJIN/g'
   ```
   `docs/` và String Catalog để phase 4 xử lý riêng vì cần đọc từng câu.

4. **Soát lại các chỗ `sed` dễ làm sai**: chuỗi hiển thị lẫn trong code, tên file ảnh, comment tiếng Anh, và những chỗ "sevinda" nằm giữa một từ dài hơn.

5. **Chạy lại bootstrap và build từng package trước, rồi app**:
   ```
   scripts/bootstrap.sh
   for p in Packages/Suijin*; do (cd "$p" && swift build) || break; done
   ```

## Kiểm chứng

```
scripts/ci-local.sh packages
scripts/ci-local.sh app
```
Cả hai phải xanh. Đây là lần đầu app build lại được kể từ phase 2.

```
git grep -i sevinda -- ':!plans' ':!docs' ':!*.xcstrings' ':!App/Migration' ':!AppTests'
```
không còn kết quả.

## Rủi ro

- `sed` trên toàn repo sẽ đụng cả comment và chuỗi hiển thị. Phải đọc diff trước khi commit, không commit mù.
- Đổi tên thư mục mà không dùng `git mv` làm mất lịch sử file và khiến review không thể đọc được.
- Xcode đang mở sẽ giữ tham chiếu tới đường dẫn cũ; đóng Xcode trước khi chạy.

## Rollback

Phase này nên là một commit duy nhất sau khi CI xanh. Nếu hỏng: `git reset --hard` về commit cuối của phase 2 rồi làm lại.
