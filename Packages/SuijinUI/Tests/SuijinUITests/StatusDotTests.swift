import AppKit
import SwiftUI
import Testing
@testable import SuijinUI

/// The pulsing status dot is animated by Core Animation. A SwiftUI `repeatForever` animation re-runs the window's
/// view graph on every display frame, which kept the main thread busy and made every list stutter.
@MainActor
struct StatusDotTests {
    private func dots(in view: some View) -> [PulsingDotView] {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.contentView = nil }
        return Self.all(in: hosting)
    }

    private static func all(in view: NSView) -> [PulsingDotView] {
        ((view as? PulsingDotView).map { [$0] } ?? []) + view.subviews.flatMap { all(in: $0) }
    }

    @Test func pulsingDotRunsALayerAnimation() throws {
        let found = dots(in: HStack { StatusDot(.warning, pulsing: true); Text(verbatim: "app") })
        let dot = try #require(found.first)
        #expect(found.count == 1)
        #expect(dot.isPulsing)
        let pulse = try #require(dot.layer?.animation(forKey: PulsingDotView.pulseKey) as? CABasicAnimation)
        #expect(pulse.keyPath == "opacity")
        #expect(pulse.fromValue as? Double == 1)
        #expect(pulse.toValue as? Double == 0.3)
        #expect(pulse.duration == 0.6)
        #expect(pulse.autoreverses)
        #expect(pulse.repeatCount == .infinity)
        #expect(dot.layer?.backgroundColor != nil, "the dot is drawn in its tone")
    }

    @Test func stillDotHasNoAnimation() {
        #expect(dots(in: StatusDot(.ok)).isEmpty)
    }

    @Test func pulseComesBackAfterTheDotReturnsToAWindow() {
        let dot = PulsingDotView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = dot
        #expect(dot.isPulsing)
        window.contentView = nil
        dot.layer?.removeAllAnimations()
        window.contentView = dot
        #expect(dot.isPulsing, "a reused list row pulses again")
        window.contentView = nil
    }
}
