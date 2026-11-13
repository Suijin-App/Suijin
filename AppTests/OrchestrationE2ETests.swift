import Foundation
import SuijinCore
import SuijinGit
import SuijinPTYProtocol
import SuijinTerminal
import Testing
@testable import Suijin

/// Orchestration end to end with the real `claude` and `codex` (the user's own logins) through the app and the PTY
/// host: a Claude coordinator, driven by text typed into its terminal, starts a Codex worker in a new worktree with
/// `suijin worker start`; the worker asks, the coordinator replies, the worker reports done and the coordinator is
/// woken. Then a worker is killed and the broker escalates. Also checks that `suijin` refuses a terminal Suijin did
/// not open.
///
/// Opt-in: `TEST_RUNNER_SUIJIN_ORCH_E2E=1`, with `TEST_RUNNER_SUIJIN_PTYHOST_SERVICE` naming a helper instance of
/// this build (scripts start one with launchctl) so the user's own helper and sessions are untouched, and
/// `TEST_RUNNER_SUIJIN_ORCH_E2E_ROOT` a short temporary directory. Prompts are tiny; screens are never printed whole.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(20)), .enabled(if: ProcessInfo.processInfo.environment["SUIJIN_ORCH_E2E"] == "1"))
struct OrchestrationE2ETests {
    private func eventually(_ timeout: Duration, every: Duration = .milliseconds(500), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: every)
        }
        return await condition()
    }

    private func log(_ text: String) {
        print("ORCH-E2E \(text)")
    }

    /// A few screen lines without anything that looks like an email address.
    private func redacted(_ screen: String) -> String {
        screen.split(separator: "\n").map { line in
            line.split(separator: " ").map { $0.contains("@") ? "[redacted]" : String($0) }.joined(separator: " ")
        }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.allSatisfy({ $0 == "─" }) }.suffix(16)
            .joined(separator: " | ")
    }

    /// The whole screen, line by line, with anything that looks like an email address removed.
    private func redactedScreen(_ screen: String) -> String {
        screen.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.split(separator: " ", omittingEmptySubsequences: false).map { $0.contains("@") ? "[redacted]" : String($0) }
                .joined(separator: " ")
        }.joined(separator: "\n")
    }

    private func git(_ args: [String], in dir: URL) async throws {
        _ = try await GitRunner().run(["-c", "user.name=Suijin Tests", "-c", "user.email=tests@example.invalid"] + args, in: dir)
    }

    /// Answers a folder-trust prompt if the agent shows one (a fresh temporary repository is never trusted).
    private func acceptTrustPrompt(_ runtime: SessionRuntime, name: String) async {
        let shown = await eventually(.seconds(25)) {
            let screen = runtime.terminal.view.visibleText().lowercased()
            return screen.contains("trust") || screen.contains("? for shortcuts") || screen.contains("context left")
        }
        guard shown, runtime.terminal.view.visibleText().lowercased().contains("trust") else { return }
        // Move the selection to the "Yes" choice (Claude preselects "No, exit"), then confirm.
        for _ in 0..<4 {
            let lines = runtime.terminal.view.visibleText().split(separator: "\n")
            guard let selected = lines.first(where: { $0.contains("❯") }) else { break }
            if selected.lowercased().contains("yes") { break }
            runtime.terminal.send("\u{1B}[B")
            try? await Task.sleep(for: .milliseconds(400))
        }
        log("\(name): accepting the trust prompt")
        runtime.terminal.send("\r")
        let gone = await eventually(.seconds(15)) { !runtime.terminal.view.visibleText().lowercased().contains("trust this") }
        #expect(gone, "\(name) still shows the trust prompt: \(redacted(runtime.terminal.view.visibleText()))")
        try? await Task.sleep(for: .seconds(3))
    }

    /// Types `text` the way a user pastes a prompt, then presses Return.
    private func type(_ text: String, into runtime: SessionRuntime) async {
        runtime.terminal.send("\u{1B}[200~" + text + "\u{1B}[201~")
        try? await Task.sleep(for: .milliseconds(800))
        runtime.terminal.send("\r")
    }

    private func runCLI(_ args: [String], environment: [String: String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: OrchestrationLaunch.cliPath)
        process.arguments = args
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    @Test func claudeCoordinatorRunsACodexWorkerInANewWorktree() async throws {
        let environment = ProcessInfo.processInfo.environment
        let base = URL(fileURLWithPath: environment["SUIJIN_ORCH_E2E_ROOT"] ?? NSTemporaryDirectory(), isDirectory: true)
        let root = base.appendingPathComponent("e2e-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let dataRoot = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try await git(["init", "-b", "main"], in: repo)
        try "e2e\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await git(["add", "."], in: repo)
        try await git(["commit", "-m", "initial"], in: repo)
        log("service \(PTYHostConstants.machServiceName), root \(root.path)")

        let model = AppModel(store: try SuijinStore(url: SuijinPaths.database(in: dataRoot)), dataRoot: dataRoot)
        await model.loadSettings()
        if environment["SUIJIN_ORCH_E2E_NO_DAEMON"] == "1" { model.setSetting(.codexNoDaemon, "true") }
        await model.addWorkspace(at: repo)
        await model.runtimes.bootstrap()
        var started: [UUID] = []
        defer {
            // Only this test's sessions are ended; the helper instance is the test's own.
            Task { @MainActor in
                for id in started { await model.closeSession(id) }
                model.runtimes.orchestration.stop()
            }
        }
        let orchestration = model.runtimes.orchestration
        #expect(await eventually(.seconds(20)) { orchestration.isConnected }, "broker link: \(orchestration.problem ?? "none")")
        let workspace = try #require(model.workspaces.first)
        let context = SessionContext.workspace(workspace.id)

        // 1. `suijin` outside Suijin's terminals is refused, with and without a made-up token.
        let plain = ["PATH": "/usr/bin:/bin", "SUIJIN_DATA_ROOT": dataRoot.path]
        let (noToken, noTokenText) = try runCLI(["worker", "list"], environment: plain)
        #expect(noToken == 3, "no token: \(noTokenText)")
        var forged = plain
        forged["SUIJIN_SESSION_TOKEN"] = OrchestrationToken.make()
        let (forgedStatus, forgedText) = try runCLI(["inbox"], environment: forged)
        #expect(forgedStatus == 1 && forgedText.contains("not opened by Suijin"), "forged token: \(forgedText)")
        log("non-Suijin terminal refused: no token exit \(noToken), forged token exit \(forgedStatus)")

        // 2. A Claude coordinator, driven by typing into its terminal.
        let coordinatorID = try #require(await model.runtimes.start(in: context, agent: .claude, accountID: nil, prompt: nil))
        started.append(coordinatorID)
        let coordinator = try #require(model.runtimes.runtime(for: coordinatorID))
        await acceptTrustPrompt(coordinator, name: "coordinator")
        #expect(await eventually(.seconds(30)) { coordinator.terminal.view.visibleText().lowercased().contains("claude") })
        try? await Task.sleep(for: .seconds(4))
        #expect(!coordinator.terminal.hasExited, "the coordinator must still run")
        if environment["SUIJIN_ORCH_E2E_DIAG"] == "codex" {
            // A Codex worker launch with no prompt (nothing reaches a model) in a fresh worktree: no trust screen.
            await model.closeSession(coordinatorID)
            started.removeAll()
            let path = WorktreeService.defaultPath(repository: repo, branch: "diag")
            let tree = try await model.createWorktree(workspaceID: workspace.id, branch: "diag", base: "main", path: path)
            orchestration.launchingWorkerPrompts.insert("")
            let codexID = try #require(await model.runtimes.start(in: .worktree(tree.id), agent: .codex, accountID: nil, prompt: ""))
            orchestration.launchingWorkerPrompts.remove("")
            let codex = try #require(model.runtimes.runtime(for: codexID))
            _ = await eventually(.seconds(40)) {
                let screen = codex.terminal.view.visibleText().lowercased()
                if screen.contains("esc skip") { codex.terminal.send("\u{1B}") }
                return screen.contains("trust this folder") || screen.contains("context left") || screen.contains("% left")
            }
            log("diag codex worker screen:\n\(redactedScreen(codex.terminal.view.visibleText()))")
            #expect(!codex.terminal.view.visibleText().lowercased().contains("trust this folder"))
            await model.closeSession(codexID)
            await model.removeWorktree(tree.id, force: true)
            return
        }
        if environment["SUIJIN_ORCH_E2E_DIAG"] == "1" {
            // Screens only, nothing is sent to a model.
            log("diag coordinator screen:\n\(redactedScreen(coordinator.terminal.view.visibleText()))")
            await model.closeSession(coordinatorID)
            started.removeAll()
            return
        }
        await type("""
        Run exactly this shell command, then end your turn without doing anything else: suijin worker start --agent codex \
        --worktree new --name e2e-w --spec "Ask your coordinator which number to write by running: suijin ask --body 'Which number?' and end your turn. After the answer arrives, write just that number into answer.txt, then run: suijin done --status success --summary 'wrote answer.txt'". \
        Later, when Suijin shows you a worker question, answer it by running suijin reply with the number 42. When Suijin reports the worker finished, reply to me with the single word FINISHED.
        """, into: coordinator)

        // 3. The worker starts in a new worktree.
        let workerStarted = await eventually(.seconds(180)) {
            orchestration.snapshot.dispatches.contains { $0.workerSessionID != nil }
        }
        #expect(workerStarted, "coordinator screen: \(redacted(coordinator.terminal.view.visibleText()))")
        guard workerStarted, let dispatch = orchestration.snapshot.dispatches.first(where: { $0.workerSessionID != nil }),
              let workerID = dispatch.workerSessionID.flatMap(UUID.init(uuidString:)) else { return }
        started.append(workerID)
        let workerRecord = try #require(model.sessions.first { $0.id == workerID })
        let worktree = try #require(workerRecord.worktreeID.flatMap { model.worktree($0) })
        #expect(worktree.branch == "e2e-w")
        #expect(dispatch.agent == .codex && dispatch.worktree == .new)
        log("worker \(dispatch.id) started in worktree \(worktree.branch)")
        let worker = try #require(model.runtimes.runtime(for: workerID))
        // Suijin trusts a worker's folder for the launch, so Codex must not ask (answering would save the folder in
        // the user's own ~/.codex/config.toml). An update notice of the user's Codex is skipped once with Esc.
        var skippedUpdate = false
        let ready = await eventually(.seconds(60)) {
            let screen = worker.terminal.view.visibleText().lowercased()
            // Esc once, only on the modal update notice: a later Esc would interrupt the worker's turn.
            if !skippedUpdate, screen.contains("skip until next version") {
                skippedUpdate = true
                worker.terminal.send("\u{1B}")
            }
            return screen.contains("trust this folder") || orchestration.snapshot.messages.contains { $0.kind == .question }
                || screen.contains("working") || screen.contains("esc to interrupt")
        }
        #expect(ready)
        #expect(!worker.terminal.view.visibleText().lowercased().contains("trust this folder"),
                "worker asked for folder trust: \(redacted(worker.terminal.view.visibleText()))")

        // 4. ask → coordinator woken → reply → done → coordinator woken again.
        let asked = await eventually(.seconds(240)) { orchestration.snapshot.messages.contains { $0.kind == .question } }
        #expect(asked, "worker screen: \(redacted(worker.terminal.view.visibleText()))")
        let replied = await eventually(.seconds(240)) { orchestration.snapshot.messages.contains { $0.kind == .reply } }
        #expect(replied, "coordinator screen: \(redacted(coordinator.terminal.view.visibleText()))")
        let done = await eventually(.seconds(300)) { orchestration.snapshot.messages.contains { $0.kind == .done } }
        #expect(done, "worker screen: \(redacted(worker.terminal.view.visibleText()))")
        let answer = try? String(contentsOfFile: URL(fileURLWithPath: worktree.path).appendingPathComponent("answer.txt").path, encoding: .utf8)
        #expect(answer?.trimmingCharacters(in: .whitespacesAndNewlines) == "42")
        let woken = await eventually(.seconds(180)) {
            coordinator.terminal.view.visibleText().contains("FINISHED")
                && orchestration.snapshot.messages.contains { $0.kind == .done && $0.status == .delivered }
        }
        #expect(woken, "coordinator screen: \(redacted(coordinator.terminal.view.visibleText()))")
        let messages = orchestration.snapshot.messages
        let questionDelivered = messages.first { $0.kind == .question }?.status == .delivered
        let replyDelivered = messages.first { $0.kind == .reply }?.status == .delivered
        #expect(questionDelivered && replyDelivered)
        for item in orchestration.snapshot.dispatches {
            log("dispatch \(item.id) \(item.name) \(item.status.rawValue) worker \(item.workerSessionID ?? "-") error \(item.lastError ?? "-") at \(item.createdAt)")
        }
        for item in messages {
            log("message \(item.id) \(item.kind.rawValue) \(item.status.rawValue) dispatch \(item.dispatchID) at \(item.createdAt): \(item.body.prefix(160))")
        }
        #expect(!messages.contains { $0.kind == .escalation }, "no escalation in the happy path")
        log("flow: \(messages.map { "\($0.kind.rawValue):\($0.status.rawValue)" }.joined(separator: ", ")); dispatch \(orchestration.snapshot.dispatches.first { $0.id == dispatch.id }?.status.rawValue ?? "?"); answer \(answer ?? "missing")")

        // 5. A shell session in Suijin has `suijin` on PATH and can start a worker; killing that worker escalates.
        let shellID = try #require(await model.runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil))
        started.append(shellID)
        let shell = try #require(model.runtimes.runtime(for: shellID))
        try? await Task.sleep(for: .seconds(3))
        shell.terminal.send("suijin worker start --agent codex --spec 'Run the shell command: sleep 600' --json > \(root.path)/start.json 2>&1\r")
        let second = await eventually(.seconds(90)) {
            orchestration.snapshot.dispatches.contains { $0.id != dispatch.id && $0.workerSessionID != nil && $0.coordinatorSessionID == shellID.uuidString }
        }
        #expect(second, "shell screen: \(redacted(shell.terminal.view.visibleText()))")
        if second, let victim = orchestration.snapshot.dispatches.first(where: { $0.coordinatorSessionID == shellID.uuidString }),
           let victimID = victim.workerSessionID.flatMap(UUID.init(uuidString:)),
           let hostID = model.runtimes.runtime(for: victimID)?.terminal.engine.sessionID {
            started.append(victimID)
            try? await Task.sleep(for: .seconds(5))
            // Killed from outside, as a crash or `kill` would; Suijin did not end it.
            PTYHostClient.shared.terminate(hostID)
            let escalated = await eventually(.seconds(30)) {
                orchestration.snapshot.messages.contains { $0.kind == .escalation && $0.dispatchID == victim.id }
            }
            #expect(escalated)
            let status = orchestration.snapshot.dispatches.first { $0.id == victim.id }?.status
            #expect(status == .exited)
            log("killed worker \(victim.id): status \(status?.rawValue ?? "?"), escalation \(escalated)")
        }
        let startJSON = (try? String(contentsOfFile: root.appendingPathComponent("start.json").path, encoding: .utf8)) ?? ""
        #expect(startJSON.contains(#""ok" : true"#), "shell `suijin worker start --json`: \(startJSON.prefix(300))")

        for id in started { await model.closeSession(id) }
        started.removeAll()
        orchestration.stop()
        await model.removeWorktree(worktree.id, force: true)
        try? FileManager.default.removeItem(at: root)
    }
}
