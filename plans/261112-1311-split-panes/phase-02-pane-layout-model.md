# Phase 2 — Mô hình layout + lưu trữ

## Mô hình
```swift
/// One tab's arrangement of terminal panes.
struct PaneLayout: Codable, Hashable {
    var id: UUID                       // stable tab identity (survives closing any pane)
    var root: PaneNode
    var focused: UUID?                 // session id of the focused pane
    var zoomed: UUID?                  // a pane shown alone (⇧⌘↩), others kept
}
indirect enum PaneNode: Codable, Hashable {
    case pane(UUID)                                        // a session
    case split(axis: Axis, children: [PaneNode], fractions: [Double])  // n-ary, fractions sum to 1
}
```
- Thao tác thuần (dễ test): `inserting(_:beside:edge:)`, `removing(_:)` (gộp node 1 con, chuẩn hoá fractions),
  `moving(_:to:edge:)` (gồm `.center` = hoán đổi), `swapping`, `equalized()`, `paneCount`, `neighbor(of:direction:)` cho điều hướng bàn phím.
- Giới hạn 10 pane kiểm ở một chỗ (`PaneLayout.maxPanes = 10`).
- Split cùng hướng với cha thì chèn vào mảng con thay vì lồng thêm cấp (giữ cây phẳng, resize tự nhiên).

## Tab và session
- Tab = `PaneLayout` (nếu có) hoặc session đơn. `tabSessions`/`tabList` dùng layout: mỗi layout 1 tab, đại diện bởi pane focus.
- Thay `AppModel.splits` + `focusedPane` bằng `paneLayouts: [UUID: PaneLayout]` + chỉ mục session→layout.
- Thứ tự tab (`sessionOrder` hiện có) chuyển sang khoá theo tab id (layout id hoặc session id).
- Đóng session: gỡ khỏi layout; còn 1 pane → huỷ layout (tab thường, giữ vị trí tab).

## Lưu trữ
- Migration `v6_pane_layout`: bảng `pane_layout(id TEXT PK, contextKey TEXT, layout BLOB/JSON, updatedAt)`; backup tự động trước migrate (đã có, kiểm lại).
- Ghi khi layout đổi (debounce 300 ms khi resize). Khôi phục lúc `load()` sau khi restore session: bỏ pane có session không còn
  (hoặc giữ ô với màn "ended" nếu record còn), chuẩn hoá.

## File
`App/Features/Terminal/PaneLayout.swift` (mới, mô hình + thao tác), `Packages/MercuryCore/.../Migrations+PaneLayout.swift`, `PaneLayoutStore.swift`,
`App/AppModel.swift`, `SessionActions.swift`, `TabOrder.swift`, `SessionRuntime.swift` (restore), tests MercuryCore + `AppTests/PaneLayoutTests.swift`.

## Kiểm tra
Unit test mọi thao tác cây (chèn 4 hướng, xoá gộp, di chuyển giữa/cạnh, swap, giới hạn 10, fractions), round-trip DB, khôi phục khi thiếu session.
