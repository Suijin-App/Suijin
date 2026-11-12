---
phase: 9
title: "Quy trình phát hành"
status: pending
priority: P2
effort: "2d"
dependencies: [1, 2, 3, 4, 5, 6, 7, 8]
---

# Phase 9: Quy trình phát hành

## Goal

Build Release ký Developer ID, notarize, đóng DMG và cập nhật qua Sparkle, dựa trên quy trình đã chạy của Capstio.

## Key insights

- Capstio có `docs/release-process.md` và `scripts/release-notarize.sh` (có `--dry-run`), dùng Sparkle 2.10.0 ghim chính xác với EdDSA.
- Mercury không sandbox; cần hardened runtime và ký cả helper `MercuryPTYHost`.

## Files to create

- `Mercury/scripts/release-notarize.sh` (port từ Capstio).
- `Mercury/docs/release-process.md`.
- Appcast Sparkle và khoá EdDSA riêng cho Mercury. Khoá riêng tư lưu ngoài repo, theo cách quản lý secret của tổ chức.

## Tasks & steps

1. Port script release; thêm bước ký helper.
2. Tạo khoá Sparkle cho Mercury; cấu hình feed URL.
3. Chạy dry-run, rồi notarize thật một bản 0.1.0.
4. Cài từ DMG trên máy sạch (tài khoản macOS mới) và chạy thử luồng chính.

## Verification

- `spctl --assess --type execute -vv Mercury.app` báo accepted, notarized.
- Update từ 0.1.0 lên 0.1.1 qua Sparkle; helper được thay đúng.

## Security

- Không commit khoá Sparkle, mật khẩu app-specific hay chứng chỉ.
