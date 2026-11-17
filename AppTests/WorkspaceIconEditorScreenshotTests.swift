import AppKit
import Foundation
import SuijinCore
import SwiftUI
import Testing
@testable import Suijin

/// Offscreen renders of the workspace icon popover with its emoji field empty, light and dark: an empty field must
/// read as empty. Runs when `SUIJIN_SCREENSHOTS` names an output folder; reviewed by eye.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SUIJIN_SCREENSHOTS"] != nil))
struct WorkspaceIconEditorScreenshotTests {
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SUIJIN_SCREENSHOTS"] ?? NSTemporaryDirectory())

    @Test func emptyEmojiField() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-icon-shots-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("demo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let workspace = try #require(model.workspaces.first)

        for dark in [false, true] {
            let window = OffscreenWindow(contentRect: CGRect(x: 0, y: 0, width: 340, height: 330), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: WorkspaceIconEditor(workspaceID: workspace.id).environment(model)
                .background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = host
            window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            defer {
                window.contentView = nil
                window.orderOut(nil)
            }
            try await Task.sleep(for: .milliseconds(700))
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent("workspace-icon-editor-\(dark ? "dark" : "light").png"))
        }
    }
}
