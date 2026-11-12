import Foundation
import SevindaPTYProtocol

/// What one run printed and its exit status.
public struct CLIResult: Equatable, Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// The `sevinda` command: parses the arguments, identifies the terminal by its session token and talks to the broker
/// in the PTY host. Exit status: 0 done, 1 refused by the broker, 2 usage error, 3 not a Sevinda terminal, 4 Sevinda
/// unreachable. Hooks never print and always exit 0, so they can never break an agent's turn.
public struct SevindaCLI: Sendable {
    public enum Exit {
        public static let ok: Int32 = 0
        public static let refused: Int32 = 1
        public static let usage: Int32 = 2
        public static let notSevindaTerminal: Int32 = 3
        public static let unreachable: Int32 = 4
    }

    public var environment: [String: String]
    /// `Sevinda.app/Contents/Resources/Skills`.
    public var skillsDirectory: URL?
    public var version: String
    public var parser: CommandParser
    public var transport: @Sendable (BrokerRequest, TimeInterval) throws -> BrokerResponse
    public var readStandardInput: @Sendable () -> Data
    /// Runs the user's own notify program, detached (Codex chains through Sevinda's).
    public var runDetached: @Sendable ([String]) -> Void

    public init(
        environment: [String: String],
        skillsDirectory: URL?,
        version: String,
        parser: CommandParser = CommandParser(),
        transport: (@Sendable (BrokerRequest, TimeInterval) throws -> BrokerResponse)? = nil,
        readStandardInput: @escaping @Sendable () -> Data = { FileHandle.standardInput.readDataToEndOfFile() },
        runDetached: @escaping @Sendable ([String]) -> Void = SevindaCLI.spawnDetached
    ) {
        self.environment = environment
        self.skillsDirectory = skillsDirectory
        self.version = version
        self.parser = parser
        let client = BrokerClient(environment: environment)
        self.transport = transport ?? { request, timeout in try client.send(request, timeout: timeout) }
        self.readStandardInput = readStandardInput
        self.runDetached = runDetached
    }

    /// `worker start` waits for the app to start the worker (the broker answers within 45 s).
    static func timeout(for command: String) -> TimeInterval {
        command == "worker.start" ? 75 : 20
    }

    static let hookTimeout: TimeInterval = 3

    public func run(_ arguments: [String]) -> CLIResult {
        let command: CLICommand
        do {
            command = try parser.parse(arguments)
        } catch let error as CLIUsageError {
            // A hook must never fail its agent's turn, even when called wrongly.
            if arguments.first == "hook" { return CLIResult() }
            return CLIResult(stderr: "sevinda: \(error)\n", exitCode: Exit.usage)
        } catch {
            return CLIResult(stderr: "sevinda: \(error.localizedDescription)\n", exitCode: Exit.usage)
        }
        switch command {
        case .help(let topic):
            return CLIResult(stdout: Self.help(topic: topic))
        case .version:
            return CLIResult(stdout: "sevinda \(version) (protocol \(PTYHostConstants.protocolVersion))\n")
        case .listSkills:
            return CLIResult(stdout: "orchestration    Start worker agents, message them, and get their results back.\n")
        case .skill(let name):
            return skill(name)
        case .claudeHook:
            claudeHook()
            return CLIResult()
        case .codexNotify(let payload, let chained):
            codexNotify(payload: payload)
            if !chained.isEmpty { runDetached(chained + [payload]) }
            return CLIResult()
        case .broker(let wire, let options, let json):
            return broker(wire, options: options, json: json)
        }
    }

    private var token: String? {
        environment[OrchestrationEnvironment.sessionToken].flatMap { $0.isEmpty ? nil : $0 }
    }

    private func broker(_ wire: String, options: [String: String], json: Bool) -> CLIResult {
        guard let token else {
            let failure = BrokerFailure(
                code: "not_sevinda_terminal",
                message: "This terminal was not opened by Sevinda, so `sevinda` cannot act for it.",
                hint: "Run it from an agent or shell session that Sevinda started.")
            return render(.failure(failure), json: json, exitCode: Exit.notSevindaTerminal)
        }
        let request = BrokerRequest(token: token, command: wire, options: options)
        do {
            let response = try transport(request, Self.timeout(for: wire))
            return render(response, json: json, exitCode: response.ok ? Exit.ok : Exit.refused)
        } catch {
            let failure = BrokerFailure(code: "unreachable", message: "\(error)",
                                        hint: "Sevinda's terminal host runs while Sevinda or its sessions do; reopen Sevinda.")
            return render(.failure(failure), json: json, exitCode: Exit.unreachable)
        }
    }

