---
title: Đổi tên ứng dụng Mercury → Sevinda
status: pending
created: 2026-11-12
owner: Vo Van Vu
mode: plan-only (thực hiện sau)
---

# Đổi tên Mercury → Sevinda

## Mục tiêu

Ứng dụng, bundle, code và mọi nội dung người dùng nhìn thấy dùng tên **Sevinda**. Sau khi đổi:
- không còn chữ "Mercury"/"mercury"/"MERCURY" trong code, cấu hình, UI, docs, ngoại trừ các chỗ được phép ở mục "Ngoại lệ";
- bản cài Mercury đang có trên máy (dữ liệu, cài đặt, helper, session đang chạy) chuyển sang Sevinda mà không mất gì;
- `scripts/ci-local.sh` xanh, không cảnh báo; app chạy, ký, notarize được với tên mới.

## Hiện trạng (khảo sát 2026-11-12)

- 332 file đã track, khoảng 3.100 chỗ chứa "mercury" (không phân biệt hoa thường).
- 9 package `Packages/Mercury*` (Accounts, Agents, Core, Diff, Git, PTYProtocol, Terminal, UI, Usage), cùng các C target `CMercuryPTY` và `CMercuryTerminalPTY`, helper `Helpers/MercuryPTYHost`, CLI `Tools/MercuryCLI` (binary `mercury`).
- Bundle ID: `com.tekmium.mercury`, `.ptyhost`, `.cli`, `.apptests`; UTType `com.tekmium.mercury.pane`; LaunchAgent `com.tekmium.mercury.ptyhost.plist` (Mach service cùng tên).
- Type có tiền tố: `MercurySpacing` (197), `MercuryColor` (117), `MercuryStore` (90), `MercuryTerminalView` (24), `MercuryRadius`, `MercuryPaths`, `MercuryFont`, `MercuryStats`, `MercuryApp`…
- Khoảng 40 biến môi trường `MERCURY_*` (runtime: `MERCURY_DATA_ROOT`, `MERCURY_SESSION_TOKEN`, `MERCURY_CLI`, `MERCURY_HOOK_EVENTS`…; build/release: `MERCURY_SIGNING_IDENTITY`, `MERCURY_NOTARY_PROFILE`…).
- Dữ liệu: `~/Library/Application Support/Mercury/` (`mercury.sqlite`, accounts, hooks, orchestration), defaults domain `com.tekmium.mercury`, thư mục tạm `mercury-orch-*`, skill `mercury-orchestration` (có thể đã được cài vào `~/.claude/skills`).
- Phân phối: Sparkle feed `mercury.tekmium.com/appcast.xml`, DMG `Mercury-<version>.dmg`.
- String Catalog: khoảng 52 key có chữ Mercury. Key chính là câu tiếng Anh, nên đổi chữ trong code thì key cũng đổi.
- Icon app hiện là chữ "S", hợp với Sevinda, không cần vẽ lại.

## Bảng đổi tên (chốt ở phase 1)

| Loại | Cũ | Mới |
|---|---|---|
| Tên hiển thị / PRODUCT_NAME | Mercury | Sevinda |
| Bundle ID app | com.tekmium.mercury | com.tekmium.sevinda |
| Helper / Mach service / LaunchAgent | com.tekmium.mercury.ptyhost, MercuryPTYHost | com.tekmium.sevinda.ptyhost, SevindaPTYHost |
| CLI | `mercury`, com.tekmium.mercury.cli | `sevinda`, com.tekmium.sevinda.cli |
| UTType kéo pane | com.tekmium.mercury.pane | com.tekmium.sevinda.pane |
| Package / module | MercuryCore… | SevindaCore… |
| Type | MercuryColor, MercuryStore… | SevindaColor, SevindaStore… |
| Env var | MERCURY_* | SEVINDA_* |
| Thư mục dữ liệu | Application Support/Mercury, mercury.sqlite | Application Support/Sevinda, sevinda.sqlite |
| Defaults domain | com.tekmium.mercury | com.tekmium.sevinda |
| Skill orchestration | mercury-orchestration | sevinda-orchestration |
| Tên miền cập nhật | mercury.tekmium.com | chưa có: tắt feed Sparkle cho tới khi có tên miền |
| Thư mục repo | ~/Self-Works/Mercury | ~/Self-Works/Sevinda (bước cuối) |

## Các phase

