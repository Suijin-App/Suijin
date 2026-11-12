import Foundation
import SevindaAgents
import SevindaCore
import SevindaTerminal
import Testing
@testable import Sevinda

/// Sevinda's own stats as the session runtime records them: agent starts count, shells do not, and working time is
/// the sum of the agent's `running` intervals. Uses an in-memory store and never starts an agent CLI.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SevindaStatsTests {
    private func makeModel() throws -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sevinda-stats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (AppModel(store: try SevindaStore.inMemory(), dataRoot: root), root)
    }

    @Test func agentStartsCountButShellsDoNot() async throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.runtimes.countStart(of: .claude)
        await model.runtimes.countStart(of: .codex)
        await model.runtimes.countStart(of: .shell)
        let stats = try model.store.sevindaStats()
        #expect(stats.agentsSpawned == 2)
        #expect(stats.trackingSince != nil)
    }

    /// A real shell started through the runtime leaves the agent count alone.
    @Test func startingAShellSessionIsNotCounted() async throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await model.addWorkspace(at: folder)
        await model.runtimes.bootstrap()
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        let id = try #require(await model.runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil))
        await model.closeSession(id)
        #expect(try model.store.sevindaStats().agentsSpawned == 0)
    }

    @Test func workingIntervalsAddUp() async throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = SessionRuntime(id: UUID(), agent: .claude, terminal: TerminalSession(engine: SwiftTermEngine()))
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(model.runtimes.trackWork(runtime, .running, at: start) == nil)
        // Staying in `running` does not restart the interval.
        model.runtimes.trackWork(runtime, .running, at: start.addingTimeInterval(10))
        await model.runtimes.trackWork(runtime, .idle, at: start.addingTimeInterval(30))?.value
        // Leaving a state other than `running` adds nothing.
        #expect(model.runtimes.trackWork(runtime, .waitingForInput, at: start.addingTimeInterval(40)) == nil)
        model.runtimes.trackWork(runtime, .running, at: start.addingTimeInterval(100))
        await model.runtimes.trackWork(runtime, .exited(0), at: start.addingTimeInterval(112))?.value
        #expect(try model.store.sevindaStats().agentWorkSeconds == 42)

        let shell = SessionRuntime(id: UUID(), agent: .shell, terminal: TerminalSession(engine: SwiftTermEngine()))
        model.runtimes.trackWork(shell, .running, at: start)
        #expect(model.runtimes.trackWork(shell, .idle, at: start.addingTimeInterval(60)) == nil)
        #expect(try model.store.sevindaStats().agentWorkSeconds == 42)
    }
}
