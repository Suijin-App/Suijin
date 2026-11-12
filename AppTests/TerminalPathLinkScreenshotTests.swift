import AppKit
import Foundation
import SevindaCore
import SwiftUI
import Testing
@testable import Sevinda

/// Offscreen renders of the Find Full Path popover content (matches and no match) and Settings › Terminal with the path
/// link options, light and dark. Runs when `SEVINDA_SCREENSHOTS` names an output folder; reviewed by eye.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SEVINDA_SCREENSHOTS"] != nil))
struct TerminalPathLinkScreenshotTests {
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SEVINDA_SCREENSHOTS"] ?? NSTemporaryDirectory())

    private func render<V: View>(_ name: String, size: CGSize, dark: Bool, wait: Duration = .milliseconds(800),
                                 @ViewBuilder _ content: () -> V) async throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: content())
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: wait)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }

    @Test func findFullPathAndSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sevinda-shots-\(UUID().uuidString)/demo", isDirectory: true)
        for folder in ["App/Views", "Packages/Kit/Sources/Views", "Legacy/Views"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
            try "x\n".write(to: root.appendingPathComponent(folder + "/Sidebar.swift"), atomically: true, encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let model = AppModel(store: try SevindaStore.inMemory(), dataRoot: root.deletingLastPathComponent().appendingPathComponent("data"))
        await model.addWorkspace(at: root)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        for dark in [false, true] {
            try await render("find-full-path-matches", size: CGSize(width: 472, height: 330), dark: dark) {
                FullPathFinder(elided: "…/Views/Sidebar.swift", context: context) {}.environment(model)
            }
            try await render("find-full-path-none", size: CGSize(width: 472, height: 330), dark: dark) {
                FullPathFinder(elided: "…/Nowhere/Missing.swift", context: context) {}.environment(model)
            }
            try await render("settings-terminal-paths", size: CGSize(width: 640, height: 1000), dark: dark) {
                TerminalSettings().environment(model)
            }
        }
    }
}
