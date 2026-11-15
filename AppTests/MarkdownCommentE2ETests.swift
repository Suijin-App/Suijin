import Foundation
import SuijinCore
import SuijinPTYProtocol
import SuijinTerminal
import Testing
@testable import Suijin

/// Markdown comments end to end through the app, the PTY host and the `suijin` CLI: comments are handed to a real
/// shell session, the shell runs `suijin comment list` and `suijin comment resolve`, and the comments in the app's
/// store take the result. Another session and a terminal Suijin did not open are refused. A result reported while
/// the app's link to the broker is down is applied when it connects again.
///
/// Opt-in like `OrchestrationE2ETests`: `TEST_RUNNER_SUIJIN_ORCH_E2E=1`, with `TEST_RUNNER_SUIJIN_PTYHOST_SERVICE`
/// naming a helper instance of this build so the user's own helper and sessions are untouched, and
/// `TEST_RUNNER_SUIJIN_ORCH_E2E_ROOT` a short temporary directory.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)), .enabled(if: ProcessInfo.processInfo.environment["SUIJIN_ORCH_E2E"] == "1"))
struct MarkdownCommentE2ETests {
    private func eventually(_ timeout: Duration, every: Duration = .milliseconds(200), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: every)
        }
        return await condition()
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

    /// Types a command into a shell's terminal and presses Return.
    private func run(_ command: String, in runtime: SessionRuntime) async {
        runtime.terminal.send(command)
        try? await Task.sleep(for: .milliseconds(300))
        runtime.terminal.send("\r")
    }

    @Test func aShellAnswersCommentsWithTheCLI() async throws {
        let environment = ProcessInfo.processInfo.environment
        let base = URL(fileURLWithPath: environment["SUIJIN_ORCH_E2E_ROOT"] ?? NSTemporaryDirectory(), isDirectory: true)
        let root = base.appendingPathComponent("cmt-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let folder = root.appendingPathComponent("work", isDirectory: true)
        let dataRoot = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = folder.appendingPathComponent("plan.md").standardizedFileURL
        try "# Plan\n\nFirst paragraph.\n\nSecond paragraph.\n\nThird paragraph.\n".write(to: file, atomically: true, encoding: .utf8)

        let model = AppModel(store: try SuijinStore(url: SuijinPaths.database(in: dataRoot)), dataRoot: dataRoot)
        await model.loadSettings()
        await model.addWorkspace(at: folder)
        await model.runtimes.bootstrap()
        var started: [UUID] = []
        defer {
            Task { @MainActor in
                for id in started { await model.closeSession(id) }
                model.runtimes.orchestration.stop()
            }
        }
        let orchestration = model.runtimes.orchestration
        #expect(await eventually(.seconds(20)) { orchestration.isConnected }, "broker link: \(orchestration.problem ?? "none")")
        #expect(orchestration.canResolveComments, "helper protocol \(orchestration.hostProtocolVersion ?? 0)")
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        model.selection = context

        let receiver = try #require(await model.runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil))
        let other = try #require(await model.runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil))
        started += [receiver, other]
        let receiverRuntime = try #require(model.runtimes.runtime(for: receiver))
        let otherRuntime = try #require(model.runtimes.runtime(for: other))
        #expect(await eventually(.seconds(15)) { receiverRuntime.terminal.isRunning && otherRuntime.terminal.isRunning })
        try? await Task.sleep(for: .seconds(2))

        // Three comments, handed to the first shell.
        model.openFile(file.path, in: context)
        let book = try #require(model.openMarkdownComments(for: file.path, in: context))
        #expect(await eventually(.seconds(5)) { book.isLoaded })
        let text = try String(contentsOf: file, encoding: .utf8) as NSString
        let first = try #require(book.create(range: text.range(of: "First paragraph."), body: "shorter"))
        let second = try #require(book.create(range: text.range(of: "Second paragraph."), body: ""))
        let third = try #require(book.create(range: text.range(of: "Third paragraph."), body: "later"))
        let ids = [first.id, second.id, third.id]
        book.markSent(ids, to: receiver)
        model.registerSentComments(book.placed, displayPath: book.displayPath, session: receiver)
        func short(_ id: UUID) -> String { MarkdownCommentFormatter.shortID(of: id, among: ids) }
        func stored(_ id: UUID) async -> MarkdownComment? { try? await model.io { try $0.markdownComment(id: id) } }
        #expect(await eventually(.seconds(5)) { await stored(third.id)?.status == .sent })
        try? await Task.sleep(for: .seconds(1))

        // 1. The receiver lists what it has to answer.
        await run("suijin comment list", in: receiverRuntime)
        #expect(await eventually(.seconds(10)) {
            let screen = receiverRuntime.terminal.view.visibleText()
            return screen.contains("Review comments on plan.md") && screen.contains(short(second.id))
        }, "list: \(receiverRuntime.terminal.view.visibleText().suffix(600))")

        // 2. Another session and a terminal Suijin did not open cannot answer it.
        await run("suijin comment resolve \(short(first.id)) --fixed --reply nope", in: otherRuntime)
        #expect(await eventually(.seconds(10)) { otherRuntime.terminal.view.visibleText().contains("No such comment for this session") })
        var forged = ["PATH": "/usr/bin:/bin", "SUIJIN_DATA_ROOT": dataRoot.path]
        forged["SUIJIN_SESSION_TOKEN"] = OrchestrationToken.make()
        let (forgedStatus, _) = try runCLI(["comment", "resolve", short(first.id), "--fixed"], environment: forged)
        #expect(forgedStatus != 0)
        try? await Task.sleep(for: .seconds(1))
        #expect(await stored(first.id)?.status == .sent, "a refused caller changes nothing")

        // 3. The receiver answers: fixed with a reply, then declined.
        await run("suijin comment resolve \(short(first.id)) --fixed --reply 'Cut it to one sentence.'", in: receiverRuntime)
        #expect(await eventually(.seconds(10)) { await stored(first.id)?.status == .fixed })
        #expect(await stored(first.id)?.agentReply == "Cut it to one sentence.")
        #expect(book.comments.first { $0.id == first.id }?.status == .fixed, "the open tab shows the result")
        await run("suijin comment resolve \(short(second.id)) --declined --reply 'Out of scope.'", in: receiverRuntime)
        #expect(await eventually(.seconds(10)) { await stored(second.id)?.status == .declined })

        // 4. With the app's link down, the result waits in the broker and is applied on the next connect.
        orchestration.stop()
        await run("suijin comment resolve \(short(third.id)) --fixed --reply 'Moved to the end.'", in: receiverRuntime)
        #expect(await eventually(.seconds(10)) { receiverRuntime.terminal.view.visibleText().contains("as fixed") })
        #expect(await stored(third.id)?.status == .sent)
        orchestration.start()
        #expect(await eventually(.seconds(30)) { await stored(third.id)?.status == .fixed })
        #expect(await stored(third.id)?.agentReply == "Moved to the end.")
    }
}
