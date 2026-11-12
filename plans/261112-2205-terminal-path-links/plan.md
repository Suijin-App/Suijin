---
title: Path trong terminal — highlight, click mở trong app, menu chuột phải, path bị cắt
status: pending
created: 2026-11-12
---

# Path trong terminal

## Mục tiêu
Path in ra trong terminal được nhận diện và dùng được ngay:
- **Path đầy đủ:** path tuyệt đối, `~/…`, path tương đối theo thư mục hiện tại, có thể kèm `:line:col`. Path xuống dòng (wrap) vẫn tính.
- **Highlight nhẹ:** gạch chân mờ màu accent, và **chỉ áp dụng cho path tồn tại thật**. Khi rê chuột thì đậm hơn và con trỏ thành bàn tay.
- **Click để mở trong app:**
  - File xem được thì mở trong tab viewer.
  - Thư mục thì hiện trong cây file của inspector.
  - Chỉ đưa sang Finder khi app không hiển thị được, theo quy tắc hiện có.
- **Chuột phải lên path:** mở menu các hành động với path.
- **Path bị cắt** (`…/feature/x.swift`, `.../Sources/A.swift`, `~/…/b.md`):
  - Không tự highlight hay click.
  - Menu chuột phải có "Find Full Path…": tìm path đầy đủ trong workspace, cho xem rồi mở trong tab mới.

## Hiện trạng (khảo sát)
- Terminal là `SevindaTerminalView`, subclass của SwiftTerm `TerminalView`. Link mở bằng ⌘-click qua `requestOpenLink`, rồi `onOpenLink`, rồi `AppModel.openTerminalLink` (`App/Features/Files/FileTabs.swift`). Hàm này đã xử lý `~`, path tương đối, `:line:col`, thư mục và Finder fallback.
- SwiftTerm có sẵn phần nhận diện link (`LinkLookupMode.explicitAndImplicit`, regex kiểu Ghostty), biết nối các dòng bị wrap (`buildGhosttyImplicitLineMap`). Ngoài ra có cơ chế mouseMoved, dùng được cho hover.
- Thư mục để resolve path tương đối: `onCurrentDirectoryChange` (OSC 7 từ shell integration). Với agent thì dùng cwd của session (`TerminalPane` đang lấy `session.cwd`).
- Các tính năng có thể bị đụng tới, xem mục "Không được hỏng":
  - bôi chọn chữ, double-click và triple-click;
  - mouse reporting của TUI (Codex, vim, htop);
  - ⌘-click link web;
  - Metal renderer, cuộn, hiệu năng feed, khung tìm kiếm (⌘F);
  - kéo-thả pane;
  - click để focus pane (`hitTest` MTKView → terminal).

## Thiết kế chính
1. **Không sửa dữ liệu buffer.** Highlight vẽ bằng một lớp overlay riêng nằm trên terminal. Lớp này không nhận click (hitTest trả nil) và chỉ vẽ cho các dòng đang hiện.
2. **Bộ nhận diện thuần** (`TerminalPathDetector`, nằm trong SevindaTerminal và có test). Đầu vào là các dòng chữ đang hiện, đã nối dòng wrap. Đầu ra là danh sách đoạn chữ, mỗi đoạn có ô bắt đầu/kết thúc, chuỗi path, loại (full/elided) và line:col.
3. **Resolver phía app** (`TerminalPathResolver`):
   - Kiểm tra file tồn tại, có cache theo `(cwd, path)` và TTL ngắn. Thay đổi file đã có FileSystemWatcher báo.
   - Tìm ứng viên cho path bị cắt bằng cách khớp phần đuôi path trong worktree/workspace: dùng `git ls-files` (có cache), hoặc duyệt thư mục có giới hạn với thư mục thường.
4. **Quét có giới hạn:**
   - Chỉ quét các dòng đang hiện, và chỉ sau khi output ngừng khoảng 120 ms (debounce).
   - Bỏ qua lúc đang phát lại scrollback.
   - Mỗi lượt quét tối đa khoảng 2 ms trên main thread. Kiểm tra file tồn tại chạy ngoài main thread.
5. **Quy tắc click** (đây là phần dễ gây lỗi nhất):

| Tình huống | Hành vi |
|---|---|
| ⌘-click trên path đã xác minh (mặc định) | Mở trong app |
| Click trái đơn, không kéo, trên path đã xác minh, chương trình không bật mouse reporting | Chỉ mở khi người dùng chọn chế độ "Click"; mặc định giữ hành vi terminal |
| Click rồi kéo (dịch quá ngưỡng), double-click, triple-click | Giữ nguyên: bôi chọn như cũ |
| Có vùng chọn đang active và click vào path nằm trong vùng chọn | Giữ nguyên (bỏ chọn như cũ), không mở |
| TUI đang bật mouse reporting (Codex, vim…) | Click gửi vào chương trình như cũ; mở path dùng ⌘-click |
| ⌘-click | Như cũ (link web và path). Path dùng cùng đường mở trong app |
| Click vào path chưa xác minh hoặc bị cắt | Không mở, giữ hành vi terminal bình thường |

