import Foundation

/// Binds one `TerminalEngine` to one `SevindaTerminalView`: view input goes to `engine.write`, engine output to the
/// view (through a `TerminalFeedScheduler`, so a flood cannot stall the main thread), grid size changes to
/// `engine.resize`, and the process exit to `onExit` once all output before it was fed.
///
/// The session owns the view, so moving it between tabs or splits keeps the screen and scrollback.
@MainActor
public final class TerminalSession {
    public let engine: any TerminalEngine
    public let view: SevindaTerminalView
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

    /// `theme` is installed before any output is fed: programs ask for the terminal's colors as they start (OSC 10/11,
    /// as Codex does to pick a light or dark palette), often before the session is on screen, and SwiftTerm answers
    /// with the view's current colors.
    public init(engine: any TerminalEngine, view: SevindaTerminalView? = nil, scheduler: TerminalFeedScheduler? = nil,
                theme: TerminalTheme? = nil) {
        self.engine = engine
        self.view = view ?? SevindaTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        self.scheduler = scheduler ?? .shared
        if let theme { self.view.apply(theme) }
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

    /// Keeps the screen hidden while the program prints a burst it starts with (a resumed agent re-printing its
    /// conversation), so it appears once, already at the end, instead of scrolling through every line. Input typed
    /// meanwhile still reaches the program.
    ///
    /// The screen shows again once the program printed something and then stayed silent, with everything fed: for
    /// `quiet` once its output filled the screen, for `quietBeforeScreenful` while it has printed less (an agent may set
    /// up the terminal first and print its history a moment later). It also shows when the program exits, and after
    /// `limit` whatever happens, so it never stays hidden. Silence is counted in checks `tick` apart, each its own turn
    /// of the main actor: a main thread that was busy for a while counts as one check, not as a quiet period, since the
    /// output and the flow-control credits it held back were waiting behind it.
    public func catchUp(quiet: Duration = .milliseconds(200), quietBeforeScreenful: Duration = .milliseconds(750),
                        limit: Duration = .seconds(3), tick: Duration = .milliseconds(25)) {
        catchUpWatch?.cancel()
        catchUpLines = 0
        view.isCatchingUp = true
        let deadline = ContinuousClock.now + limit
        let startFed = fedByteCount
        catchUpWatch = Task { @MainActor [weak self] in
            var silentChecks = 0
            var seenFed = startFed
            while true {
                guard (try? await Task.sleep(for: tick)) != nil else { return }
                guard let self, view.isCatchingUp else { return }
                if ContinuousClock.now >= deadline { break }
                if fedByteCount != seenFed || pendingByteCount > 0 {
                    seenFed = fedByteCount
                    silentChecks = 0
                    continue
                }
                guard fedByteCount > startFed else { continue } // still starting: nothing printed yet
                silentChecks += 1
                let needed = catchUpLines >= view.gridSize.rows ? quiet : quietBeforeScreenful
                if tick * silentChecks >= needed { break }
            }
            self?.endCatchUp()
        }
    }

    private func endCatchUp() {
        catchUpWatch?.cancel()
        catchUpWatch = nil
        if view.isCatchingUp { view.isCatchingUp = false }
    }

    private var catchUpWatch: Task<Void, Never>?
    /// Lines the program printed during the catch-up.
    private var catchUpLines = 0

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
            view.noteOutputFed(byteCount: count)
            pendingOffset = end
            fedByteCount += count
            let scrollback = min(count, pendingScrollback)
            pendingScrollback -= scrollback
            if pendingScrollback == 0, view.isReplayingScrollback { view.isReplayingScrollback = false }
            if count > scrollback {
                engine.outputConsumed(count - scrollback)
                if view.isCatchingUp {
                    catchUpLines += pending[(end - count + scrollback)..<end].reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
                }
            }
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
        // Nothing more is coming: show what the program left.
        endCatchUp()
        releaseExitWaiters()
        onExit?(code)
    }
}
