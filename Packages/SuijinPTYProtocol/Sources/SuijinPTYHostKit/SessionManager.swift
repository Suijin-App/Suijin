import Foundation
import SuijinPTYProtocol
import os

/// Owns every `PTYSession` of the helper: lookup by id, which client is attached where, persisted metadata,
/// letting go of ended sessions and the idle signal that lets the helper exit.
///
/// What is kept of an ended session: nothing once a client asked to terminate it (closing its tab, or the app having
/// recorded its end), and otherwise the tail of its scrollback until the retention window is over.
///
/// All mutable state is confined to a private serial queue (hence `@unchecked Sendable`). Session queues never wait on
/// the manager queue, so the manager may call into sessions synchronously without deadlock.
public final class SessionManager: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Where `<id>.json` metadata files live; nil disables persistence.
        public var metadataDirectory: URL?
        public var scrollbackCapacity = ScrollbackBuffer.defaultCapacity
        public var sessionTuning = PTYSessionTuning()
        /// Exited sessions nobody is attached to are dropped (with their metadata) after this long.
        public var exitedRetention: TimeInterval = 24 * 3600
        /// Scrollback kept for a session that exited on its own. The app reads only the last lines of it (the end of
        /// a failure, an agent's resume hint), once.
        public var exitedTailBytes = 256 * 1024
        /// How long the helper must stay idle (no running session, no connected client) before `onIdle` fires.
        public var idleGrace: TimeInterval = 10
        public var reapInterval: TimeInterval = 600

        public init(metadataDirectory: URL?) {
            self.metadataDirectory = metadataDirectory
        }
    }

    /// What is written to `<metadataDirectory>/<id>.json`. Never contains the environment or arguments.
    struct PersistedSession: Codable, Sendable {
        var info: PTYSessionInfo
        var endedAt: Date?
    }

    private static let logger = Logger(subsystem: "com.tekmium.suijin.ptyhost", category: "sessions")

    public let configuration: Configuration
    private let onIdle: (@Sendable () -> Void)?
    private let queue = DispatchQueue(label: "com.tekmium.suijin.ptyhost.manager")

    // Queue-confined state.
    private var sessions: [String: PTYSession] = [:]
    private var endedAt: [String: Date] = [:]
    /// Sessions a client asked to terminate: forgotten as soon as they are settled.
    private var released: Set<String> = []
    /// Sessions recorded by a previous helper process; informative only, never running.
    private var stale: [String: PersistedSession] = [:]
    /// clientID -> sessionID -> attachment token.
    private var clients: [UUID: [String: UUID]] = [:]
    private var idleGeneration = 0
    private var reapTimer: DispatchSourceTimer?
    private var started = false
    private var observer: (any SessionLifecycleObserver)?

    public init(configuration: Configuration, onIdle: (@Sendable () -> Void)? = nil) {
        self.configuration = configuration
        self.onIdle = onIdle
    }

    deinit {
        reapTimer?.cancel()
    }

    /// Reports spawns, exits and client input to `observer` (the orchestration broker). Its callbacks must not call
    /// back into the manager synchronously.
    public func setObserver(_ observer: (any SessionLifecycleObserver)?) {
        queue.sync { self.observer = observer }
    }

    /// `<dataRoot>/pty-host/sessions`, with the data root from `SUIJIN_DATA_ROOT` or `~/Library/Application Support/Suijin`.
    public static func defaultMetadataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let root: URL
        if let override = environment["SUIJIN_DATA_ROOT"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Suijin", isDirectory: true)
        }
        return root.appendingPathComponent("pty-host/sessions", isDirectory: true)
    }

    /// Loads metadata left by earlier helper processes, starts the reap timer and arms the idle check.
    public func start() {
        queue.sync {
            guard !started else { return }
            started = true
            loadPersistedSessions()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + configuration.reapInterval, repeating: configuration.reapInterval)
            timer.setEventHandler { [weak self] in self?.reapLocked(now: Date()) }
            timer.resume()
            reapTimer = timer
            evaluateIdleLocked()
        }
    }

    // MARK: Sessions

    public func spawn(_ request: PTYSpawnRequest) throws -> PTYSessionInfo {
        let (info, observer) = try spawnLocked(request)
        observer?.sessionSpawned(info, environment: request.environment)
        return info
    }

    private func spawnLocked(_ request: PTYSpawnRequest) throws -> (PTYSessionInfo, (any SessionLifecycleObserver)?) {
        try queue.sync {
            let session = try PTYSession.spawn(
                request: request,
                scrollbackCapacity: configuration.scrollbackCapacity,
                tuning: configuration.sessionTuning,
                onExit: { [weak self] session, status in
                    guard let self else { return }
                    self.queue.async { self.sessionExited(session, status: status) }
                },
                onSettled: { [weak self] session in
                    guard let self else { return }
                    self.queue.async { self.sessionSettled(session) }
                }
            )
            sessions[session.id] = session
            idleGeneration += 1 // a running session cancels a pending idle exit
            let info = session.info
            persistLocked(PersistedSession(info: info, endedAt: nil))
            Self.logger.info("spawned session \(session.id, privacy: .public) pid \(session.pid)")
            return (info, observer)
        }
    }

    public func session(_ id: String) -> PTYSession? {
        queue.sync { sessions[id] }
    }

    /// Live sessions of this helper plus sessions recorded by previous helper processes (flagged not running).
    public func listSessions() -> [PTYSessionInfo] {
        queue.sync {
            let live = sessions.values.map(\.info)
            let old = stale.values.map(\.info)
            return (live + old).sorted { $0.startedAt < $1.startedAt }
        }
    }

    public var runningSessionCount: Int {
        queue.sync { sessions.values.filter(\.isRunning).count }
    }

    /// Input from a client (the user typing in the app).
    public func write(sessionID: String, data: Data) {
        let (session, observer) = queue.sync { (sessions[sessionID], self.observer) }
        session?.write(data)
        if session != nil { observer?.sessionReceivedInput(sessionID, data: data) }
    }

    /// Input Suijin types itself (an orchestration message); not reported as user input.
    public func injectInput(sessionID: String, data: Data) {
        session(sessionID)?.write(data)
    }

    public func resize(sessionID: String, cols: Int, rows: Int) {
        session(sessionID)?.resize(cols: cols, rows: rows)
    }

    /// Ends the session's processes and forgets the session: once it is settled (exited, swept, and its exit received
    /// by every attachment) it is dropped with its scrollback and metadata. A session that already ended is dropped
    /// the same way, and so is a record left by a previous helper process.
    public func terminate(sessionID: String, completion: (@Sendable (Int32) -> Void)? = nil) {
        let session: PTYSession? = queue.sync {
            if let session = sessions[sessionID] {
                released.insert(sessionID)
                return session
            }
            if stale.removeValue(forKey: sessionID) != nil { deleteMetadataLocked(sessionID) }
            return nil
        }
        guard let session else {
            completion?(-1)
            return
        }
        session.terminate(completion: completion) // reports settled, now or when the processes are gone
    }

    // MARK: Clients

    public func clientConnected(_ clientID: UUID) {
        queue.sync {
            if clients[clientID] == nil { clients[clientID] = [:] }
            idleGeneration += 1
        }
    }

    /// Detaches everything the client was attached to (connection invalidated or interrupted).
    public func clientDisconnected(_ clientID: UUID) {
        queue.sync {
            guard let attachments = clients.removeValue(forKey: clientID) else { return }
            for (sessionID, token) in attachments {
                sessions[sessionID]?.detach(token)
            }
            evaluateIdleLocked()
        }
    }

    public var connectedClientCount: Int {
        queue.sync { clients.count }
    }

    /// Attaches `sink` for `clientID`, replacing an earlier attachment of the same client to the same session.
    /// `onSnapshot` runs synchronously, before any live output reaches `sink`. Returns false for an unknown session.
    /// A `flowControlled` client must `acknowledge` consumed bytes.
    @discardableResult
    public func attach(
        sessionID: String,
        clientID: UUID,
        sink: any PTYOutputSink,
        flowControlled: Bool = false,
        onSnapshot: (Data, PTYSessionInfo) -> Void
    ) -> Bool {
        queue.sync {
            guard let session = sessions[sessionID] else { return false }
            if let previous = clients[clientID]?[sessionID] {
                session.detach(previous)
            }
            let token = session.attach(sink, flowControlled: flowControlled, onSnapshot: onSnapshot)
            clients[clientID, default: [:]][sessionID] = token
            return true
        }
    }

    public func acknowledge(sessionID: String, clientID: UUID, bytes: Int) {
        queue.sync {
            guard let token = clients[clientID]?[sessionID] else { return }
            sessions[sessionID]?.acknowledge(token, bytes: bytes)
        }
    }

    public func detach(sessionID: String, clientID: UUID) {
        queue.sync {
            guard let token = clients[clientID]?.removeValue(forKey: sessionID) else { return }
            sessions[sessionID]?.detach(token)
        }
    }

    // MARK: Lifecycle

    /// Fires `onIdle` right away when no session is running (connected clients do not count).
    public func shutdownIfIdle() {
        queue.async {
            guard self.runningCountLocked() == 0 else { return }
            Self.logger.info("shutdown requested while idle")
            self.onIdle?()
        }
    }

    /// Drops exited, unattached sessions and stale records older than the retention window.
    public func reap(now: Date = Date()) {
        queue.sync { reapLocked(now: now) }
    }

    // MARK: Queue-confined internals

    private func runningCountLocked() -> Int {
        sessions.values.filter(\.isRunning).count
    }

    private func isAttachedLocked(_ sessionID: String) -> Bool {
        clients.values.contains { $0[sessionID] != nil }
    }

    /// Runs after `sessionExited`. A released session goes entirely; one that ended on its own keeps its tail.
    private func sessionSettled(_ session: PTYSession) {
        guard sessions[session.id] === session else { return }
        guard released.contains(session.id) else {
            session.trimScrollback(toLast: configuration.exitedTailBytes)
            return
        }
        sessions[session.id] = nil
        endedAt[session.id] = nil
        released.remove(session.id)
        for client in clients.keys { clients[client]?[session.id] = nil }
        deleteMetadataLocked(session.id)
        Self.logger.info("forgot session \(session.id, privacy: .public)")
    }

    private func sessionExited(_ session: PTYSession, status: Int32) {
        let now = Date()
        endedAt[session.id] = now
        persistLocked(PersistedSession(info: session.info, endedAt: now))
        Self.logger.info("session \(session.id, privacy: .public) exited with \(status)")
        observer?.sessionExited(session.id, status: status)
        evaluateIdleLocked()
    }

    private func evaluateIdleLocked() {
        guard started, runningCountLocked() == 0, clients.isEmpty else { return }
        idleGeneration += 1
        let generation = idleGeneration
        queue.asyncAfter(deadline: .now() + configuration.idleGrace) { [weak self] in
            guard let self, self.idleGeneration == generation,
                  self.runningCountLocked() == 0, self.clients.isEmpty else { return }
            Self.logger.info("idle, exiting")
            self.onIdle?()
        }
    }

    private func reapLocked(now: Date) {
        let cutoff = now.addingTimeInterval(-configuration.exitedRetention)
        for (id, session) in sessions where !session.isRunning && !isAttachedLocked(id) {
            guard let ended = endedAt[id], ended <= cutoff else { continue }
            sessions[id] = nil
            endedAt[id] = nil
            deleteMetadataLocked(id)
        }
        for (id, record) in stale where (record.endedAt ?? record.info.startedAt) <= cutoff {
            stale[id] = nil
            deleteMetadataLocked(id)
        }
    }

    // MARK: Persistence

    private func metadataURL(_ id: String) -> URL? {
        configuration.metadataDirectory?.appendingPathComponent("\(id).json", isDirectory: false)
    }

    private func persistLocked(_ record: PersistedSession) {
        guard let directory = configuration.metadataDirectory, let url = metadataURL(record.info.id) else { return }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            try PTYCoding.encode(record).write(to: url, options: .atomic)
        } catch {
            Self.logger.error("cannot persist session metadata: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deleteMetadataLocked(_ id: String) {
        guard let url = metadataURL(id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func loadPersistedSessions() {
        guard let directory = configuration.metadataDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        let now = Date()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var record = try? PTYCoding.decode(PersistedSession.self, from: data),
                  file.deletingPathExtension().lastPathComponent == record.info.id,
                  sessions[record.info.id] == nil
            else { continue }
            if record.info.isRunning {
                // Its PTY died with the previous helper; the exit status is unknown.
                record.info.isRunning = false
                record.endedAt = record.endedAt ?? now
                persistLocked(record)
            }
            stale[record.info.id] = record
        }
    }
}
