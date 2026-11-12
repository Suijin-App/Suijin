import Foundation

/// Binds one `TerminalEngine` to one `MercuryTerminalView`: view input goes to `engine.write`, engine output to the
/// view (through a `TerminalFeedScheduler`, so a flood cannot stall the main thread), grid size changes to
/// `engine.resize`, and the process exit to `onExit` once all output before it was fed.
///
/// The session owns the view, so moving it between tabs or splits keeps the screen and scrollback.
@MainActor
public final class TerminalSession {
    public let engine: any TerminalEngine
    public let view: MercuryTerminalView
    public let scheduler: TerminalFeedScheduler

    /// Called once when the process exits, after its last output was fed (see `TerminalEngine.onExit` for the code).
    public var onExit: ((Int32?) -> Void)?
    public private(set) var isRunning = false
    public private(set) var exitCode: Int32?
    public private(set) var hasExited = false

    /// Scrollback from `attached(scrollback:)` is still waiting to be fed.
    var isReplayingScrollback: Bool { pendingScrollback > 0 }

    /// Output received but not fed to the view yet.
    public var pendingByteCount: Int { pending.count - pendingOffset }
    /// Bytes fed to the view so far, scrollback included (diagnostics and tests).
    public private(set) var fedByteCount = 0

    private var pending: [UInt8] = []
    private var pendingOffset = 0
    /// Leading pending bytes that are scrollback from `attached(scrollback:)`, not engine output, so they are not
    /// reported through `outputConsumed`.
    private var pendingScrollback = 0
    /// The exit the engine reported, waiting for the pending output to be fed.
    private var pendingExit: Int32??

    public init(engine: any TerminalEngine, view: MercuryTerminalView? = nil, scheduler: TerminalFeedScheduler? = nil) {
        self.engine = engine
        self.view = view ?? MercuryTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        self.scheduler = scheduler ?? .shared
        (engine as? SwiftTermEngine)?.enableConsumptionFlowControl()
        bind()
    }

    private func bind() {
        view.onInput = { [weak self] bytes in
            guard let self, isRunning else { return }
            engine.write(bytes)
        }
        view.onSizeChange = { [weak self] size in
            guard let self, isRunning else { return }
            engine.resize(size)
        }
        engine.onOutput = { [weak self] bytes in
            self?.receive(bytes)
        }
        engine.onExit = { [weak self] code in
            guard let self, !hasExited, pendingExit == nil else { return }
            pendingExit = .some(code)
            scheduler.enqueue(self)
        }
    }

    /// Starts the process at the view's current grid size.
    public func start(_ launch: TerminalLaunch) async throws {
        try await engine.start(launch, size: view.gridSize)
        isRunning = !hasExited && pendingExit == nil
        // The view may have been laid out while the process was starting.
        if isRunning { engine.resize(view.gridSize) }
    }

    /// Marks a session the engine already attached to (a hosted session restored after relaunch) as running and
    /// shows its scrollback ahead of any live output that already arrived.
    public func attached(scrollback: [UInt8]) {
        if !scrollback.isEmpty {
            pending = scrollback + pending[pendingOffset...]
            pendingOffset = 0
            pendingScrollback += scrollback.count
            view.isReplayingScrollback = true
            scheduler.enqueue(self)
        }
        isRunning = !hasExited && pendingExit == nil
        if isRunning { engine.resize(view.gridSize) }
    }

    /// Sends bytes to the program as if typed.
    public func send(_ bytes: [UInt8]) {
        guard isRunning else { return }
        engine.write(bytes[...])
    }

    public func send(_ text: String) {
        send(Array(text.utf8))
    }

    /// Hangs up and, if needed, kills the process; returns once it is gone and its exit was delivered (after the
    /// output before it), or after `exitTimeout` when the engine never reports an exit.
    public func terminate(exitTimeout: Duration = .seconds(5)) async {
        await engine.terminate()
        guard !hasExited else { return }
        let timer = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: exitTimeout)) != nil else { return }
            self?.releaseExitWaiters()
        }
        await withCheckedContinuation { exitWaiters.append($0) }
        timer.cancel()
    }

    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    private func releaseExitWaiters() {
        let waiters = exitWaiters
        exitWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    // MARK: Feeding

    private func receive(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        pending.append(contentsOf: bytes)
        scheduler.enqueue(self)
    }

    /// Feeds up to `maxBytes` to the view, then delivers a pending exit once nothing is left. Returns whether more
    /// work remains.
    func feedNextChunk(maxBytes: Int) -> Bool {
        let count = min(maxBytes, pendingByteCount)
        if count > 0 {
            let end = pendingOffset + count
            view.feed(byteArray: pending[pendingOffset..<end])
            pendingOffset = end
            fedByteCount += count
            let scrollback = min(count, pendingScrollback)
            pendingScrollback -= scrollback
            if pendingScrollback == 0, view.isReplayingScrollback { view.isReplayingScrollback = false }
            if count > scrollback { engine.outputConsumed(count - scrollback) }
            compactPending()
        }
        if pendingByteCount > 0 { return true }
        if let code = pendingExit {
            pendingExit = nil
            deliverExit(code)
        }
        return false
    }

    private func compactPending() {
        if pendingOffset == pending.count {
            pending.removeAll(keepingCapacity: pending.capacity <= 1024 * 1024)
            pendingOffset = 0
        } else if pendingOffset > 1024 * 1024, pendingOffset * 2 > pending.count {
            pending.removeFirst(pendingOffset)
            pendingOffset = 0
        }
    }

    private func deliverExit(_ code: Int32?) {
        guard !hasExited else { return }
        isRunning = false
        hasExited = true
        exitCode = code
        releaseExitWaiters()
        onExit?(code)
    }
}
