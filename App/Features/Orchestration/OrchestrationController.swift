import AppKit
import Foundation
import SevindaCore
import SevindaPTYProtocol
import Observation
import os
import Synchronization

private let logger = Logger(subsystem: "com.tekmium.sevinda", category: "orchestration")

/// The app's link to the orchestration broker of its data root, which lives in the PTY host helper.
///
/// The app executes the broker's worker starts (worktree, account, launch: things only the app knows), mirrors the
/// broker's state for the sidebar and the inspector, and posts a notification when a coordinator needs the user. The
/// broker keeps running and delivering messages while the app is closed; worker starts requested meanwhile wait in
/// the broker until the app connects again.
@Observable
@MainActor
final class OrchestrationController {
    @ObservationIgnored private unowned let model: AppModel
    private(set) var snapshot = OrchestrationSnapshot()
    /// Why orchestration is unavailable (an older terminal host, no host at all), nil while connected or connecting.
    private(set) var problem: String?
    private(set) var isConnected = false

    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var broker: (any OrchestrationHostXPC)?
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var retryDelay: Duration = .seconds(2)
    @ObservationIgnored private var started = false
    @ObservationIgnored private let launcher: WorkerLauncher
    /// Prompts of workers being launched right now, so the launch can tell a worker from a user's session.
    @ObservationIgnored var launchingWorkerPrompts: Set<String> = []

    init(model: AppModel) {
        self.model = model
        self.launcher = WorkerLauncher(model: model)
    }

    /// Connects once the PTY host is known to work; reconnects by itself after the helper restarts.
    func start() {
        guard !started else { return }
        started = true
        Task { await connect() }
    }

    func stop() {
        started = false
        connection?.invalidate()
        connection = nil
        broker = nil
        isConnected = false
    }

    // MARK: Connection

