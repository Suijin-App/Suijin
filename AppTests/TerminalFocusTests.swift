import AppKit
import Foundation
import SuijinCore
import Testing
@testable import Suijin

/// Clicking a session in the sidebar must leave the keyboard in its terminal, not in the list (where the arrow keys
/// would switch sessions instead of reaching the agent).
@MainActor
@Suite(.endsHostedSessions, .serialized)
struct TerminalFocusTests {
    @Test func clickedSessionTakesTheKeyboardFromTheList() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-focus-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        model.selection = context
        await model.runtimes.bootstrap()
        let id = try #require(await model.runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil))
        defer { Task { await model.closeSession(id) } }
        let terminal = try #require(model.runtimes.runtime(for: id)).terminal.view

        // The window holds a list (the sidebar) and the terminal; the click left the list focused.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let stack = NSStackView()
        let list = NSTableView(frame: CGRect(x: 0, y: 0, width: 200, height: 600))
        list.addTableColumn(NSTableColumn(identifier: .init("name")))
        list.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let field = NSTextField()
        stack.addArrangedSubview(list)
        stack.addArrangedSubview(field)
        stack.addArrangedSubview(terminal)
        window.contentView = stack
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        window.makeFirstResponder(list)
        #expect(window.firstResponder === list)

        // Longer than the focus waits for a mouse button held on this machine (up to a second).
        model.focusActiveTerminalAfterClick()
        try await Task.sleep(for: .milliseconds(1_300))
        #expect(window.firstResponder === terminal)

        // Never taken from a field the user moved to.
        window.makeFirstResponder(field)
        let editor = window.firstResponder
        model.focusActiveTerminalAfterClick()
        try await Task.sleep(for: .milliseconds(1_300))
        #expect(window.firstResponder === editor)
    }
}
