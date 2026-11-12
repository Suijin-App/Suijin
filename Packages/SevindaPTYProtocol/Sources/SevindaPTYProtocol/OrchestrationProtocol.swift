import Darwin
import Foundation

// Agent orchestration: a coordinator agent starts worker agents with the `sevinda` CLI, they exchange messages, and
// the broker in the PTY host delivers each message when the receiving agent ends its turn. This file holds what the
// broker (helper), the CLI and the app share: environment names, paths, the stored records, the CLI wire format and
// the XPC interfaces between the broker and the app.

/// Environment variables Sevinda sets in every terminal it opens.
public enum OrchestrationEnvironment {
    /// The app's session UUID (`AgentSessionRecord.id`).
    public static let sessionID = "SEVINDA_SESSION_ID"
    /// A random secret per session. The broker identifies a caller by it, never by what the caller claims. Never logged.
    public static let sessionToken = "SEVINDA_SESSION_TOKEN"
    /// The broker's Unix socket.
    public static let socket = "SEVINDA_ORCH_SOCKET"
    /// The broker's file drop box, for callers a sandbox keeps off the socket (Codex's `workspace-write`).
    public static let spool = "SEVINDA_ORCH_SPOOL"
    /// Absolute path of the bundled `sevinda` executable (hooks call it even when `PATH` was rewritten).
    public static let cli = "SEVINDA_CLI"
    public static let dataRoot = "SEVINDA_DATA_ROOT"
}

/// Session tokens: the app issues one per terminal and passes it only in that terminal's environment.
public enum OrchestrationToken {
    /// 32 random bytes from the system generator, hex encoded.
    public static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}

/// Session metadata keys the app attaches to every launch (`PTYSpawnRequest.metadata`).
public enum OrchestrationMetadata {
    public static let session = "sevinda.session"
    public static let dataRoot = "sevinda.dataRoot"
    public static let agent = "agent"
}

/// Where a data root's broker keeps its state and listens.
public enum OrchestrationPaths {
    /// `sun_path` holds 104 bytes including the terminating NUL.
    public static let socketPathByteLimit = 103

    /// `<dataRoot>/orchestration`: the state file and, when the path is short enough, the socket. Mode 700.
    public static func directory(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("orchestration", isDirectory: true)
    }

    /// The durable state, owned by the helper alone (the app never writes it).
    public static func stateFile(dataRoot: URL) -> URL {
        directory(dataRoot: dataRoot).appendingPathComponent("state.json", isDirectory: false)
    }

    /// `<dataRoot>/orchestration/broker.sock`, or a socket in the user's private temporary directory when that path
    /// does not fit `sun_path` (deep test data roots).
    public static func socketPath(dataRoot: URL) -> String {
        let preferred = directory(dataRoot: dataRoot).appendingPathComponent("broker.sock").path
        if preferred.utf8.count <= socketPathByteLimit { return preferred }
        return runtimeDirectory(dataRoot: dataRoot).appendingPathComponent("broker.sock").path
    }

    /// The drop box: `requests/` and `responses/` below it. It lives in the user's temporary directory because
    /// Codex's default sandbox may write there but may not connect to Unix sockets.
    public static func spoolDirectory(dataRoot: URL) -> URL {
        runtimeDirectory(dataRoot: dataRoot).appendingPathComponent("spool", isDirectory: true)
    }

    /// `<user temporary directory>/sevinda-orch-<hash of the data root>`. The per-user temporary directory is 700 and
    /// the same for every process of the user (the app, the helper and the agents).
    public static func runtimeDirectory(dataRoot: URL) -> URL {
        userTemporaryDirectory().appendingPathComponent("sevinda-orch-\(dataRootHash(dataRoot))", isDirectory: true)
    }

