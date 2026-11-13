import Foundation
import SuijinPTYProtocol
import os
import ServiceManagement
import Synchronization

/// Why a call to the PTY host failed.
public enum PTYHostClientError: Error, LocalizedError, Equatable, Sendable {
    /// The user has to allow Suijin's background item in System Settings > General > Login Items.
    case requiresApproval
    /// The LaunchAgent plist is missing from the app bundle.
    case notFound
    case registrationFailed(String)
    /// The running helper speaks another protocol version (typically an old helper after an app update). It was asked
    /// to exit when idle; the next call reconnects.
    case protocolMismatch(host: Int, client: Int)
    case connectionFailed(String)
    case timedOut
    case spawnFailed(String)
    case sessionNotFound(String)
    case invalidReply

    public var errorDescription: String? {
        switch self {
        case .requiresApproval:
            "Suijin's terminal host needs approval in System Settings > General > Login Items."
        case .notFound: "The terminal host is missing from the Suijin app bundle."
        case .registrationFailed(let reason): "Could not register the terminal host: \(reason)"
        case .protocolMismatch(let host, let client):
            "The running terminal host speaks protocol \(host), this app needs \(client). Quit sessions to update it."
        case .connectionFailed(let reason): "Lost the connection to the terminal host: \(reason)"
        case .timedOut: "The terminal host did not answer in time."
        case .spawnFailed(let reason): "Could not start the terminal process: \(reason)"
        case .sessionNotFound(let id): "The terminal session \(id) no longer exists."
        case .invalidReply: "The terminal host sent an invalid reply."
        }
    }
}

/// The app's end of the XPC connection to the PTY host helper.
///
/// Owns one `NSXPCConnection` (created lazily by `connectionFactory`), performs the protocol handshake before any other
/// call, routes streamed output and exits to the `HostedTerminalEngine` attached to each session, and recovers
/// attached engines when the helper connection is interrupted. All XPC callbacks are moved to the main queue with
/// `DispatchQueue.main.async`, which is FIFO, so per-session ordering from the helper is preserved.
@MainActor public final class PTYHostClient {
    public static let shared = PTYHostClient(connectionFactory: {
        NSXPCConnection(machServiceName: PTYHostConstants.machServiceName, options: [])
    })

    private nonisolated static let logger = Logger(subsystem: "com.tekmium.suijin", category: "pty-host-client")

    /// Applies to every request that expects a reply.
    public var requestTimeout: TimeInterval = 10
    /// Build string reported by the helper in the last successful handshake.
    public private(set) var hostBuild: String?
    /// Protocol version the helper answered in the last successful handshake. An older helper that is still
    /// compatible (it keeps the user's running sessions) is used with its own feature set.
    public private(set) var hostProtocolVersion: Int?

    private let connectionFactory: () -> NSXPCConnection
    private var connection: NSXPCConnection?
    private var hostProxy: (any PTYHostXPC)?
    private var handshakeTask: Task<Void, any Error>?
    private var engines: [String: WeakEngine] = [:]
    /// Consumed bytes not yet reported to the helper, per session (batched: 64 KB or 16 ms).
    private var pendingAcks: [String: Int] = [:]
    private var ackFlushScheduled = false
    private static let ackBatchBytes = 64 * 1024
    private static let ackBatchDelay: TimeInterval = 0.016

    private struct WeakEngine {
        weak var engine: HostedTerminalEngine?
    }

    public init(connectionFactory: @escaping () -> NSXPCConnection) {
        self.connectionFactory = connectionFactory
    }

    // MARK: Registration

    /// Registers the helper's LaunchAgent with launchd (`SMAppService.agent`). Safe to call on every launch.
    public func register() throws {
        let service = SMAppService.agent(plistName: PTYHostConstants.launchAgentPlist)
        switch service.status {
        case .enabled: return
        case .requiresApproval: throw PTYHostClientError.requiresApproval
        case .notRegistered, .notFound: break
        @unknown default: break
        }
        do {
            try service.register()
        } catch {
            let code = (error as NSError).code
            if code == Int(kSMErrorAlreadyRegistered), service.status == .enabled { return }
            if code == Int(kSMErrorLaunchDeniedByUser) || service.status == .requiresApproval {
                throw PTYHostClientError.requiresApproval
            }
            throw PTYHostClientError.registrationFailed(error.localizedDescription)
        }
        switch service.status {
        case .enabled: return
        case .requiresApproval: throw PTYHostClientError.requiresApproval
        case .notFound: throw PTYHostClientError.notFound
        case .notRegistered: throw PTYHostClientError.registrationFailed("launchd reports the agent as not registered")
        @unknown default: throw PTYHostClientError.registrationFailed("unknown status \(service.status.rawValue)")
        }
    }

    // MARK: Requests

    /// Connects and checks the protocol version; other calls do this implicitly.
    @discardableResult
    public func handshake() async throws -> String {
        _ = try await readyConnection()
        return hostBuild ?? ""
    }

