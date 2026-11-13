import Foundation
import SuijinCLIKit
@testable import SuijinPTYHostKit
import SuijinPTYProtocol
import Synchronization
import Testing

/// A short private directory: socket paths must fit `sun_path`.
private func shortDirectory() throws -> URL {
    let url = OrchestrationPaths.userTemporaryDirectory().appendingPathComponent("mo-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
}

@Suite("Orchestration transport", .serialized)
struct OrchestrationTransportTests {
    @Test func socketIsPrivateAndAnswersOneLine() throws {
        let directory = try shortDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("b.sock").path
        let server = BrokerSocketServer(path: path) { request, reply in
            reply(.success(["echo": request.command], text: "hello \(request.options["name"] ?? "")"))
        }
        try server.start()
        defer { server.stop() }
        let mode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? 0
        #expect(mode == 0o600)
        let client = BrokerClient(socketPath: path, spoolDirectory: nil)
        let response = try client.send(BrokerRequest(token: "t", command: "whoami", options: ["name": "x"]), timeout: 5)
        #expect(response.ok)
        #expect(response.text == "hello x")
        #expect(response.result?["echo"]?.stringValue == "whoami")
    }

    @Test func staleSocketIsReplacedButOtherFilesAreNot() throws {
        let directory = try shortDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("b.sock").path
        let first = BrokerSocketServer(path: path) { _, reply in reply(.success([String](), text: "one")) }
        try first.start()
        first.stop()
        let second = BrokerSocketServer(path: path) { _, reply in reply(.success([String](), text: "two")) }
        try second.start()
        // Simulate a socket left behind by a crashed helper: start again over it.
        let third = BrokerSocketServer(path: path) { _, reply in reply(.success([String](), text: "three")) }
        try third.start()
        defer { third.stop(); second.stop() }
        let response = try BrokerClient(socketPath: path, spoolDirectory: nil).send(BrokerRequest(token: "t", command: "x"), timeout: 5)
        #expect(response.text == "three")
        let plain = directory.appendingPathComponent("plain").path
        FileManager.default.createFile(atPath: plain, contents: Data("keep".utf8))
        #expect(throws: (any Error).self) { try BrokerSocketServer(path: plain) { _, _ in }.start() }
        #expect(FileManager.default.contents(atPath: plain) == Data("keep".utf8))
    }

    @Test func spoolServesCallersThatCannotUseTheSocket() throws {
        let directory = try shortDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("spool", isDirectory: true)
        let spool = BrokerSpool(root: root) { request, reply in
            reply(.success([String](), text: "via spool: \(request.command)"))
        }
        try spool.start()
        defer { spool.stop() }
        let mode = (try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("requests").path)[.posixPermissions] as? Int) ?? 0
        #expect(mode == 0o700)
        // The socket path does not exist: the client falls back to the spool.
        let client = BrokerClient(socketPath: directory.appendingPathComponent("missing.sock").path, spoolDirectory: root)
        let response = try client.send(BrokerRequest(token: "t", command: "inbox"), timeout: 10)
        #expect(response.text == "via spool: inbox")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("responses").path)
        #expect(leftovers.isEmpty, "the client removes its response")
    }

    @Test func nothingListeningIsReportedQuickly() throws {
        let directory = try shortDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A spool directory with no broker sweeping it (the helper exited).
        let root = directory.appendingPathComponent("spool", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("requests"), withIntermediateDirectories: true)
        let client = BrokerClient(socketPath: directory.appendingPathComponent("gone.sock").path, spoolDirectory: root)
        let start = Date()
        #expect(throws: BrokerClientError.self) { try client.send(BrokerRequest(token: "t", command: "inbox"), timeout: 30) }
        #expect(Date().timeIntervalSince(start) < 6)
        let left = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("requests").path)
        #expect(left.isEmpty, "an unanswered request is withdrawn")
        #expect(throws: BrokerClientError.self) {
            try BrokerClient(socketPath: directory.appendingPathComponent("gone.sock").path, spoolDirectory: nil)
                .send(BrokerRequest(token: "t", command: "inbox"), timeout: 1)
        }
    }

    /// The whole helper path: a real PTY session spawned with a token and metadata registers with the hub, the CLI
    /// reaches the broker over the socket, and the app connects to the broker endpoint over XPC.
    @Test func hubRegistersSessionsAndServesTheCLIAndTheApp() async throws {
        let directory = try shortDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dataRoot = directory.appendingPathComponent("d", isDirectory: true)
        let manager = SessionManager(configuration: SessionManager.Configuration(metadataDirectory: nil))
        var configuration = OrchestrationHub.Configuration()
        configuration.tuning.startReplyTimeout = 1
        let hub = OrchestrationHub(manager: manager, configuration: configuration)
        manager.setObserver(hub)
        manager.start()
        defer { hub.shutdown() }
        let token = OrchestrationToken.make()
        let info = try manager.spawn(PTYSpawnRequest(
            executable: "/bin/cat", environment: [OrchestrationEnvironment.sessionToken: token, "PATH": "/usr/bin:/bin"],
            cwd: "/tmp", metadata: [OrchestrationMetadata.session: "S-1", OrchestrationMetadata.dataRoot: dataRoot.path,
                                    OrchestrationMetadata.agent: "claude"]))
        defer { manager.terminate(sessionID: info.id) }

        let environment = [OrchestrationEnvironment.sessionToken: token, OrchestrationEnvironment.dataRoot: dataRoot.path]
        let cli = SuijinCLI(environment: environment, skillsDirectory: nil, version: "test")
        let whoami = cli.run(["whoami", "--json"])
        #expect(whoami.exitCode == 0, "\(whoami.stderr)")
        #expect(whoami.stdout.contains(#""sessionID" : "S-1""#))
        let state = OrchestrationPaths.stateFile(dataRoot: dataRoot)
        let directoryMode = (try FileManager.default.attributesOfItem(atPath: state.deletingLastPathComponent().path)[.posixPermissions] as? Int) ?? 0
        #expect(directoryMode == 0o700)

        // A forged token from a terminal Suijin did not open is refused by the broker itself.
        var forged = environment
        forged[OrchestrationEnvironment.sessionToken] = OrchestrationToken.make()
        let refused = SuijinCLI(environment: forged, skillsDirectory: nil, version: "test").run(["inbox"])
        #expect(refused.exitCode == SuijinCLI.Exit.refused)
        #expect(refused.stderr.contains("not opened by Suijin"))

        // The app side: endpoint, hello, snapshot.
        let endpoint = hub.endpoint(dataRoot: dataRoot)
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = OrchestrationXPCInterfaces.host()
        connection.exportedInterface = OrchestrationXPCInterfaces.client()
        connection.exportedObject = SilentClient()
        connection.resume()
        defer { connection.invalidate() }
        let proxy = try #require(connection.remoteObjectProxy as? any OrchestrationHostXPC)
        let accepted = await withCheckedContinuation { continuation in proxy.hello(appBuild: "test") { continuation.resume(returning: $0) } }
        #expect(accepted)
        let start = cli.run(["worker", "start", "--agent", "codex", "--spec", "Say hi", "--json"])
        // The silent app never answers, so the broker answers "starting" after its timeout.
        #expect(start.exitCode == 0, "\(start.stderr)")
        #expect(start.stdout.contains(#""status" : "starting""#))
        let data = await withCheckedContinuation { continuation in proxy.snapshot { continuation.resume(returning: $0) } }
        let snapshot = try OrchestrationCoding.decoder.decode(OrchestrationSnapshot.self, from: data)
        #expect(snapshot.dispatches.count == 1)
        #expect(snapshot.dispatches.first?.coordinatorSessionID == "S-1")
    }
}