    /// The standardized data root path the broker is keyed by.
    public static func key(dataRoot: URL) -> String {
        dataRoot.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func dataRootHash(_ dataRoot: URL) -> String {
        // FNV-1a 64: stable across processes and launches, unlike `Hasher`.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key(dataRoot: dataRoot).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// `confstr(_CS_DARWIN_USER_TEMP_DIR)`, falling back to `NSTemporaryDirectory()`.
    public static func userTemporaryDirectory() -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        if length > 0, length <= buffer.count {
            let path = String(decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }
}

// MARK: Records

/// The agent a worker runs.
public enum OrchestrationAgent: String, Codable, Sendable, CaseIterable, Hashable {
    case claude, codex
}

/// Where a worker runs: the coordinator's own folder or worktree, or a new worktree of the same repository.
public enum WorktreeMode: String, Codable, Sendable, CaseIterable, Hashable {
    case current, new
}

/// One coordinator session's orchestration: every worker it started belongs to it.
public struct OrchestrationRun: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var coordinatorSessionID: String
    public var createdAt: Date

    public init(id: String, coordinatorSessionID: String, createdAt: Date) {
        self.id = id
        self.coordinatorSessionID = coordinatorSessionID
        self.createdAt = createdAt
    }
}

/// A piece of work: the spec a worker received. A message sent to a finished worker becomes a follow-up Task.
public struct OrchestrationTask: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var runID: String
    public var spec: String
    /// The Task this one continues (a follow-up sent to a finished worker).
    public var followUpOf: String?
    public var createdAt: Date

    public init(id: String, runID: String, spec: String, followUpOf: String? = nil, createdAt: Date) {
        self.id = id
        self.runID = runID
        self.spec = spec
        self.followUpOf = followUpOf
        self.createdAt = createdAt
    }
}

/// Where a dispatch stands.
public enum DispatchStatus: String, Codable, Sendable, CaseIterable, Hashable {
    /// Waiting for Sevinda (the app) to start the worker; no app is connected.
    case queued
    /// The app is starting the worker.
    case starting
    case running
    /// The worker asked a question that has no reply yet.
    case asking
    /// The worker ended a turn without `done`; it is still alive and can be steered with `send`.
    case stalled
    /// `done --status success`.
    case succeeded
    /// `done --status failed`.
    case failed
    /// The worker's process ended without `done`.
    case exited
    /// The worker could not be started.
    case startFailed

    /// No further report will come from this dispatch.
    public var isSettled: Bool {
        switch self {
        case .succeeded, .failed, .exited, .startFailed: true
        case .queued, .starting, .running, .asking, .stalled: false
        }
    }
}

/// A Task assigned to one worker session.
public struct OrchestrationDispatch: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var taskID: String
    public var runID: String
    public var coordinatorSessionID: String
    /// The worker's app session UUID, once the app started it.
    public var workerSessionID: String?
    /// Short human name (`--name`, or derived from the spec).
    public var name: String
    public var agent: OrchestrationAgent
    public var worktree: WorktreeMode
    public var accountID: String?
    public var status: DispatchStatus
    /// The worker's `done` summary.
    public var summary: String?
    /// Why the start failed, or how the process ended.
    public var lastError: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String, taskID: String, runID: String, coordinatorSessionID: String, workerSessionID: String? = nil,
        name: String, agent: OrchestrationAgent, worktree: WorktreeMode, accountID: String? = nil,
        status: DispatchStatus, summary: String? = nil, lastError: String? = nil, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.taskID = taskID
        self.runID = runID
        self.coordinatorSessionID = coordinatorSessionID
        self.workerSessionID = workerSessionID
        self.name = name
        self.agent = agent
        self.worktree = worktree
        self.accountID = accountID
        self.status = status
        self.summary = summary
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum MessageKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// Coordinator → worker (`send`), or a follow-up Task for a finished worker.
    case send
    /// Worker → coordinator (`ask`).
    case question
    /// Coordinator → worker (`reply`).
    case reply
    /// Worker → coordinator (`done`).
    case done
    /// Broker → coordinator: a worker stopped or exited without `done`, or could not start.
    case escalation
}

public enum MessageStatus: String, Codable, Sendable, Hashable {
    /// Waits for the recipient to end its turn.
    case pending
    /// Typed into the recipient's terminal (exactly once).
    case delivered
    /// The recipient's terminal ended before it could be delivered.
    case undeliverable
}

