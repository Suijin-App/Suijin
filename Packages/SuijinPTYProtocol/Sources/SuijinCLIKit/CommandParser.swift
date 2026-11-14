import Foundation

/// What one `suijin` invocation asks for.
public enum CLICommand: Equatable, Sendable {
    /// A broker request: `command` is the wire name, `options` its validated flags.
    case broker(command: String, options: [String: String], json: Bool)
    case skill(name: String)
    case listSkills
    case claudeHook
    /// `chained`: the user's own notify program (and its arguments), run after Suijin's handling.
    case codexNotify(payload: String, chained: [String])
    case help(topic: String?)
    case version
}

/// A usage error, with the command that was probably meant.
public struct CLIUsageError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public var suggestion: String?

    public init(_ message: String, suggestion: String? = nil) {
        self.message = message
        self.suggestion = suggestion
    }

    public var description: String {
        guard let suggestion else { return message }
        return "\(message)\nDid you mean: \(suggestion)"
    }
}

/// The command table: wire name, the words that select it, its flags and the required ones.
struct CommandSpec: Sendable {
    let words: [String]
    let wire: String
    /// Flag name (without `--`) -> option key on the wire.
    let flags: [String: String]
    /// Flags that take no value.
    let switches: Set<String>
    let required: [String]
    let usage: String

    static let all: [CommandSpec] = [
        CommandSpec(words: ["worker", "start"], wire: "worker.start",
                    flags: ["spec": "spec", "agent": "agent", "worktree": "worktree", "name": "name", "account": "account",
                            "task": "spec", "prompt": "spec"],
                    switches: [], required: ["spec", "agent"],
                    usage: "suijin worker start --agent claude|codex --spec <text|@file|-> [--worktree current|new] [--name <short-name>] [--account <id>] [--json]"),
        CommandSpec(words: ["worker", "list"], wire: "worker.list", flags: [:], switches: [], required: [],
                    usage: "suijin worker list [--json]"),
        CommandSpec(words: ["worker", "stop"], wire: "worker.stop",
                    flags: ["to": "to", "dispatch": "to", "name": "to"], switches: [], required: ["to"],
                    usage: "suijin worker stop --to <dispatch-id|worker-name> [--json]"),
        CommandSpec(words: ["send"], wire: "send",
                    flags: ["to": "to", "body": "body", "message": "body", "dispatch": "to"], switches: [],
                    required: ["to", "body"], usage: "suijin send --to <dispatch-id> --body <text|@file|-> [--json]"),
        CommandSpec(words: ["ask"], wire: "ask", flags: ["body": "body", "question": "body"], switches: [],
                    required: ["body"], usage: "suijin ask --body <question> [--json]   (then end your turn)"),
        CommandSpec(words: ["reply"], wire: "reply", flags: ["id": "id", "body": "body", "answer": "body"], switches: [],
                    required: ["id", "body"], usage: "suijin reply --id <question-id> --body <answer> [--json]"),
        CommandSpec(words: ["done"], wire: "done",
                    flags: ["status": "status", "outcome": "status", "summary": "summary", "body": "summary"],
                    switches: [], required: ["status", "summary"],
                    usage: "suijin done --status success|failed --summary <what you did, found, left> [--json]"),
        CommandSpec(words: ["inbox"], wire: "inbox", flags: ["limit": "limit"], switches: ["all"], required: [],
                    usage: "suijin inbox [--all] [--limit <n>] [--json]"),
        CommandSpec(words: ["whoami"], wire: "whoami", flags: [:], switches: [], required: [],
                    usage: "suijin whoami [--json]"),
    ]

    /// Every spelling an agent may type for a command, for suggestions.
    static var allPhrases: [String] {
        all.map { $0.words.joined(separator: " ") } + ["skills get orchestration", "skills list", "help", "--version"]
    }
}

/// Parses `suijin` arguments. Flags take `--flag value` or `--flag=value`; `--json` works on every broker command.
/// A value `@path` names a file to read (when it exists), `-` reads standard input.
public struct CommandParser: Sendable {
    public var readFile: @Sendable (String) -> String?
    public var readStandardInput: @Sendable () -> String