    private func connect() async {
        guard started, connection == nil else { return }
        do {
            let endpoint = try await Self.fetchEndpoint(dataRoot: model.dataRoot.path)
            let connection = NSXPCConnection(listenerEndpoint: endpoint)
            connection.remoteObjectInterface = OrchestrationXPCInterfaces.host()
            connection.exportedInterface = OrchestrationXPCInterfaces.client()
            connection.exportedObject = OrchestrationClientReceiver(
                startWorker: { [weak self] request in Task { @MainActor in await self?.startWorker(request) } },
                stateChanged: { [weak self] in Task { @MainActor in self?.scheduleRefresh() } },
                attention: { [weak self] event in Task { @MainActor in self?.notify(event) } }
            )
            let identity = ObjectIdentifier(connection)
            // XPC calls these handlers on its own queue; `@Sendable` keeps them from inheriting the controller's
            // main-actor isolation, which Swift checks at run time and would stop the app on.
            connection.interruptionHandler = { @Sendable [weak self] in
                Task { @MainActor in self?.connectionLost(identity) }
            }
            connection.invalidationHandler = { @Sendable [weak self] in
                Task { @MainActor in self?.connectionLost(identity) }
            }
            connection.resume()
            self.connection = connection
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
            let accepted: Bool = try await Self.call(connection, timeout: 10) { (host: any OrchestrationHostXPC, finish) in
                host.hello(appBuild: build) { finish($0) }
            }
            guard accepted else { throw OrchestrationLinkError.refused }
            broker = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                logger.debug("broker message failed: \(error.localizedDescription, privacy: .public)")
            } as? any OrchestrationHostXPC
            isConnected = true
            problem = nil
            retryDelay = .seconds(2)
            await refresh()
        } catch {
            connection?.invalidate()
            connection = nil
            broker = nil
            isConnected = false
            problem = error.localizedDescription
            logger.notice("orchestration unavailable: \(error.localizedDescription, privacy: .public)")
            // An older helper stays until its sessions end; keep trying so orchestration appears once it is replaced.
            scheduleReconnect()
        }
    }

    private func connectionLost(_ identity: ObjectIdentifier) {
        guard let current = connection, ObjectIdentifier(current) == identity else { return }
        connection = nil
        broker = nil
        isConnected = false
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard started else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, .seconds(30))
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.connect()
        }
    }

    /// A short-lived connection to the helper's Mach service for the broker endpoint (protocol 3).
    private static func fetchEndpoint(dataRoot: String) async throws -> NSXPCListenerEndpoint {
        let host = NSXPCConnection(machServiceName: PTYHostConstants.machServiceName, options: [])
        host.remoteObjectInterface = PTYXPCInterfaces.host()
        host.resume()
        defer { host.invalidate() }
        let version: Int = try await call(host, timeout: 10) { (proxy: any PTYHostXPC, finish) in
            proxy.handshake(clientProtocolVersion: PTYHostConstants.protocolVersion) { version, _ in finish(version) }
        }
        guard version >= 3 else { throw OrchestrationLinkError.oldHost(version) }
        let (endpoint, error): (NSXPCListenerEndpoint?, String?) = try await call(host, timeout: 10) { (proxy: any PTYHostXPC, finish) in
            proxy.orchestrationEndpoint(dataRoot: dataRoot) { finish(($0, $1)) }
        }
        guard let endpoint else { throw OrchestrationLinkError.unavailable(error ?? "no endpoint") }
        return endpoint
    }

    /// One request with a reply, a connection error or a timeout, whichever comes first.
    private static func call<Proxy, T: Sendable>(
        _ connection: NSXPCConnection, timeout: TimeInterval,
        _ body: (Proxy, @escaping @Sendable (T) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeGuard(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                once.resume(throwing: OrchestrationLinkError.unavailable(error.localizedDescription))
            }
            guard let typed = proxy as? Proxy else {
                once.resume(throwing: OrchestrationLinkError.unavailable("unexpected proxy"))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                once.resume(throwing: OrchestrationLinkError.unavailable("the terminal host did not answer"))
            }
            body(typed) { once.resume(returning: $0) }
        }
    }

    // MARK: State

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            self.refreshScheduled = false
            await self.refresh()
        }
    }

    func refresh() async {
        guard let connection else { return }
        do {
            let data: Data = try await Self.call(connection, timeout: 10) { (host: any OrchestrationHostXPC, finish) in
                host.snapshot { finish($0) }
            }
            snapshot = try OrchestrationCoding.decoder.decode(OrchestrationSnapshot.self, from: data)
        } catch {
            logger.debug("snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startWorker(_ request: WorkerLaunchRequest) async {
        let result = await launcher.launch(request)
        guard let data = try? OrchestrationCoding.encoder.encode(result) else { return }
        broker?.workerStartFinished(data)
    }

    #if DEBUG
    /// Screenshot tests show orchestration without a broker.
    func setSnapshotForPreview(_ snapshot: OrchestrationSnapshot) {
        self.snapshot = snapshot
    }
    #endif

    // MARK: Queries for the sidebar and inspector

    /// The newest dispatch of each worker `coordinator` started, oldest worker first.
    func workers(of coordinator: UUID) -> [OrchestrationDispatch] {
        let id = coordinator.uuidString
        let led = snapshot.dispatches.filter { $0.coordinatorSessionID == id }
        var newest: [String: OrchestrationDispatch] = [:]
        for dispatch in led {
            let key = dispatch.workerSessionID ?? dispatch.id
            if let existing = newest[key], existing.createdAt >= dispatch.createdAt { continue }
            newest[key] = dispatch
        }
        return newest.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// The dispatches a worker session ran, newest first.
    func dispatches(ofWorker worker: UUID) -> [OrchestrationDispatch] {
        snapshot.dispatches.filter { $0.workerSessionID == worker.uuidString }.sorted { $0.createdAt > $1.createdAt }
    }

    func isWorker(_ session: UUID) -> Bool {
        snapshot.dispatches.contains { $0.workerSessionID == session.uuidString }
    }

    /// A worker shown nested under its coordinator in the same sidebar row, so it is not listed twice there.
    func isNestedWorker(_ session: AgentSessionRecord, in context: SessionContext) -> Bool {
        guard let dispatch = snapshot.dispatches.first(where: { $0.workerSessionID == session.id.uuidString }),
              let coordinatorID = UUID(uuidString: dispatch.coordinatorSessionID),
              let coordinator = model.sessions.first(where: { $0.id == coordinatorID }) else { return false }
        return model.context(of: coordinator) == context
    }

    func task(_ id: String) -> OrchestrationTask? {
        snapshot.tasks.first { $0.id == id }
    }

    func messages(of dispatch: OrchestrationDispatch) -> [OrchestrationMessage] {
        snapshot.messages.filter { $0.dispatchID == dispatch.id }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Questions from `coordinator`'s workers it has not answered.
    func openQuestions(for coordinator: UUID) -> Int {
        snapshot.messages.filter { $0.toSessionID == coordinator.uuidString && $0.kind == .question && $0.answeredBy == nil }.count
    }

    // MARK: Notifications

    private func notify(_ event: OrchestrationAttention) {
        guard model.setting(.notifyWhenWaiting) != "false", model.notifiesUser,
              let id = UUID(uuidString: event.sessionID),
              let record = model.sessions.first(where: { $0.id == id }) else { return }
        let title = switch event.kind {
        case .permission: String(localized: "\(record.title) needs your permission")
        case .decision: String(localized: "\(record.title) needs your decision")
        }
        UserNotifier.shared.post(identifier: "orchestration-\(id.uuidString)", title: title, body: event.body, session: id)
    }
}

enum OrchestrationLinkError: LocalizedError {
    case oldHost(Int)
    case unavailable(String)
    case refused

    var errorDescription: String? {
        switch self {
        case .oldHost(let version):
            String(localized: "The running terminal host (protocol \(version)) predates orchestration. It is replaced once its sessions end.")
        case .unavailable(let reason): String(localized: "Orchestration is unavailable: \(reason)")
        case .refused: String(localized: "The terminal host refused the orchestration connection.")
        }
    }
}

/// Resumes a continuation at most once (reply, error handler and timeout race for it).
private final class ResumeGuard<T: Sendable>: Sendable {
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

/// Exported to the broker; decodes and forwards to the controller on the main actor.
private final class OrchestrationClientReceiver: NSObject, OrchestrationClientXPC, Sendable {
    private let onStartWorker: @Sendable (WorkerLaunchRequest) -> Void
    private let onStateChanged: @Sendable () -> Void
    private let onAttention: @Sendable (OrchestrationAttention) -> Void

    init(startWorker: @escaping @Sendable (WorkerLaunchRequest) -> Void, stateChanged: @escaping @Sendable () -> Void,
         attention: @escaping @Sendable (OrchestrationAttention) -> Void) {
        onStartWorker = startWorker
        onStateChanged = stateChanged
        onAttention = attention
    }

    func startWorker(_ request: Data) {
        guard let decoded = try? OrchestrationCoding.decoder.decode(WorkerLaunchRequest.self, from: request) else { return }
        onStartWorker(decoded)
    }

    func stateChanged() {
        onStateChanged()
    }

    func attention(_ event: Data) {
        guard let decoded = try? OrchestrationCoding.decoder.decode(OrchestrationAttention.self, from: event) else { return }
        onAttention(decoded)
    }
}
