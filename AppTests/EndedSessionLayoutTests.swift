import AppKit
import Foundation
import SuijinCore
import SuijinTerminal
import SwiftUI
import Testing
@testable import Suijin

/// The ended card of a failed session (with its last output) must not change the window's layout: the main window
/// hosts the real `RootView` offscreen and the inspector's file list keeps its place when the card appears.
@MainActor
@Suite(.endsHostedSessions, .serialized, .timeLimit(.minutes(3)))
struct EndedSessionLayoutTests {
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
        return condition()
    }

    private func settle(_ host: NSView) {
        for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        host.layoutSubtreeIfNeeded()
    }

    /// The frames, in window coordinates, of every scroll view in the window (the inspector's file list among them).
    private func scrollFrames(in view: NSView) -> [CGRect] {
        (view is NSScrollView ? [view.convert(view.bounds, to: nil)] : []) + view.subviews.flatMap(scrollFrames)
    }

    @Test func lastOutputKeepsTheWindowLayout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-ended-layout-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("my-project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fail.sh")
        try "#!/bin/sh\nprintf 'No conversation found with session ID: 26365d16-6f5f-4605-9d69-286ef0c2fcbe\\n'\nexit 1\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.load()
        await model.addWorkspace(at: folder)
        let workspace = try #require(model.workspaces.first)
        let context = SessionContext.workspace(workspace.id)
        model.selection = context
        await model.runtimes.bootstrap()

        // First an ended session without last output, which never moved anything.
        let clean = AgentSessionRecord(workspaceID: workspace.id, agent: .claude, title: "Claude", cwd: folder.path,
                                       state: .exited, exitCode: 0, createdAt: Date().addingTimeInterval(-100), endedAt: Date())
        await model.upsert(clean)
        model.selectedTab[context] = .session(clean.id)

        let window = OffscreenWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 1200, height: 760),
                                     styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RootView().environment(model))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        settle(host)
        let before = (fitting: host.fittingSize.height, scrolls: scrollFrames(in: host))
        #expect(!before.scrolls.isEmpty)

        // Then a session that failed and printed one line.
        let failed = AgentSessionRecord(workspaceID: workspace.id, agent: .claude, title: "Claude", cwd: folder.path)
        try await model.runtimes.run(failed, launch: ShellLaunch.command(script.path, [], cwd: folder, environment: [:], interactive: false))
        #expect(await eventually { model.runtimes.endedOutput[failed.id] != nil })
        model.selectedTab[context] = .session(failed.id)
        settle(host)

        #expect(host.fittingSize.height == before.fitting)
        #expect(scrollFrames(in: host) == before.scrolls)
        for session in model.sessions { await model.closeSession(session.id) }
    }
}
