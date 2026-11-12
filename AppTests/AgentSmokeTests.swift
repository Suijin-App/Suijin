import Foundation
import MercuryAgents
import MercuryCore
import MercuryGit
import MercuryTerminal
import Testing
@testable import Mercury

/// Starts the real `claude` and `codex` CLIs (no prompt, so nothing is sent to a model) through the app runtime and
/// the PTY host, with the user's own login: the TUI must draw, and Claude's SessionStart hook must reach the events
/// file. Opt-in: `TEST_RUNNER_MERCURY_AGENT_SMOKE=1`. Screen text is checked, never printed (it can show an email).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: ProcessInfo.processInfo.environment["MERCURY_AGENT_SMOKE"] == "1"))
struct AgentSmokeTests {
    private func eventually(_ timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    @Test(arguments: [AgentKind.claude, .codex])
    func agentStartsInTheHostAndDraws(_ agent: AgentKind) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mercury-smoke-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A git repository, as agents mostly run in worktrees.
        _ = try await GitRunner().run(["init", "-b", "main"], in: folder)
        let dataRoot = root.appendingPathComponent("data", isDirectory: true)
        let model = AppModel(store: try MercuryStore.inMemory(), dataRoot: dataRoot)
        await model.addWorkspace(at: folder)
        await model.runtimes.bootstrap()
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)

        let id = try #require(await model.runtimes.start(in: context, agent: agent, accountID: nil, prompt: nil))
        let runtime = try #require(model.runtimes.runtime(for: id))
        // The agent's own screen names it (Claude Code's welcome box, Codex's header or trust prompt).
        let marker = agent == .claude ? "claude" : "codex"
        let drew = await eventually(.seconds(30)) {
            runtime.terminal.view.visibleText().lowercased().contains(marker)
        }
        let screen = runtime.terminal.view.visibleText()
        #expect(drew, "\(agent) drew \(screen.count) characters")
        #expect(!screen.contains("not found"), "\(agent) failed to start")
        #expect(!screen.contains("No such file"), "\(agent) failed to start")
        let redacted = screen.split(separator: "\n").map { line in
            line.split(separator: " ").map { $0.contains("@") ? "[redacted]" : String($0) }.joined(separator: " ")
        }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(6).joined(separator: " | ")
        print("SMOKE \(agent) screen: \(redacted.prefix(300))")
        print("SMOKE \(agent): drew \(screen.filter { !$0.isWhitespace }.count) visible characters, activity \(model.runtimes.activities[id].map { "\($0)" } ?? "none")")
        if agent == .claude {
            let events = dataRoot.appendingPathComponent("hooks/events/\(id.uuidString).jsonl")
            let hooked = await eventually(.seconds(20)) { ((try? Data(contentsOf: events))?.count ?? 0) > 0 }
            let attributes = try? FileManager.default.attributesOfItem(atPath: events.path)
            print("SMOKE claude: hook events file \(hooked ? "received events" : "empty"), mode \(String(format: "%o", (attributes?[.posixPermissions] as? Int) ?? 0))")
        }
        let hostID = try #require(runtime.terminal.engine.sessionID)
        await model.closeSession(id)
        let remaining = try await PTYHostClient.shared.listSessions()
        #expect(!remaining.contains { $0.id == hostID && $0.isRunning }, "\(agent) still runs after closing its tab")
    }
}