    public init(
        readFile: @escaping @Sendable (String) -> String? = { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
            return try? String(contentsOfFile: path, encoding: .utf8)
        },
        readStandardInput: @escaping @Sendable () -> String = {
            String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
    ) {
        self.readFile = readFile
        self.readStandardInput = readStandardInput
    }

    public func parse(_ arguments: [String]) throws -> CLICommand {
        var args = arguments
        guard let first = args.first else { return .help(topic: nil) }
        switch first {
        case "help", "--help", "-h":
            return .help(topic: args.dropFirst().first)
        case "--version", "-V", "version":
            return .version
        case "skills":
            return try parseSkills(Array(args.dropFirst()))
        case "hook":
            return try parseHook(Array(args.dropFirst()))
        default:
            break
        }
        // Orca-style spellings: `worker-start`, `worker_list`, `orchestration worker-start`.
        if first == "orchestration" { args.removeFirst() }
        if args.first == "worker_done" || args.first == "worker-done" { args[0] = "done" }
        if let head = args.first, head.hasPrefix("worker-") || head.hasPrefix("worker_") {
            args.replaceSubrange(0...0, with: ["worker", String(head.dropFirst("worker-".count))])
        }
        guard let spec = CommandSpec.all.first(where: { Array(args.prefix($0.words.count)) == $0.words }) else {
            let typed = args.prefix(2).filter { !$0.hasPrefix("-") }.joined(separator: " ")
            throw CLIUsageError("Unknown command `\(typed.isEmpty ? first : typed)`.",
                                suggestion: Suggestions.closest(typed.isEmpty ? first : typed, among: CommandSpec.allPhrases).map { "suijin \($0)" })
        }
        if args.contains("--help") || args.contains("-h") { return .help(topic: spec.words.joined(separator: " ")) }
        return try parseFlags(Array(args.dropFirst(spec.words.count)), spec: spec)
    }

    private func parseFlags(_ args: [String], spec: CommandSpec) throws -> CLICommand {
        var options: [String: String] = [:]
        var json = false
        var index = 0
        while index < args.count {
            let argument = args[index]
            index += 1
            guard argument.hasPrefix("--"), argument.count > 2 else {
                throw CLIUsageError("Unexpected argument `\(argument)`; values follow a flag.", suggestion: spec.usage)
            }
            var name = String(argument.dropFirst(2))
            var inlineValue: String?
            if let equals = name.firstIndex(of: "=") {
                inlineValue = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            if name == "json" {
                json = true
                continue
            }
            if spec.switches.contains(name) {
                options[name] = "true"
                continue
            }
            guard let key = spec.flags[name] else {
                let known = Array(spec.flags.keys) + Array(spec.switches) + ["json"]
                throw CLIUsageError("Unknown flag `--\(name)` for `suijin \(spec.words.joined(separator: " "))`.",
                                    suggestion: Suggestions.closest(name, among: known).map { "--\($0)" } ?? spec.usage)
            }
            let raw: String
            if let inlineValue {
                raw = inlineValue
            } else {
                guard index < args.count else { throw CLIUsageError("`--\(name)` needs a value.", suggestion: spec.usage) }
                raw = args[index]
                index += 1
            }
            options[key] = resolve(raw)
        }
        for key in spec.required where (options[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIUsageError("Missing `--\(key)`.", suggestion: spec.usage)
        }
        if spec.wire == "worker.start" {
            if let agent = options["agent"], !["claude", "codex"].contains(agent.lowercased()) {
                throw CLIUsageError("`--agent` must be `claude` or `codex`.", suggestion: spec.usage)
            }
            if let mode = options["worktree"], !["current", "new"].contains(mode.lowercased()) {
                throw CLIUsageError("`--worktree` must be `current` or `new`.",
                                    suggestion: mode.lowercased().hasPrefix("new") ? "--worktree new" : spec.usage)
            }
        }
        if spec.wire == "done", let status = options["status"],
           !["success", "succeeded", "failed", "failure"].contains(status.lowercased()) {
            throw CLIUsageError("`--status` must be `success` or `failed`.", suggestion: spec.usage)
        }
        if spec.wire == "inbox", let limit = options["limit"], Int(limit).map({ $0 > 0 }) != true {
            throw CLIUsageError("`--limit` must be a positive number.", suggestion: spec.usage)
        }
        return .broker(command: spec.wire, options: options, json: json)
    }

    /// `@path` reads the file when it exists (otherwise the text is literal, e.g. "@user"); `-` reads stdin.
    private func resolve(_ raw: String) -> String {
        if raw == "-" { return readStandardInput() }
        if raw.hasPrefix("@"), raw.count > 1, let contents = readFile(String(raw.dropFirst())) { return contents }
        return raw
    }

    private func parseSkills(_ args: [String]) throws -> CLICommand {
        switch args.first {
        case "get":
            guard let name = args.dropFirst().first else {
                throw CLIUsageError("Missing skill name.", suggestion: "suijin skills get orchestration")
            }
            return .skill(name: name)
        case "list", nil:
            return .listSkills
        default:
            throw CLIUsageError("Unknown `skills` command `\(args[0])`.", suggestion: "suijin skills get orchestration")
        }
    }

    private func parseHook(_ args: [String]) throws -> CLICommand {
        switch args.first {
        case "claude":
            return .claudeHook
        case "codex-notify":
            // Codex appends the JSON payload as the last argument: `hook codex-notify [-- program args…] <payload>`.
            var rest = Array(args.dropFirst())
            guard let payload = rest.popLast() else { throw CLIUsageError("Missing notify payload.") }
            if rest.first == "--" { rest.removeFirst() }
            return .codexNotify(payload: payload, chained: rest)
        default:
            throw CLIUsageError("Unknown hook `\(args.first ?? "")`.")
        }
    }
}

/// "Did you mean" for mistyped commands and flags (edit distance, at most 3).
enum Suggestions {
    static func closest(_ input: String, among candidates: [String]) -> String? {
        let typed = input.lowercased()
        guard !typed.isEmpty else { return nil }
        let limit = max(1, min(3, typed.count / 2))
        var best: (candidate: String, score: Int)?
        for candidate in candidates.sorted() {
            let score = distance(typed, candidate.lowercased())
            guard score <= limit, score < (best?.score ?? Int.max) else { continue }
            best = (candidate, score)
        }
        if let best { return best.candidate }
        // A typed prefix of one command ("worker" → "worker start").
        return candidates.first { $0.lowercased().hasPrefix(typed + " ") || $0.lowercased().hasPrefix(typed) }
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
