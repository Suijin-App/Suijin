import SuijinCore
import SuijinUI
import SwiftUI

/// Design system review screen: color tokens, status symbols, buttons and glass on both systems. Opened with ⌥⇧⌘G.
struct DesignGalleryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SuijinSpacing.xl) {
                section("Brand and status colors") {
                    HStack(spacing: SuijinSpacing.l) {
                        swatch(SuijinColor.brand, "brand")
                        swatch(SuijinColor.ok, "ok")
                        swatch(SuijinColor.warning, "warning")
                        swatch(SuijinColor.error, "error")
                        swatch(SuijinColor.idle, "idle")
                        swatch(SuijinColor.agent, "agent")
                    }
                    HStack(spacing: SuijinSpacing.l) {
                        ForEach(StatusTone.allCases, id: \.self) { tone in
                            HStack(spacing: 6) { StatusDot(tone); Tag(Text(verbatim: tone.rawValue), tone: tone) }
                        }
                        StatusDot(.warning, pulsing: true)
                    }
                }
                section("Session activity") {
                    HStack(spacing: SuijinSpacing.l) {
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
                        HStack(spacing: SuijinSpacing.m) {
                            Label("Waiting for input", systemImage: "exclamationmark.bubble.fill")
                                .padding(.horizontal, SuijinSpacing.m).padding(.vertical, SuijinSpacing.s)
                                .floatingGlass(in: Capsule())
                            Label("3 running", systemImage: "terminal")
                                .padding(.horizontal, SuijinSpacing.m).padding(.vertical, SuijinSpacing.s)
                                .floatingGlass(in: Capsule())
                        }
                    }
                    .padding(SuijinSpacing.l)
                    .background(SuijinColor.brand.gradient.opacity(0.35), in: RoundedRectangle(cornerRadius: SuijinRadius.card))
                }
                section("Empty state") {
                    EmptyState(systemImage: "terminal", title: Text("No Sessions"))
                        .frame(height: 140)
                }
            }
            .padding(SuijinSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SuijinSpacing.s) {
            Text(title).font(.headline)
            content()
        }
    }

    private func swatch(_ color: Color, _ name: String) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: SuijinRadius.control).fill(color).frame(width: 44, height: 28)
            Text(verbatim: name).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
