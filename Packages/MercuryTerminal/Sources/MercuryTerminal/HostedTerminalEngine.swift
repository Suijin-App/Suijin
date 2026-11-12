import Foundation
import MercuryPTYProtocol

/// A `TerminalEngine` whose process lives in the PTY host helper, so it survives the app quitting or crashing.
///
/// `start` spawns a session in the helper and attaches; `attach(sessionID:)` re-attaches to a session after an app
/// restart and returns its scrollback for the caller to replay into the emulator before live output continues.
///
/// Ordering: XPC orders messages but not a reply relative to messages, so the helper opens each attachment's stream
/// with an empty output message. Bytes before that marker belong to an earlier attachment and are dropped; bytes after
/// it that arrive before the awaiting caller resumes are buffered and appended to the returned scrollback.
///
/// Flow control: the helper streams at most a window of unacknowledged bytes. Bytes handed to `onOutput` are credited
/// back when the consumer reports them through `outputConsumed(_:)` (TerminalSession does after feeding each chunk);
/// bytes the engine drops are credited at once. A consumer that never reports consumption stalls the session.
@MainActor public final class HostedTerminalEngine: TerminalEngine {
    public var onOutput: (@MainActor (ArraySlice<UInt8>) -> Void)?
    public var onExit: (@MainActor (Int32?) -> Void)?
    public private(set) var sessionID: String?
    /// Session details from the last attach reply.
    public private(set) var info: PTYSessionInfo?

    /// Upper bound on how long `terminate()` waits for the exit after SIGHUP (the helper escalates at 2 s).
    public var terminateTimeout: Duration = .seconds(5)

    private enum Phase: Equatable {
        case idle
        /// Attach request sent; the caller has not resumed yet.
        case attaching
        case live
        case exited
    }

    private let client: PTYHostClient
    private var phase = Phase.idle
    /// The stream-start marker of the current attachment has arrived.
    private var streamStarted = false
    private var pendingOutput: [UInt8] = []
    private var pendingExitStatus: Int32?
    /// Stream bytes handed to `onOutput` and not yet reported consumed.
    private var unconsumed = 0
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    public init(client: PTYHostClient) {
        self.client = client
    }

    public func start(_ launch: TerminalLaunch, size: TerminalSize) async throws {
        guard phase == .idle, sessionID == nil else { throw TerminalEngineError.alreadyStarted }
        let size = size.clamped
        let request = PTYSpawnRequest(
            executable: launch.executable, arguments: launch.arguments, environment: launch.environment,
            cwd: launch.cwd, cols: size.cols, rows: size.rows, metadata: launch.metadata
        )
        let id = try await client.spawn(request)
        let (scrollback, buffered) = try await attachSession(id)
        let initial = scrollback + buffered
        if !initial.isEmpty {
            if onOutput != nil {
                unconsumed += buffered.count // the scrollback part was never counted by the helper
                onOutput?(initial[...])
            } else {
                credit(buffered.count)
            }
        }
        deliverPendingExit()
    }