public struct OrchestrationMessage: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var runID: String
    public var dispatchID: String
    public var kind: MessageKind
    /// The sender's session, nil for the broker's own escalations.
    public var fromSessionID: String?
    public var toSessionID: String
    public var body: String
    /// For a reply: the question it answers.
    public var inReplyTo: String?
    /// For a question: the reply that answered it.
    public var answeredBy: String?
    /// For a follow-up `send` to a finished worker: the Task it became.
    public var followUpTaskID: String?
    public var status: MessageStatus
    public var createdAt: Date
    public var deliveredAt: Date?

    public init(
        id: String, runID: String, dispatchID: String, kind: MessageKind, fromSessionID: String?, toSessionID: String,
        body: String, inReplyTo: String? = nil, answeredBy: String? = nil, followUpTaskID: String? = nil,
        status: MessageStatus = .pending, createdAt: Date, deliveredAt: Date? = nil
    ) {
        self.id = id
        self.runID = runID
        self.dispatchID = dispatchID
        self.kind = kind
        self.fromSessionID = fromSessionID
        self.toSessionID = toSessionID
        self.body = body
        self.inReplyTo = inReplyTo
        self.answeredBy = answeredBy
        self.followUpTaskID = followUpTaskID
        self.status = status
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
    }
}

/// Everything the broker stores for one data root; also what the app's sidebar and inspector read.
public struct OrchestrationSnapshot: Codable, Sendable, Hashable {
    public var runs: [OrchestrationRun]
    public var tasks: [OrchestrationTask]
    public var dispatches: [OrchestrationDispatch]
    public var messages: [OrchestrationMessage]

    public init(runs: [OrchestrationRun] = [], tasks: [OrchestrationTask] = [], dispatches: [OrchestrationDispatch] = [],
                messages: [OrchestrationMessage] = []) {
        self.runs = runs
        self.tasks = tasks
        self.dispatches = dispatches
        self.messages = messages
    }
}

// MARK: CLI wire format

/// One CLI request: one JSON object on one line, over the socket or as a file in the spool's `requests/`.
public struct BrokerRequest: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public var version: Int
    /// Correlates a spool response with its request; random per call.
    public var id: String
    /// The caller's `SEVINDA_SESSION_TOKEN`.
    public var token: String?
    /// `worker.start`, `worker.list`, `send`, `ask`, `reply`, `done`, `inbox`, `hook.claude`, `hook.codex`, `whoami`.
    public var command: String
    public var options: [String: String]

    public init(id: String = UUID().uuidString, token: String?, command: String, options: [String: String] = [:]) {
        self.version = Self.currentVersion
        self.id = id
        self.token = token
        self.command = command
        self.options = options
    }
}

/// Why a request failed; `hint` names the command that would work.
public struct BrokerFailure: Codable, Sendable, Hashable, Error {
    public var code: String
    public var message: String
    public var hint: String?

    public init(code: String, message: String, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
    }
}

/// The answer to one request. `--json` prints it as is; otherwise the CLI prints `text` or the failure.
public struct BrokerResponse: Codable, Sendable, Hashable {
    public var ok: Bool
    public var result: JSONValue?
    /// The human-readable outcome, written for an agent: what happened and what to do next.
    public var text: String?
    public var error: BrokerFailure?

    public init(ok: Bool, result: JSONValue? = nil, text: String? = nil, error: BrokerFailure? = nil) {
        self.ok = ok
        self.result = result
        self.text = text
        self.error = error
    }

    public static func success<T: Encodable>(_ value: T, text: String) -> BrokerResponse {
        BrokerResponse(ok: true, result: (try? JSONValue(encoding: value)) ?? .null, text: text)
    }

    public static func failure(_ failure: BrokerFailure) -> BrokerResponse {
        BrokerResponse(ok: false, error: failure)
    }
}

/// Any JSON value, so a response can carry each command's own result type.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(encoding value: some Encodable) throws {
        let data = try OrchestrationCoding.encoder.encode(value)
        self = try OrchestrationCoding.decoder.decode(JSONValue.self, from: data)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