| # | Phase | Kết quả | File |
|---|---|---|---|
| 1 | Quyết định & chuẩn bị | Chốt bảng tên, tên miền, chiến lược migration; nhánh riêng; backup | [phase-01](phase-01-decisions-and-prep.md) |
| 2 | Định danh & build | project.yml, bundle ID, Info.plist, entitlements, LaunchAgent, scripts release | [phase-02](phase-02-identifiers-and-build.md) |
| 3 | Code: package, module, type, env | `git mv` package/thư mục, đổi import/type/env var/CLI | [phase-03](phase-03-code-rename.md) |
| 4 | Nội dung người dùng thấy | UI, String Catalog, onboarding, About/Legal, docs, ảnh chụp | [phase-04](phase-04-user-facing-content.md) |
| 5 | Migration bản cài cũ | Chuyển dữ liệu, defaults, helper, skill; giữ session | [phase-05](phase-05-migration-of-existing-installs.md) |
| 6 | Kiểm chứng & phát hành | grep gate, CI, chạy thử cài mới và nâng cấp, notarize | [phase-06](phase-06-verification-and-release.md) |

Thứ tự bắt buộc: 1 → 2 → 3 → 4 → 5 → 6. Phase 2 và 3 phải vào chung một nhánh và chỉ merge khi build xanh lại. Giữa chừng (sau phase 2, trước khi xong phase 3) app sẽ không build được.

## Tiêu chí hoàn thành

1. `git grep -i mercury` chỉ còn các chỗ trong danh sách "Ngoại lệ" (phase 6 có lệnh kiểm tra).
2. `scripts/bootstrap.sh && scripts/ci-local.sh` xanh, không cảnh báo trong code Sevinda.
3. Cài mới: app tên Sevinda, menu "Sevinda", About/Onboarding/Legal ghi Sevinda, dữ liệu nằm ở `Application Support/Sevinda`.
4. Nâng cấp từ Mercury trên máy dev: workspace, account, session record, bố cục pane và cài đặt còn nguyên. Session đang chạy trong helper cũ được nối lại, hoặc kết thúc có thông báo, theo quyết định ở phase 1.
5. Bản Release ký và notarize thành công. Sparkle feed mới hoạt động.

## Ngoại lệ (được phép còn chữ Mercury)

- `plans/` cũ và `plans/reports/` (lịch sử, không sửa).
- Code migration ở phase 5: đường dẫn, defaults domain, bundle ID và label helper cũ, cần để tìm và dọn bản cài Mercury.
- Test của migration.
- Một dòng trong release notes hoặc changelog: "Mercury is now Sevinda".

## Rủi ro chính

- **Đổi bundle ID:** macOS coi đây là app mới. Quyền TCC (Full Disk, Accessibility), các item Keychain gắn với app, Login Items và quyền thông báo phải cấp lại. Sparkle cũng không tự nâng cấp được từ Mercury sang Sevinda nếu bản cũ đã phát hành. Xem phase 1, mục "Đã phát hành chưa".
- **Helper cũ vẫn chạy** với session thật: không được giết bừa. Phase 5 xử lý.
- **Key String Catalog đổi:** nếu đã có bản dịch thì bản dịch bị mất. Hiện chỉ có tiếng Anh nên rủi ro thấp.
- **Diff rất lớn:** dùng `git mv` để giữ lịch sử, tách commit theo phase để review được.

## Quyết định đã chốt (2026-11-12)

1. **Chưa phát hành** ra ngoài máy dev. Vì vậy không cần nâng cấp Sparkle từ Mercury sang Sevinda, và không cần bản "Mercury cuối". Phase 5 chỉ chuyển dữ liệu trên máy dev, bản cài đó vẫn cần giữ nguyên dữ liệu.
2. **Chưa có tên miền.** Gỡ `SUFeedURL` và các URL `mercury.tekmium.com` ra khỏi app và script. Updater rơi về trạng thái "chưa cấu hình cập nhật", app đã có sẵn trạng thái này. Legal text không nhắc tên miền nào. Khi có tên miền, phải làm một việc riêng để bật lại.
3. **Đổi tên thư mục repo** thành `~/Self-Works/Sevinda`. Repo hiện chưa có remote nên không cần đổi remote. Đây là bước cuối của phase 6 (xem ở đó).
4. **Lệnh CLI là `sevinda`.**
