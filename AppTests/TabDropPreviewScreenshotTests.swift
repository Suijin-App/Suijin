import AppKit
import Foundation
import SuijinCore
import SwiftUI
import Testing
@testable import Suijin

/// Renders where a dragged tab would land for review: the preview on each edge of a plain tab's terminal and of a
/// pane of a split tab, narrow and wide, light and dark. Opt-in with `TEST_RUNNER_SUIJIN_TAB_DROP_SHOT=<file>`: at
/// each step the file receives `<name> <window number>` and the window stays up while the caller captures it with
/// `screencapture -l` (Liquid Glass does not draw into `cacheDisplay`). The window is ordered in without activating
/// the app.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: ProcessInfo.processInfo.environment["SUIJIN_TAB_DROP_SHOT"] != nil))
struct TabDropPreviewScreenshotTests {
    let output = ProcessInfo.processInfo.environment["SUIJIN_TAB_DROP_SHOT"] ?? ""

    private func render<V: View>(_ name: String, size: CGSize, dark: Bool, @ViewBuilder _ content: () -> V) async throws {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 40, y: 40), size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: content())
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(900))
        try "\(name)-\(Int(size.width))-\(dark ? "dark" : "light") \(window.windowNumber)"
            .write(toFile: output, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(1_800))
    }

    @Test func previews() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-tab-drop-shots-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("my-project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let workspace = try #require(model.workspaces.first)
        let context = SessionContext.workspace(workspace.id)
        model.selection = context
        // Ended sessions: no process is started, each shows its ended view under the preview.
        var ids: [UUID] = []
        for title in ["Claude", "Codex", "Shell", "Review"] {
            let record = AgentSessionRecord(workspaceID: workspace.id, agent: .shell, title: title, cwd: folder.path, state: .exited)
            await model.upsert(record)
            ids.append(record.id)
        }

        // A plain tab on screen, another tab dragged over each of its edges.
        model.selectedTab[context] = .session(ids[0])
        model.paneDrag.beginTab(.session(ids[3]))
        for dark in [false, true] {
            for (width, edge) in [(560.0, PaneEdge.left), (560.0, .top), (1200.0, .right), (1200.0, .bottom)] {
                model.paneDrag.hover(ids[0], placement: .edge(edge))
                try await render("tab-drop-plain-\(edge.rawValue)", size: CGSize(width: width, height: 520), dark: dark) {
                    SessionTabsView(context: context).environment(model)
                }
            }
        }

        // A split tab of three panes on screen; the preview over its smallest pane.
        try model.insertPane(ids[1], beside: ids[0], edge: .right)
        try model.insertPane(ids[2], beside: ids[1], edge: .bottom)
        model.paneDrag.beginTab(.session(ids[3]))
        for dark in [false, true] {
            for (width, edge) in [(560.0, PaneEdge.left), (560.0, .bottom), (1200.0, .right), (1200.0, .top)] {
                model.paneDrag.hover(ids[2], placement: .edge(edge))
                try await render("tab-drop-pane-\(edge.rawValue)", size: CGSize(width: width, height: 520), dark: dark) {
                    SessionTabsView(context: context).environment(model)
                }
            }
        }
        model.paneDrag.end()
    }
}
