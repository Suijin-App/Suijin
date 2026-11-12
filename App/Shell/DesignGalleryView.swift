import SevindaCore
import SevindaUI
import SwiftUI

/// Design system review screen: color tokens, status symbols, buttons and glass on both systems. Opened with ⌥⇧⌘G.
struct DesignGalleryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SevindaSpacing.xl) {
                section("Brand and status colors") {
                    HStack(spacing: SevindaSpacing.l) {
                        swatch(SevindaColor.brand, "brand")
                        swatch(SevindaColor.ok, "ok")
                        swatch(SevindaColor.warning, "warning")
                        swatch(SevindaColor.error, "error")
                        swatch(SevindaColor.idle, "idle")
                        swatch(SevindaColor.agent, "agent")
                    }
                    HStack(spacing: SevindaSpacing.l) {
                        ForEach(StatusTone.allCases, id: \.self) { tone in
                            HStack(spacing: 6) { StatusDot(tone); Tag(Text(verbatim: tone.rawValue), tone: tone) }
                        }
                        StatusDot(.warning, pulsing: true)
                    }
                }
                section("Session activity") {
                    HStack(spacing: SevindaSpacing.l) {
                        ForEach([SessionActivityDisplay.starting, .running, .waitingForInput, .idle, .exited, .failed], id: \.self) { activity in
                            Label { activity.label } icon: { Image(systemName: activity.systemImage).foregroundStyle(activity.color) }
                        }
                    }
                }
                section("Buttons") {
                    HStack {
                        Button("Prominent") {}.glassProminentButtonStyle()
                        Button("Glass") {}.glassButtonStyle()
                        Button {} label: { Image(systemName: "plus") }.glassIconButtonStyle().accessibilityLabel(Text("Add"))
                        Button("Bordered") {}.buttonStyle(.bordered)
                    }
                }
                section("Floating glass") {
                    GlassGroup {
                        HStack(spacing: SevindaSpacing.m) {
                            Label("Waiting for input", systemImage: "exclamationmark.bubble.fill")
                                .padding(.horizontal, SevindaSpacing.m).padding(.vertical, SevindaSpacing.s)
                                .floatingGlass(in: Capsule())
                            Label("3 running", systemImage: "terminal")
                                .padding(.horizontal, SevindaSpacing.m).padding(.vertical, SevindaSpacing.s)
                                .floatingGlass(in: Capsule())
                        }
                    }
                    .padding(SevindaSpacing.l)
                    .background(SevindaColor.brand.gradient.opacity(0.35), in: RoundedRectangle(cornerRadius: SevindaRadius.card))
                }
                section("Empty state") {
                    EmptyState(systemImage: "terminal", title: Text("No Sessions"))
                        .frame(height: 140)
                }
            }
            .padding(SevindaSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SevindaSpacing.s) {
            Text(title).font(.headline)
            content()
        }
    }

    private func swatch(_ color: Color, _ name: String) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: SevindaRadius.control).fill(color).frame(width: 44, height: 28)
            Text(verbatim: name).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
