---
title: Đổi tên ứng dụng Sevinda → Suijin
status: pending
created: 2026-11-13
owner: Vo Van Vu
mode: plan-only (thực hiện sau)
---

# Đổi tên Sevinda → Suijin

## Mục tiêu

Ứng dụng, bundle, package, code và mọi nội dung người dùng nhìn thấy dùng tên **Suijin** (水神). Sau khi đổi:

- không còn chữ "Sevinda"/"sevinda"/"SEVINDA" trong code, cấu hình, UI và docs, trừ các chỗ ở mục "Ngoại lệ";
- bản cài Sevinda trên máy dev (dữ liệu, cài đặt, helper, session đang chạy) chuyển sang Suijin không mất gì;
- `scripts/ci-local.sh` xanh, không cảnh báo trong code của dự án; app chạy, ký và notarize được với tên mới.

## Hiện trạng (khảo sát 2026-11-13)

- **356 file đã track, 3.058 chỗ chứa "sevinda"** (không phân biệt hoa thường).
- 9 package `Packages/Sevinda*`: Accounts, Agents, Core, Diff, Git, PTYProtocol, Terminal, UI, Usage.
- 2 C target: `CSevindaPTY`, `CSevindaTerminalPTY`. Helper `Helpers/SevindaPTYHost`. CLI `Tools/SevindaCLI` (binary `sevinda`).
- Bundle ID: `com.tekmium.sevinda` và các nhánh `.ptyhost`, `.cli`, `.apptests`; UTType `com.tekmium.sevinda.pane`; LaunchAgent `com.tekmium.sevinda.ptyhost.plist` (Mach service cùng tên).
- Type có tiền tố: `SevindaSpacing` (229), `SevindaStore` (132), `SevindaColor` (119), `SevindaTerminalView` (47), `SevindaRadius` (20), `SevindaPTYHostKit` (15) và các tên module.
- Khoảng **40 biến môi trường `SEVINDA_*`**, gồm runtime (`SEVINDA_DATA_ROOT`, `SEVINDA_CLI`, `SEVINDA_HOOK_EVENTS`, `SEVINDA_PTYHOST_SERVICE`…) và build/release (`SEVINDA_NOTARY_PROFILE`…).
- Dữ liệu: `~/Library/Application Support/Sevinda/` (`sevinda.sqlite`, accounts, hooks, orchestration), defaults domain `com.tekmium.sevinda`, marker `.sevinda-managed-home`, `.sevinda-migration-pending`, `.sevinda-login-staging`, skill `sevinda-orchestration`, theme `sevinda-light` / `sevinda-dark`.
- String Catalog: **78 chỗ** chứa chữ Sevinda trong `App/Resources/Localizable.xcstrings`.
- **Chưa phát hành.** `CHANGELOG.md` ghi `0.1.0 (unreleased)`, không có git tag nào, `Info.plist` không có `SUFeedURL` nên Sparkle đang tắt.
- Đã có sẵn `App/Migration/LegacyMercuryMigration.swift` — cơ chế chuyển dữ liệu từ lần đổi tên trước (Mercury → Sevinda), dùng làm khuôn cho lần này.
- **Icon đã xong**, không nằm trong phạm vi plan này: `App/Resources/AppIcon.icon` đã là icon Suijin (đĩa nước và ba vòng sóng).
- Thư mục repo vẫn là `~/Self-Works/Mercury` — lần đổi tên trước không đổi thư mục.

## Điều kiện thuận lợi quyết định phạm vi

Ứng dụng **chưa từng phát hành ra ngoài**: không tag, không feed Sparkle, changelog còn ở `0.1.0 (unreleased)`. Hệ quả:

- không có người dùng ngoài nào phải migrate, nên không có bài toán Sparkle không nâng cấp được qua bundle ID mới;
- không ai phải cấp lại quyền TCC, Keychain, Login Item, thông báo — trừ chính máy dev;
- **bản cài duy nhất cần quan tâm là máy của bạn.**

Điều này làm phase 5 nhẹ hơn hẳn so với lần đổi Mercury → Sevinda, và mở ra một lựa chọn cắt phạm vi được nêu ở phase 1.

## Bảng đổi tên (chốt ở phase 1)

| Loại | Cũ | Mới |
|---|---|---|
| Tên hiển thị / PRODUCT_NAME | Sevinda | Suijin |
| Bundle ID app | com.tekmium.sevinda | com.tekmium.suijin |
| Helper / Mach service / LaunchAgent | com.tekmium.sevinda.ptyhost, SevindaPTYHost | com.tekmium.suijin.ptyhost, SuijinPTYHost |
| CLI | `sevinda`, com.tekmium.sevinda.cli | `suijin`, com.tekmium.suijin.cli |
| Test bundle | com.tekmium.sevinda.apptests | com.tekmium.suijin.apptests |
| UTType kéo pane | com.tekmium.sevinda.pane | com.tekmium.suijin.pane |
| Package / module | SevindaCore, SevindaUI… (9 package) | SuijinCore, SuijinUI… |
| C target | CSevindaPTY, CSevindaTerminalPTY | CSuijinPTY, CSuijinTerminalPTY |
| Type | SevindaSpacing, SevindaStore, SevindaColor… | SuijinSpacing, SuijinStore, SuijinColor… |
| Env var | SEVINDA_* (~40) | SUIJIN_* |
| Thư mục dữ liệu | Application Support/Sevinda, sevinda.sqlite | Application Support/Suijin, suijin.sqlite |
| Defaults domain | com.tekmium.sevinda | com.tekmium.suijin |
| Marker file | .sevinda-managed-home, .sevinda-migration-pending, .sevinda-login-staging | .suijin-* |
| Skill orchestration | sevinda-orchestration | suijin-orchestration |
| Theme | sevinda-light, sevinda-dark | suijin-light, suijin-dark |
| Tên miền cập nhật | chưa có | chưa có: giữ Sparkle tắt cho tới khi có `suijin.app` |
| Thư mục repo | ~/Self-Works/Mercury | ~/Self-Works/Suijin (bước cuối) |

