import Foundation
import SuijinPTYProtocol
import os
import ServiceManagement
import Synchronization

/// Why a call to the PTY host failed.
public enum PTYHostClientError: Error, LocalizedError, Equatable, Sendable {
    /// The user has to allow Suijin's background item in System Settings > General > Login Items.
    case requiresApproval
    /// launchd has the agent registered for another copy of Suijin (another path), not for this one.
    case registeredElsewhere
    /// The LaunchAgent plist is missing from the app bundle.
    case notFound
    case registrationFailed(String)
    /// The running helper speaks another protocol version (typically an old helper after an app update). It was asked
    /// to exit when idle; the next call reconnects.
    case protocolMismatch(host: Int, client: Int)
    case connectionFailed(String)
    case timedOut
    /// The helper could not be reached even after the client repaired its launchd registration (or could not repair it
    /// without ending running sessions). The user has to act: Settings › General › Permissions, or a restart.
    case notResponding
    case spawnFailed(String)
    case sessionNotFound(String)
    case invalidReply

    public var errorDescription: String? {
        switch self {
        case .requiresApproval:
            "Suijin's terminal host needs approval in System Settings > General > Login Items."
        case .registeredElsewhere: "The terminal host is registered by another copy of Suijin."
        case .notFound: "The terminal host is missing from the Suijin app bundle."
        case .registrationFailed(let reason): "Could not register the terminal host: \(reason)"
        case .protocolMismatch(let host, let client):
            "The running terminal host speaks protocol \(host), this app needs \(client). Quit sessions to update it."
        case .connectionFailed(let reason): "Lost the connection to the terminal host: \(reason)"
        case .timedOut: "The terminal host did not answer in time."
        case .notResponding: "The terminal host does not start or does not answer."
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
    /// Numbers each connection the client makes. Late interruption and invalidation handlers compare it, not the object's
    /// address: a connection made right after another was released can get the same address, and a late invalidation of
    /// the old one would otherwise drop the new one.
    private var connectionGeneration = 0
    private var hostProxy: (any PTYHostXPC)?
    private var handshakeTask: Task<Void, any Error>?
    /// Handshakes running right now (`handshakeTask` can outlive its handshake until its caller resumes).
    private var handshakesInFlight = 0
    private var engines: [String: WeakEngine] = [:]
    /// Consumed bytes not yet reported to the helper, per session (batched: 64 KB or 16 ms).
    private var pendingAcks: [String: Int] = [:]
    private var ackFlushScheduled = false
    private static let ackBatchBytes = 64 * 1024
    private static let ackBatchDelay: TimeInterval = 0.016

    private struct WeakEngine {
        weak var engine: HostedTerminalEngine?
    }

    /// How the client reaches launchd. The live one uses `SMAppService`; tests replace it so no real agent is touched.
    public var registration: PTYHostRegistration = .live
    /// True after `connect()` or `reconnect()` gave up on reaching the helper, until a handshake succeeds again. Settings
    /// shows the background helper as not working meanwhile, whatever launchd says about its approval.
    public private(set) var isHelperUnreachable = false
    /// Longest a renewal of the registration may take; `SMAppService.unregister()` has no timeout of its own.
    public var renewalTimeout: Duration = .seconds(15)
    /// The renewal in progress. There is only ever one: every other caller waits for it, and no connection is opened
    /// while it runs, so launchd cannot start a helper that the renewal's unregister would then stop.
    private var renewal: Task<Void, any Error>?
    /// Counts finished renewals, so a caller whose request failed before another caller's renewal only tries again.
    private var renewalGeneration = 0
    /// Set once an automatic renewal did not make the helper reachable (or failed): for the rest of this launch requests
    /// only try again, and only the Repair button (`repair()`) renews.
    private(set) var automaticRenewalSpent = false

    public init(connectionFactory: @escaping () -> NSXPCConnection) {
        self.connectionFactory = connectionFactory
    }

    private var isConnected: Bool { connection != nil && hostProxy != nil }

    // MARK: Registration

    /// Registers the helper's LaunchAgent with launchd (`SMAppService.agent`). Safe to call on every launch. Returns
    /// true when it registered the agent now, false when it already was.
    @discardableResult
    public func register() throws -> Bool {
        try registration.register()
    }

    /// The `SMAppService` registration behind `PTYHostRegistration.live`.
    nonisolated static func registerAgent() throws -> Bool {
        let service = SMAppService.agent(plistName: PTYHostConstants.launchAgentPlist)
        switch service.status {
        case .enabled: return false
        case .requiresApproval: throw PTYHostClientError.requiresApproval
        case .notRegistered, .notFound: break
        @unknown default: break
        }
        do {
            try service.register()
        } catch {
            let code = (error as NSError).code
            if code == Int(kSMErrorAlreadyRegistered) {
                if service.status == .enabled { return false }
                // launchd has the agent, but not for this copy of the app (another copy at another path registered it).
                throw PTYHostClientError.registeredElsewhere
            }
            if code == Int(kSMErrorLaunchDeniedByUser) || service.status == .requiresApproval {
                throw PTYHostClientError.requiresApproval
            }
            throw PTYHostClientError.registrationFailed(error.localizedDescription)
        }
        switch service.status {
        case .enabled: return true
        case .requiresApproval: throw PTYHostClientError.requiresApproval
        case .notFound: throw PTYHostClientError.notFound
        case .notRegistered: throw PTYHostClientError.registrationFailed("launchd reports the agent as not registered")
        @unknown default: throw PTYHostClientError.registrationFailed("unknown status \(service.status.rawValue)")
        }
    }

    /// Removes the agent from launchd and registers it again, so launchd takes the helper binary, its path and its
    /// signature from the bundle as it is now. Removing the agent stops a running helper with all its sessions, so this
    /// is only ever called when no helper process runs.
    nonisolated static func reregisterAgent() async throws {
        let service = SMAppService.agent(plistName: PTYHostConstants.launchAgentPlist)
        do {
            try await service.unregister()
        } catch {
            // A registration launchd already dropped cannot be removed; registering again is what matters.
            logger.notice("Unregistering the PTY host failed: \(error.localizedDescription, privacy: .public)")
        }
        _ = try registerAgent()
    }

    // MARK: Connecting with repair

    /// Registers the helper and connects to it. When the registration was made by another kind of build or another copy
    /// of the app and no helper runs, it is renewed first. When the helper cannot be reached, the registration is
    /// renewed once per launch (only while no helper process runs, so no session ever ends for it) and the connection
    /// tried again. Throws `notResponding` when the helper still cannot be reached.
    public func connect() async throws {
        try await connect(forced: false)
    }

    /// The Repair button: like `connect()`, but renews the registration even when an automatic renewal was already
    /// spent this launch. Still never while a helper process runs.
    public func repair() async throws {
        try await connect(forced: true)
    }

    private func connect(forced: Bool) async throws {
        if isConnected { return }
        let registration = registration
        do {
            if try registration.register(), registration.canRepair { registration.recordIdentity(registration.identity) }
        } catch PTYHostClientError.registeredElsewhere {
            Self.logger.notice("PTY host is registered by another copy of the app; registering it for this one")
            guard try await renewIfAllowed(forced: forced, since: renewalGeneration) else {
                isHelperUnreachable = true
                throw PTYHostClientError.registeredElsewhere
            }
        }
        await refreshRegistrationIfStale()
        try await reachHost(forced: forced)
    }

    /// Connects to the registered helper if the client is not connected, with the same single repair as `connect()`
    /// but without registering first. For the start of a session: it fails here, before any process is spawned, so a
    /// retry can never start a program twice.
    public func reconnect() async throws {
        if isConnected { return }
        try await reachHost(forced: false)
    }

    /// Renews the registration when another kind of build or another copy of the app made it and no helper process
    /// runs. Used at launch and after an update once the old helper exited.
    public func refreshRegistrationIfStale() async {
        let registration = registration
        // The cheap checks first: once renewed (or not repairable) this returns before asking launchd anything.
        guard registration.canRepair, !automaticRenewalSpent, renewal == nil,
              registration.recordedIdentity() != registration.identity,
              Self.registrationNeedsRefresh(
                  recorded: registration.recordedIdentity(), current: registration.identity,
                  approval: registration.approval(), helperRunning: registration.helperRunning(),
                  canRepair: registration.canRepair) else { return }
        Self.logger.notice("PTY host registration was made by another build or copy; registering it again")
        do {
            _ = try await renewIfAllowed(forced: false, since: renewalGeneration)
        } catch {
            automaticRenewalSpent = true
            Self.logger.error("Renewing the PTY host registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Renews the registration unless that is not allowed now. Returns true when the caller should try the helper again:
    /// it renewed, or shared a renewal in progress, or another caller renewed since `generation`. A renewal already in
    /// progress is awaited, never started a second time.
    private func renewIfAllowed(forced: Bool, since generation: Int) async throws -> Bool {
        if let renewal {
            try await renewal.value
            return true
        }
        if renewalGeneration != generation { return true }
        guard registration.canRepair, forced || !automaticRenewalSpent else { return false }
        // Cleared by the task itself as it ends, so callers waiting in `readyConnection()` see it gone at once.
        let task = Task { @MainActor in
            defer {
                self.renewal = nil
                self.renewalGeneration += 1
            }
            try await self.performRenewal()
        }
        renewal = task
        try await task.value
        return true
    }

    /// The renewal itself, only ever run as `renewal`. It checks again, right before unregistering, that no helper runs
    /// and no connection is open or being opened (requests wait for `renewal`, so none starts meanwhile).
    private func performRenewal() async throws {
        guard !isConnected, handshakesInFlight == 0, registration.helperRunning() == false else {
            Self.logger.notice("PTY host renewal skipped: a helper runs or a connection is open")
            return
        }
        disconnect()
        let registration = registration
        try await Self.within(renewalTimeout) { try await registration.reregister() }
        registration.recordIdentity(registration.identity)
    }

    /// Runs `operation`, giving up with `notResponding` after `limit` (the operation itself cannot be cancelled and
    /// may still finish later).
    private static func within(_ limit: Duration,
                               _ operation: @escaping @MainActor @Sendable () async throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = ResumeOnce(continuation)
            Task { @MainActor in
                do {
                    try await operation()
                    once.resume(returning: ())
                } catch {
                    once.resume(throwing: error)
                }
            }
            Task {
                try? await Task.sleep(for: limit)
                once.resume(throwing: PTYHostClientError.notResponding)
            }
        }
    }

    /// One handshake; on a failure that a repair can fix, the repair (at most once per launch unless `forced`) and one
    /// more handshake.
    private func reachHost(forced: Bool) async throws {
        let generation = renewalGeneration
        var renewed = false
        do {
            _ = try await handshake()
            return
        } catch {
            let approval = registration.approval()
            let step = Self.recoveryStep(after: error, approval: approval, helperRunning: registration.helperRunning(),
                                         canRepair: registration.canRepair && (forced || !automaticRenewalSpent))
            Self.logger.error("PTY host not reached (\(error.localizedDescription, privacy: .public)); recovery: \(String(describing: step), privacy: .public)")
            switch step {
            case .none:
                isHelperUnreachable = Self.isUnreachable(error)
                throw Self.reportedError(after: error, approval: approval)
            case .retry:
                break
            case .reregister:
                do {
                    renewed = try await renewIfAllowed(forced: forced, since: generation)
                } catch {
                    automaticRenewalSpent = true
                    isHelperUnreachable = true
                    Self.logger.error("Renewing the PTY host registration failed: \(error.localizedDescription, privacy: .public)")
                    throw Self.reportedError(after: error, approval: registration.approval())
                }
            }
        }
        do {
            _ = try await handshake()
        } catch {
            if renewed { automaticRenewalSpent = true }
            isHelperUnreachable = Self.isUnreachable(error)
            throw Self.reportedError(after: error, approval: registration.approval())
        }
    }

    // MARK: Recovery decisions

    /// What to do after a request to the helper failed.
    public enum RecoveryStep: Equatable, Sendable {
        /// Nothing helps from here (another error, or the user has to approve the helper).
        case none
        /// Try once more as it is: a helper process runs (or that is unknown), and renewing the registration would stop
        /// it with every session it runs; or renewing is not allowed now.
        case retry
        /// No helper runs and launchd could not start one: renew the registration, then try again.
        case reregister
    }

    /// The helper did not answer a request or could not be reached, as opposed to answering with a failure.
    public nonisolated static func isUnreachable(_ error: any Error) -> Bool {
        switch error as? PTYHostClientError {
        case .timedOut?, .connectionFailed?, .notResponding?: true
        default: false
        }
    }

    /// The step after `error`, given launchd's view of the agent and whether a helper process runs (nil: unknown).
    /// `canRepair` is false when renewing is not allowed now (a test host, or the launch's automatic renewal is spent).
    nonisolated static func recoveryStep(after error: any Error, approval: HostApproval, helperRunning: Bool?,
                                         canRepair: Bool) -> RecoveryStep {
        guard isUnreachable(error) else { return .none }
        switch approval {
        case .requiresApproval, .notFound: return .none
        case .enabled, .notRegistered: break
        }
        guard helperRunning == false, canRepair else { return .retry }
        return .reregister
    }

    /// Whether to renew a registration that works as far as launchd says, before connecting: another kind of build or
    /// another copy made it (`recorded` differs from `current`), and no helper process runs that renewing it would stop.
    nonisolated static func registrationNeedsRefresh(recorded: String?, current: String, approval: HostApproval,
                                                     helperRunning: Bool?, canRepair: Bool) -> Bool {
        canRepair && approval == .enabled && recorded != current && helperRunning == false
    }

    /// The error a caller sees once the client gave up: what the user can act on rather than a bare timeout.
    nonisolated static func reportedError(after error: any Error, approval: HostApproval) -> any Error {
        switch approval {
        case .requiresApproval: return PTYHostClientError.requiresApproval
        case .notFound: return PTYHostClientError.notFound
        case .enabled, .notRegistered: break
        }
        return isUnreachable(error) ? PTYHostClientError.notResponding : error
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
        // No connection is opened while the registration is renewed: launchd would start a helper under the old
        // registration that the renewal then stops, with whatever was spawned in it.
        while let renewal { _ = try? await renewal.value }
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
        handshakesInFlight += 1
        defer { handshakesInFlight -= 1 }
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
        isHelperUnreachable = false
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
        connectionGeneration += 1
        let identity = connectionGeneration
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
    private func connectionLost(_ identity: Int, invalidated: Bool) {
        guard connection != nil, connectionGeneration == identity else { return }
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
