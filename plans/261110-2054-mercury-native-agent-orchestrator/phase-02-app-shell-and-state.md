---
phase: 2
title: "Khung app và lưu trạng thái"
status: pending
priority: P1
effort: "4d"
dependencies: [1]
---

# Phase 2: Khung app và lưu trạng thái

## Goal

Có sidebar workspace (repo git → worktree, hoặc thư mục thường → phiên), vùng nội dung theo tab, thanh trạng thái, Settings, và state lưu bền bằng GRDB.

## Architecture

- `NavigationSplitView`: sidebar (repo, worktree dưới mỗi repo), detail (tab terminal/diff), `.inspector` cho thông tin worktree.
- Thanh trạng thái dưới cùng: usage tài khoản (phase 5–6), số phiên đang chạy, RAM app.
- `Settings` scene dùng `Form`: General, Agents, Accounts, Terminal.
- Package `MercuryCore`: model và store.
  - Bảng: `workspace` (cột `kind`: `git` hoặc `folder`), `worktree` (chỉ cho workspace `git`), `agent_session`, `managed_account`, `setting`.
  <!-- Updated: user request - support both git repos and plain folders -->
  - Phiên agent gắn vào worktree (git) hoặc thẳng vào workspace (folder).
  - Migration GRDB đánh version; DB ở `~/Library/Application Support/Mercury/mercury.sqlite`.
- `AppModel` `@Observable`, `@MainActor`; IO chạy ngoài main thread.

## Files to create

- `Mercury/Packages/MercuryCore/Package.swift`, `Sources/MercuryCore/{Models,Store,Migrations}.swift`, `Tests/MercuryCoreTests/`.
- `Mercury/App/AppModel.swift`, `Mercury/App/Shell/{SidebarView,StatusBarView,MainToolbar}.swift`.
- `Mercury/App/Features/Settings/SettingsView.swift`.
- `Mercury/App/Features/Workspaces/AddWorkspaceFlow.swift` (chọn thư mục qua `NSOpenPanel`, tự nhận biết repo git hay thư mục thường).

## Tasks & steps

1. Tạo `MercuryCore` với GRDB, migration v1, test đọc/ghi.
2. Thêm workspace: chọn thư mục, chạy `git rev-parse --show-toplevel`. Thành công thì lưu loại `git` với gốc repo; thất bại thì lưu loại `folder`. Cả hai đều hợp lệ.
3. Sidebar hiện workspace; workspace `git` có worktree con (lấy từ phase 4), workspace `folder` hiện thẳng các phiên. Biểu tượng SF Symbol khác nhau cho hai loại.
4. Thanh trạng thái và Settings khung.
5. Phím tắt menu: ⌘N worktree mới, ⌘T tab mới, ⌘W đóng tab, ⌘, Settings.

## Verification

- `swift test --package-path Packages/MercuryCore` pass.
- Thêm một repo git và một thư mục thường, thoát app, mở lại thì cả hai vẫn còn với đúng loại.
- Ảnh chụp offscreen sidebar: trạng thái rỗng, có dữ liệu, lỗi; sáng/tối; cửa sổ hẹp/rộng.