    private func render(_ response: BrokerResponse, json: Bool, exitCode: Int32) -> CLIResult {
        if json {
            let encoder = OrchestrationCoding.encoder
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
            let text = (try? encoder.encode(response)).map { String(decoding: $0, as: UTF8.self) } ?? #"{"ok":false}"#
            return CLIResult(stdout: text + "\n", exitCode: exitCode)
        }
        if let error = response.error {
            var message = "sevinda: \(error.message)\n"
            if let hint = error.hint { message += "Next: \(hint)\n" }
            return CLIResult(stderr: message, exitCode: exitCode)
        }
        let text = response.text ?? ""
        return CLIResult(stdout: text.isEmpty ? "" : text + "\n", exitCode: exitCode)
    }

    private func skill(_ name: String) -> CLIResult {
        let normalized = name.lowercased().replacingOccurrences(of: "sevinda-", with: "")
        guard normalized == "orchestration" else {
            return CLIResult(stderr: "sevinda: no skill `\(name)`.\nNext: sevinda skills get orchestration\n", exitCode: Exit.usage)
        }
        guard let file = skillsDirectory?.appendingPathComponent("sevinda-orchestration/SKILL.md"),
              let text = try? String(contentsOf: file, encoding: .utf8) else {
            return CLIResult(stderr: "sevinda: the orchestration guide is missing from the Sevinda app bundle.\n", exitCode: Exit.refused)
        }
        return CLIResult(stdout: text.hasSuffix("\n") ? text : text + "\n")
    }

    // MARK: Hooks

    /// Claude's hook JSON arrives on stdin. Only the turn signals are forwarded; everything else is dropped.
    private func claudeHook() {
        guard token != nil else { return }
        let data = readStandardInput().prefix(1 << 20)
        guard let object = try? JSONSerialization.jsonObject(with: Data(data)) as? [String: Any],
              let event = object["hook_event_name"] as? String,
              ["Stop", "UserPromptSubmit", "Notification"].contains(event) else { return }
        var options = ["event": event]
        if let type = object["notification_type"] as? String { options["notificationType"] = type }
        if let message = object["message"] as? String { options["message"] = String(message.prefix(300)) }
        _ = try? transport(BrokerRequest(token: token, command: "hook.claude", options: options), Self.hookTimeout)
    }

    /// Codex's `notify` payload: `{"type":"agent-turn-complete","thread-id":…,"turn-id":…,"cwd":…,…}`.
    private func codexNotify(payload: String) {
        guard token != nil,
              let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return }
        _ = try? transport(BrokerRequest(token: token, command: "hook.codex", options: ["type": type]), Self.hookTimeout)
    }

    public static let spawnDetached: @Sendable ([String]) -> Void = { argv in
        guard let executable = argv.first else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: Help

    static func help(topic: String?) -> String {
        if let topic, let spec = CommandSpec.all.first(where: { $0.words.joined(separator: " ") == topic || $0.words.first == topic }) {
            return "Usage: \(spec.usage)\n"
        }
        return """
        sevinda — orchestrate agents inside Sevinda (only in terminals Sevinda opened)

        Coordinator:
          \(CommandSpec.all[0].usage)
          sevinda worker list [--json]
          sevinda send --to <dispatch-id> --body <message>
          sevinda reply --id <question-id> --body <answer>
        Worker:
          sevinda ask --body <question>          then end your turn
          sevinda done --status success|failed --summary <summary>
        Both:
          sevinda inbox [--all] [--json]
          sevinda whoami [--json]
          sevinda skills get orchestration       the full guide

        Start workers, then END YOUR TURN: Sevinda types replies and results into your terminal when your turn has
        ended. Never poll or loop waiting. Every command takes --json for a stable machine-readable result.

        """
    }
}
