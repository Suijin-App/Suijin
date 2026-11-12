# Phase 3 — Trang Stats & Usage

## File
- `App/Features/Settings/StatsUsageSettings.swift` (+ tách `UsageHeatmap.swift`, `ProviderUsageCard.swift` nếu dài).
- `App/Features/Settings/SettingsView.swift` — thêm `SettingsPage.stats` ("Stats & Usage", `chart.bar`), icon trong thanh tab overlay.
- `App/AppModel.swift` hoặc controller riêng giữ `UsageStore` + `StatsStore`, refresh khi mở trang, không quét khi trang đóng.

## Bố cục (native)
- Hàng 3 thẻ số (Agents spawned, Time agents worked, PRs created) + "Tracking since".
- "Usage Analytics": `Picker` phạm vi (Overview / Claude / Codex) + `Picker` thời gian (7 days / 30 days mặc định / All time), nút refresh + "Updated …", tiến trình quét lần đầu (`ProgressView` có %).
- 4 thẻ: Total tokens, Est. cost (tooltip: "Estimated at API list prices; not your subscription bill."), Active days, Cache share.
- "Daily intensity": Swift Charts `RectangleMark` lưới 7×N tuần, màu theo mức (tint hệ thống), nhãn ngày đầu/cuối, badge "Best: <ngày>".
- "Token mix": thanh xếp chồng (Charts `BarMark` ngang) + chú thích.
- "Providers": thẻ Claude/Codex: trạng thái, model + project nhiều nhất, token, sessions/turns, chi phí; provider chưa có dữ liệu ghi rõ.
- Trạng thái rỗng (`ContentUnavailableView`), lỗi đọc thư mục (cảnh báo nhỏ), số định dạng gọn (11.4B, $6,742.52).

## Kiểm tra
Render offscreen + ảnh chụp app thật sáng/tối, hẹp/rộng; không clip; accessibility label cho thẻ và heatmap.
