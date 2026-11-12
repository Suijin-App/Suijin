import Foundation
import MercuryPTYProtocol
import os

/// What the `SessionManager` reports to the orchestration broker.
public protocol SessionLifecycleObserver: AnyObject, Sendable {
    /// `environment` is the spawn request's (it holds the session token); it is never stored.
    func sessionSpawned(_ info: PTYSessionInfo, environment: [String: String])
    func sessionExited(_ sessionID: String, status: Int32)
    /// Bytes a client wrote to the session (the user typing in the app).
    func sessionReceivedInput(_ sessionID: String, data: Data)
}

/// The helper's orchestration: one `Broker` per data root, opened when a session of that data root starts or the app
/// of that data root asks for its endpoint. Data roots share one helper (a second install, the tests) without seeing
/// each other's workers, messages or sockets.
///
/// A data root's broker, socket, spool watcher and XPC listener each hold descriptors or ports, so they are closed
/// again once nothing uses them: no running session of that data root and no app connected to its endpoint for
/// `idleGrace`, or the data root directory no longer exists. The grace covers the app's hand-off (it fetches the
/// endpoint over a short-lived connection, then connects to it) and keeps a quickly reopened data root warm.
public final class OrchestrationHub: SessionLifecycleObserver, OrchestrationSessionIO, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.tekmium.mercury.ptyhost", category: "orchestration")

    public struct Configuration: Sendable {
        /// Code-signing requirement for app connections to a broker endpoint (the helper's own requirement).
        public var connectionRequirement: String?
        public var tuning = Broker.Tuning()
        /// Serve the CLI over a socket and a spool (off in tests that call the broker directly).
        public var servesCLI = true
        /// How long a data root stays open with no session and no app before it is closed.
        public var idleGrace: TimeInterval = 60
        /// How often idle and deleted data roots are looked for; 0 disables the sweep (tests call `sweep`).
        public var sweepInterval: TimeInterval = 30

        public init(connectionRequirement: String? = nil) {
            self.connectionRequirement = connectionRequirement
        }
    }

    final class Entry: @unchecked Sendable {
        let key: String
        let dataRoot: URL
        let broker: Broker
        // Guarded by the hub's `lock`.
        var socket: BrokerSocketServer?
        var spool: BrokerSpool?
        var listener: NSXPCListener?
        var listenerDelegate: OrchestrationListenerDelegate?
        /// Running host sessions of this data root.
        var sessions: Set<String> = []
        /// App connections to this data root's endpoint.
        var apps: Set<UUID> = []
        /// When the last user went away (or the entry opened unused); nil while it is in use.
        var idleSince: Date?

        init(key: String, dataRoot: URL, broker: Broker) {
            self.key = key
            self.dataRoot = dataRoot
            self.broker = broker
        }

        var inUse: Bool { !sessions.isEmpty || !apps.isEmpty }

        /// Starts or ends the idle grace after a change of users.
        func updateIdle(now: Date) {
            if inUse {
                idleSince = nil
            } else if idleSince == nil {
                idleSince = now
            }
        }

        /// Stops serving and releases every descriptor and port. Called outside the hub's lock: the broker's queue may
        /// be waiting on the session manager, whose callbacks take that lock.
        func close(dataRootDeleted: Bool) {
            socket?.stop()
            spool?.stop()
            listener?.invalidate()
            broker.close()
            if dataRootDeleted {
                // The socket (when it did not fit inside the data root) and the spool live here.
                try? FileManager.default.removeItem(at: OrchestrationPaths.runtimeDirectory(dataRoot: dataRoot))
            }
        }
    }

    private let configuration: Configuration
    private weak var manager: SessionManager?
    private let lock = NSLock()
    private let sweepQueue = DispatchQueue(label: "com.tekmium.mercury.ptyhost.orchestration.sweep")
    // Guarded by `lock`.
    private var entries: [String: Entry] = [:]
    private var sessionRoots: [String: String] = [:] // running host session id -> data root key
    private var sweepTimer: DispatchSourceTimer?

    public init(manager: SessionManager, configuration: Configuration = Configuration()) {
        self.manager = manager
        self.configuration = configuration
    }

    deinit {
        sweepTimer?.cancel()
    }

    /// The broker of `dataRoot`, opening it (state, socket, spool) on first use.
    public func broker(dataRoot: URL) -> Broker {
        let key = OrchestrationPaths.key(dataRoot: dataRoot)
        return lock.withLock { entryLocked(key: key, dataRoot: dataRoot).broker }
    }

    /// Data roots open right now (tests).
    var openDataRootCount: Int {
        lock.withLock { entries.count }
    }

    private func entryLocked(key: String, dataRoot: URL) -> Entry {
        if let existing = entries[key] { return existing }
        let broker = Broker(dataRoot: dataRoot, stateFile: OrchestrationPaths.stateFile(dataRoot: dataRoot), io: self,
                            tuning: configuration.tuning)
        broker.open()
        let entry = Entry(key: key, dataRoot: dataRoot, broker: broker)
        if configuration.servesCLI {
            let handler: BrokerRequestHandler = { [weak broker] request, reply in
                guard let broker else {
                    reply(.failure(BrokerFailure(code: "unavailable", message: "Mercury's broker is shutting down.")))
                    return
                }
                broker.handle(request, reply: reply)
            }
            do {
                try makePrivateDirectory(OrchestrationPaths.directory(dataRoot: dataRoot).path)
                let socket = BrokerSocketServer(path: OrchestrationPaths.socketPath(dataRoot: dataRoot), handler: handler)
                try socket.start()
                entry.socket = socket
            } catch {
                Self.logger.error("orchestration socket unavailable: \(error.localizedDescription, privacy: .public)")
            }
            do {
                let spool = BrokerSpool(root: OrchestrationPaths.spoolDirectory(dataRoot: dataRoot), handler: handler)
                try spool.start()
                entry.spool = spool
            } catch {
                Self.logger.error("orchestration spool unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
        entry.updateIdle(now: Date())
        entries[key] = entry
        startSweepingLocked()
        Self.logger.info("orchestration broker open for a data root")
        return entry
    }

    private func startSweepingLocked() {
        guard sweepTimer == nil, configuration.sweepInterval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: sweepQueue)
        timer.schedule(deadline: .now() + configuration.sweepInterval, repeating: configuration.sweepInterval,
                       leeway: .milliseconds(Int(configuration.sweepInterval * 100)))
        timer.setEventHandler { [weak self] in self?.sweep() }
        timer.resume()
        sweepTimer = timer
    }

    /// An endpoint the app of `dataRoot` connects to (see `OrchestrationHostXPC`).
    public func endpoint(dataRoot: URL) -> NSXPCListenerEndpoint {
        let key = OrchestrationPaths.key(dataRoot: dataRoot)
        return lock.withLock {
            let entry = entryLocked(key: key, dataRoot: dataRoot)
            // A fresh grace for the app to connect to what it is handed.
            if !entry.inUse { entry.idleSince = Date() }
            if let listener = entry.listener { return listener.endpoint }
            let listener = NSXPCListener.anonymous()
            if let requirement = configuration.connectionRequirement {
                listener.setConnectionCodeSigningRequirement(requirement)
            }
            let delegate = OrchestrationListenerDelegate(hub: self, entry: entry)
            listener.delegate = delegate
            listener.resume()
            entry.listener = listener
            entry.listenerDelegate = delegate
            return listener.endpoint
        }
    }

    /// An app connected to `entry`'s endpoint; false when that data root has closed meanwhile.
    func appConnected(_ id: UUID, to entry: Entry) -> Bool {
        lock.withLock {
            guard entries[entry.key] === entry else { return false }
            entry.apps.insert(id)
            entry.updateIdle(now: Date())
            return true
        }
    }

    func appDisconnected(_ id: UUID, from entry: Entry) {
        lock.withLock {
            guard entry.apps.remove(id) != nil else { return }
            entry.updateIdle(now: Date())
        }
    }

    /// Closes data roots that have been unused for `idleGrace` and those whose directory is gone (even with sessions
    /// still running: nothing should recreate a deleted data root). Runs every `sweepInterval`.
    func sweep(now: Date = Date()) {
        let closing = lock.withLock { () -> [(Entry, Bool)] in
            var closing: [(Entry, Bool)] = []
            for entry in entries.values {
                let deleted = !FileManager.default.fileExists(atPath: entry.dataRoot.path)
                let idle = entry.idleSince.map { now.timeIntervalSince($0) >= configuration.idleGrace } ?? false
                guard deleted || idle else { continue }
                entries[entry.key] = nil
                for session in entry.sessions { sessionRoots[session] = nil }
                closing.append((entry, deleted))
            }
            return closing
        }
        for (entry, deleted) in closing {
            entry.close(dataRootDeleted: deleted)
            Self.logger.info("orchestration broker closed for a data root (\(deleted ? "deleted" : "unused", privacy: .public))")
        }
    }

    /// Stops every socket and spool (helper exit, tests).
    public func shutdown() {
        let all = lock.withLock { () -> [Entry] in
            defer {
                entries.removeAll()
                sessionRoots.removeAll()
                sweepTimer?.cancel()
                sweepTimer = nil
            }
            return Array(entries.values)
        }
        for entry in all { entry.close(dataRootDeleted: false) }
    }

    // MARK: SessionLifecycleObserver

    public func sessionSpawned(_ info: PTYSessionInfo, environment: [String: String]) {
        guard let root = info.metadata[OrchestrationMetadata.dataRoot], !root.isEmpty,
              let sessionID = info.metadata[OrchestrationMetadata.session], !sessionID.isEmpty,
              let token = environment[OrchestrationEnvironment.sessionToken], !token.isEmpty
        else { return }
        let dataRoot = URL(fileURLWithPath: root, isDirectory: true)
        let key = OrchestrationPaths.key(dataRoot: dataRoot)
        let broker = lock.withLock { () -> Broker in
            sessionRoots[info.id] = key
            let entry = entryLocked(key: key, dataRoot: dataRoot)
            entry.sessions.insert(info.id)
            entry.updateIdle(now: Date())
            return entry.broker
        }
        let agent = info.metadata[OrchestrationMetadata.agent].flatMap(OrchestrationAgent.init(rawValue:))
        broker.sessionSpawned(hostSessionID: info.id, sessionID: sessionID, agent: agent, token: token)
    }

    public func sessionExited(_ sessionID: String, status: Int32) {
        let broker = lock.withLock { () -> Broker? in
            guard let key = sessionRoots.removeValue(forKey: sessionID), let entry = entries[key] else { return nil }
            entry.sessions.remove(sessionID)
            entry.updateIdle(now: Date())
            return entry.broker
        }
        broker?.sessionExited(hostSessionID: sessionID, status: status)
    }

    public func sessionReceivedInput(_ sessionID: String, data: Data) {
        let broker = lock.withLock { sessionRoots[sessionID].flatMap { entries[$0]?.broker } }
        broker?.userInput(hostSessionID: sessionID, data: data)
    }

    // MARK: OrchestrationSessionIO

    public func injectInput(hostSessionID: String, data: Data) {
        manager?.injectInput(sessionID: hostSessionID, data: data)
    }

    public func bytesRead(hostSessionID: String) -> UInt64? {
        manager?.session(hostSessionID)?.bytesRead
    }
}

/// Accepts app connections to one data root's endpoint and tells the hub while each one lasts.
final class OrchestrationListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    // Immutable after init.
    private weak var hub: OrchestrationHub?
    private weak var entry: OrchestrationHub.Entry?

    init(hub: OrchestrationHub, entry: OrchestrationHub.Entry) {
        self.hub = hub
        self.entry = entry
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let id = UUID()
        guard let hub, let entry, hub.appConnected(id, to: entry) else { return false }
        let broker = entry.broker
        connection.exportedInterface = OrchestrationXPCInterfaces.host()
        connection.remoteObjectInterface = OrchestrationXPCInterfaces.client()
        let link = XPCAppLink(connection: connection)
        connection.exportedObject = OrchestrationHostService(broker: broker, link: link, id: id)
        let ended: @Sendable () -> Void = { [weak broker, weak hub, weak entry] in
            broker?.detachApp(id: id)
            if let hub, let entry { hub.appDisconnected(id, from: entry) }
        }
        connection.invalidationHandler = ended
        connection.interruptionHandler = ended
        connection.resume()
        return true
    }
}

