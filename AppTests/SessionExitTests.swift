import AppKit
import Foundation
import SevindaAgents
import SevindaCore
import SevindaTerminal
import SwiftUI
import Testing
@testable import Sevinda

/// An agent that exits on its own (Ctrl-C twice in Claude Code or Codex) must leave its pane for the Session Ended
/// view: the dead terminal stays on screen otherwise, and nothing can be done in it. A small script stands in for the
/// agent: it prints the same exit hint as Claude Code and exits on the second SIGINT.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SessionExitTests {
    static let resumeID = "0f4c3a52-7d1e-4b8a-9c2d-5e6f7a8b9c0d"
    static let codexID = "019a5f3e-8c2b-7d41-a9e0-3b6c1d2e4f50"
    static let hookID = "6b1d2c3e-4f5a-4b6c-8d7e-9f0a1b2c3d4e"

    struct Fixture {
        let model: AppModel
        let context: SessionContext
        let window: NSWindow
        let root: URL
        let folder: URL
        let script: URL

        @MainActor
        func tearDown() async {
            window.orderOut(nil)
            for session in model.sessions { await model.closeSession(session.id) }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func eventually(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return condition()
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sevinda-exit-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("fake-agent.sh")
        // The first SIGINT warns, the second prints the resume hint and exits 0, as Claude Code does.
        try """
        #!/bin/sh
        if [ "$1" = fail ]; then printf 'fatal: could not reach the account\n'; exit 3; fi
        armed=""
        if [ "$1" = codex ]; then hint="To continue this session, run codex resume \(Self.codexID)"; else hint="Resume this session with:\\nclaude --resume \(Self.resumeID)"; fi
        trap 'if [ -n "$armed" ]; then printf "\\n$hint\\n"; exit 0; fi; armed=1; printf "\\nPress Ctrl-C again to exit\\n"' INT
        printf 'FAKE AGENT READY\\n'
        while :; do sleep 0.1; done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let model = AppModel(store: try SevindaStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        model.selection = context
        await model.runtimes.bootstrap()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1000, height: 600), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SessionTabsView(context: context).environment(model))
        window.orderFrontRegardless()
        return Fixture(model: model, context: context, window: window, root: root, folder: folder, script: script)
    }

    /// Replaces the session's shell with the fake agent and exits it with Ctrl-C twice.
    private func runFakeAgentAndExit(_ terminal: TerminalSession, script: URL) async {
        terminal.send("exec '\(script.path)'\n")
        #expect(await eventually { terminal.view.visibleText().contains("FAKE AGENT READY") })
        terminal.send([0x03])
        #expect(await eventually { terminal.view.visibleText().contains("Press Ctrl-C again to exit") })
        terminal.send([0x03])
    }

    /// Runs the fake agent directly as a session of `agent` (a stand-in for the real CLI) and exits it with Ctrl-C twice.
    private func runAgentAndExit(_ agent: AgentKind, in fixture: Fixture, hookEvent: String? = nil) async throws -> UUID {
        let model = fixture.model
        let workspace = try #require(model.workspaces.first)
        let record = AgentSessionRecord(workspaceID: workspace.id, agent: agent, title: "Agent", cwd: fixture.folder.path)
        let events = model.dataRoot.appendingPathComponent("hooks/events/\(record.id.uuidString).jsonl")
        try FileManager.default.createDirectory(at: events.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (hookEvent.map { $0 + "\n" } ?? "").write(to: events, atomically: true, encoding: .utf8)
        let launch = ShellLaunch.command(fixture.script.path, [agent.rawValue], cwd: fixture.folder, environment: [:], interactive: false)
        try await model.runtimes.run(record, launch: launch)
        model.selectedTab[fixture.context] = .session(record.id)
        let terminal = try #require(model.runtimes.runtime(for: record.id)).terminal
        #expect(await eventually { terminal.view.visibleText().contains("FAKE AGENT READY") })
        if let hookEvent, hookEvent.contains(Self.hookID) {
            // Claude's id is stored while it runs, before any exit.
            #expect(await eventually { model.sessions.first { $0.id == record.id }?.agentSessionID == Self.hookID })
        }
        terminal.send([0x03])
        #expect(await eventually { terminal.view.visibleText().contains("Press Ctrl-C again to exit") })
        terminal.send([0x03])
        #expect(await eventually { model.runtimes.runtime(for: record.id) == nil })
        return record.id
    }

    @Test func claudeResumesWithTheIDItsHooksReported() async throws {
        let fixture = try await makeFixture()
        let hook = #"{"hook_event_name":"SessionStart","session_id":"\#(Self.hookID)","source":"startup"}"#
        let id = try await runAgentAndExit(.claude, in: fixture, hookEvent: hook)
        let record = try #require(fixture.model.sessions.first { $0.id == id })
        // The hook's id wins over the printed hint.
        #expect(record.agentSessionID == Self.hookID)
        #expect(fixture.model.canResume(record))
        await fixture.tearDown()
    }

    @Test func claudeWithoutHooksResumesWithThePrintedID() async throws {
        let fixture = try await makeFixture()
        let id = try await runAgentAndExit(.claude, in: fixture)
        #expect(fixture.model.sessions.first { $0.id == id }?.agentSessionID == Self.resumeID)
        await fixture.tearDown()
    }

    @Test func codexResumesWithThePrintedID() async throws {
        let fixture = try await makeFixture()
        let id = try await runAgentAndExit(.codex, in: fixture)
        let record = try #require(fixture.model.sessions.first { $0.id == id })
        #expect(record.agentSessionID == Self.codexID)
        #expect(fixture.model.canResume(record))
        await fixture.tearDown()
    }

    @Test func aShellOrAnUnknownConversationCannotBeResumed() async throws {
        let fixture = try await makeFixture()
        let id = try #require(await fixture.model.runtimes.start(in: fixture.context, agent: .shell, accountID: nil, prompt: nil))
        let terminal = try #require(fixture.model.runtimes.runtime(for: id)).terminal
        await runFakeAgentAndExit(terminal, script: fixture.script)
        #expect(await eventually { fixture.model.runtimes.runtime(for: id) == nil })
        let shell = try #require(fixture.model.sessions.first)
        // The hint on a shell's screen is not the shell's conversation.
        #expect(shell.agentSessionID == nil && !fixture.model.canResume(shell))
        var agent = shell
        agent.agent = .claude
        #expect(!fixture.model.canResume(agent))
        await fixture.tearDown()
    }

    /// The resume command is built from the real CLIs when they are installed (nothing is started): Codex's own
    /// options stay before its `resume` subcommand, Claude's `--resume` follows the hook settings.
    @Test(arguments: [AgentKind.claude, .codex])
    func resumeLaunchesReopenTheConversation(_ agent: AgentKind) async throws {
        let fixture = try await makeFixture()
        guard AgentCatalog.resolveBinary(agent, path: await AgentCatalog.loginShellPATH()) != nil else {
            await fixture.tearDown()
            return
        }
        let workspace = try #require(fixture.model.workspaces.first)
        let record = AgentSessionRecord(workspaceID: workspace.id, agent: agent, title: "Agent", cwd: fixture.folder.path)
        let id = agent == .claude ? Self.resumeID : Self.codexID
        let launch = try await fixture.model.runtimes.makeLaunch(record: record, cwd: fixture.folder, accountID: nil,
                                                                 prompt: nil, resume: id)
        let arguments = launch.arguments
        let binary = try #require(arguments.lastIndex { $0.hasSuffix("/\(agent.rawValue)") })
        let after = Array(arguments[(binary + 1)...])
        if agent == .claude {
            #expect(Array(after.suffix(2)) == ["--resume", id])
            #expect(after.firstIndex(of: "--settings").map { $0 < after.count - 2 } == true)
        } else {
            #expect(Array(after.suffix(2)) == ["resume", id])
            #expect(!after.dropLast(2).contains("resume"))
        }
        await fixture.tearDown()
    }

    @Test func aRelaunchedSessionComesBackInItsOwnPane() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let primary = try #require(await model.runtimes.start(in: fixture.context, agent: .shell, accountID: nil, prompt: nil))
        _ = await model.addPane(in: fixture.context, axis: .sideBySide, agent: .shell)
        #expect(await eventually { model.sessions.count == 2 })
        let secondary = try #require(model.sessions.first { $0.id != primary }?.id)
        let tab = try #require(model.currentTab(in: fixture.context))
        let panes = model.panes(of: tab)
        let ended = try #require(model.runtimes.runtime(for: secondary)).terminal
        await runFakeAgentAndExit(ended, script: fixture.script)
        #expect(await eventually { model.runtimes.runtime(for: secondary) == nil })
        let record = try #require(model.sessions.first { $0.id == secondary })

        let launch = ShellLaunch.command(fixture.script.path, ["claude"], cwd: fixture.folder, environment: [:], interactive: false)
        try await model.runtimes.relaunch(record, launch: launch)

        // Same session, same pane, same tab: running again with the previous exit cleared.
        let terminal = try #require(model.runtimes.runtime(for: secondary)).terminal
        #expect(await eventually { terminal.view.window === fixture.window })
        #expect(model.currentTab(in: fixture.context) == tab && model.panes(of: tab) == panes)
        let again = try #require(model.sessions.first { $0.id == secondary })
        #expect(again.state == .running && again.exitCode == nil && again.endedAt == nil)
        #expect(model.runtimes.liveCount == 2)
        await fixture.tearDown()
    }

    @Test func anAgentThatExitsLeavesItsTabForTheEndedView() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let id = try #require(await model.runtimes.start(in: fixture.context, agent: .shell, accountID: nil, prompt: nil))
        let terminal = try #require(model.runtimes.runtime(for: id)).terminal
        #expect(await eventually { terminal.view.window === fixture.window })
        #expect(model.runtimes.liveCount == 1)

        await runFakeAgentAndExit(terminal, script: fixture.script)

        #expect(await eventually { terminal.hasExited })
        // The ended view replaces the terminal, and everything that counts sessions agrees it ended.
        #expect(await eventually { terminal.view.window == nil }, "the dead terminal is still on screen")
        #expect(model.runtimes.runtime(for: id) == nil)
        #expect(model.runtimes.liveCount == 0)
        #expect(model.runtimes.activity(of: try #require(model.sessions.first)) == .exited)
        #expect(model.sessions.first?.state == .exited)
        // Typing into the ended session reaches no process.
        terminal.send("echo still-here\n")
        #expect(!terminal.isRunning)
        await fixture.tearDown()
    }

    @Test func aFailedSessionKeepsItsLastOutputForTheEndedView() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let id = try #require(await model.runtimes.start(in: fixture.context, agent: .shell, accountID: nil, prompt: nil))
        let terminal = try #require(model.runtimes.runtime(for: id)).terminal
        #expect(await eventually { terminal.view.window === fixture.window })
        terminal.send("exec '\(fixture.script.path)' fail\n")

        #expect(await eventually { model.runtimes.runtime(for: id) == nil })
        let record = try #require(model.sessions.first)
        #expect(record.state == .failed && record.exitCode == 3)
        #expect(model.runtimes.endedOutput[id]?.contains("fatal: could not reach the account") == true)
        // Closing forgets it.
        await model.closeSession(id)
        #expect(model.runtimes.endedOutput[id] == nil)
        await fixture.tearDown()
    }

    @Test func anAgentThatExitsInASplitPaneLeavesOnlyThatPane() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let primary = try #require(await model.runtimes.start(in: fixture.context, agent: .shell, accountID: nil, prompt: nil))
        _ = await model.addPane(in: fixture.context, axis: .sideBySide, agent: .shell)
        #expect(await eventually { model.sessions.count == 2 })
        let secondary = try #require(model.sessions.first { $0.id != primary }?.id)
        let primaryTerminal = try #require(model.runtimes.runtime(for: primary)).terminal
        let secondaryTerminal = try #require(model.runtimes.runtime(for: secondary)).terminal
        #expect(await eventually { secondaryTerminal.view.window === fixture.window && primaryTerminal.view.window === fixture.window })

        await runFakeAgentAndExit(secondaryTerminal, script: fixture.script)

        #expect(await eventually { secondaryTerminal.view.window == nil }, "the dead pane still shows its terminal")
        // The other pane keeps its live terminal, and the split keeps both places.
        #expect(primaryTerminal.view.window === fixture.window)
        #expect(model.runtimes.liveCount == 1)
        #expect(model.panes(of: try #require(model.currentTab(in: fixture.context))).count == 2)
        await fixture.tearDown()
    }
}
