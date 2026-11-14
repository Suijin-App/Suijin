import Foundation
import SuijinCore
import SuijinPTYProtocol
import Testing
@testable import Suijin

/// Which workers the sidebar and the inspector list under their coordinator, and which tabs close by themselves after
/// the coordinator stopped a worker. No process is started: the sessions are records only.
@MainActor
@Suite(.serialized)
struct WorkerSidebarTests {
    private let coordinator = UUID()
    private let now = Date()

    private func dispatch(_ id: String, worker: UUID?, status: DispatchStatus, stopped: Bool = false,
                          age: TimeInterval = 0) -> OrchestrationDispatch {
        OrchestrationDispatch(id: id, taskID: "t-\(id)", runID: "r-1", coordinatorSessionID: coordinator.uuidString,
                              workerSessionID: worker?.uuidString, name: id, agent: .codex, worktree: .current,
                              status: status, stoppedAt: stopped ? now : nil,
                              createdAt: now.addingTimeInterval(age), updatedAt: now)
    }

    @Test func settledWorkersWithoutASessionAreNotListed() {
        let open = UUID(), closedAfterDone = UUID(), closedWhileRunning = UUID(), closedAfterExit = UUID()
        let dispatches = [
            dispatch("open-done", worker: open, status: .succeeded, age: 0),
            dispatch("closed-done", worker: closedAfterDone, status: .succeeded, age: 1),
            dispatch("closed-failed", worker: UUID(), status: .failed, age: 2),
            dispatch("closed-exited", worker: closedAfterExit, status: .exited, age: 3),
            dispatch("never-started", worker: nil, status: .startFailed, age: 4),
            dispatch("queued", worker: nil, status: .queued, age: 5),
            dispatch("starting", worker: nil, status: .starting, age: 6),
            dispatch("still-running", worker: closedWhileRunning, status: .running, age: 7),
        ]
        let listed = OrchestrationController.visibleWorkers(in: dispatches, coordinator: coordinator, liveSessions: [open])
        #expect(listed.map(\.id) == ["open-done", "queued", "starting", "still-running"])
    }

    @Test func aWorkerIsListedOnceByItsNewestDispatch() {
        let worker = UUID()
        let dispatches = [
            dispatch("first", worker: worker, status: .succeeded, age: 0),
            dispatch("follow-up", worker: worker, status: .running, age: 1),
        ]
        let listed = OrchestrationController.visibleWorkers(in: dispatches, coordinator: coordinator, liveSessions: [worker])
        #expect(listed.map(\.id) == ["follow-up"])
        #expect(OrchestrationController.visibleWorkers(in: dispatches, coordinator: UUID(), liveSessions: [worker]).isEmpty)
    }

    /// The tree and the inspector both read `workers(of:)`, which uses the app's sessions; a stopped worker's tab
    /// closes by itself and its row goes, while a worker that reported on its own keeps both.
    @Test func stoppedWorkersCloseTheirTabAndLeaveTheList() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-workers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root)
        let workspace = Workspace(name: "demo", path: root.path, kind: .folder, sortOrder: 0)
        try model.store.save(workspace)
        let lead = AgentSessionRecord(id: coordinator, workspaceID: workspace.id, agent: .claude, title: "Claude", cwd: root.path, state: .running)
        let stopped = AgentSessionRecord(workspaceID: workspace.id, agent: .codex, title: "Codex · stopped", cwd: root.path, state: .running)
        let finished = AgentSessionRecord(workspaceID: workspace.id, agent: .codex, title: "Codex · finished", cwd: root.path, state: .running)
        for session in [lead, stopped, finished] { try model.store.save(session) }
        await model.load()

        let orchestration = model.runtimes.orchestration
        orchestration.setSnapshotForPreview(OrchestrationSnapshot(dispatches: [
            dispatch("stopped", worker: stopped.id, status: .exited, stopped: true, age: 0),
            dispatch("finished", worker: finished.id, status: .succeeded, age: 1),
        ]))
        #expect(orchestration.workers(of: coordinator).map(\.id) == ["stopped", "finished"])

        await orchestration.closeStoppedWorkers()
        #expect(!model.sessions.contains { $0.id == stopped.id }, "the stopped worker's tab closed")
        #expect(model.sessions.contains { $0.id == finished.id }, "a worker that finished on its own keeps its tab")
        #expect(orchestration.workers(of: coordinator).map(\.id) == ["finished"])

        // The user closes the finished worker's tab by hand: its row goes too.
        await model.closeSession(finished.id)
        #expect(orchestration.workers(of: coordinator).isEmpty)
    }
}
