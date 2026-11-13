---
phase: 5
title: Dữ liệu — xoá sạch, giữ tài khoản
depends_on: [4]
status: pending
---

# Phase 5 — Dữ liệu: xoá sạch, giữ tài khoản

## Quyết định chi phối phase này

Chốt ngày 2026-11-13: **Suijin bắt đầu với dữ liệu trắng, chỉ mang theo hai tài khoản Claude đang đăng nhập.** Workspace, worktree, session, pane layout, usage, hooks, thống kê và mọi cài đặt đều bỏ.

Hệ quả quan trọng: **phase này không viết dòng code migration nào trong app.** Chỉ một máy duy nhất cần chuyển, và app chưa phát hành, nên việc này làm bằng một script chạy tay rồi vứt, không nhúng vào sản phẩm. Toàn bộ `App/Migration/LegacyMercuryMigration.swift` và test của nó bị xoá chứ không đổi tên.

## Hiện trạng dữ liệu (khảo sát 2026-11-13)

`~/Library/Application Support/Sevinda/`, 26MB:

| Mục | Nội dung | Xử lý |
|---|---|---|
| `claude-profiles/` | 2 thư mục UUID, chứa credential của 2 tài khoản đang đăng nhập | **Giữ**, chuyển sang Suijin |
| `sevinda.sqlite` → `managed_account` | 2 dòng, cột `homePath` trỏ tuyệt đối vào `claude-profiles/<uuid>` | **Giữ 2 dòng**, viết lại `homePath` |
| `sevinda.sqlite` → `workspace` (3), `worktree` (2), `agent_session` (2), `setting` (10), `stat_counter` (3), `diff_note`, `stat_pr`, `pane_layout` | Dữ liệu làm việc | Bỏ |
| `mercury.sqlite.backup-*` (6 file), `sevinda.sqlite.backup-*` (2 file) | Backup từ các lần đổi schema cũ | Bỏ |
| `usage/`, `hooks/`, `orchestration/`, `shell-integration/`, `pty-host/` | App và helper tự sinh lại khi chạy | Bỏ |

## Ranh giới không được vượt

- **Không đụng tới login của chính người dùng.** `~/.claude`, `~/.claude.json`, `~/.codex` và mục Keychain `Claude Code-credentials` mặc định nằm ngoài phạm vi, đúng như quy tắc trong `CLAUDE.md`.
- **Không in, không log, không copy nội dung file credential.** Việc chuyển profile làm ở mức thư mục, giữ nguyên quyền 700 cho thư mục và 600 cho file.
- Không xoá thư mục Sevinda cũ cho tới khi Suijin chạy được và hai tài khoản hiện đúng trong Settings.

## Các bước

### 1. Xoá code migration cũ

```
git rm App/Migration/LegacyMercuryMigration.swift
git rm AppTests/LegacyMercuryMigrationTests.swift
```

Gỡ lời gọi trong `AppModel.live()` (hiện ở khoảng dòng 143–160). Sau bước này trong `App/` không còn chữ Mercury nào.

**Bẫy khi cắt:** trong `live()` có **hai** đường dẫn tới store in-memory, nằm cách nhau mười mấy dòng và trông rất giống nhau.

| Đường dẫn | Xử lý |
|---|---|
| `case .blocked` — không được tạo database vì còn bản cũ chưa chuyển | Thuộc migration, **xoá cùng** |
| `catch` khi không mở được database (đĩa đầy, sai quyền) | Xử lý lỗi thật, **giữ nguyên** |

Sau khi cắt, `live()` chỉ còn: lấy data root, mở store, lỗi thì chạy in-memory kèm thông báo.

### 2. Backup trước khi đụng vào dữ liệu thật

```
cp -Rp ~/Library/Application\ Support/Sevinda \
       ~/Library/Application\ Support/Sevinda.backup-$(date +%Y%m%d-%H%M)
```

`-p` để giữ quyền file; thiếu nó là hỏng ràng buộc 700/600.

### 3. Chạy Suijin lần đầu trên data root trắng

Để app tự tạo `~/Library/Application Support/Suijin/` và `suijin.sqlite` với schema đúng phiên bản hiện tại. **Không tự tay tạo database**, vì bảng `grdb_migrations` phải do app ghi.

