import MercuryCore
import MercuryUI
import SwiftUI

/// Design system review screen: color tokens, status symbols, buttons and glass on both systems. Opened with ⌥⇧⌘G.
struct DesignGalleryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MercurySpacing.xl) {
                section("Brand and status colors") {
                    HStack(spacing: MercurySpacing.l) {
                        swatch(MercuryColor.brand, "brand")
                        swatch(MercuryColor.ok, "ok")
                        swatch(MercuryColor.warning, "warning")
                        swatch(MercuryColor.error, "error")
                        swatch(MercuryColor.idle, "idle")
                        swatch(MercuryColor.agent, "agent")
                    }
                    HStack(spacing: MercurySpacing.l) {
                        ForEach(StatusTone.allCases, id: \.self) { tone in
                            HStack(spacing: 6) { StatusDot(tone); Tag(Text(verbatim: tone.rawValue), tone: tone) }
                        }
                        StatusDot(.warning, pulsing: true)
                    }
                }
                section("Session activity") {
                    HStack(spacing: MercurySpacing.l) {
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
                        HStack(spacing: MercurySpacing.m) {
                            Label("Waiting for input", systemImage: "exclamationmark.bubble.fill")
                                .padding(.horizontal, MercurySpacing.m).padding(.vertical, MercurySpacing.s)
                                .floatingGlass(in: Capsule())
                            Label("3 running", systemImage: "terminal")
                                .padding(.horizontal, MercurySpacing.m).padding(.vertical, MercurySpacing.s)
                                .floatingGlass(in: Capsule())
                        }
                    }
                    .padding(MercurySpacing.l)
                    .background(MercuryColor.brand.gradient.opacity(0.35), in: RoundedRectangle(cornerRadius: MercuryRadius.card))
                }
                section("Empty state") {
                    EmptyState(systemImage: "terminal", title: Text("No Sessions"))
                        .frame(height: 140)
                }
            }
            .padding(MercurySpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: MercurySpacing.s) {
            Text(title).font(.headline)
            content()
        }
    }

    private func swatch(_ color: Color, _ name: String) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: MercuryRadius.control).fill(color).frame(width: 44, height: 28)
            Text(verbatim: name).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