/// `OrchestrationHostXPC` for one app connection.
final class OrchestrationHostService: NSObject, OrchestrationHostXPC, @unchecked Sendable {
    // Immutable after init.
    private weak var broker: Broker?
    private let link: XPCAppLink
    private let id: UUID

    init(broker: Broker, link: XPCAppLink, id: UUID) {
        self.broker = broker
        self.link = link
        self.id = id
    }

    func hello(appBuild: String, reply: @escaping @Sendable (Bool) -> Void) {
        guard let broker else {
            reply(false)
            return
        }
        broker.attachApp(link, id: id)
        reply(true)
    }

    func snapshot(reply: @escaping @Sendable (Data) -> Void) {
        let snapshot = broker?.snapshot() ?? OrchestrationSnapshot()
        reply((try? OrchestrationCoding.encoder.encode(snapshot)) ?? Data("{}".utf8))
    }

    func workerStartFinished(_ result: Data) {
        guard let decoded = try? OrchestrationCoding.decoder.decode(WorkerLaunchResult.self, from: result) else { return }
        broker?.workerStartFinished(decoded)
    }
}

/// The broker's handle on the app: the connection's `OrchestrationClientXPC` proxy.
final class XPCAppLink: OrchestrationAppLink, @unchecked Sendable {
    // NSXPCConnection proxies are thread-safe; immutable after init.
    private let proxy: (any OrchestrationClientXPC)?

    init(connection: NSXPCConnection) {
        proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            // Failures surface as invalidation, which detaches the app.
        } as? any OrchestrationClientXPC
    }

    func startWorker(_ request: WorkerLaunchRequest) {
        guard let data = try? OrchestrationCoding.encoder.encode(request) else { return }
        proxy?.startWorker(data)
    }

    func stateChanged() {
        proxy?.stateChanged()
    }

    func attention(_ event: OrchestrationAttention) {
        guard let data = try? OrchestrationCoding.encoder.encode(event) else { return }
        proxy?.attention(data)
    }
}