/// An app that takes worker starts and never answers.
private final class SilentClient: NSObject, OrchestrationClientXPC, Sendable {
    func startWorker(_ request: Data) {}
    func stateChanged() {}
    func attention(_ event: Data) {}
}

@Suite("suijin CLI")
struct CLIParsingTests {
    let parser = CommandParser(readFile: { $0 == "/spec.md" ? "spec from file" : nil }, readStandardInput: { "from stdin" })

    @Test func parsesEveryCommand() throws {
        #expect(try parser.parse(["worker", "start", "--agent", "codex", "--spec", "Fix it", "--worktree", "new", "--name", "fix", "--json"])
                == .broker(command: "worker.start", options: ["agent": "codex", "spec": "Fix it", "worktree": "new", "name": "fix"], json: true))
        #expect(try parser.parse(["worker", "list"]) == .broker(command: "worker.list", options: [:], json: false))
        #expect(try parser.parse(["send", "--to=d-1", "--body", "hi"]) == .broker(command: "send", options: ["to": "d-1", "body": "hi"], json: false))
        #expect(try parser.parse(["ask", "--body", "why?"]) == .broker(command: "ask", options: ["body": "why?"], json: false))
        #expect(try parser.parse(["reply", "--id", "m-1", "--body", "because"]) == .broker(command: "reply", options: ["id": "m-1", "body": "because"], json: false))
        #expect(try parser.parse(["done", "--status", "success", "--summary", "ok"]) == .broker(command: "done", options: ["status": "success", "summary": "ok"], json: false))
        #expect(try parser.parse(["inbox", "--all", "--limit", "5"]) == .broker(command: "inbox", options: ["all": "true", "limit": "5"], json: false))
        #expect(try parser.parse(["skills", "get", "orchestration"]) == .skill(name: "orchestration"))
        #expect(try parser.parse(["--version"]) == .version)
        #expect(try parser.parse([]) == .help(topic: nil))
        #expect(try parser.parse(["ask", "--help"]) == .help(topic: "ask"))
    }

    @Test func acceptsOrcaSpellingsAndAliases() throws {
        #expect(try parser.parse(["worker-start", "--agent", "claude", "--task", "x"]) == .broker(command: "worker.start", options: ["agent": "claude", "spec": "x"], json: false))
        #expect(try parser.parse(["orchestration", "worker-list"]) == .broker(command: "worker.list", options: [:], json: false))
        #expect(try parser.parse(["ask", "--question", "q"]) == .broker(command: "ask", options: ["body": "q"], json: false))
        #expect(try parser.parse(["worker_done", "--outcome", "failed", "--body", "no"]) == .broker(command: "done", options: ["status": "failed", "summary": "no"], json: false))
    }

    @Test func readsFilesAndStandardInput() throws {
        #expect(try parser.parse(["worker", "start", "--agent", "codex", "--spec", "@/spec.md"])
                == .broker(command: "worker.start", options: ["agent": "codex", "spec": "spec from file"], json: false))
        #expect(try parser.parse(["ask", "--body", "@user what now"]) == .broker(command: "ask", options: ["body": "@user what now"], json: false),
                "an @ that names no file is literal")
        #expect(try parser.parse(["ask", "--body", "-"]) == .broker(command: "ask", options: ["body": "from stdin"], json: false))
    }

    @Test func mistakesGetSuggestions() {
        func failure(_ args: [String]) -> CLIUsageError? {
            do { _ = try parser.parse(args); return nil } catch let error as CLIUsageError { return error } catch { return nil }
        }
        #expect(failure(["wroker", "start"])?.suggestion == "suijin worker start")
        #expect(failure(["worker", "start", "--agent", "codex", "--spce", "x"])?.suggestion == "--spec")
        #expect(failure(["worker", "start", "--spec", "x"])?.message == "Missing `--agent`.")
        #expect(failure(["worker", "start", "--agent", "gpt", "--spec", "x"])?.message.contains("claude") == true)
        #expect(failure(["worker", "start", "--agent", "codex", "--spec", "x", "--worktree", "new-child"])?.suggestion == "--worktree new")
        #expect(failure(["done", "--status", "maybe", "--summary", "x"]) != nil)
        #expect(failure(["send", "--to"])?.message == "`--to` needs a value.")
        #expect(failure(["inbox", "--limit", "0"]) != nil)
        #expect(failure(["ask", "stray"])?.message.contains("Unexpected argument") == true)
    }

    @Test func refusesTerminalsWithoutAToken() {
        let cli = SuijinCLI(environment: [:], skillsDirectory: nil, version: "t", transport: { _, _ in
            Issue.record("must not reach the broker without a token")
            return .failure(BrokerFailure(code: "x", message: "x"))
        })
        let plain = cli.run(["worker", "list"])
        #expect(plain.exitCode == SuijinCLI.Exit.notSuijinTerminal)
        #expect(plain.stderr.contains("not opened by Suijin"))
        let json = cli.run(["worker", "list", "--json"])
        #expect(json.exitCode == SuijinCLI.Exit.notSuijinTerminal)
        #expect(json.stdout.contains(#""code" : "not_suijin_terminal""#))
        #expect(json.stdout.contains(#""ok" : false"#))
    }

    @Test func printsTextOrStableJSON() {
        let seen = Mutex<[BrokerRequest]>([])
        let cli = SuijinCLI(environment: [OrchestrationEnvironment.sessionToken: "tok"], skillsDirectory: nil, version: "t",
                             transport: { request, timeout in
                                 seen.withLock { $0.append(request) }
                                 #expect(timeout == (request.command == "worker.start" ? 75 : 20))
                                 return .success(["b": 2, "a": 1], text: "All good.")
                             })
        let text = cli.run(["worker", "list"])
        #expect(text == CLIResult(stdout: "All good.\n"))
        let json = cli.run(["worker", "list", "--json"])
        #expect(json.stdout == "{\n  \"ok\" : true,\n  \"result\" : {\n    \"a\" : 1,\n    \"b\" : 2\n  },\n  \"text\" : \"All good.\"\n}\n")
        #expect(seen.withLock { $0 }.allSatisfy { $0.token == "tok" && $0.command == "worker.list" })
        let refusing = SuijinCLI(environment: [OrchestrationEnvironment.sessionToken: "tok"], skillsDirectory: nil, version: "t",
                                  transport: { _, _ in .failure(BrokerFailure(code: "not_worker", message: "No.", hint: "Do this.")) })
        let refused = refusing.run(["ask", "--body", "?"])
        #expect(refused == CLIResult(stderr: "suijin: No.\nNext: Do this.\n", exitCode: SuijinCLI.Exit.refused))
        let unreachable = SuijinCLI(environment: [OrchestrationEnvironment.sessionToken: "tok"], skillsDirectory: nil, version: "t",
                                     transport: { _, _ in throw BrokerClientError.unreachable("ENOENT") })
        #expect(unreachable.run(["inbox"]).exitCode == SuijinCLI.Exit.unreachable)
    }

    @Test func hooksForwardTurnSignalsSilently() {
        let seen = Mutex<[BrokerRequest]>([])
        let chained = Mutex<[[String]]>([])
        let stdin = Data(#"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Allow Bash?"}"#.utf8)
        let cli = SuijinCLI(environment: [OrchestrationEnvironment.sessionToken: "tok"], skillsDirectory: nil, version: "t",
                             transport: { request, timeout in
                                 #expect(timeout == 3)
                                 seen.withLock { $0.append(request) }
                                 throw BrokerClientError.timedOut // a hook ignores failures
                             },
                             readStandardInput: { stdin },
                             runDetached: { argv in chained.withLock { $0.append(argv) } })
        #expect(cli.run(["hook", "claude"]) == CLIResult())
        let payload = #"{"type":"agent-turn-complete","thread-id":"t","turn-id":"u"}"#
        #expect(cli.run(["hook", "codex-notify", "--", "/usr/bin/true", "turn-ended", payload]) == CLIResult())
        #expect(cli.run(["hook", "codex-notify"]) == CLIResult(), "a malformed hook still never fails")
        let requests = seen.withLock { $0 }
        #expect(requests.map(\.command) == ["hook.claude", "hook.codex"])
        #expect(requests.first?.options == ["event": "Notification", "notificationType": "permission_prompt", "message": "Allow Bash?"])
        #expect(requests.last?.options == ["type": "agent-turn-complete"])
        #expect(chained.withLock { $0 } == [["/usr/bin/true", "turn-ended", payload]], "the user's own notify program still runs")
    }

    @Test func skillGuideComesFromTheBundle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("suijin-orchestration/SKILL.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Guide".write(to: file, atomically: true, encoding: .utf8)
        let cli = SuijinCLI(environment: [:], skillsDirectory: directory, version: "t")
        #expect(cli.run(["skills", "get", "orchestration"]) == CLIResult(stdout: "# Guide\n"))
        #expect(cli.run(["skills", "get", "other"]).exitCode == SuijinCLI.Exit.usage)
        #expect(cli.run(["--version"]).stdout == "suijin t (protocol 3)\n")
    }
}
