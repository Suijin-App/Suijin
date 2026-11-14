import AppKit
import Foundation
import SuijinCore
import SwiftUI
import Testing
@testable import Suijin

/// Offscreen renders of every step of the welcome tour, wide, at the window's minimum size and smaller, light and dark. Runs
/// when `SUIJIN_SCREENSHOTS` names an output folder; the images are reviewed by eye.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SUIJIN_SCREENSHOTS"] != nil))
struct OnboardingScreenshotTests {
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SUIJIN_SCREENSHOTS"] ?? NSTemporaryDirectory())

    private func render(_ name: String, size: CGSize, dark: Bool, step: OnboardingStep, model: AppModel) throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: OnboardingOverlay(tour: OnboardingTour(step: step)).environment(model))
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer {
            // Taking the view down removes the tour's key monitor.
            window.contentView = nil
            window.orderOut(nil)
        }
        // Long enough for the staggered entrance and the arrows to finish drawing.
        for _ in 0..<22 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("onboarding-\(name)-\(dark ? "dark" : "light").png"))
    }

    @Test func everyStep() throws {
        let model = AppModel(store: try SuijinStore.inMemory(),
                             dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent("suijin-onboarding-shots-\(UUID().uuidString)"))
        for dark in [false, true] {
            for step in OnboardingStep.allCases {
                try render("\(step.rawValue)-wide", size: CGSize(width: 1280, height: 800), dark: dark, step: step, model: model)
                // The smallest window the app allows, then smaller still for the compact layout.
                try render("\(step.rawValue)-minimum", size: CGSize(width: 1000, height: 640), dark: dark, step: step, model: model)
                try render("\(step.rawValue)-narrow", size: CGSize(width: 860, height: 560), dark: dark, step: step, model: model)
            }
        }
    }
}
