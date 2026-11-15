import AppKit
import Foundation
import SuijinAccounts
import SuijinCore
import SwiftUI
import Testing
@testable import Suijin

/// Renders "Continue With Another Account" for review: the limit banner over a running session, the moving progress,
/// the ended view's menu button and the usage popover's, narrow and wide, light and dark. Opt-in with
/// `TEST_RUNNER_SUIJIN_SWITCH_SHOT=<file>`: at each step the file receives `<name> <window number>` and the caller
/// captures that window with `screencapture -l` (Liquid Glass does not draw into `cacheDisplay`, and the window server
/// draws no window outside every display). The borderless window sits at the desktop's level, behind every app window
/// and the desktop icons, ignores the mouse and is ordered in without activating the app, so nothing comes to the
/// front or takes focus.
/// A stand-in `claude` script runs instead of the real one.
@MainActor
@Suite(.endsHostedSessions, .serialized, .timeLimit(.minutes(3)), .enabled(if: ProcessInfo.processInfo.environment["SUIJIN_SWITCH_SHOT"] != nil))
struct ContinueWithAccountScreenshotTests {
    let output = ProcessInfo.processInfo.environment["SUIJIN_SWITCH_SHOT"] ?? ""

    private func render<V: View>(_ name: String, size: CGSize, dark: Bool, @ViewBuilder _ content: () -> V) async throws {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 0, y: 0), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces]
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = NSHostingView(rootView: content().frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(900))
        try "\(name)-\(Int(size.width))-\(dark ? "dark" : "light") \(window.windowNumber)"
            .write(toFile: output, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(1_800))
    }

    @Test func switchViews() async throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-switch-shots-\(UUID().uuidString)", isDirectory: true)
        let folder = raw.appendingPathComponent("my-project", isDirectory: true)
        let bin = raw.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: raw) }
        let script = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf 'Claude usage limit reached.\\n'\nIFS= read -r line\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: raw.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let workspace = try #require(model.workspaces.first)
        let context = SessionContext.workspace(workspace.id)
        model.selection = context
        await model.runtimes.bootstrap()
        model.runtimes.agentSearchPath = bin.path
        let work = ManagedAccountRecord(provider: .claude, label: "Work", email: "work@example.com",
                                        homePath: raw.appendingPathComponent("data/claude-profiles/work/home").path)
        let personal = ManagedAccountRecord(provider: .claude, label: "Personal", email: "me@example.com",
                                            homePath: raw.appendingPathComponent("data/claude-profiles/personal/home").path)
        await model.upsert(work)
        await model.upsert(personal)
        let now = Date()
        model.accountsController.setUsageForPreview(work.id, UsageSnapshot(
            fiveHour: UsageWindow(usedFraction: 1, resetsAt: now.addingTimeInterval(2 * 3600 + 1200)),
            sevenDay: UsageWindow(usedFraction: 0.62, resetsAt: now.addingTimeInterval(4 * 86_400)), fetchedAt: now))

        let running = try #require(await model.runtimes.start(in: context, agent: .claude, accountID: work.id, prompt: nil))
        model.runtimes.storeConversation("0f4c3a52-7d1e-4b8a-9c2d-5e6f7a8b9c0d", for: running)
        let ended = AgentSessionRecord(workspaceID: workspace.id, agent: .claude, accountID: work.id,
                                       title: "Claude · \(work.displayName)", cwd: folder.path, state: .exited, exitCode: 0,
                                       createdAt: now.addingTimeInterval(-1_520), endedAt: now.addingTimeInterval(-40),
                                       agentSessionID: "1a2b3c4d-7d1e-4b8a-9c2d-5e6f7a8b9c0d")
        await model.upsert(ended)
        try await Task.sleep(for: .milliseconds(500))

        for dark in [false, true] {
            for width in [560.0, 1200.0] {
                try await render("banner", size: CGSize(width: width, height: 360), dark: dark) {
                    SessionPaneContent(session: running, context: context, isFocused: false, closeTitle: "Close Tab").environment(model)
                }
                try await render("ended", size: CGSize(width: width, height: 640), dark: dark) {
                    SessionPaneContent(session: ended.id, context: context, isFocused: false, closeTitle: "Close Tab").environment(model)
                }
                model.runtimes.previewMovingConversation(ended.id, to: personal.displayName)
                try await render("moving", size: CGSize(width: width, height: 360), dark: dark) {
                    SessionPaneContent(session: ended.id, context: context, isFocused: false, closeTitle: "Close Tab").environment(model)
                }
                model.runtimes.previewMovingConversation(ended.id, to: nil)
            }
            model.selectedTab[context] = .session(running)
            let state = ProviderUsageState(snapshot: model.accountsController.usage[work.id], failure: nil,
                                           accountName: work.displayName, isManaged: true, managedID: work.id)
            try await render("popover", size: CGSize(width: 300, height: 420), dark: dark) {
                UsageDetailsPopover(provider: .claude, state: state,
                                    sections: ProviderUsagePolicy.sections(model.accountsController.usage[work.id], now: now),
                                    now: now).environment(model)
            }
        }
        for session in model.sessions { await model.closeSession(session.id) }
    }
}