/// JSON coding for everything orchestration stores or sends: ISO 8601 dates, sorted keys (stable `--json`).
public enum OrchestrationCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: Broker ↔ app

/// The broker asks the app to start a worker: the app owns worktrees, accounts and the launch environment.
public struct WorkerLaunchRequest: Codable, Sendable, Hashable {
    public var dispatchID: String
    public var coordinatorSessionID: String
    public var agent: OrchestrationAgent
    public var worktree: WorktreeMode
    public var name: String
    public var accountID: String?
    /// The worker's first prompt: the preamble with Task and Dispatch IDs, then the spec.
    public var prompt: String

    public init(dispatchID: String, coordinatorSessionID: String, agent: OrchestrationAgent, worktree: WorktreeMode,
                name: String, accountID: String?, prompt: String) {
        self.dispatchID = dispatchID
        self.coordinatorSessionID = coordinatorSessionID
        self.agent = agent
        self.worktree = worktree
        self.name = name
        self.accountID = accountID
        self.prompt = prompt
    }
}

/// The app's answer to a `WorkerLaunchRequest`.
public struct WorkerLaunchResult: Codable, Sendable, Hashable {
    public var dispatchID: String
    /// The worker's app session UUID; nil when the start failed.
    public var workerSessionID: String?
    /// The worker's folder (a new worktree's path).
    public var directory: String?
    public var error: String?

    public init(dispatchID: String, workerSessionID: String?, directory: String? = nil, error: String? = nil) {
        self.dispatchID = dispatchID
        self.workerSessionID = workerSessionID
        self.directory = directory
        self.error = error
    }
}

/// Something the user should look at: the coordinator waits for a decision only they can make.
public struct OrchestrationAttention: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// The coordinator waits on a permission prompt.
        case permission
        /// The coordinator ended its turn with a worker's question unanswered: it is asking the user.
        case decision
    }

    public var sessionID: String
    public var kind: Kind
    /// What the coordinator is waiting for (the permission prompt, or the worker's question).
    public var body: String

    public init(sessionID: String, kind: Kind, body: String) {
        self.sessionID = sessionID
        self.kind = kind
        self.body = body
    }
}

/// Exported by the helper on the connection made to `PTYHostXPC.orchestrationEndpoint`. Payloads are JSON.
@objc public protocol OrchestrationHostXPC {
    /// Registers the connection as the data root's app: worker starts go to it from now on (queued ones right away).
    func hello(appBuild: String, reply: @escaping @Sendable (_ accepted: Bool) -> Void)
    /// Replies with JSON `OrchestrationSnapshot`.
    func snapshot(reply: @escaping @Sendable (Data) -> Void)
    /// JSON `WorkerLaunchResult`.
    func workerStartFinished(_ result: Data)
}

/// Exported by the app on the same connection.
@objc public protocol OrchestrationClientXPC {
    /// JSON `WorkerLaunchRequest`; the app answers with `OrchestrationHostXPC.workerStartFinished`.
    func startWorker(_ request: Data)
    /// The stored state changed; the app fetches a new snapshot.
    func stateChanged()
    /// JSON `OrchestrationAttention`: post a notification.
    func attention(_ event: Data)
}

public enum OrchestrationXPCInterfaces {
    public static func host() -> NSXPCInterface {
        NSXPCInterface(with: OrchestrationHostXPC.self)
    }

    public static func client() -> NSXPCInterface {
        NSXPCInterface(with: OrchestrationClientXPC.self)
    }
}

/// Short random identifiers agents can type: `<prefix>-<8 hex digits>`.
public enum OrchestrationID {
    public static func make(_ prefix: String) -> String {
        "\(prefix)-\(String(format: "%08x", UInt32.random(in: 0...UInt32.max)))"
    }

    /// Accepts `d-1a2b3c4d`, `dispatch:d-1a2b3c4d` and surrounding whitespace.
    public static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["dispatch:", "message:", "task:", "run:"] where value.lowercased().hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        return value.lowercased()
    }
}
