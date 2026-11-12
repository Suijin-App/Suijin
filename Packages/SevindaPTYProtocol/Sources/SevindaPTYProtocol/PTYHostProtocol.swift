import Foundation

/// Names and versions shared by the app and the PTY host helper.
public enum PTYHostConstants {
    /// Mach service of the launchd agent Sevinda registers (the LaunchAgent plist `MachServices` key).
    public static let defaultMachServiceName = "com.tekmium.sevinda.ptyhost"
    /// Environment variable naming another helper instance, for tests that must not share the user's helper (an
    /// end-to-end run with a newer protocol while the user's own sessions keep the installed helper busy). Only names
    /// below `defaultMachServiceName` are honored.
    public static let machServiceOverrideEnv = "SEVINDA_PTYHOST_SERVICE"
    /// The Mach service the app connects to and the helper listens on.
    public static let machServiceName: String = resolveMachServiceName(environment: ProcessInfo.processInfo.environment)
    /// The oldest app protocol a helper still serves; such an app simply never calls the newer methods.
    public static let minimumCompatibleProtocolVersion = 2
    /// File name of the LaunchAgent plist inside `Sevinda.app/Contents/Library/LaunchAgents`.
    public static let launchAgentPlist = "com.tekmium.sevinda.ptyhost.plist"
    /// Bumped whenever the XPC surface or a JSON payload changes incompatibly.
    /// 2: `ack` flow control (the helper streams at most a window of unacknowledged bytes per attachment).
    /// 3: `orchestrationEndpoint` (the agent orchestration broker lives in the helper).
    public static let protocolVersion: Int = 3

    public static func resolveMachServiceName(environment: [String: String]) -> String {
        guard let override = environment[machServiceOverrideEnv], override.hasPrefix(defaultMachServiceName + "."),
              override.count <= 128,
              override.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
        else { return defaultMachServiceName }
        return override
    }

    /// Whether an app can work with a helper that answered `hostVersion`: any version from
    /// `minimumCompatibleProtocolVersion` up to the app's own. Against an older helper the app uses only that
    /// version's features (no orchestration below 3) until the helper is replaced once it is idle.
    public static func isCompatible(hostVersion: Int) -> Bool {
        (minimumCompatibleProtocolVersion...protocolVersion).contains(hostVersion)
    }

    /// The version the helper answers a client with: the client's own when the helper still speaks it, so an app one
    /// version behind keeps working with a newer helper; otherwise the helper's, which the client rejects.
    public static func negotiatedVersion(clientVersion: Int) -> Int {
        (minimumCompatibleProtocolVersion...protocolVersion).contains(clientVersion) ? clientVersion : protocolVersion
    }
}

/// Everything the helper needs to start one process on a new pseudo terminal.
public struct PTYSpawnRequest: Codable, Sendable, Hashable {
    /// Absolute path, or a bare name resolved against `PATH` from `environment`.
    public var executable: String
    /// Arguments after `argv[0]` (the helper passes `executable` as `argv[0]`).
    public var arguments: [String]
    /// The complete environment of the child; nothing is inherited from the helper. A bare `executable` is resolved
    /// against its `PATH` (default `/usr/bin:/bin:/usr/sbin:/sbin`).
    public var environment: [String: String]
    public var cwd: String
    public var cols: Int
    public var rows: Int
    /// Opaque key/value pairs the app attaches to a session (e.g. its own session UUID); persisted by the helper.
    public var metadata: [String: String]

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        cwd: String,
        cols: Int = 80,
        rows: Int = 24,
        metadata: [String: String] = [:]
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.metadata = metadata
    }
}

/// A snapshot of one helper session, as returned by `listSessions` and `attach`.
public struct PTYSessionInfo: Codable, Sendable, Hashable {
    public var id: String
    public var pid: Int32
    public var executable: String
    public var cwd: String
    public var startedAt: Date
    public var isRunning: Bool
    /// Exit code for a normal exit, `128 + signal` for a signal death, nil while running or when unknown
    /// (a session left over from a previous helper process).
    public var exitStatus: Int32?
    public var metadata: [String: String]

    public init(
        id: String,
        pid: Int32,
        executable: String,
        cwd: String,
        startedAt: Date,
        isRunning: Bool,
        exitStatus: Int32?,
        metadata: [String: String]
    ) {
        self.id = id
        self.pid = pid
        self.executable = executable
        self.cwd = cwd
        self.startedAt = startedAt
        self.isRunning = isRunning
        self.exitStatus = exitStatus
        self.metadata = metadata
    }
}

/// JSON coding used for every payload that crosses the XPC boundary or is persisted by the helper.
public enum PTYCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }
}

/// Exported by the helper. All structured payloads are JSON `Data` for forward compatibility.
@objc public protocol PTYHostXPC {
    func handshake(clientProtocolVersion: Int, reply: @escaping @Sendable (_ hostProtocolVersion: Int, _ hostBuild: String) -> Void)
    /// Replies with JSON `[PTYSessionInfo]`.
    func listSessions(reply: @escaping @Sendable (Data) -> Void)
    /// `request` is JSON `PTYSpawnRequest`. Replies with the new session id, or nil and an error description.
    func spawn(_ request: Data, reply: @escaping @Sendable (_ sessionID: String?, _ error: String?) -> Void)
    /// Replies with the scrollback and JSON `PTYSessionInfo` (both nil for an unknown session). The host then sends
    /// an empty `PTYClientXPC.output` as the stream-start marker, followed by every byte produced after the scrollback
    /// snapshot, with no gap and no duplication; `exited` follows the last output byte. XPC does not order a reply
    /// relative to incoming messages, but it does order messages: bytes before the marker belong to an earlier
    /// attachment and must be dropped, bytes after it continue the returned scrollback.
    func attach(_ sessionID: String, reply: @escaping @Sendable (_ scrollback: Data?, _ info: Data?) -> Void)
    func detach(_ sessionID: String)
    func write(_ sessionID: String, data: Data)
    func resize(_ sessionID: String, cols: Int, rows: Int)
    /// SIGHUP to the process group, wait 2 s, then SIGKILL the process group.
    func terminate(_ sessionID: String)
    /// Exits the helper when no session is running (used after a protocol version mismatch).
    func shutdownIfIdle()
    /// The app has consumed (fed to its emulator, or dropped) `bytes` of streamed output for `sessionID`. Refills the
    /// attachment's send window; when the window is exhausted the helper stops reading the PTY, so a slow app blocks
    /// the child the way a real terminal does. Apps batch these (e.g. every 64 KB or 16 ms).
    func ack(_ sessionID: String, bytes: Int)
    /// Protocol 3. The orchestration broker of `dataRoot`: an endpoint the app connects to with
    /// `OrchestrationXPCInterfaces` (it executes worker starts and shows the state), or nil and an error description.
    func orchestrationEndpoint(dataRoot: String, reply: @escaping @Sendable (NSXPCListenerEndpoint?, String?) -> Void)
}

/// Exported by the app on the same connection; receives the live stream of attached sessions.
@objc public protocol PTYClientXPC {
    func output(_ sessionID: String, data: Data)
    func exited(_ sessionID: String, status: Int32)
}

public enum PTYXPCInterfaces {
    public static func host() -> NSXPCInterface {
        NSXPCInterface(with: PTYHostXPC.self)
    }

    public static func client() -> NSXPCInterface {
        NSXPCInterface(with: PTYClientXPC.self)
    }
}
