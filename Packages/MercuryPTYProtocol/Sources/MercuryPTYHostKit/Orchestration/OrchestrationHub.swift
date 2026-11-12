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
/// of that data root connects. Data roots share one helper (a second install, the tests) without seeing each other's
/// workers, messages or sockets.
public final class OrchestrationHub: SessionLifecycleObserver, OrchestrationSessionIO, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.tekmium.mercury.ptyhost", category: "orchestration")

    public struct Configuration: Sendable {
        /// Code-signing requirement for app connections to a broker endpoint (the helper's own requirement).
        public var connectionRequirement: String?
        public var tuning = Broker.Tuning()
        /// Serve the CLI over a socket and a spool (off in tests that call the broker directly).
        public var servesCLI = true

        public init(connectionRequirement: String? = nil) {
            self.connectionRequirement = connectionRequirement
        }
    }

    private final class Entry: @unchecked Sendable {
        let broker: Broker
        var socket: BrokerSocketServer?
        var spool: BrokerSpool?
        var listener: NSXPCListener?
        var listenerDelegate: OrchestrationListenerDelegate?

        init(broker: Broker) {
            self.broker = broker
        }
    }

    private let configuration: Configuration
    private weak var manager: SessionManager?
    private let lock = NSLock()
    // Guarded by `lock`.
    private var entries: [String: Entry] = [:]
    private var sessionRoots: [String: String] = [:] // host session id -> data root key

    public init(manager: SessionManager, configuration: Configuration = Configuration()) {
        self.manager = manager
        self.configuration = configuration
    }

    /// The broker of `dataRoot`, opening it (state, socket, spool) on first use.
    public func broker(dataRoot: URL) -> Broker {
        let key = OrchestrationPaths.key(dataRoot: dataRoot)
        return lock.withLock { entryLocked(key: key, dataRoot: dataRoot).broker }
    }

    private func entryLocked(key: String, dataRoot: URL) -> Entry {
        if let existing = entries[key] { return existing }
        let broker = Broker(dataRoot: dataRoot, stateFile: OrchestrationPaths.stateFile(dataRoot: dataRoot), io: self,
                            tuning: configuration.tuning)
        broker.open()
        let entry = Entry(broker: broker)
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
        entries[key] = entry
        Self.logger.info("orchestration broker open for a data root")
        return entry
    }

    /// An endpoint the app of `dataRoot` connects to (see `OrchestrationHostXPC`).
    public func endpoint(dataRoot: URL) -> NSXPCListenerEndpoint {
        let key = OrchestrationPaths.key(dataRoot: dataRoot)
        return lock.withLock {
            let entry = entryLocked(key: key, dataRoot: dataRoot)
            if let listener = entry.listener { return listener.endpoint }
            let listener = NSXPCListener.anonymous()
            if let requirement = configuration.connectionRequirement {
                listener.setConnectionCodeSigningRequirement(requirement)
            }
            let delegate = OrchestrationListenerDelegate(broker: entry.broker)
            listener.delegate = delegate
            listener.resume()
            entry.listener = listener
            entry.listenerDelegate = delegate
            return listener.endpoint
        }
    }

    /// Stops every socket and spool (helper exit, tests).
    public func shutdown() {
        let all = lock.withLock { () -> [Entry] in
            defer { entries.removeAll() }
            return Array(entries.values)
        }
        for entry in all {
            entry.socket?.stop()
            entry.spool?.stop()
            entry.listener?.invalidate()
        }
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
            return entryLocked(key: key, dataRoot: dataRoot).broker
        }
        let agent = info.metadata[OrchestrationMetadata.agent].flatMap(OrchestrationAgent.init(rawValue:))
        broker.sessionSpawned(hostSessionID: info.id, sessionID: sessionID, agent: agent, token: token)
    }

    public func sessionExited(_ sessionID: String, status: Int32) {
        brokerFor(hostSessionID: sessionID)?.sessionExited(hostSessionID: sessionID, status: status)
    }

    public func sessionReceivedInput(_ sessionID: String, data: Data) {
        brokerFor(hostSessionID: sessionID)?.userInput(hostSessionID: sessionID, data: data)
    }

    private func brokerFor(hostSessionID: String) -> Broker? {
        lock.withLock { sessionRoots[hostSessionID].flatMap { entries[$0]?.broker } }
    }

    // MARK: OrchestrationSessionIO

    public func injectInput(hostSessionID: String, data: Data) {
        manager?.injectInput(sessionID: hostSessionID, data: data)
    }

    public func bytesRead(hostSessionID: String) -> UInt64? {
        manager?.session(hostSessionID)?.bytesRead
    }
}

/// Accepts app connections to one broker's endpoint.
final class OrchestrationListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private weak var broker: Broker?

    init(broker: Broker) {
        self.broker = broker
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let broker else { return false }
        let id = UUID()
        connection.exportedInterface = OrchestrationXPCInterfaces.host()
        connection.remoteObjectInterface = OrchestrationXPCInterfaces.client()
        let link = XPCAppLink(connection: connection)
        connection.exportedObject = OrchestrationHostService(broker: broker, link: link, id: id)
        connection.invalidationHandler = { [weak broker] in broker?.detachApp(id: id) }
        connection.interruptionHandler = { [weak broker] in broker?.detachApp(id: id) }
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
