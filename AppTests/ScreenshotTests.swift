import AppKit
import Foundation
import SuijinAccounts
import SuijinCore
import SwiftUI
import Testing
@testable import Suijin

/// Offscreen renders of the main screens, light and dark, narrow and wide. Runs when `SUIJIN_SCREENSHOTS` names an
/// output folder (`TEST_RUNNER_SUIJIN_SCREENSHOTS=<dir> xcodebuild test`); the images are reviewed by eye.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SUIJIN_SCREENSHOTS"] != nil))
struct ScreenshotTests {
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SUIJIN_SCREENSHOTS"] ?? NSTemporaryDirectory())
    static let sizes: [(String, CGSize)] = [("narrow", CGSize(width: 1000, height: 640)), ("wide", CGSize(width: 1280, height: 760))]

    private func render<V: View>(_ name: String, size: CGSize, dark: Bool, @ViewBuilder _ content: () -> V) throws {
        let window = OffscreenWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: content())
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        host.layoutSubtreeIfNeeded()
        let bounds = host.bounds
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: bounds))
        host.cacheDisplay(in: bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }

    private func sampleModel(empty: Bool) async throws -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-shots-\(UUID().uuidString)")
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root)
        guard !empty else { return model }
        let repo = Workspace(name: "suijin-api", path: "/Users/demo/Code/suijin-api", kind: .git, sortOrder: 0)
        let folder = Workspace(name: "design-notes", path: "/Users/demo/Documents/design-notes", kind: .folder, sortOrder: 1)
        for workspace in [repo, folder] { try model.store.save(workspace) }
        let trees = [
            WorktreeRecord(workspaceID: repo.id, path: "/Users/demo/Code/suijin-api-worktrees/feature/usage-bar", branch: "feature/usage-bar", baseBranch: "main"),
            WorktreeRecord(workspaceID: repo.id, path: "/Users/demo/Code/suijin-api-worktrees/fix/login-timeout", branch: "fix/login-timeout", baseBranch: "main"),
        ]
        for tree in trees { try model.store.save(tree) }
        let sessions = [
            AgentSessionRecord(workspaceID: repo.id, worktreeID: trees[0].id, agent: .claude, title: "Claude · work@example.com", cwd: trees[0].path, state: .exited, exitCode: 0),
            AgentSessionRecord(workspaceID: repo.id, worktreeID: trees[1].id, agent: .codex, title: "Codex", cwd: trees[1].path, state: .failed, exitCode: 1),
            AgentSessionRecord(workspaceID: folder.id, agent: .claude, title: "Claude", cwd: folder.path, state: .exited, exitCode: 0),
        ]
        for session in sessions { try model.store.save(session) }
        for account in [
            ManagedAccountRecord(provider: .claude, label: "Claude", email: "work@example.com", organization: "Example Org", homePath: "/tmp/a"),
            ManagedAccountRecord(provider: .claude, label: "Claude", email: "personal@example.com", homePath: "/tmp/b"),
            ManagedAccountRecord(provider: .codex, label: "Codex", email: "dev@example.com", homePath: "/tmp/c"),
        ] { try model.store.save(account) }
        await model.load()
        model.selection = .worktree(trees[0].id)
        return model
    }

    @Test func mainWindow() async throws {
        for (label, size) in Self.sizes {
            for dark in [false, true] {
                let empty = try await sampleModel(empty: true)
                try render("main-empty-\(label)", size: size, dark: dark) { RootView().environment(empty) }
                let model = try await sampleModel(empty: false)
                try render("main-worktree-\(label)", size: size, dark: dark) { RootView().environment(model) }
                model.selection = .workspace(model.workspaces[1].id)
                try render("main-folder-\(label)", size: size, dark: dark) { RootView().environment(model) }
                model.selection = .workspace(model.workspaces[0].id)
                model.selectedTab[.workspace(model.workspaces[0].id)] = .changes
                try render("main-changes-\(label)", size: size, dark: dark) { RootView().environment(model) }
            }
        }
    }

    @Test func settingsAndSheets() async throws {
        let model = try await sampleModel(empty: false)
        let claude = try #require(model.accounts.first { $0.provider == .claude })
        model.setSetting(.defaultClaudeAccount, claude.id.uuidString)
        model.accountsController.setUsageForPreview(claude.id, UsageSnapshot(
            fiveHour: UsageWindow(usedFraction: 0.52, resetsAt: Date().addingTimeInterval(3 * 3600)),
            sevenDay: UsageWindow(usedFraction: 0.81, resetsAt: Date().addingTimeInterval(6 * 86400)), fetchedAt: Date()))
        for dark in [false, true] {
            try render("settings-accounts", size: CGSize(width: 600, height: 520), dark: dark) { AccountsSettingsView().environment(model) }
            try render("sheet-new-worktree", size: CGSize(width: 520, height: 560), dark: dark) {
                NewWorktreeSheet(workspace: model.workspaces[0]).environment(model)
            }
            try render("statusbar", size: CGSize(width: 900, height: 40), dark: dark) { StatusBarView().environment(model) }
            try render("design-gallery", size: CGSize(width: 860, height: 640), dark: dark) { DesignGalleryView() }
        }
    }

    /// The usage popover of the own login while the focused session runs on a managed account.
    @Test func usagePopoverNamesTheFocusedSessionsAccount() async throws {
        let model = try await sampleModel(empty: false)
        let now = Date()
        let snapshot = UsageSnapshot(fiveHour: UsageWindow(usedFraction: 0.18, resetsAt: now.addingTimeInterval(2 * 3600)),
                                     sevenDay: UsageWindow(usedFraction: 0.64, resetsAt: now.addingTimeInterval(4 * 86400)), fetchedAt: now)
        let state = ProviderUsageState(snapshot: snapshot, failure: nil, accountName: "own-login@example.com", isManaged: false)
        let session = SessionAccount(provider: .claude, managedID: UUID(), name: "work@example.com", signedInNow: nil, startedAs: nil)
        let note = UsageDescription.sessionNote(session, state: state, usage: snapshot, now: now)
        for dark in [false, true] {
            try render("usage-popover-session", size: CGSize(width: 280, height: 330), dark: dark) {
                UsageDetailsPopover(provider: .claude, state: state, sections: ProviderUsagePolicy.sections(snapshot, now: now),
                                    sessionNote: note, now: now)
                    .environment(model)
            }
        }
    }

    @Test func shortcutsSettings() async throws {
        let model = try await sampleModel(empty: true)
        let sizes = [("narrow", CGSize(width: 1000, height: 640)), ("wide", CGSize(width: 1400, height: 880))]
        for (label, size) in sizes {
            for dark in [false, true] {
                try render("settings-shortcuts-\(label)", size: size, dark: dark) {
                    SettingsOverlay(page: .shortcuts).environment(model)
                }
                for (state, query) in [("search", "split"), ("empty", "qqqq")] {
                    try render("settings-shortcuts-\(state)-\(label)", size: size, dark: dark) {
                        ShortcutsSettings(initialQuery: query)
                            .scrollContentBackground(.hidden)
                            .frame(maxWidth: 760)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.top, 70)
                            .background { OverlayBackdrop() }
                    }
                }
            }
        }
    }
}
