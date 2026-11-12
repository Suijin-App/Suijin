---
phase: 7
title: "PTY host helper giữ phiên sống"
status: pending
priority: P1
effort: "5d"
dependencies: [3, 4]
---

# Phase 7: PTY host helper giữ phiên sống

## Goal

Phiên agent vẫn chạy khi app thoát hoặc crash. Mở app lại thì gắn vào phiên cũ và thấy lại scrollback.

## Key insights

- Orca chạy terminal trong daemon riêng (`src/main/daemon/`: `pty-subprocess`, `sessions`, `history`, `transport`, `health`), nên UI khởi động lại không giết phiên.
- Trên macOS cách chuẩn là helper đăng ký bằng `SMAppService.agent(plistName:)` (launchd agent), giao tiếp qua XPC (`NSXPCConnection` với Mach service).

## Architecture

- Target `MercuryPTYHost`: command-line helper nhúng trong `Mercury.app/Contents/Library/LaunchAgents` + `Contents/MacOS`.
- Helper sở hữu PTY và process con, giữ ring buffer scrollback cho mỗi phiên (giới hạn theo MB), và ghi metadata phiên vào thư mục của Mercury.
- Package `MercuryPTYProtocol`: giao thức XPC gồm list, spawn, attach, write, resize, terminate, cùng luồng output.
- `TerminalEngine` có hiện thực thứ hai `HostedTerminalEngine`: nhận output từ XPC rồi đưa vào `TerminalView` của SwiftTerm (chế độ không tự chạy process).
- Khi attach lại: phát lại scrollback vào emulator, sau đó stream trực tiếp.
- Tự dọn: phiên đã thoát và không còn ai attach quá N giờ thì xoá; helper tự thoát khi không còn phiên.

## Files to create

- `Mercury/Helpers/MercuryPTYHost/{main,SessionManager,PTYSession,ScrollbackBuffer}.swift`.
- `Mercury/Packages/MercuryPTYProtocol/Sources/MercuryPTYProtocol/PTYHostProtocol.swift`.
- `Mercury/Packages/MercuryTerminal/Sources/MercuryTerminal/HostedTerminalEngine.swift`.
- `Mercury/App/Resources/LaunchAgents/com.tekmium.mercury.ptyhost.plist`.
- Cập nhật `project.yml` để thêm target helper và copy vào bundle.

## Tasks & steps

1. Spike: `SMAppService.agent` đăng ký helper, kết nối XPC, ping.
2. Spawn PTY trong helper, stream output và xử lý input.
3. Scrollback buffer và attach lại.
4. Thay `SwiftTermEngine` bằng `HostedTerminalEngine` cho **mọi** terminal, cả phiên agent lẫn shell thường; tất cả đều sống sót khi thoát app.
   <!-- Updated: Validation Session 1 - all terminals persist via the helper -->
5. Kiểm tra phiên bản giữa app và helper: khi update qua Sparkle, helper cũ phải bàn giao hoặc dừng sạch.
6. Lifecycle: đóng tab thì kết thúc phiên; thoát app thì giữ phiên (có tuỳ chọn trong Settings).

## Verification

- Chạy agent và một shell thường, `kill -9` app, mở lại: cả hai vẫn chạy, scrollback còn.
- Thoát hẳn mọi phiên thì helper tự thoát; `ps` không còn process Mercury.
- Đo độ trễ gõ phím qua XPC; không thấy chậm hơn chạy trong app một cách rõ ràng.

## Risks

- XPC thêm một tầng copy dữ liệu; output lớn cần gom theo khối và có backpressure.
- Notarization và hardened runtime với helper nhúng: kiểm sớm ở phase 9 bằng bản dry-run.
