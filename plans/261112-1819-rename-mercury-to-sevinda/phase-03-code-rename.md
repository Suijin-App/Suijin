---
phase: 3
title: Code: package, module, type, biến môi trường
status: pending
depends_on: [2]
---

# Phase 3: Đổi tên trong code

## Mục tiêu
Mọi package, module, type, biến môi trường và lệnh CLI dùng tên Sevinda. Build và test xanh trở lại.

## Thứ tự (mỗi bước một commit, chạy build sau từng bước)

1. **Thư mục và package** (dùng `git mv` để giữ lịch sử):
   - `Packages/Mercury{Accounts,Agents,Core,Diff,Git,PTYProtocol,Terminal,UI,Usage}` → `Packages/Sevinda*`
   - `Helpers/MercuryPTYHost` → `Helpers/SevindaPTYHost`, `Tools/MercuryCLI` → `Tools/SevindaCLI`
   - Các thư mục Sources/Tests bên trong, kể cả `CMercuryPTY` và `CMercuryTerminalPTY` (đổi luôn module map và `include/`).
   - `App/Resources/Skills/mercury-orchestration` → `sevinda-orchestration`
   - Mỗi `Package.swift`: đổi `name`, product, target, dependency `.package(path: "../Sevinda…")`.
2. **import và tên module**:
   - `import MercuryX` → `import SevindaX`, kể cả `@testable import`.
   - `Bundle.module` không đổi, nhưng resource bundle name sẽ đổi theo package.
3. **Type và symbol có tiền tố**. Dùng refactor của Xcode, hoặc `sed` theo ranh giới từ rồi build lại:
   - `MercurySpacing`, `MercuryColor`, `MercuryRadius`, `MercuryFont`, `MercuryStore`, `MercuryPaths`, `MercuryStats`, `MercuryTerminalView`, `MercuryApp`, `MercuryCommands`…
   - Lệnh gợi ý: `git grep -l -E '\bMercury[A-Z]' -- '*.swift' | xargs sed -i '' -E 's/\bMercury([A-Z][A-Za-z]*)/Sevinda\1/g'`
   - Không động vào: chuỗi trong code migration ở phase 5.
4. **Biến môi trường** `MERCURY_*` → `SEVINDA_*`:
   - Áp dụng cho code app, helper, CLI, hook script, `claude-settings.json` sinh ra và skill.
   - Lưu ý: biến được truyền vào session đang chạy (`MERCURY_SESSION_TOKEN`, `MERCURY_CLI`…). Session cũ sẽ không gọi được CLI mới, vì vậy phase 1 chọn cách (b).
5. **Chuỗi định danh khác**:
   - `mercury-orch-` (thư mục tạm), `mercury.sqlite` → `sevinda.sqlite`;
   - log subsystem `com.tekmium.mercury.*`, tên DispatchQueue;
   - UserDefaults key có tiền tố, launch argument DEBUG `-Mercury…` → `-Sevinda…` (sửa luôn các script trong scratchpad nếu còn dùng);
   - tên theme `"mercury-light"` và `"mercury-dark"`. Theme đã lưu trong settings của người dùng phải được map lại ở phase 5.
6. **CLI**: binary `mercury` → `sevinda`.
   - Áp dụng cho PATH được inject vào terminal, câu `mercury help`, và tài liệu skill (`mercury ask`, `mercury done`…).
   - Cân nhắc: tạo symlink `mercury` trỏ tới `sevinda` trong một phiên bản, để các prompt cũ vẫn chạy.
7. **Comment**: đổi "Mercury" thành "Sevinda" trong comment. Comment lint phải vẫn qua.
8. `scripts/bootstrap.sh` rồi build. Sửa đến khi không còn lỗi và không còn cảnh báo.

## Xong khi
- `git grep -n -E 'Mercury|MERCURY_|mercury' -- '*.swift' '*.h' '*.c' '*.modulemap' 'Package.swift' 'project.yml'` chỉ còn chuỗi migration (phase 5).
- `scripts/ci-local.sh` xanh.

## Rủi ro
- Lệnh `sed` quá rộng có thể đổi nhầm chữ trong tên repo demo hay test fixture. Phải đọc diff trước khi commit.
- C module đổi tên mà module map chưa khớp thì Xcode báo "No such module". Đổi đồng bộ cả thư mục `include/`.
- Cache SwiftPM `.build/` và DerivedData cũ: xoá trước khi build lại.