    public func listSessions() async throws -> [PTYSessionInfo] {
        let connection = try await readyConnection()
        let data: Data = try await call(connection) { host, finish in
            host.listSessions { finish($0) }
        }
        do {
            return try PTYCoding.decode([PTYSessionInfo].self, from: data)
        } catch {
            throw PTYHostClientError.invalidReply
        }
    }

    public func spawn(_ request: PTYSpawnRequest) async throws -> String {
        let connection = try await readyConnection()
        let payload = try PTYCoding.encode(request)
        let (sessionID, error): (String?, String?) = try await call(connection) { host, finish in
            host.spawn(payload) { finish(($0, $1)) }
        }
        guard let sessionID else { throw PTYHostClientError.spawnFailed(error ?? "unknown error") }
        return sessionID
    }

    /// Attaches `engine` to `sessionID`. Output for the session is routed to the engine from the moment the request is
    /// sent; the engine finds the new stream's start by the helper's empty marker message.
    func attach(_ sessionID: String, engine: HostedTerminalEngine) async throws -> (scrollback: Data, info: PTYSessionInfo) {
        let connection = try await readyConnection()
        engines[sessionID] = WeakEngine(engine: engine)
        let reply: (Data?, Data?)
        do {
            reply = try await call(connection) { host, finish in
                host.attach(sessionID) { scrollback, info in finish((scrollback, info)) }
            }
        } catch {
            // A reply that comes after a timeout would leave a live attachment streaming to nobody.
            if engines[sessionID]?.engine === engine { detach(sessionID) }
            throw error
        }
        guard let scrollback = reply.0, let infoData = reply.1 else {
            unregister(sessionID, engine: engine)
            throw PTYHostClientError.sessionNotFound(sessionID)
        }
        guard let info = try? PTYCoding.decode(PTYSessionInfo.self, from: infoData) else {
            if engines[sessionID]?.engine === engine { detach(sessionID) }
            throw PTYHostClientError.invalidReply
        }
        return (scrollback, info)
    }

    /// Stops streaming `sessionID` to this app; the session keeps running in the helper.
    public func detach(_ sessionID: String) {
        engines[sessionID] = nil
        pendingAcks[sessionID] = nil
        hostProxy?.detach(sessionID)
    }

