---
phase: 8
title: "Diff viewer native"
status: pending
priority: P2
effort: "3d"
dependencies: [4]
---

# Phase 8: Diff viewer native

## Goal

Xem thay đổi của worktree so với base branch, hoặc thay đổi chưa commit: danh sách file và diff unified có highlight cú pháp, cuộn mượt với diff lớn. Chỉ đọc.

## Architecture

- `MercuryGit` thêm:
  - `git diff --name-status -z <base>...HEAD` và cho working tree.
  - `git diff --no-color --unified=3 <base> -- <file>`.
  - Parser unified diff thành model hunk/line, có test.
- Package `MercuryDiff`:
  - `DiffTextView` dựa trên TextKit 2 (`NSTextLayoutManager`, `NSTextContentStorage`). Có thể dùng STTextView làm nền nếu giảm đáng kể công sức (chốt trong spike).
  - Nền dòng thêm/xoá bằng token màu (`ok`, `error` với độ trong suốt thấp), số dòng hai cột cũ/mới.
  - Highlight cú pháp bằng tree-sitter (SwiftTreeSitter) cho các ngôn ngữ phổ biến; file lạ thì không highlight.
- UI: danh sách file bên trái (`List`), diff bên phải; tự làm mới khi file trong worktree đổi (FSEvents, có debounce).
- Workspace `folder` không có git nên không có diff: hiện `ContentUnavailableView` giải thích, kèm nút "Khởi tạo git" (chạy `git init` sau khi người dùng xác nhận).
  <!-- Updated: user request - support both git repos and plain folders -->

## Files to create

- `Mercury/Packages/MercuryGit/Sources/MercuryGit/{DiffParser,DiffModels}.swift` + tests.
- `Mercury/Packages/MercuryDiff/Sources/MercuryDiff/{DiffTextView,DiffLayout,SyntaxHighlighter}.swift`.
- `Mercury/App/Features/Diff/{DiffScreen,ChangedFilesList}.swift`.

## Tasks & steps

1. Parser diff + test với các trường hợp: file mới, file xoá, đổi tên, binary, không có newline cuối file.
2. Spike TextKit 2 so với STTextView cho 5.000 dòng diff; chọn một.
3. Render diff, số dòng, màu nền.
4. Highlight tree-sitter chạy nền, cập nhật dần.
5. Tự làm mới bằng FSEvents.

## Verification

- `swift test --package-path Packages/MercuryGit` pass các ca diff.
- Diff 5.000 dòng cuộn mượt; mở file binary không treo.
- Ảnh chụp offscreen sáng/tối.

## Next (ngoài plan)

Ghi chú theo dòng gửi lại cho agent, diff hai cột, stage/commit.
