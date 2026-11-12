import AppKit
import Foundation
import SevindaCore
import SevindaPTYProtocol
import SwiftUI
import Testing
@testable import Sevinda

/// Offscreen renders of the worker tree (sidebar), the orchestration inspector and its settings section, light and
/// dark, narrow and wide. Runs when `SEVINDA_SCREENSHOTS` names an output folder; the images are reviewed by eye.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SEVINDA_SCREENSHOTS"] != nil))
struct OrchestrationScreenshotTests {
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SEVINDA_SCREENSHOTS"] ?? NSTemporaryDirectory())

    private func render<V: View>(_ name: String, size: CGSize, dark: Bool, @ViewBuilder _ content: () -> V) throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: content())
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("orchestration-\(name)-\(dark ? "dark" : "light").png"))
    }

    @Test func workerTreeInspectorAndSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sevinda-orch-shots-\(UUID().uuidString)")
        let model = AppModel(store: try SevindaStore.inMemory(), dataRoot: root)
        let repo = Workspace(name: "sevinda-api", path: "/Users/demo/Code/sevinda-api", kind: .git, sortOrder: 0)
        try model.store.save(repo)
        let tree = WorktreeRecord(workspaceID: repo.id, path: "/Users/demo/Code/sevinda-api-worktrees/fix-login", branch: "fix-login", baseBranch: "main")
        try model.store.save(tree)
        let coordinator = AgentSessionRecord(workspaceID: repo.id, agent: .claude, title: "Claude", cwd: repo.path, state: .running)
        let worker = AgentSessionRecord(workspaceID: repo.id, worktreeID: tree.id, agent: .codex, title: "Codex · fix-login", cwd: tree.path, state: .running)
        let reviewer = AgentSessionRecord(workspaceID: repo.id, agent: .claude, title: "Claude · write-a-very-long-worker-name-for-docs", cwd: repo.path, state: .running)
        for session in [coordinator, worker, reviewer] { try model.store.save(session) }
        await model.load()
        model.selection = .workspace(repo.id)
        model.selectedTab[.workspace(repo.id)] = .session(coordinator.id)

        let now = Date()
        let run = OrchestrationRun(id: "r-1", coordinatorSessionID: coordinator.id.uuidString, createdAt: now)
        let tasks = [
            OrchestrationTask(id: "t-1", runID: run.id, spec: "Fix the login timeout in AuthService and add a regression test. Do not touch the UI.", createdAt: now),
            OrchestrationTask(id: "t-2", runID: run.id, spec: "Review the README and propose a clearer install section.", createdAt: now),
            OrchestrationTask(id: "t-3", runID: run.id, spec: "Run the migration dry run.", createdAt: now),
        ]
        let dispatches = [
            OrchestrationDispatch(id: "d-1a2b3c4d", taskID: "t-1", runID: run.id, coordinatorSessionID: coordinator.id.uuidString,
                                  workerSessionID: worker.id.uuidString, name: "fix-login", agent: .codex, worktree: .new,
                                  status: .asking, createdAt: now, updatedAt: now),
            OrchestrationDispatch(id: "d-5e6f7a8b", taskID: "t-2", runID: run.id, coordinatorSessionID: coordinator.id.uuidString,
                                  workerSessionID: reviewer.id.uuidString, name: "write-a-very-long-worker-name-for-docs", agent: .claude,
                                  worktree: .current, status: .succeeded, summary: "Rewrote the install section; links checked; nothing left.",
                                  createdAt: now.addingTimeInterval(1), updatedAt: now),
            OrchestrationDispatch(id: "d-9c0d1e2f", taskID: "t-3", runID: run.id, coordinatorSessionID: coordinator.id.uuidString,
                                  name: "migration-dry-run", agent: .codex, worktree: .new, status: .startFailed,
                                  lastError: "“sevinda-api” has uncommitted changes in the way.", createdAt: now.addingTimeInterval(2), updatedAt: now),
        ]
        let messages = [
            OrchestrationMessage(id: "m-11111111", runID: run.id, dispatchID: "d-1a2b3c4d", kind: .question, fromSessionID: worker.id.uuidString,
                                 toSessionID: coordinator.id.uuidString, body: "Should the timeout be 30 or 60 seconds?", status: .delivered, createdAt: now),
            OrchestrationMessage(id: "m-22222222", runID: run.id, dispatchID: "d-5e6f7a8b", kind: .done, fromSessionID: reviewer.id.uuidString,
                                 toSessionID: coordinator.id.uuidString, body: "Rewrote the install section; links checked; nothing left.",
                                 status: .pending, createdAt: now),
        ]
        model.runtimes.orchestration.setSnapshotForPreview(OrchestrationSnapshot(runs: [run], tasks: tasks, dispatches: dispatches, messages: messages))

        for dark in [false, true] {
            for (label, width) in [("narrow", 240.0), ("wide", 380.0)] {
                try render("sidebar-\(label)", size: CGSize(width: width, height: 360), dark: dark) {
                    SidebarView().environment(model)
                }
                try render("inspector-\(label)", size: CGSize(width: width + 60, height: 900), dark: dark) {
                    WorktreeInspector(context: .workspace(repo.id)).environment(model)
                }
            }
            try render("settings", size: CGSize(width: 600, height: 260), dark: dark) {
                Form { OrchestrationSettingsSection() }.formStyle(.grouped).environment(model)
            }
        }
        model.selectedTab[.worktree(tree.id)] = .session(worker.id)
        try render("worker-inspector", size: CGSize(width: 320, height: 640), dark: false) {
            WorktreeInspector(context: .worktree(tree.id)).environment(model)
        }
    }
}
