---
phase: 5
title: "Tài khoản Claude"
status: pending
priority: P1
effort: "6d"
dependencies: [4]
---

# Phase 5: Tài khoản Claude

## Goal

Quản lý nhiều tài khoản Claude trên cùng máy giống Orca: thêm, đăng nhập lại, xoá, chọn tài khoản cho từng lần chạy, và xem usage. Không bao giờ ghi đè login gốc `~/.claude`.

## Key insights (từ code Orca, `src/main/claude-accounts/`)

- Mỗi tài khoản có một thư mục `<dataRoot>/claude-profiles/<accountId>/home` dùng làm `CLAUDE_CONFIG_DIR` (`claude-profile-paths.ts`). Thư mục cha có `profile.json` đánh dấu chủ sở hữu, chỉ ghi khi setup thành công. Thư mục không được trùng hay lồng với `~/.claude`, `~/.config/claude`, và không được chứa symlink trên đường dẫn.
- Đăng nhập: `claude auth login --claudeai` với `CLAUDE_CONFIG_DIR` đã đặt, timeout 10 phút (`claude-login-session.ts`).
- Email/org đọc từ `oauthAccount` trong `.claude.json` của thư mục profile (`claude-account-folder.ts`).
- Keychain: service `Claude Code-credentials` cho mặc định; `Claude Code-credentials-<sha256(configDir NFC)[0:8]>` cho thư mục riêng; account là `$USER` (nếu không hợp lệ thì `claude-code-user`). Code thử cả alias realpath, và **không bao giờ** rơi về credential mặc định (`keychain.ts`).
- Chia sẻ (`claude-profile-provisioning.ts`):
  - Thư mục trong `~/.claude` được symlink vào profile.
  - File được copy; `CLAUDE.md` thay bằng `@~/.claude/CLAUDE.md`.
  - `settings.json` đồng bộ theo từng key qua digest (`claude-profile-settings.ts`).
  - `.claude.json` copy nhưng bỏ key gắn tài khoản; `projects`, `mcpServers` được trộn.
  - Danh sách runtime state không chia sẻ (`CLAUDE_RUNTIME_STATE_ENTRIES`).
- Env khi chạy: xoá `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `AWS_BEARER_TOKEN_BEDROCK`, và `ANTHROPIC_CUSTOM_HEADERS` nếu giống header xác thực (`environment.ts`).
- Terminal: file con trỏ `claude-profiles/selected-host` cộng hàm shell `claude` đọc lại con trỏ mỗi lần chạy (`src/shared/claude-shell-function.ts`). Hàm tôn trọng `CLAUDE_CONFIG_DIR` người dùng tự đặt và hàm `claude` có sẵn của người dùng.
- Usage: `GET https://api.anthropic.com/api/oauth/usage` với OAuth token, trả về `five_hour`, `seven_day`, `limits[]` (`rate-limits/providers/claude/claude-oauth-usage-request.ts`). Endpoint này không có tài liệu chính thức.

## Architecture

- Package `MercuryAccounts`, phần Claude:
  - `ClaudeProfileStore`: tạo, kiểm tra và xoá thư mục profile.
  - `ClaudeProfileProvisioner`: symlink, copy và sync như Orca. Chạy lại trước mỗi lần chạy agent nếu `~/.claude` đã đổi.
  - `ClaudeLoginRunner`: chạy `claude auth login --claudeai` qua `Process`, có huỷ được.
  - `ClaudeKeychainReader`: đọc qua `/usr/bin/security find-generic-password -s <service> -a <account> -w`, như Orca, để tránh hộp thoại hỏi quyền vì mục do binary `claude` tạo. Token chỉ giữ trong bộ nhớ, không log, không ghi đĩa.
  - `ClaudeUsageClient`: `URLSession`, timeout 10s, poll có backoff.
  - `ClaudeLaunchEnv`: sinh env patch cho `AgentLaunchSpec` và nội dung file con trỏ.
- Hàm shell `claude` đưa vào shell integration của phase 3 (zsh, bash).

## Files to create

- `Mercury/Packages/MercuryAccounts/Sources/MercuryAccounts/Claude/{ClaudeProfileStore,ClaudeProfileProvisioner,ClaudeSettingsSync,ClaudeStateCopy,ClaudeLoginRunner,ClaudeKeychainReader,ClaudeUsageClient,ClaudeLaunchEnv}.swift`.
- `Mercury/Packages/MercuryTerminal/Sources/MercuryTerminal/Resources/claude-shell-function.zsh` (và `.bash`).
- `Mercury/App/Features/Accounts/{AccountsSettingsView,ClaudeAccountRow,UsageStatusItem}.swift`.
- Tests: provisioning trên thư mục tạm (symlink, copy, lọc key, trộn `projects`), tên service Keychain, logic hàm shell.

## Tasks & steps

1. Port logic đường dẫn và kiểm tra an toàn thư mục profile, kèm test.
2. Port provisioning: danh sách runtime state, lọc key, sync settings theo digest.
3. Luồng đăng nhập kèm "Copy link" (mở trong cửa sổ ẩn danh).
4. Đọc Keychain và lấy usage; hiện ở thanh trạng thái như ảnh Orca ("52% used 6d 3h").
5. Chọn tài khoản: mặc định toàn app, và chọn riêng khi tạo worktree hoặc phiên.
6. File con trỏ và hàm shell để người dùng gõ `claude` trong terminal thường cũng ra đúng tài khoản.
7. Xoá tài khoản: dừng phiên đang dùng, xoá thư mục profile. Mục Keychain do Claude tạo: chạy `claude auth logout` trong profile trước khi xoá.

## Verification

- Test package pass.
- Thêm 2 tài khoản, chạy `claude` ở hai worktree với hai tài khoản khác nhau cùng lúc; `/status` trong mỗi phiên hiện đúng email.
- `~/.claude` và mục Keychain mặc định không đổi (so mtime và `security find-generic-password -s 'Claude Code-credentials'` trước/sau, chỉ kiểm tồn tại, không in giá trị).
- Thêm skill mới vào `~/.claude/skills` thì mọi tài khoản đều thấy.

## Security

- Không bao giờ in, log hay lưu token; chỉ báo trạng thái.
- Thư mục profile quyền 700, file 600.
- Tuân thủ điều khoản sử dụng của Anthropic: mỗi tài khoản phải là tài khoản hợp lệ của người dùng.

## Risks

- Claude Code đổi cách đặt tên Keychain hoặc cấu trúc thư mục. Cách giảm rủi ro: kiểm version `claude --version` và có test tên service; theo dõi Orca vì họ cập nhật theo từng bản Claude.
- Endpoint usage không chính thức có thể đổi. Lỗi usage không được chặn việc chạy agent.
