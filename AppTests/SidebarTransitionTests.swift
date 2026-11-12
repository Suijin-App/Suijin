import AppKit
import SevindaCore
import SevindaGit
import SwiftUI
import Testing
@testable import Sevinda

/// Renders the real window through the sidebar's tricky transitions (a session opening and closing, switching to
/// another worktree, removing a workspace) for review: opt-in with `TEST_RUNNER_SEVINDA_SIDEBAR_SHOT=<file>`. At each
/// step the file receives `<step> <window number>` and the window stays up for four seconds while the caller captures
/// it with `screencapture -l` (the test host may not record the screen itself).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SEVINDA_SIDEBAR_SHOT"] != nil))
struct SidebarTransitionTests {
    @Test func sidebarStaysCleanThroughTransitions() async throws {
        let output = try #require(ProcessInfo.processInfo.environment["SEVINDA_SIDEBAR_SHOT"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sevinda-sidebar-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("api", isDirectory: true)
        let folder = root.appendingPathComponent("Projects", isDirectory: true)
        for dir in [repo, folder] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        let git = GitRunner(), identity = ["-c", "user.name=T", "-c", "user.email=t@example.invalid"]
        _ = try await git.run(["init", "-b", "main"], in: repo)
        try "x\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "."], in: repo)
        _ = try await git.run(identity + ["commit", "-m", "i"], in: repo)

        let model = AppModel(store: try SevindaStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: repo)
        await model.addWorkspace(at: folder)
        let gitID = try #require(model.workspaces.first).id
        let trees = [
            try await model.createWorktree(workspaceID: gitID, branch: "sync-1", base: "main", path: root.appendingPathComponent("wt/sync-1")),
            try await model.createWorktree(workspaceID: gitID, branch: "sync-2", base: "main", path: root.appendingPathComponent("wt/sync-2")),
        ]
        await model.runtimes.bootstrap()

        let window = NSWindow(contentRect: CGRect(x: 120, y: 120, width: 900, height: 560), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: RootView().environment(model))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        func publish(_ step: String) async throws {
            try await Task.sleep(for: .milliseconds(800))
            try "\(step) \(window.windowNumber)".write(toFile: output, atomically: true, encoding: .utf8)
            try await Task.sleep(for: .seconds(4))
        }

        let main = SessionContext.workspace(gitID)
        let id = try #require(await model.runtimes.start(in: main, agent: .shell, accountID: nil, prompt: nil))
        try await publish("1-session-open")
        model.selection = .worktree(trees[0].id)
        try await publish("2-other-worktree")
        await model.closeSession(id)
        try await publish("3-session-closed")
        model.selection = main
        await model.removeWorkspace(gitID)
        try await publish("4-workspace-removed")
        #expect(model.selection == .workspace(try #require(model.workspaces.first).id))
    }
}
