import AppKit
import Foundation
import SuijinAgents
import SuijinCore
import SuijinTerminal
import SwiftUI
import Testing
@testable import Suijin

/// `claude` or `codex` typed in a shell session makes the session look and behave like that agent while it runs
/// (logo, title, status, notifications, stats, resume id) and a shell again once it is done. Fake `claude` and `codex`
/// scripts first on PATH stand in for the real CLIs, which never run here.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ShellAgentSessionTests {
    static let hookID = "3a1b2c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    static let codexID = "019a5f3e-8c2b-7d41-a9e0-3b6c1d2e4f51"

    // MARK: Stack

    @Test func stackFollowsStartsAndEnds() {
        var stack = ShellAgentStack()
        #expect(stack.current == nil)
        let unknown = stack.apply(.started(agent: "vim"))
        #expect(!unknown, "only agents Suijin knows count")
        let orphanEnd = stack.apply(.ended(agent: "claude", status: 0))
        #expect(!orphanEnd, "an end without its start changes nothing")
        let claude = stack.apply(.started(agent: "claude"))
        #expect(claude && stack.current == .claude)
        let codex = stack.apply(.started(agent: "codex"))
        #expect(codex && stack.current == .codex)
        // Codex started inside Claude cannot outlive it.
        let end = stack.apply(.ended(agent: "claude", status: 130))
        #expect(end && stack.current == nil && stack.agents.isEmpty)

        for _ in 0..<20 { stack.apply(.started(agent: "claude")) }
        #expect(stack.agents.count == ShellAgentStack.maximumDepth)
    }

    // MARK: Sessions

    struct Fixture {
        let model: AppModel
        let context: SessionContext
        let window: NSWindow
        let root: URL
        let bin: URL

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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-shell-agent-\(UUID().uuidString)",
                                                                                 isDirectory: true)
        let folder = root.appendingPathComponent("work", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // Reads commands from the terminal: `ask` and `stop` append Claude's hook events, `quit N` exits with N.
        // Ctrl-C prints the agent's resume hint and exits 130.
        try writeExecutable(bin.appendingPathComponent("claude"), """
            #!/bin/sh
            printf '%s' "$*" > "${0%/*}/claude-args"
            trap 'printf "\\nResume this session with:\\nclaude --resume 00000000-0000-4000-8000-000000000000\\n"; exit 130' INT
            printf '{"hook_event_name":"SessionStart","session_id":"\(Self.hookID)"}\\n' >> "$SUIJIN_HOOK_EVENTS"
            printf 'FAKE READY\\n'
            while IFS= read -r line; do
              case "$line" in
                ask) printf '{"hook_event_name":"Notification","notification_type":"permission_prompt"}\\n' >> "$SUIJIN_HOOK_EVENTS"; echo ASKED ;;
                stop) printf '{"hook_event_name":"Stop"}\\n' >> "$SUIJIN_HOOK_EVENTS"; echo STOPPED ;;
                quit*) exit "${line#quit }" ;;
              esac
            done
            """)
        try writeExecutable(bin.appendingPathComponent("codex"), """
            #!/bin/sh
            trap 'printf "\\nTo continue this session, run codex resume \(Self.codexID)\\n"; exit 130' INT
            printf 'FAKE READY\\n'
            while :; do sleep 0.1; done
            """)
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        model.selection = context
        await model.runtimes.bootstrap()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1000, height: 600), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SessionTabsView(context: context).environment(model))
        window.orderFrontRegardless()
        return Fixture(model: model, context: context, window: window, root: root, bin: bin)
    }

    private func writeExecutable(_ url: URL, _ text: String) throws {
        try Data((text + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// A shell session with the fake agents first on PATH. The command runs only when Suijin's function wraps the
    /// agent, and `\` skips any alias of the user's, so nothing but the fake can start.
    private func startShell(in fixture: Fixture) async throws -> (UUID, TerminalSession) {
        let model = fixture.model
        let id = try #require(await model.runtimes.start(in: fixture.context, agent: .shell, accountID: nil, prompt: nil))
        let terminal = try #require(model.runtimes.runtime(for: id)).terminal
        terminal.send("export PATH='\(fixture.bin.path)':\"$PATH\"; echo PATH-SET\n")
        #expect(await eventually(.seconds(20)) { terminal.view.visibleText().contains("PATH-SET") })
        return (id, terminal)
    }

    /// Types `command` (`claude …` or `codex …`) so that it runs only through Suijin's function, never an alias or a
    /// function of the user's.
    private func run(_ command: String, in terminal: TerminalSession) {
        let agent = command.split(separator: " ").first.map(String.init) ?? command
        terminal.send("typeset -f __suijin_\(agent)_run >/dev/null && \\\(command)\n")
    }

    private func record(_ id: UUID, in model: AppModel) throws -> AgentSessionRecord {
        try #require(model.sessions.first { $0.id == id })
    }

    @Test func claudeInAShellShowsAsClaudeUntilItExits() async throws {
        UserNotifier.shared.clearWithheld()
        let fixture = try await makeFixture()
        let model = fixture.model
        let runtimes = model.runtimes
        let (id, terminal) = try await startShell(in: fixture)
        #expect(runtimes.displayAgent(of: try record(id, in: model)) == .shell)
        #expect(runtimes.displayTitle(of: try record(id, in: model)) != "Claude")
        #expect(try model.store.suijinStats().agentsSpawned == 0)

        run("claude hi", in: terminal)
        #expect(await eventually { terminal.view.visibleText().contains("FAKE READY") })
        #expect(await eventually { (try? runtimes.displayAgent(of: record(id, in: model))) == .claude })
        let running = try record(id, in: model)
        #expect(running.agent == .shell, "the record stays a shell, so Start Again opens a shell")
        #expect(runtimes.displayTitle(of: running) == "Claude")
        #expect(terminal.view.pasteGuardPolicy == .unlessBracketedPaste)
        // Started through Suijin's function: with the session's hooks settings.
        let settings = model.dataRoot.appendingPathComponent("hooks/claude-settings.json").path
        let arguments = try String(contentsOf: fixture.bin.appendingPathComponent("claude-args"), encoding: .utf8)
        #expect(arguments == "--settings \(settings) hi")
        // The conversation id its hooks report is kept, and the run counts as a started agent.
        #expect(await eventually { (try? record(id, in: model).agentSessionID) == Self.hookID })
        #expect(await eventually { (try? model.store.suijinStats().agentsSpawned) == 1 })

        terminal.send("ask\n")
        #expect(await eventually { (try? runtimes.activity(of: record(id, in: model))) == .waitingForInput })
        let message = try #require(UserNotifier.shared.withheld.last)
        #expect(message.identifier == id.uuidString)
        #expect(message.title == "Claude needs your input")
        terminal.send("stop\n")
        #expect(await eventually { (try? runtimes.activity(of: record(id, in: model))) == .idle })

        terminal.send("quit 3\n")
        #expect(await eventually { (try? runtimes.displayAgent(of: record(id, in: model))) == .shell })
        // The shell goes on: no Session Ended view, a shell's status again, its own title.
        let back = try record(id, in: model)
        #expect(runtimes.runtime(for: id) != nil && terminal.isRunning)
        #expect(back.state != .exited && back.state != .failed)
        #expect(runtimes.activity(of: back) == .running)
        // Claude's title went with it (the shell's prompt may set its own).
        #expect(runtimes.displayTitle(of: back) != "Claude")
        #expect(terminal.view.pasteGuardPolicy == .always)
        #expect(back.agentSessionID == Self.hookID)
        // Hook events after the run do not reach the shell's status.
        let notices = UserNotifier.shared.withheld.count
        try Data(#"{"hook_event_name":"Notification","notification_type":"permission_prompt"}"#.utf8 + [0x0a])
            .append(to: model.dataRoot.appendingPathComponent("hooks/events/\(id.uuidString).jsonl"))
        try await Task.sleep(for: .milliseconds(500))
        #expect(UserNotifier.shared.withheld.count == notices)
        #expect(runtimes.activity(of: back) == .running)
        await fixture.tearDown()
    }

    @Test func ctrlCEndsCodexInAShellAndKeepsItsResumeID() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let runtimes = model.runtimes
        let (id, terminal) = try await startShell(in: fixture)
        run("codex", in: terminal)
        #expect(await eventually { terminal.view.visibleText().contains("FAKE READY") })
        #expect(await eventually { (try? runtimes.displayAgent(of: record(id, in: model))) == .codex })
        #expect(runtimes.displayTitle(of: try record(id, in: model)) == "Codex")

        terminal.send([0x03])
        #expect(await eventually { (try? runtimes.displayAgent(of: record(id, in: model))) == .shell })
        #expect(await eventually { (try? record(id, in: model).agentSessionID) == Self.codexID })
        #expect(runtimes.runtime(for: id) != nil && terminal.isRunning)
        #expect(try record(id, in: model).agent == .shell)

        // A second run shows the agent again, and the shell still answers after it.
        run("codex", in: terminal)
        #expect(await eventually { (try? runtimes.displayAgent(of: record(id, in: model))) == .codex })
        terminal.send([0x03])
        #expect(await eventually { (try? runtimes.displayAgent(of: record(id, in: model))) == .shell })
        terminal.send("echo SHELL-OK\n")
        #expect(await eventually { terminal.view.visibleText().contains("SHELL-OK") })
        await fixture.tearDown()
    }

    @Test func markersOutsideAShellChangeNothing() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let workspace = try #require(model.workspaces.first)
        let record = AgentSessionRecord(workspaceID: workspace.id, agent: .claude, title: "Claude", cwd: fixture.root.path)
        let launch = ShellLaunch.command("/bin/sh", ["-c", #"printf '\033]6973;start;codex\007MARKED\n'; sleep 30"#],
                                         cwd: fixture.root, environment: [:], interactive: false)
        try await model.runtimes.run(record, launch: launch)
        let runtime = try #require(model.runtimes.runtime(for: record.id))
        #expect(await eventually { runtime.terminal.view.visibleText().contains("MARKED") })
        #expect(model.runtimes.displayAgent(of: record) == .claude)
        #expect(runtime.activeAgent == .claude)
        await fixture.tearDown()
    }

    /// For review: the sidebar and tabs of a shell before, during (Claude waiting for input) and after a `claude` run,
    /// narrow and wide, light and dark. Opt-in with `TEST_RUNNER_SUIJIN_SHELL_AGENT_SHOT=<file>`: at each step the file
    /// receives `<name> <window number>` and the window stays up while the caller captures it with `screencapture -l`.
    /// The window is ordered in without activating the app.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUIJIN_SHELL_AGENT_SHOT"] != nil))
    func screenshots() async throws {
        let output = try #require(ProcessInfo.processInfo.environment["SUIJIN_SHELL_AGENT_SHOT"])
        let fixture = try await makeFixture()
        let model = fixture.model
        fixture.window.orderOut(nil)
        // A second, plain shell beside it, which never runs an agent.
        _ = try #require(await model.runtimes.start(in: fixture.context, agent: .shell, accountID: nil, prompt: nil))
        let (id, terminal) = try await startShell(in: fixture)

        func capture(_ step: String) async throws {
            for dark in [false, true] {
                for width in [760.0, 1280.0] {
                    let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: width, height: 520),
                                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = NSHostingView(rootView: NavigationSplitView {
                        SidebarView().navigationSplitViewColumnWidth(260)
                    } detail: {
                        SessionTabsView(context: fixture.context)
                    }.environment(model))
                    window.orderFrontRegardless()
                    try await Task.sleep(for: .milliseconds(900))
                    try "\(step)-\(Int(width))-\(dark ? "dark" : "light") \(window.windowNumber)"
                        .write(toFile: output, atomically: true, encoding: .utf8)
                    try await Task.sleep(for: .milliseconds(1_800))
                    window.orderOut(nil)
                }
            }
        }

        model.selectedTab[fixture.context] = .session(id)
        try await capture("1-shell")
        run("claude", in: terminal)
        #expect(await eventually { (try? model.runtimes.displayAgent(of: record(id, in: model))) == .claude })
        terminal.send("ask\n")
        #expect(await eventually { (try? model.runtimes.activity(of: record(id, in: model))) == .waitingForInput })
        try await capture("2-claude-waiting")
        terminal.send("quit 0\n")
        #expect(await eventually { (try? model.runtimes.displayAgent(of: record(id, in: model))) == .shell })
        try await capture("3-shell-again")
        try "done".write(toFile: output, atomically: true, encoding: .utf8)
        await fixture.tearDown()
    }
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