Thoát app trước khi sang bước 4.

### 4. Chuyển hai profile tài khoản

```
cp -Rp ~/Library/Application\ Support/Sevinda/claude-profiles \
       ~/Library/Application\ Support/Suijin/
```

Kiểm tra quyền giữ nguyên:
```
find ~/Library/Application\ Support/Suijin/claude-profiles -type d -exec stat -f '%A %N' {} \;
```
Thư mục phải là `700`.

### 5. Chép hai dòng tài khoản sang database mới

Viết lại `homePath` từ `.../Sevinda/...` thành `.../Suijin/...` ngay trong lúc chèn:

```sql
ATTACH '<đường dẫn>/Sevinda/sevinda.sqlite' AS old;
INSERT INTO managed_account (id, provider, label, email, organization, homePath, createdAt)
SELECT id, provider, label, email, organization,
       replace(homePath, '/Application Support/Sevinda/', '/Application Support/Suijin/'),
       createdAt
FROM old.managed_account;
DETACH old;
```

Chỉ bảng này. Không chép `workspace`, `worktree`, `agent_session`, `setting`, `stat_counter`.

### 6. Dọn thư mục cũ

Chỉ làm sau khi bước kiểm chứng bên dưới xanh:

```
rm -rf ~/Library/Application\ Support/Sevinda
defaults delete com.tekmium.sevinda
```

Bản backup ở bước 2 vẫn giữ, xoá tay sau vài ngày.

## Phát hiện khi thực hiện (2026-11-14)

Bước 1 (xoá code migration) đã xong và nằm trong commit `refactor: rename Sevinda to Suijin`. Các bước 2–6 chưa chạy.

**Chép thư mục profile là chưa đủ để giữ đăng nhập.** Phiên đăng nhập của hai tài khoản không nằm trong file mà nằm trong Keychain, dưới tên `Claude Code-credentials-<8 ký tự đầu của SHA-256 đường dẫn config dir>` (xem `ClaudeKeychainReader.serviceName`). Config dir là `.../claude-profiles/<uuid>/home`, nên khi đường dẫn đổi từ `Sevinda` sang `Suijin` thì tên mục Keychain cũng đổi và Claude không tìm thấy phiên cũ. Đã kiểm tra trên máy: cả hai mục Keychain theo đường dẫn Sevinda đều tồn tại, không có file `.credentials.json` nào.

Vì vậy bước 4 cần thêm một việc: sao hai mục Keychain sang tên tính theo đường dẫn Suijin. Việc này đọc credential (chỉ trong bộ nhớ, không in ra) nên cần chủ máy đồng ý trước; nếu không làm thì phải đăng nhập lại hai tài khoản.

## Kiểm chứng

1. Mở Suijin. Settings › Accounts hiện **đúng hai tài khoản**, đúng label và email, trạng thái đăng nhập còn hiệu lực — **không phải đăng nhập lại**.
2. Tạo workspace mới, mở terminal, chạy một agent Claude trên từng tài khoản tới khi ra kết quả. Đây là phép thử thật cho việc profile còn dùng được.
3. Danh sách workspace trống, đúng như mong đợi.
4. Cài đặt về mặc định, theme về mặc định.
5. Thoát và mở lại: hai tài khoản vẫn còn.
6. `scripts/ci-local.sh` xanh sau khi xoá code migration — không còn test nào tham chiếu tới nó.

## Rủi ro

- **Dùng `cp -R` không có `-p`** làm mất quyền 700/600 của thư mục profile. Agent có thể vẫn chạy, nhưng credential bị phơi quyền đọc cho tiến trình khác trên máy.
- **Chèn dòng tài khoản vào database do tay tạo** thay vì để app tạo sẽ sai `grdb_migrations` và app từ chối mở.
- **Xoá thư mục Sevinda trước khi kiểm chứng**: nếu profile không dùng được thì mất luôn phiên đăng nhập, phải login lại từ đầu.

## Rollback

Thoát Suijin, `rm -rf ~/Library/Application Support/Suijin`, đổi tên thư mục backup ở bước 2 về `Sevinda`. Bản Sevinda cũ chạy lại bình thường.
