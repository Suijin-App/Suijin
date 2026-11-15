import AppKit
import SwiftUI

/// Status tones shared by dots, tags, and banners.
public enum StatusTone: String, Sendable, CaseIterable {
    case ok, warning, error, idle, agent, info

    public var color: Color {
        switch self {
        case .ok: SuijinColor.ok
        case .warning: SuijinColor.warning
        case .error: SuijinColor.error
        case .idle: SuijinColor.idle
        case .agent: SuijinColor.agent
        case .info: SuijinColor.accent
        }
    }

    /// Text color readable on a light background of the same tone.
    public var textColor: Color {
        switch self {
        case .ok: SuijinColor.okText
        case .warning: SuijinColor.warningText
        case .error: SuijinColor.errorText
        case .idle: .secondary
        case .agent: SuijinColor.agent
        case .info: SuijinColor.accent
        }
    }
}

/// Status dot for a host/app. `pulsing` is used while connecting. Custom on purpose: AppKit and SwiftUI have
/// no small colored status indicator (the sidebar, toolbar and Fleet need the same dot next to text).
public struct StatusDot: View {
    let tone: StatusTone
    let pulsing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ tone: StatusTone, pulsing: Bool = false) {
        self.tone = tone
        self.pulsing = pulsing
    }

    public var body: some View {
        Group {
            if pulsing, !reduceMotion {
                // The clear 8-point view gives the pulsing dot the same size and baseline as the still one.
                Color.clear.overlay { PulsingDot(color: NSColor(tone.color)) }
            } else {
                Circle().fill(tone.color)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}

/// The pulsing status dot, animated by Core Animation instead of SwiftUI. A SwiftUI `repeatForever` animation
/// re-runs the window's view graph and layout on every display frame: one restarting app in the Apps list kept
/// about 60% of the main thread busy and made every list in the window stutter. A layer animation runs in the
/// render server and costs the main thread nothing per frame.
struct PulsingDot: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> PulsingDotView {
        PulsingDotView()
    }

    func updateNSView(_ view: PulsingDotView, context: Context) {
        view.color = color
    }
}

/// A round, colored layer whose opacity goes 1 → 0.3 → 1 every 1.2 seconds (ease in-out), forever.
final class PulsingDotView: NSView {
    static let pulseKey = "capstio.statusDot.pulse"

    var color: NSColor = .clear {
        didSet { if color != oldValue { applyColor() } }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    /// Whether the pulse animation is attached to the layer.
    var isPulsing: Bool { layer?.animation(forKey: Self.pulseKey) != nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    /// Dynamic colors resolve against this view's light or dark appearance.
    private func applyColor() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance { layer.backgroundColor = color.cgColor }
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    /// AppKit may drop layer animations when a view leaves its window (a list row being reused): add it again.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        addPulse()
    }

    private func addPulse() {
        guard window != nil, let layer, layer.animation(forKey: Self.pulseKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.3
        pulse.duration = 0.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: Self.pulseKey)
    }
}

/// Small rounded label (tag, risk level, app type). Custom on purpose: macOS has no inline tag/badge view
/// (`.badge` only decorates list rows and tab items).
public struct Tag: View {
    let text: Text
    let tone: StatusTone?

    public init(_ text: Text, tone: StatusTone? = nil) {
        self.text = text
        self.tone = tone
    }

    public init(_ key: LocalizedStringKey, tone: StatusTone? = nil) {
        self.init(Text(key), tone: tone)
    }

    public var body: some View {
        text
            .font(.caption2.weight(.medium))
            // A tag is one short label: wrapped onto two lines its capsule turns into a blob.
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .foregroundStyle(tone?.textColor ?? .secondary)
            .background(Capsule().fill((tone?.color ?? SuijinColor.idle).opacity(tone == nil ? 0.15 : 0.16)))
    }
}

/// Usage bar for CPU/RAM/Disk: a native linear capacity `Gauge`, tinted by threshold.
public struct MiniBar: View {
    let fraction: Double
    let tone: StatusTone?

    public init(fraction: Double, tone: StatusTone? = nil) {
        self.fraction = min(max(fraction, 0), 1)
        self.tone = tone
    }

    public static func tone(forPercent value: Double) -> StatusTone {
        value > 85 ? .error : value > 70 ? .warning : .info
    }

    public var body: some View {
        Gauge(value: fraction) { EmptyView() }
            .gaugeStyle(.linearCapacity)
            .labelsHidden()
            .controlSize(.mini)
            .tint((tone ?? MiniBar.tone(forPercent: fraction * 100)).color)
            .accessibilityElement()
            .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

/// Metric card on the Overview (`Tổng quan`) and Fleet tabs, in a native `GroupBox`.
public struct StatCard<Footer: View>: View {
    let title: LocalizedStringKey
    let systemImage: String?
    let value: String
    let fraction: Double?
    let footer: Footer

    public init(_ title: LocalizedStringKey, systemImage: String? = nil, value: String, fraction: Double? = nil,
                @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
        self.fraction = fraction
        self.footer = footer()
    }

    public var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let systemImage { Image(systemName: systemImage).imageScale(.small) }
                    Text(title).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(value).font(SuijinFont.statValue).lineLimit(1).minimumScaleFactor(0.6)
                if let fraction { MiniBar(fraction: fraction) }
                footer
                // Cards in one row share the tallest card's height; the content stays at the top.
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(SuijinSpacing.xs)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Empty state (no file selected, no data yet…), shown with the system `ContentUnavailableView`.
public struct EmptyState: View {
    let systemImage: String
    let title: Text
    let message: Text?

    public init(systemImage: String, title: Text, message: Text? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
    }

    public var body: some View {
        ContentUnavailableView {
            Label { title } icon: { Image(systemName: systemImage) }
        } description: {
            if let message { message }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
