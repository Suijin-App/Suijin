import AppKit
import Foundation
import SevindaAccounts
import SevindaCore
import SwiftUI
import Testing
@testable import Sevinda

/// Renders automatic account switching for review: Settings → Accounts with both switches on and a fallback order, and
/// the note a session's pane shows after it moved, narrow and wide, light and dark. Opt-in with
/// `TEST_RUNNER_SEVINDA_AUTOSWITCH_SHOT=<file>`: at each step the file receives `<name> <window number>` and the caller
/// captures that window with `screencapture -l`. The borderless window sits at the desktop's level, behind every app
/// window and the desktop icons, ignores the mouse and is ordered in without activating the app, so nothing comes to
/// the front or takes focus. A stand-in `claude` script runs instead of the real one.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: ProcessInfo.processInfo.environment["SEVINDA_AUTOSWITCH_SHOT"] != nil))
struct AutoAccountSwitchScreenshotTests {
    let output = ProcessInfo.processInfo.environment["SEVINDA_AUTOSWITCH_SHOT"] ?? ""

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

    @Test func autoSwitchViews() async throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("sevinda-autoswitch-shots-\(UUID().uuidString)", isDirectory: true)
        let folder = raw.appendingPathComponent("my-project", isDirectory: true)
        let bin = raw.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: raw) }
        let script = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf 'Resumed conversation.\\n'\nIFS= read -r line\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let model = AppModel(store: try SevindaStore.inMemory(), dataRoot: raw.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        model.selection = context
        await model.runtimes.bootstrap()
        model.runtimes.agentSearchPath = bin.path
        let work = ManagedAccountRecord(provider: .claude, label: "Work", email: "work@example.com",
                                        homePath: raw.appendingPathComponent("data/claude-profiles/work/home").path)
        let personal = ManagedAccountRecord(provider: .claude, label: "Personal", email: "a-much-longer-address-for-truncation@example.com",
                                            homePath: raw.appendingPathComponent("data/claude-profiles/personal/home").path)
        await model.upsert(work)
        await model.upsert(personal)
        let now = Date()
        model.accountsController.setUsageForPreview(work.id, UsageSnapshot(
            fiveHour: UsageWindow(usedFraction: 1, resetsAt: now.addingTimeInterval(2 * 3600)),
            sevenDay: UsageWindow(usedFraction: 0.62, resetsAt: now.addingTimeInterval(4 * 86_400)), fetchedAt: now))
        model.accountsController.setUsageForPreview(personal.id, UsageSnapshot(
            fiveHour: UsageWindow(usedFraction: 0.18, resetsAt: now.addingTimeInterval(4 * 3600)),
            sevenDay: UsageWindow(usedFraction: 0.4, resetsAt: now.addingTimeInterval(3 * 86_400)), fetchedAt: now))
        model.setSetting(.defaultClaudeAccount, personal.id.uuidString)
        model.setMovesOnDefaultChange(.claude, true)
        model.setSetting(.claudeSwitchAtLimit, "true")
        model.setFallbackOrder([.managed(personal.id), .ownLogin, .managed(work.id)], for: .claude)

        let running = try #require(await model.runtimes.start(in: context, agent: .claude, accountID: personal.id, prompt: nil))
        model.autoSwitcher.movedNoteDuration = .seconds(600)
        model.autoSwitcher.showForPreview(AutoSwitchNote(
            kind: .moved, text: "Moved to \(personal.displayName) because \(work.displayName) hit its 5-hour limit."), for: running)
        try await Task.sleep(for: .milliseconds(500))

        for dark in [false, true] {
            for width in [520.0, 900.0] {
                try await render("settings", size: CGSize(width: width, height: 1_000), dark: dark) {
                    AccountsSettingsView().environment(model)
                }
                try await render("note", size: CGSize(width: width, height: 260), dark: dark) {
                    SessionPaneContent(session: running, context: context, isFocused: false, closeTitle: "Close Tab").environment(model)
                }
            }
        }
        for session in model.sessions { await model.closeSession(session.id) }
    }
}