6. **Menu chuột phải** (trên path; vị trí khác giữ menu hiện có của terminal):
   - Open in Sevinda (mặc định) và Open in New Tab
   - Open With Default App
   - Reveal in File Tree
   - Show in Finder: chỉ thêm như một lựa chọn chủ động của người dùng, không phải hành vi mặc định
   - Copy Path, Copy Relative Path, Copy Path:Line
   - Với path bị cắt: Find Full Path… (mở popover danh sách ứng viên kèm đường dẫn đầy đủ và nút Open), cùng Copy Text
   - Phần còn lại của menu như cũ: Copy, Paste, Select All, Find, Clear…
   - Khi TUI đang bật mouse reporting, chuột phải vẫn mở menu này nếu đang trỏ vào path. Còn lại thì giữ hành vi hiện tại.
7. **Cài đặt:** Settings › Terminal có mục "Highlight file paths", mặc định bật, kèm chọn mở path bằng "⌘-Click" (mặc định) hoặc "Click". Tắt highlight thì không quét gì và hành vi về y như cũ. Đây là đường lui an toàn.

## Các phase

| # | Phase | File |
|---|---|---|
| 1 | Bộ nhận diện và resolver (thuần, có test) | [phase-01](phase-01-detector-and-resolver.md) |
| 2 | Lớp highlight và hover | [phase-02](phase-02-highlight-overlay.md) |
| 3 | Click để mở và quy tắc chuột | [phase-03](phase-03-click-to-open.md) |
| 4 | Menu chuột phải và path bị cắt | [phase-04](phase-04-context-menu-and-elided-paths.md) |
| 5 | Cài đặt, kiểm chứng hồi quy, hiệu năng | [phase-05](phase-05-settings-and-regression.md) |

Thứ tự: 1 → 2 → 3 → 4 → 5. Mỗi phase một commit, CI xanh trước khi commit.

## Tiêu chí hoàn thành
1. Các path dưới đây trong output của shell, Claude Code và Codex được highlight và mở đúng khi click:
   - `/abs/a.swift`, `~/x.md`, `src/a.ts:12:4`;
   - path nằm trong backtick hoặc ngoặc kép;
   - path bị wrap qua hai dòng.
   
   Path không tồn tại thì không highlight.
2. Không có hồi quy, kiểm tra bằng test và chạy app thật:
   - bôi chọn, double-click và triple-click, kéo chọn;
   - TUI có mouse reporting nhận click như cũ;
   - ⌘-click link web;
   - ⌘F;
   - click để focus pane;
   - kéo-thả pane;
   - cuộn mượt khi output dài;
   - bật/tắt Metal renderer.
3. Hiệu năng: khi feed liên tục (ví dụ `yes`, hoặc build log), không có lượt quét nào chạy giữa lúc output đang chảy. Thời gian quét đo được ≤ 2 ms mỗi lượt. Footprint không tăng quá vài MB.
4. Path bị cắt: "Find Full Path…" tìm ra ứng viên trong worktree. Một ứng viên thì mở luôn, nhiều thì cho chọn. Không có ứng viên nào thì báo rõ.
5. Tắt cài đặt "Highlight file paths" thì hành vi giống hệt hiện tại.

## Không được hỏng (checklist hồi quy, phase 5)
- Bôi chọn chữ, copy (⌘C), paste guard
- Mouse reporting của TUI (Codex, vim, htop, less)
- ⌘-click link web; link OSC 8 (do chương trình in ra)
- ⌘F trong terminal
- Click để focus pane (sửa ở `88782e9`), kéo header pane, Esc
- Metal renderer bật/tắt; ẩn và hiện tab (trả bộ nhớ Metal)
- Thời gian phát lại scrollback lúc khởi động (`isReplayingScrollback`)
- Phím tắt do Sevinda bắt trước terminal (`TerminalKeyRouting`)

## Quyết định đã chốt (2026-11-12)
1. **Mở bằng ⌘-click là mặc định.** Click trơn giữ nguyên hành vi terminal (bôi chọn, gửi vào TUI), nên rủi ro hồi quy thấp hơn nhiều.
   - Highlight nhẹ luôn hiện. Khi giữ ⌘ và rê chuột lên path thì gạch chân đậm và con trỏ thành bàn tay.
   - Settings › Terminal có lựa chọn "Open paths with: ⌘-Click (mặc định) / Click" cho ai muốn click trơn. Quy tắc click trơn ở phase 3 chỉ áp dụng khi người dùng chọn "Click".
2. **Highlight cả URL web** (`http(s)://…`) cùng kiểu. ⌘-click URL mở bằng trình duyệt mặc định như hiện nay. Menu chuột phải trên URL gồm Open Link, Copy Link.
3. **Giữ "Show in Finder"** trong menu chuột phải, coi như hành động chủ động của người dùng. Hành vi mặc định khi mở path vẫn là mở trong app.