    /// Re-attaches to an existing helper session and returns its scrollback (plus anything produced while attaching).
    /// Live output follows through `onOutput`. If the session already exited, `onExit` fires right after the caller's
    /// current main-actor turn, so the scrollback can be fed first.
    public func attach(sessionID: String) async throws -> [UInt8] {
        guard phase == .idle, self.sessionID == nil else { throw TerminalEngineError.alreadyStarted }
        let (scrollback, buffered) = try await attachSession(sessionID)
        credit(buffered.count) // returned to the caller, outside the onOutput accounting
        if pendingExitStatus != nil {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.deliverPendingExit() } }
        }
        return scrollback + buffered
    }

    public func write(_ bytes: ArraySlice<UInt8>) {
        guard phase == .live || phase == .attaching, let sessionID, !bytes.isEmpty else { return }
        client.write(sessionID, data: Data(bytes))
    }

    public func resize(_ size: TerminalSize) {
        guard phase != .exited, phase != .idle, let sessionID else { return }
        let size = size.clamped
        client.resize(sessionID, cols: size.cols, rows: size.rows)
    }

    /// Closing the tab: ends every process of the session. Also sent after the shell exited on its own, so background
    /// jobs it left behind are swept too.
    public func terminate() async {
        guard let sessionID, phase != .idle else { return }
        client.terminate(sessionID)
        guard phase != .exited else { return }
        let timeout = terminateTimeout
        await withCheckedContinuation { continuation in
            exitWaiters.append(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resumeExitWaiters()
            }
        }
    }

    public func outputConsumed(_ byteCount: Int) {
        let consumed = min(max(byteCount, 0), unconsumed)
        guard consumed > 0 else { return }
        unconsumed -= consumed
        credit(consumed)
    }

    /// Stops receiving the session in this app; it keeps running in the helper and can be attached again later.
    public func detach() {
        guard let sessionID, phase != .idle else { return }
        client.detach(sessionID)
        self.sessionID = nil
        phase = .idle
        streamStarted = false
        pendingOutput = []
        pendingExitStatus = nil
        unconsumed = 0
        resumeExitWaiters()
    }

    // MARK: Called by PTYHostClient (main queue, in connection order)

    func receive(output: Data) {
        guard phase == .attaching || phase == .live else { return credit(output.count) }
        guard streamStarted else {
            // Leftovers of an earlier attachment; the helper no longer counts them against this one.
            if output.isEmpty { streamStarted = true }
            return
        }
        guard !output.isEmpty else { return }
        if phase == .attaching {
            pendingOutput.append(contentsOf: output)
        } else if onOutput != nil {
            unconsumed += output.count
            onOutput?([UInt8](output)[...])
        } else {
            credit(output.count)
        }
    }

    func receive(exitStatus: Int32) {
        guard streamStarted else { return } // an earlier attachment's exit; this one reports its own
        switch phase {
        case .attaching: pendingExitStatus = exitStatus
        case .live: finish(exitStatus: exitStatus)
        case .idle, .exited: break
        }
    }

    /// After the helper connection broke: re-attach without replaying scrollback (it is already on screen). A session
    /// that is gone (the helper died with it) ends with an unknown status.
    func recoverAfterHostConnectionLoss() async {
        guard phase == .live, let sessionID else { return }
        do {
            let (_, buffered) = try await attachSession(sessionID)
            if !buffered.isEmpty {
                if onOutput != nil {
                    unconsumed += buffered.count
                    onOutput?(buffered[...])
                } else {
                    credit(buffered.count)
                }
            }
            deliverPendingExit()
        } catch {
            finish(exitStatus: nil)
        }
    }

    // MARK: Internals

    /// Returns the scrollback and the live bytes buffered while attaching.
    private func attachSession(_ id: String) async throws -> (scrollback: [UInt8], buffered: [UInt8]) {
        sessionID = id
        phase = .attaching
        streamStarted = false
        pendingOutput = []
        pendingExitStatus = nil
        unconsumed = 0
        do {
            let (scrollback, info) = try await client.attach(id, engine: self)
            self.info = info
            let buffered = pendingOutput
            pendingOutput = []
            phase = .live
            return ([UInt8](scrollback), buffered)
        } catch {
            if phase != .exited {
                phase = .idle
                sessionID = nil
                streamStarted = false
                pendingOutput = []
            }
            throw error
        }
    }

    private func credit(_ bytes: Int) {
        guard bytes > 0, let sessionID else { return }
        client.acknowledge(sessionID, bytes: bytes)
    }

    private func deliverPendingExit() {
        guard let status = pendingExitStatus, phase == .live else { return }
        pendingExitStatus = nil
        finish(exitStatus: status)
    }

    private func finish(exitStatus: Int32?) {
        guard phase != .exited else { return }
        phase = .exited
        if let sessionID { client.unregister(sessionID, engine: self) }
        onExit?(exitStatus)
        resumeExitWaiters()
    }

    private func resumeExitWaiters() {
        let waiters = exitWaiters
        exitWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
