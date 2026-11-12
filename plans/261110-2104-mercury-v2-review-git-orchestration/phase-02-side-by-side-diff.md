---
phase: 2
title: "Diff hai cột"
status: pending
priority: P2
effort: "3d"
dependencies: []
---

# Phase 2: Diff hai cột

## Goal

Thêm chế độ xem diff hai cột (bản cũ bên trái, bản mới bên phải) bên cạnh chế độ unified, chuyển qua lại bằng một segmented `Picker` trên toolbar.

## Architecture

- Từ model hunk/line của `MercuryGit` (plan 1 phase 8), dựng hai luồng dòng đã căn hàng: dòng bị xoá chỉ ở trái, dòng thêm chỉ ở phải, phía thiếu chèn dòng đệm để hai bên luôn bằng chiều cao.
- Cặp dòng xoá/thêm liền nhau được ghép hàng ngang; có highlight mức từ (word diff) cho các cặp này.
- Hai `DiffTextView` dùng chung một `NSScrollView` cha, hoặc đồng bộ qua thông báo `boundsDidChange`; cuộn ngang thì độc lập.
- Highlight cú pháp dùng lại bộ tree-sitter của plan 1, mỗi cột theo nội dung bản đó.
- Ghi chú của phase 1 hiện ở cột phải.
- Cửa sổ hẹp hơn một ngưỡng thì tự chuyển về unified và báo nhẹ.

## Files to create / modify

- Create: `Packages/MercuryDiff/Sources/MercuryDiff/{SideBySideLayout,SideBySideDiffView,WordDiff}.swift`.
- Modify: `App/Features/Diff/DiffScreen.swift` (picker chế độ, lưu lựa chọn).
- Tests: `SideBySideLayoutTests` (căn hàng với thêm/xoá/sửa xen kẽ), `WordDiffTests`.

## Tasks & steps

1. Thuật toán căn hàng, kèm test.
2. Word diff cho cặp dòng sửa.
3. View hai cột, cuộn đồng bộ.
4. Picker chế độ, nhớ lựa chọn; tự về unified khi cửa sổ hẹp.

## Verification

- Test căn hàng và word diff pass.
- Diff 5.000 dòng ở hai cột vẫn cuộn mượt.
- Ảnh chụp offscreen sáng/tối, cửa sổ hẹp/rộng.
