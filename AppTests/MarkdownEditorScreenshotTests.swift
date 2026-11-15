import AppKit
import Foundation
import SuijinCore
import SwiftUI
import Testing
@testable import Suijin

/// Offscreen renders of a Markdown tab in Edit: the header with the Read/Edit switch, the editor with every kind of
/// block, and the bar shown when the file changed on disk. Narrow and wide, light and dark. Runs when
/// `SUIJIN_SCREENSHOTS` names an output folder; reviewed by eye.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SUIJIN_SCREENSHOTS"] != nil))
struct MarkdownEditorScreenshotTests {
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SUIJIN_SCREENSHOTS"] ?? NSTemporaryDirectory())

    static let document = """
    ---
    title: Release checklist
    status: pending
    ---
    # Release checklist

    Everything that must be true before **Suijin** ships. See the [release process](docs/release-process.md) and run `scripts/ci-local.sh` first.

    ## Before the build

    - Bump the version in *both* places, the app and the helper, so the two never drift apart on a user's machine
      - The helper refuses older apps
    - [x] Changelog written
    - [ ] Screenshots taken
    1. Tag the commit

    > Releases are notarized. A build that is not stapled is ~~shipped~~ rejected.

    ---

    ```swift
    let version = "1.4.0"
    print("Releasing \\(version)")
    ```

    | Step | Owner |
    |------|-------|
    | Sign | CI    |

    """

    static func render<V: View>(_ name: String, size: CGSize, dark: Bool, output: URL, wait: Duration = .milliseconds(900),
                                prepare: () -> Void = {}, @ViewBuilder _ content: () -> V) async throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // The window's own background is not part of a view snapshot; paint it under the content.
        let host = NSHostingView(rootView: content().background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        // The content is taken out of the window afterwards: a view left alive would keep following the model and
        // take the editor's views away from the next render.
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }
        try await Task.sleep(for: wait)
        prepare()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("\(name)-\(Int(size.width))-\(dark ? "dark" : "light").png"))
    }

    @Test func editorAndConflictBar() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-md-shots-\(UUID().uuidString)/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = root.appendingPathComponent("release-checklist.md")
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.deletingLastPathComponent().appendingPathComponent("data"))
        await model.addWorkspace(at: root)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        model.selection = context

        for dark in [false, true] {
            for width in [560.0, 1200.0] {
                try Self.document.write(to: file, atomically: true, encoding: .utf8)
                model.closeFile(file.path, in: context)
                model.openFile(file.path, in: context)
                let session = try #require(model.markdownSession(for: file.path, in: context, create: true))
                session.mode = .edit
                // The insertion point on the paragraph line: its markers show as typed.
                let line = (session.text as NSString).range(of: "Everything that")
                session.controller.textView.setSelectedRange(NSRange(location: line.location, length: 0))
                try await Self.render("markdown-editor", size: CGSize(width: width, height: 860), dark: dark, output: output) {
                    FileViewer(path: file.path, context: context).environment(model)
                }
                // Unsaved edits, then another writer changes the file.
                session.controller.textView.insertText("Edited: ", replacementRange: NSRange(location: line.location, length: 0))
                try (Self.document + "\nAdded by an agent.\n").write(to: file, atomically: true, encoding: .utf8)
                session.diskMayHaveChanged()
                #expect(session.conflict == .changed)
                try await Self.render("markdown-editor-conflict", size: CGSize(width: width, height: 420), dark: dark, output: output) {
                    FileViewer(path: file.path, context: context).environment(model)
                }
            }
        }
    }
}
