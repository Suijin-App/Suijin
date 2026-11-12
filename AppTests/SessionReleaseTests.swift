import AppKit
import Foundation
import SevindaCore
import SwiftUI
import Testing
@testable import Sevinda

/// A closed session must free its terminal: the view, its scrollback and its renderer. A handler the pane installed on
/// the view once captured the pane (which holds the runtime), so every closed tab stayed in memory.
@MainActor
@Suite(.serialized)
struct SessionReleaseTests {
    @Test func closingASessionShownInAPaneReleasesItsTerminal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mercury-release-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: try MercuryStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        await model.runtimes.bootstrap()
        let id = try #require(await model.runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil))

        weak let runtime = model.runtimes.runtime(for: id)
        let view = runtime?.terminal.view
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        do {
            let pane = TerminalPane(runtime: try #require(runtime), context: context, isFocused: true).environment(model)
            window.contentView = NSHostingView(rootView: pane)
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(500))
            #expect(view?.onPasteReview != nil)
        }

        await model.closeSession(id)
        window.contentView = nil
        window.orderOut(nil)
        // Let SwiftUI drop the removed pane.
        for _ in 0..<20 where runtime != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(runtime == nil, "the closed session's runtime is still referenced")
        // The view itself goes once AppKit runs the blocks it keeps for a removed view, which a test cannot wait for
        // reliably; what Mercury controls is that nothing it installed on the view still holds anything.
        #expect(view?.onPasteReview == nil && view?.onInput == nil && view?.onKeyRoute == nil)
    }
}
