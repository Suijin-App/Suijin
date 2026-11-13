import AppKit
import Foundation
import SevindaCore
import SwiftUI
import Testing
@testable import Sevinda

/// Offscreen renders of the permission defaults in Settings → Agents, light and dark, narrow and wide. Runs when
/// `SEVINDA_SCREENSHOTS` names an output folder; the images are reviewed by eye.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SEVINDA_SCREENSHOTS"] != nil))
struct PermissionModeScreenshotTests {
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SEVINDA_SCREENSHOTS"] ?? NSTemporaryDirectory())
    static let sizes: [(String, CGSize)] = [("narrow", CGSize(width: 1000, height: 900)), ("wide", CGSize(width: 1400, height: 900))]

    private func render<V: View>(_ name: String, size: CGSize, dark: Bool, @ViewBuilder _ content: () -> V) throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: content())
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("permissions-\(name)-\(dark ? "dark" : "light").png"))
    }

    @Test func agentSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sevinda-perm-shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: try SevindaStore.inMemory(), dataRoot: root)
        model.setDefaultPermissionMode(.acceptEdits, for: .claude)
        model.setDefaultPermissionMode(.bypass, for: .codex)

        for (label, size) in Self.sizes {
            for dark in [false, true] {
                try render("settings-\(label)", size: size, dark: dark) {
                    AgentSettings()
                        .environment(model)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}
