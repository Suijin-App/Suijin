import AppKit
import Foundation
import SevindaCore
import SevindaTerminal
import SwiftUI
import Testing
@testable import Sevinda

/// Renders the Session Ended view for review: a Claude session that can be resumed, a failed session with its last
/// output, and an ended pane beside a live one in a split tab, narrow and wide, light and dark. Opt-in with
/// `TEST_RUNNER_SEVINDA_ENDED_SHOT=<file>`: at each step the file receives `<name> <window number>` and the window stays
/// up while the caller captures it with `screencapture -l` (Liquid Glass does not draw into `cacheDisplay`). The window
/// is ordered in without activating the app.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: ProcessInfo.processInfo.environment["SEVINDA_ENDED_SHOT"] != nil))
struct EndedSessionScreenshotTests {
    let output = ProcessInfo.processInfo.environment["SEVINDA_ENDED_SHOT"] ?? ""

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

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
        return condition()
    }

    @Test func endedViews() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sevinda-ended-shots-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("my-project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fail.sh")
        try "#!/bin/sh\nprintf 'Error: could not reach the account.\\nRun claude /login and try again.\\n'\nexit 1\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let model = AppModel(store: try SevindaStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let workspace = try #require(model.workspaces.first)
        let context = SessionContext.workspace(workspace.id)
        model.selection = context
        await model.runtimes.bootstrap()

        // A Claude session that exited after Ctrl-C twice, its conversation known.
        let claude = AgentSessionRecord(workspaceID: workspace.id, agent: .claude, title: "Claude", cwd: folder.path,
                                        state: .exited, exitCode: 0, createdAt: Date().addingTimeInterval(-1_520),
                                        endedAt: Date().addingTimeInterval(-40),
                                        agentSessionID: "0f4c3a52-7d1e-4b8a-9c2d-5e6f7a8b9c0d")
        await model.upsert(claude)
        // A session that failed, with what it printed.
        let failed = AgentSessionRecord(workspaceID: workspace.id, agent: .codex, title: "Codex", cwd: folder.path)
        try await model.runtimes.run(failed, launch: ShellLaunch.command(script.path, [], cwd: folder, environment: [:], interactive: false))
        #expect(await eventually { model.runtimes.endedOutput[failed.id] != nil })

        for dark in [false, true] {
            for width in [560.0, 1200.0] {
                try await render("ended-resume", size: CGSize(width: width, height: 640), dark: dark) {
                    SessionPaneContent(session: claude.id, context: context, isFocused: true, closeTitle: "Close Tab").environment(model)
                }
                try await render("ended-failed", size: CGSize(width: width, height: 700), dark: dark) {
                    SessionPaneContent(session: failed.id, context: context, isFocused: true, closeTitle: "Close Tab").environment(model)
                }
            }
        }

        // A split tab: a live shell beside the ended Claude pane.
        // Explicitly a shell: the default new pane runs the focused pane's agent, which would start a real Claude.
        model.selectedTab[context] = .session(claude.id)
        _ = try #require(await model.addPane(in: context, axis: .sideBySide, agent: .shell))
        for dark in [false, true] {
            for width in [900.0, 1400.0] {
                try await render("ended-split", size: CGSize(width: width, height: 640), dark: dark) {
                    SessionTabsView(context: context).environment(model)
                }
            }
        }
        for session in model.sessions { await model.closeSession(session.id) }
    }
}

