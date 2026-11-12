---
phase: 6
title: "Tài khoản Codex"
status: pending
priority: P2
effort: "4d"
dependencies: [5]
---

# Phase 6: Tài khoản Codex

## Goal

Quản lý nhiều tài khoản Codex giống phần Claude, dùng chung UI và khung `MercuryAccounts`.

## Key insights (từ code Orca, `src/main/codex-accounts/`)

- Mỗi tài khoản có một thư mục home riêng dùng làm `CODEX_HOME`. Credential nằm ở `auth.json` trong thư mục đó, không phải Keychain (`codex-login-session.ts`, `runtime-home-service-managed-home.ts`).
- Đăng nhập: `codex login`, hoặc `codex login --device-auth` khi đăng nhập từ thiết bị khác. Orca theo dõi `auth.json` thay đổi để biết login xong.
- `config.toml` của `~/.codex` được mirror vào từng home (`codex-config-mirror.ts`). Lịch sử phiên có tuỳ chọn chia sẻ giữa các tài khoản, mặc định bật (`codex-history-sharing.ts`).
- Danh tính lấy từ `auth.json` (email, account id) (`codex-auth-identity.ts`).
- Usage: `GET https://chatgpt.com/backend-api/wham/usage` (`rate-limits/providers/codex/codex-backend-usage-client.ts`), cũng không có tài liệu chính thức.
- Chi tiết header, cấu trúc `auth.json` và cách chia sẻ `sessions/` cần đọc kỹ lại trong Orca trước khi code. [UNVERIFIED]

## Architecture

- `MercuryAccounts/Codex/{CodexHomeStore,CodexConfigMirror,CodexLoginRunner,CodexIdentity,CodexUsageClient,CodexLaunchEnv}.swift`.
- Giao thức chung `ManagedAccountProvider` cho Claude và Codex, để UI và chọn tài khoản dùng một đường.
- Hàm shell `codex` đọc file con trỏ riêng, giống hàm `claude`.

## Tasks & steps

1. Đọc lại `src/main/codex-accounts/` của Orca, ghi tóm tắt vào `Mercury/plans/.../reports/codex-accounts-notes.md`.
2. Rút giao thức `ManagedAccountProvider` từ phần Claude (không đổi hành vi Claude).
3. Hiện thực Codex: tạo home, login, mirror config, đọc danh tính, usage.
4. UI Settings > Accounts thêm mục Codex, như ảnh Orca.
5. Chọn tài khoản Codex khi tạo worktree hoặc phiên.

## Verification

- Hai tài khoản Codex chạy song song ở hai worktree; mỗi phiên đúng tài khoản.
- `~/.codex/auth.json` không đổi (so mtime/hash, không in nội dung).
- Đổi `~/.codex/config.toml` thì lần chạy sau các home được cập nhật.

## Security

- `auth.json` quyền 600, không bao giờ log hay hiển thị nội dung.
