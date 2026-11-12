---
phase: 1
title: "Nền tảng dự án và design system"
status: pending
priority: P1
effort: "3d"
dependencies: []
---

# Phase 1: Nền tảng dự án và design system

## Goal

Có repo Mercury build được một cửa sổ trống bằng XcodeGen, với design system tách từ CapstioUI và bộ quy tắc repo.

## Key insights

- `CapstioUI` không phụ thuộc package domain nào (`Packages/CapstioUI/Package.swift` không có dependency), nên tách ra được nguyên vẹn.
- `Tokens.swift` có `CapstioColor.brand = 0x1F294A` (màu Tekmium/Capstio). Mercury cần brand riêng.
- `GlassStyles.swift` đã có fallback đúng: macOS 26 dùng `.glass` / `.glassEffect`, macOS 15 dùng control thường.
- Capstio dùng XcodeGen (`project.yml`), Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`, String Catalogs.
- Máy dev: macOS 27.2, Xcode 27.0, xcodegen có sẵn.

## Files to create

- `Mercury/project.yml` — target app `Mercury`, deployment macOS 15.0, Swift 6, strict concurrency.
- `Mercury/App/MercuryApp.swift`, `Mercury/App/RootView.swift`.
- `Mercury/App/Info.plist`, `Mercury/App/Mercury.entitlements` (không sandbox; hardened runtime).
- `Mercury/App/Resources/Localizable.xcstrings` (chỉ tiếng Anh; vẫn dùng String Catalog để thêm ngôn ngữ sau).
- `Mercury/CLAUDE.md` — quy tắc repo, chép phần UI của Capstio (native first, real Liquid Glass only, verify visually) và thêm quy tắc riêng của Mercury. Bỏ quy tắc Vietnamese-first của Capstio, vì UI Mercury chỉ tiếng Anh.
- `Mercury/README.md`, `Mercury/.gitignore`.
- `Mercury/scripts/bootstrap.sh` (chạy `xcodegen`), `Mercury/scripts/ci-local.sh` (build + test package).
- `Mercury/Packages/MercuryUI/` — copy từ CapstioUI vào trong Mercury: `Tokens.swift` (brand color của Mercury), `GlassStyles.swift`, các component chung. Chuỗi UI chuyển sang tiếng Anh.
  <!-- Updated: Validation Session 1 - design system copied into Mercury, English-only UI -->
- `Mercury/LICENSES/orca-MIT.txt` — chỉ khi có copy code Orca nguyên văn.

## Tasks & steps

1. `git init` trong `Mercury/`, branch `main`. Bundle id `com.tekmium.mercury`, team TEKMIUM SOLUTIONS (`YWSHDN5Y3H`), Automatic signing như Capstio.
2. Copy CapstioUI thành `Packages/MercuryUI`: đổi tên module, thay màu brand, dịch chuỗi sang tiếng Anh, giữ fallback macOS 15. **Không sửa Capstio.**
3. Tạo token màu brand của Mercury trong app (light/dark).
4. Viết `project.yml`, chạy `xcodegen`, build cửa sổ trống dùng `NavigationSplitView`.
5. Thêm `CLAUDE.md` và script CI local.
6. Tạo `DesignGalleryView` (giống `App/Shell/DesignGalleryView.swift` của Capstio) để soát token, glass, button ở cả hai hệ điều hành.

## Verification

- `scripts/bootstrap.sh && xcodebuild -scheme Mercury -destination 'platform=macOS' build` thành công.
- `swift test --package-path Packages/MercuryUI` pass.
- Ảnh chụp offscreen `DesignGalleryView` sáng/tối.

## Risks

- MercuryUI và CapstioUI sẽ lệch nhau theo thời gian. Đây là đánh đổi đã chấp nhận; sửa lỗi quan trọng thì port tay giữa hai bên.
