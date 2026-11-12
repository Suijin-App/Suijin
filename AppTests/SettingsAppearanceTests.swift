import AppKit
import Foundation
import SevindaAgents
import SevindaCore
import SwiftUI
import Testing
@testable import Sevinda

@MainActor
struct SettingsAppearanceTests {
    private func model() throws -> AppModel {
        AppModel(store: try MercuryStore.inMemory(),
                 dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent("mercury-appearance-\(UUID().uuidString)"))
    }

    @Test func missingOrUnknownAppearanceFollowsTheSystem() {
        #expect(AppAppearance(setting: nil) == .system)
        #expect(AppAppearance(setting: "sepia") == .system)
        #expect(AppAppearance(setting: "dark") == .dark)
        #expect(AppAppearance.system.nsAppearance == nil)
        #expect(AppAppearance.light.nsAppearance?.name == .aqua)
        #expect(AppAppearance.dark.nsAppearance?.name == .darkAqua)
    }

    @Test func appearanceSettingRoundTripsThroughTheStore() async throws {
        let model = try model()
        model.setSetting(.appearance, AppAppearance.dark.rawValue)
        #expect(model.appearance == .dark)
        // The write is detached; wait for it, then read the value back as a fresh launch would.
        for _ in 0..<50 where (try? model.store.setting(SettingKey.appearance.rawValue)) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try model.store.setting(SettingKey.appearance.rawValue) == "dark")
        let relaunched = AppModel(store: model.store, dataRoot: model.dataRoot)
        await relaunched.loadSettings()
        #expect(relaunched.appearance == .dark)

        // System is stored as no value at all.
        model.setSetting(.appearance, nil)
        #expect(model.appearance == .system)
    }
}

/// Offscreen renders of every Settings tab, light and dark. Runs when `MERCURY_SCREENSHOTS` names an output folder,
/// like `ScreenshotTests`; the images are reviewed by eye.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MERCURY_SCREENSHOTS"] != nil))
struct SettingsScreenshotTests {
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MERCURY_SCREENSHOTS"] ?? NSTemporaryDirectory())

    private func render<V: View>(_ name: String, height: CGFloat, dark: Bool, @ViewBuilder _ content: () -> V) throws {
        let size = CGSize(width: 720, height: height)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: content())
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("settings-\(name)-\(dark ? "dark" : "light").png"))
    }

    @Test func settingsTabs() async throws {
        // Resolve the login shell PATH first, so the Installed rows show their final state.
        _ = await AgentCatalog.loginShellPATH()
        let model = AppModel(store: try MercuryStore.inMemory(),
                             dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent("mercury-settings-shots-\(UUID().uuidString)"))
        model.setSetting(.terminalTheme, "dracula")
        for dark in [false, true] {
            model.setSetting(.appearance, dark ? "dark" : nil)
            try render("general", height: 600, dark: dark) { GeneralSettings().environment(model) }
            try render("agents", height: 640, dark: dark) { AgentSettings().environment(model) }
            try render("accounts-empty", height: 520, dark: dark) { AccountsSettingsView().environment(model) }
            try render("terminal", height: 680, dark: dark) { TerminalSettings().environment(model) }
            try render("terminal-scrolled", height: 1400, dark: dark) { TerminalSettings().environment(model) }
        }
    }
}