    /// Reports consumed output so the helper refills the session's send window. Batched per session: sent once 64 KB
    /// accumulate, otherwise within 16 ms (the window is far larger, so interactive echo never waits for it).
    public func acknowledge(_ sessionID: String, bytes: Int) {
        guard bytes > 0 else { return }
        let total = pendingAcks[sessionID, default: 0] + bytes
        if total >= Self.ackBatchBytes {
            pendingAcks[sessionID] = nil
            hostProxy?.ack(sessionID, bytes: total)
            return
        }
        pendingAcks[sessionID] = total
        guard !ackFlushScheduled else { return }
        ackFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ackBatchDelay) { [weak self] in
            MainActor.assumeIsolated { self?.flushAcks() }
        }
    }

    private func flushAcks() {
        ackFlushScheduled = false
        let acks = pendingAcks
        pendingAcks.removeAll()
        for (sessionID, bytes) in acks { hostProxy?.ack(sessionID, bytes: bytes) }
    }

    public func write(_ sessionID: String, data: Data) {
        hostProxy?.write(sessionID, data: data)
    }

    public func resize(_ sessionID: String, cols: Int, rows: Int) {
        hostProxy?.resize(sessionID, cols: cols, rows: rows)
    }

    /// SIGHUP, then SIGKILL after 2 s, to the session's process group. The exit arrives through the engine.
    public func terminate(_ sessionID: String) {
        hostProxy?.terminate(sessionID)
    }

    /// Asks the helper to exit if no session is running.
    public func shutdownHostIfIdle() {
        hostProxy?.shutdownIfIdle()
    }

    /// Drops the connection without touching the sessions (they keep running in the helper).
    public func disconnect() {
        guard let connection else { return }
        dropConnection(connection)
    }

    func unregister(_ sessionID: String, engine: HostedTerminalEngine) {
        if engines[sessionID]?.engine === engine { engines[sessionID] = nil }
    }

    // MARK: Connection

    private func readyConnection() async throws -> NSXPCConnection {
        if let connection, hostProxy != nil { return connection }
        if let handshakeTask {
            // Another caller is already handshaking; share its outcome.
            try await handshakeTask.value
            guard let connection, hostProxy != nil else { throw PTYHostClientError.connectionFailed("handshake failed") }
            return connection
        }

        let connection = self.connection ?? makeConnection()
        let task = Task { @MainActor in try await self.performHandshake(on: connection) }
        handshakeTask = task
        defer { handshakeTask = nil }
        try await task.value
        return connection
    }

    private func performHandshake(on connection: NSXPCConnection) async throws {
        let clientVersion = PTYHostConstants.protocolVersion
        let version: Int
        let build: String
        do {
            (version, build) = try await call(connection) { host, finish in
                host.handshake(clientProtocolVersion: clientVersion) { finish(($0, $1)) }
            }
        } catch {
            dropConnection(connection)
            throw error
        }
        guard PTYHostConstants.isCompatible(hostVersion: version) else {
            Self.logger.error("PTY host protocol \(version) does not match \(clientVersion); asking it to exit when idle")
            (connection.remoteObjectProxy as? any PTYHostXPC)?.shutdownIfIdle()
            dropConnection(connection)
            throw PTYHostClientError.protocolMismatch(host: version, client: clientVersion)
        }
        guard self.connection === connection else { throw PTYHostClientError.connectionFailed("connection replaced") }
        hostBuild = build
        hostProtocolVersion = version
        if version < clientVersion {
            Self.logger.notice("PTY host speaks protocol \(version) (app \(clientVersion)); newer features stay off until it is replaced")
        }
        // XPC calls these handlers on its own queue: they must not inherit the client's main-actor isolation, or Swift's
        // runtime check stops the app the first time one fires (`@Sendable` keeps them nonisolated).
        hostProxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
            // Fire-and-forget calls: failures surface as interruption or invalidation.
            Self.logger.debug("PTY host message failed: \(error.localizedDescription, privacy: .public)")
        } as? any PTYHostXPC
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = connectionFactory()
        let identity = ObjectIdentifier(connection)
        connection.remoteObjectInterface = PTYXPCInterfaces.host()
        connection.exportedInterface = PTYXPCInterfaces.client()
        connection.exportedObject = PTYClientReceiver(
            output: { [weak self] sessionID, data in
                guard let self else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.routeOutput(sessionID, data: data) } }
            },
            exited: { [weak self] sessionID, status in
                guard let self else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.routeExit(sessionID, status: status) } }
            }
        )
        connection.interruptionHandler = { @Sendable [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.connectionLost(identity, invalidated: false) } }
        }
        connection.invalidationHandler = { @Sendable [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.connectionLost(identity, invalidated: true) } }
        }
        self.connection = connection
        hostProxy = nil
        connection.resume()
        return connection
    }

    private func dropConnection(_ connection: NSXPCConnection) {
        if self.connection === connection {
            self.connection = nil
            hostProxy = nil
            pendingAcks.removeAll()
        }
        connection.invalidate()
    }

    /// The helper died (interruption) or the connection became unusable (invalidation). Attached engines try to
    /// re-attach through a fresh handshake; sessions that did not survive end with an unknown exit status.
    private func connectionLost(_ identity: ObjectIdentifier, invalidated: Bool) {
        guard let current = connection, ObjectIdentifier(current) == identity else { return }
        Self.logger.notice("PTY host connection \(invalidated ? "invalidated" : "interrupted", privacy: .public)")
        hostProxy = nil
        hostBuild = nil
        hostProtocolVersion = nil
        pendingAcks.removeAll() // credits belong to the lost connection's attachments
        if invalidated { connection = nil }
        let attached = engines.values.compactMap(\.engine)
        guard !attached.isEmpty else { return }
        Task { @MainActor in
            for engine in attached {
                await engine.recoverAfterHostConnectionLoss()
            }
        }
    }

    private func routeOutput(_ sessionID: String, data: Data) {
        guard let engine = engines[sessionID]?.engine else {
            // Nobody here wants this session (engine gone, or a late attach after a timeout): stop the stream. Data
            // after a detach is not credited; the helper drops that attachment's accounting with it.
            if !data.isEmpty || engines[sessionID] != nil { detach(sessionID) }
            return
        }
        engine.receive(output: data)
    }

    private func routeExit(_ sessionID: String, status: Int32) {
        engines[sessionID]?.engine?.receive(exitStatus: status)
    }

    /// Sends one request and awaits its reply, a connection error, or the timeout — whichever comes first.
    private func call<T: Sendable>(
        _ connection: NSXPCConnection,
        _ body: (any PTYHostXPC, @escaping @Sendable (T) -> Void) -> Void
    ) async throws -> T {
        let timeout = requestTimeout
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                once.resume(throwing: PTYHostClientError.connectionFailed(error.localizedDescription))
            }
            guard let host = proxy as? any PTYHostXPC else {
                once.resume(throwing: PTYHostClientError.invalidReply)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                once.resume(throwing: PTYHostClientError.timedOut)
            }
            body(host) { once.resume(returning: $0) }
        }
    }
}

/// Resumes a continuation at most once (reply, error handler and timeout race for it).
private final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, any Error>?>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(returning value: T) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, any Error>? {
        continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
    }
}

/// Exported to the helper on the same connection; forwards to the client (which hops to the main queue).
private final class PTYClientReceiver: NSObject, PTYClientXPC, Sendable {
    private let onOutput: @Sendable (String, Data) -> Void
    private let onExited: @Sendable (String, Int32) -> Void

    init(output: @escaping @Sendable (String, Data) -> Void, exited: @escaping @Sendable (String, Int32) -> Void) {
        self.onOutput = output
        self.onExited = exited
    }

    func output(_ sessionID: String, data: Data) {
        onOutput(sessionID, data)
    }

    func exited(_ sessionID: String, status: Int32) {
        onExited(sessionID, status)
    }
}