## Các phase

| # | Phase | Kết quả | File |
|---|---|---|---|
| 1 | Quyết định & chuẩn bị | Chốt bảng tên, chiến lược migration, nhánh riêng, backup dữ liệu | [phase-01](phase-01-decisions-and-prep.md) |
| 2 | Định danh & build | project.yml, bundle ID, Info.plist, entitlements, LaunchAgent, script release | [phase-02](phase-02-identifiers-and-build.md) |
| 3 | Code: package, module, type, env | `git mv` package và thư mục, đổi import, type, env var, CLI, C target | [phase-03](phase-03-code-rename.md) |
| 4 | Nội dung người dùng thấy | UI, String Catalog, onboarding, About/Legal, docs, README, CLAUDE.md | [phase-04](phase-04-user-facing-content.md) |
| 5 | Dữ liệu: xoá sạch, giữ tài khoản | Suijin bắt đầu trắng, chỉ mang theo 2 tài khoản Claude; xoá hẳn code migration | [phase-05](phase-05-migration-of-existing-install.md) |
| 6 | Kiểm chứng & dọn dẹp | grep gate, CI xanh, thử cài mới và nâng cấp, đổi thư mục repo | [phase-06](phase-06-verification-and-cleanup.md) |

Thứ tự bắt buộc: 1 → 2 → 3 → 4 → 5 → 6.

Phase 2 và 3 phải nằm chung một nhánh và chỉ merge khi build xanh trở lại. **Giữa phase 2 và lúc phase 3 xong, app sẽ không build được** — đó là trạng thái dự kiến, không phải lỗi.

## Tiêu chí hoàn thành

1. `git grep -i sevinda` chỉ còn các chỗ trong "Ngoại lệ"; phase 6 có lệnh kiểm tra cụ thể.
2. `scripts/bootstrap.sh && scripts/ci-local.sh` xanh, không cảnh báo trình biên dịch trong code của dự án.
3. Cài mới: app tên Suijin, menu "Suijin", About / Onboarding / Legal ghi Suijin, dữ liệu nằm ở `Application Support/Suijin`.
4. Dữ liệu: Suijin chạy với thư mục trắng, **chỉ hai tài khoản Claude được mang sang và không phải đăng nhập lại**. Mọi thứ khác bắt đầu từ đầu.
5. **Mọi chức năng đã build từ trước vẫn chạy đúng.** Phase 6 có danh sách thử tay từng tính năng, không chấp nhận "CI xanh" là đủ.
6. Bản Release ký và notarize thành công.

## Ngoại lệ (được phép còn chữ Sevinda)

- `plans/` cũ và `plans/reports/`: hồ sơ lịch sử, không sửa.
- Một dòng trong CHANGELOG: "Sevinda is now Suijin".

Vì phase 5 xoá hẳn code migration thay vì viết lại, **không còn ngoại lệ nào trong `App/`**. Cổng grep ở phase 6 vì vậy chặt hơn bản kế hoạch ban đầu: chỉ `plans/` và một dòng CHANGELOG được phép còn tên cũ.

## Rủi ro chính

- **Đổi bundle ID:** macOS coi đây là app mới. Trên máy dev phải cấp lại quyền Full Disk Access, Accessibility, thông báo, và các item Keychain gắn theo app. Vì app chưa phát hành nên rủi ro này chỉ ảnh hưởng một máy.
- **Mất phiên đăng nhập của hai tài khoản Claude.** Đây là thứ duy nhất trong dữ liệu cũ phải giữ. Rủi ro nằm ở quyền file: chép thư mục profile mà không giữ quyền 700/600 là phơi credential cho tiến trình khác trên máy. Phase 5 có lệnh kiểm tra.
- **Chức năng hỏng âm thầm sau khi đổi tên.** Build xanh không chứng minh app còn chạy: Mach service, LaunchAgent, UTType kéo pane và khoảng 40 biến `SUIJIN_*` đều là thứ chỉ sai lúc chạy. Phase 6 có danh sách thử tay từng tính năng.
- ~~Hai tầng migration chồng nhau~~ — **đã xử lý.** Phase 5 xoá hẳn code migration thay vì viết lại, nên sau phase đó trong `App/` không còn chữ Mercury lẫn Sevinda nào.
- **Key String Catalog đổi theo chuỗi tiếng Anh:** 78 chỗ sẽ sinh key mới. Hiện chỉ có tiếng Anh nên không mất bản dịch, nhưng phải chạy lại và xoá key mồ côi.
- **Đổi thư mục repo** làm hỏng đường dẫn tuyệt đối trong cấu hình công cụ bên ngoài (Xcode recents, `.claude`, DerivedData). Để ở bước cuối cùng của phase 6.

## Việc không nằm trong plan này

- Thiết kế và áp dụng app icon: đã xong trước plan này.
- Mua tên miền, dựng trang và bật Sparkle feed: việc riêng, làm sau khi đổi tên xong.
- Đăng ký nhãn hiệu Suijin.
