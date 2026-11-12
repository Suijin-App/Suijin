---
phase: 1
title: Bộ nhận diện path và resolver
status: pending
---

# Phase 1: Bộ nhận diện và resolver

## Mục tiêu
Logic thuần, có test, chưa đụng tới UI: từ chữ đang hiện trên terminal, tìm các đoạn là path, rồi xác định path đó có tồn tại và trỏ tới file nào.

## File
- Mới: `Packages/SevindaTerminal/Sources/SevindaTerminal/TerminalPathDetector.swift`. Package không phụ thuộc app.
- Mới: `App/Features/Terminal/TerminalPathResolver.swift`. Phần này cần biết workspace và worktree.
- Test: `Packages/SevindaTerminal/Tests/.../TerminalPathDetectorTests.swift`, `AppTests/TerminalPathResolverTests.swift`.
- Tái dùng phần xử lý `~`, path tương đối và `:line:col` trong `AppModel.openTerminalLink` (`FileTabs.swift`): tách ra hàm thuần dùng chung, không viết lại lần hai.

## Detector
- **Đầu vào:** các dòng hiển thị, mỗi dòng có cờ "nối tiếp dòng trên" (soft wrap). Lấy cờ này từ buffer SwiftTerm: thuộc tính wrapped của `BufferLine`, giống cách `canJoinImplicitRows` làm.
- **Nhận diện:**
  - path tuyệt đối, `~/`, `./` và `../`;
  - path tương đối có ít nhất một `/` hoặc có đuôi file quen thuộc;
  - hậu tố `:line`, `:line:col`, `(line,col)`, `#Lnn`;
  - path bọc trong backtick, ngoặc đơn hoặc ngoặc kép, markdown link `[x](path)`;
  - bỏ dấu câu ở cuối (`.,;:)`).
- **Đánh dấu "elided"** khi có `…`, `...` ở đầu hoặc giữa path, hoặc `~/…`.
- **URL web** (`http(s)://`): nhận diện thành loại `.url` để highlight, không cần kiểm tra trên đĩa.
- **Bỏ qua:** chuỗi quá dài (> 1024 ký tự), dòng prompt của shell nếu xác định được.
- **Đầu ra:** `[PathMatch(text, cells: [(row, colRange)], kind: .full/.elided, line, column)]`. Mỗi match có thể trải qua nhiều dòng.

## Resolver
- `resolve(match, cwd, workspaceRoot) async -> ResolvedPath?`:
  - stat ngoài main thread;
  - cache LRU khoảng 512 mục, TTL 2 s;
  - xoá cache khi FileSystemWatcher báo thay đổi trong thư mục liên quan.
- `candidates(forElided:in root) async -> [URL]`:
  - repo git: dùng `git ls-files -z` (cache theo HEAD và index mtime) rồi khớp phần đuôi path;
  - thư mục thường: duyệt có giới hạn (tối đa khoảng 50k mục, bỏ `node_modules`, `.git`, `build`);
  - trả về tối đa 20 ứng viên, xếp hạng theo độ khớp đuôi rồi độ ngắn.
- cwd cho path tương đối, theo thứ tự ưu tiên:
  1. OSC 7 (`onCurrentDirectoryChange`) mới nhất;
  2. cwd của session;
  3. gốc worktree.

## Test (bảng)
- Có hoặc không có `:12:4`; có dấu cách thì chỉ nhận khi có quote; path trong backtick; markdown link.
- Path wrap qua 2–3 dòng; dòng wrap thật và dòng xuống thường phân biệt đúng.
- Elided: `…/a/b.swift`, `.../Sources/X.swift`, `~/…/c.md`.
- Không nhận: `http://…`, `1.2.3`, `a/b` khi không tồn tại (detector vẫn trả ra, resolver loại).
- Resolver: tồn tại, không tồn tại, thư mục, symlink, cache hit, cache bị xoá khi file thay đổi, ứng viên cho path elided trong repo tạm.

## Xong khi
Test qua và không đụng tới UI. `scripts/ci-local.sh` xanh.
