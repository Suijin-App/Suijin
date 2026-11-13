---
phase: 6
title: Kiểm chứng & dọn dẹp
depends_on: [5]
status: pending
---

# Phase 6 — Kiểm chứng & dọn dẹp

## Bối cảnh

Chốt lại: không còn tên cũ ngoài danh sách ngoại lệ, mọi thứ build và chạy được, và cuối cùng là đổi tên thư mục repo — việc để sau cùng vì nó làm hỏng mọi đường dẫn tuyệt đối đang mở.

## Cổng kiểm tra

### 1. Grep gate

```
git grep -iE 'sevinda|mercury' -- ':!plans' ':!CHANGELOG.md'
```

Phải **không có kết quả**. Vì phase 5 xoá hẳn code migration thay vì viết lại, không còn ngoại lệ nào trong `App/` — cổng này chặt hơn so với lần đổi tên trước, và bắt được cả tên Mercury còn sót.

### 2. CI đầy đủ

```
scripts/bootstrap.sh
scripts/ci-local.sh
```

Xanh toàn bộ: comment lint, test từng package, build app, test app, không cảnh báo trình biên dịch trong code của dự án. **Đóng Xcode trước khi chạy** — hai lần build hỏng gần đây là do Xcode và dòng lệnh cùng ghi vào một DerivedData.

### 3. Ma trận chức năng — thử tay, không bỏ mục nào

CI xanh **không** chứng minh app còn chạy đúng. Mach service, LaunchAgent, UTType và khoảng 40 biến `SUIJIN_*` đều là thứ chỉ sai lúc chạy, không sai lúc biên dịch. Chạy trên data root sạch (`SUIJIN_DATA_ROOT` trỏ vào thư mục tạm) và đánh dấu từng dòng.

| # | Chức năng | Cách thử | Hỏng thì do đâu |
|---|---|---|---|
| 1 | App khởi động | Tên trong Dock, menu chính, tiêu đề cửa sổ là Suijin | PRODUCT_NAME, Info.plist |
| 2 | Helper PTY đăng ký | Mở một terminal bất kỳ. Không mở được là helper chưa đăng ký | Mach service, LaunchAgent, tên file plist |
| 3 | Helper sống sót khi thoát app | Mở session, thoát app, mở lại, session còn chạy | `SMAppService`, label helper |
| 4 | Đóng tab thì session chết | Đóng tab, `ps` không còn tiến trình con | SIGHUP/SIGKILL trong helper |
| 5 | Workspace kiểu git | Thêm một repo, thấy nhánh và trạng thái | — |
| 6 | Workspace kiểu thư mục | Thêm một thư mục thường, agent chạy thẳng trong đó | `kind == .folder` |
| 7 | Worktree | Tạo và xoá worktree trên workspace git | — |
| 8 | Diff viewer | Sửa file trong worktree, mở diff, xem được | — |
| 9 | Agent Claude Code | Chạy tới khi ra kết quả | Env `SUIJIN_CLAUDE_SETTINGS`, hooks |
| 10 | Agent Codex | Chạy tới khi ra kết quả | Env `SUIJIN_CODEX_INJECTED_HOME`, marker `.suijin-managed-home` |
| 11 | Hai tài khoản | Chạy agent trên từng tài khoản | `claude-profiles`, `managed_account.homePath` |
| 12 | Tự chuyển tài khoản | Bật trong Settings › Accounts, ép một tài khoản hết hạn mức | — |
| 13 | Split pane | Chia dọc và ngang, bố cục giữ sau khi mở lại | `pane_layout` |
| 14 | Kéo thả pane | Kéo một pane sang vị trí khác | **UTType `com.tekmium.suijin.pane`** |
| 15 | Link đường dẫn trong terminal | Click một đường dẫn trong output, mở đúng file | — |
| 16 | Cây file và xem file | Mở file, ảnh zoom và pan được | — |
| 17 | Orchestration | Chạy một luồng nhiều agent | Env `SUIJIN_ORCH_SOCKET`, `SUIJIN_ORCH_SPOOL`, skill `suijin-orchestration` |
| 18 | Hook events | Kiểm tra hook ghi nhận sự kiện | `com.tekmium.suijin.hook-event-watcher` |
| 19 | Shell integration | Mở terminal zsh, prompt tích hợp hoạt động | `shell-integration/zsh` |
| 20 | Thông báo | Đưa app xuống nền, chờ agent xong, có thông báo | **Bundle ID mới phải được cấp lại quyền Notifications** |
| 21 | Thống kê và usage | Mở Settings › Usage, số liệu hiện | `stat_counter` |
| 22 | Theme terminal | Đổi sáng/tối, màu đúng | `suijin-light`, `suijin-dark` |
| 23 | CLI | `suijin --help` trong terminal của app | Env `SUIJIN_CLI`, PRODUCT_NAME của target CLI |
| 24 | Updater | Settings báo "not configured", không crash | Sparkle vẫn tắt đúng chủ ý |
| 25 | Không có tiến trình mồ côi | Thoát app, `pgrep -fl suijin` sạch | — |

Mục **2, 14, 17, 20** là bốn chỗ dễ hỏng nhất vì chúng phụ thuộc vào định danh hệ điều hành chứ không phải code.

### 4. Chạy thử trên dữ liệu thật

Theo đúng kịch bản ở phase 5: hai tài khoản Claude hiện đủ và **không phải đăng nhập lại**, còn mọi thứ khác bắt đầu trắng.

### 5. Ký và notarize

```
scripts/make-dmg.sh
scripts/release-notarize.sh
```

DMG tên `Suijin-<version>.dmg`, notarize thành công, mở DMG trên máy sạch không bị Gatekeeper chặn.

## Dọn dẹp cuối

1. Xoá LaunchAgent cũ còn sót trên máy dev:
   ```
   launchctl print gui/$(id -u) | grep -i sevinda
   ```
   nếu còn thì `launchctl bootout` rồi xoá plist trong `~/Library/LaunchAgents/`.

2. Xoá app cũ trong `/Applications` và DerivedData của scheme cũ.

3. Cấp lại quyền cho bundle ID mới: Full Disk Access, Accessibility, Notifications. Dùng danh sách đã ghi ở phase 1.

4. **Đổi tên thư mục repo** — bước cuối cùng, sau khi mọi thứ trên đã xanh:
   ```
   cd ~/Self-Works && mv Mercury Suijin
   ```
   Sau đó: mở lại Xcode từ đường dẫn mới, xoá DerivedData cũ, cập nhật mọi worktree đang mở, và kiểm tra `.claude/` cùng các cấu hình công cụ có đường dẫn tuyệt đối.

5. Cập nhật `CHANGELOG.md`: một dòng "Sevinda is now Suijin" kèm ghi chú rằng người dùng phải cấp lại quyền hệ thống vì bundle ID đổi.

## Rủi ro

Đổi tên thư mục repo trong khi còn worktree đang mở hoặc Xcode đang chạy sẽ để lại tiến trình trỏ vào đường dẫn không còn tồn tại. Đóng hết trước khi `mv`.

## Rollback

Thư mục: `mv Suijin Mercury`. Code: nhánh `rename/suijin` chưa merge thì `git switch main`.

## Hoàn thành

Khi cả năm cổng kiểm tra xanh và bước dọn dẹp xong, merge `rename/suijin` vào `main` bằng một commit theo Conventional Commits, ví dụ `refactor: rename Sevinda to Suijin`.
