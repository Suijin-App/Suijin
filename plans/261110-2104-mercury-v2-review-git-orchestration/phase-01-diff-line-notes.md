---
phase: 1
title: "Ghi chú theo dòng trên diff"
status: pending
priority: P1
effort: "4d"
dependencies: []
---

# Phase 1: Ghi chú theo dòng trên diff

## Goal

Người dùng ghi chú lên một dòng, một khoảng dòng hoặc cả file trong diff, rồi gửi một lượt các ghi chú chưa gửi vào phiên agent của worktree đó.

## Key insights (từ Orca)

- Model ghi chú (`src/shared/diff-comment-types.ts`): `id`, `worktreeId`, `filePath`, `startLine?`, `lineNumber` (0 nghĩa là cả file), `body`, `createdAt`, `updatedAt?`, `sentAt?` (sửa thì xoá), `scope` (`unstaged` | `staged` | `branch`), `oldPath?`, `diffIdentity?`. Bản đầu chỉ ghi chú phía bản mới.
- Định dạng gửi agent (`src/shared/diff-comments-format.ts`), cố định và an toàn với dấu nháy:
  ```
  File: <path>
  Line: <n>            (hoặc "Lines: a-b", hoặc "Scope: file")
  User comment: "<body đã escape \\ \" \r \n>"
  ```
  Nhiều ghi chú nối với nhau bằng một dòng trống.

## Architecture

- `MercuryCore`: bảng `diff_note` (migration mới), gắn với worktree hoặc workspace `folder`.
- `MercuryDiff`: nút "+" ở rãnh số dòng khi rê chuột, kéo để chọn khoảng dòng, ô soạn ghi chú nằm ngay dưới dòng (view chèn giữa các dòng TextKit 2), thẻ ghi chú đã lưu.
- Khi diff đổi (`diffIdentity` khác), ghi chú vẫn giữ nhưng được đánh dấu "có thể đã lệch" nếu dòng đó không còn.
- Gửi:
  - "Send to agent": ghép text theo định dạng trên, đưa vào phiên agent đang mở của worktree bằng **bracketed paste** (`ESC[200~ … ESC[201~`) để TUI nhận như một lần dán, không chạy từng dòng. Người dùng tự nhấn Enter, hoặc bật tuỳ chọn tự gửi.
  - "Copy": chép vào clipboard.
  - Gửi xong thì đặt `sentAt`.
- Workspace `folder` không có diff nên không ghi chú trên diff được; ghi chú trên file mở trong viewer là việc ngoài plan này.

## Files to create / modify

- Create: `Packages/MercuryCore/Sources/MercuryCore/DiffNote.swift`, migration `v_diff_note`.
- Create: `Packages/MercuryDiff/Sources/MercuryDiff/{DiffNoteGutter,DiffNoteComposer,DiffNoteCard,DiffNoteFormatter}.swift`.
- Modify: `Packages/MercuryDiff/Sources/MercuryDiff/DiffTextView.swift` để chèn view giữa các dòng.
- Create: `App/Features/Diff/DiffNotesSendMenu.swift`.
- Tests: `DiffNoteFormatterTests` (escape, khoảng dòng, cả file, nhiều ghi chú), lưu/đọc DB.

## Tasks & steps

1. Model và migration, kèm test.
2. Formatter port từ Orca, với test dùng chuỗi kết quả viết tay (không tính bằng code production).
3. Gutter, kéo chọn khoảng dòng, ô soạn và thẻ ghi chú.
4. Gửi vào phiên agent bằng bracketed paste; chọn phiên nếu worktree có nhiều phiên.
5. Trạng thái đã gửi/chưa gửi; lọc "Unsent".

## Verification

- Test formatter và DB pass.
- Tạo 3 ghi chú (một dòng, một khoảng, cả file), gửi vào Claude Code; prompt của Claude hiện đúng nội dung, không tự chạy từng dòng.
- Sửa ghi chú đã gửi thì nó quay về "chưa gửi".
