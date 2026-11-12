import Darwin
import Foundation

/// Runs the process under a PTY inside the app's own process (no helper). Closing the app ends its terminals.
///
/// `terminate()` hangs up every process group attached to the PTY, waits `terminationGracePeriod`, then SIGKILLs the
/// child and every process still attached to the PTY (including `nohup`ed jobs), so closing a tab leaves nothing behind.
@MainActor
public final class SwiftTermEngine: TerminalEngine {
    public var onOutput: (@MainActor (ArraySlice<UInt8>) -> Void)?
    public var onExit: (@MainActor (Int32?) -> Void)?
    public var sessionID: String? { nil }

    /// The child's PID once started.
    public private(set) var processID: pid_t?
    /// The exit code once the child exited (see `TerminalEngine.onExit`).
    public private(set) var exitCode: Int32?
    public private(set) var hasExited = false
    public let terminationGracePeriod: Duration

    private var channel: PTYChannel?
    private var isTerminating = false
    private var consumptionFlowControl = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    public init(terminationGracePeriod: Duration = .seconds(2)) {
        self.terminationGracePeriod = terminationGracePeriod
    }

    isolated deinit {
        // Dropped without `terminate()`: hang up and kill without waiting. The channel keeps itself alive until it has
        // reaped the child, so no zombie is left either.
        guard let channel, !channel.hasExited else { return }
        channel.signalSession(SIGHUP)
        channel.killSessionMembers()
    }

    public func start(_ launch: TerminalLaunch, size: TerminalSize) async throws {
        guard channel == nil else { throw TerminalEngineError.alreadyStarted }
        let spawned = try PTYChannel.spawn(launch, size: size)
        channel = spawned
        processID = spawned.pid
        if consumptionFlowControl { spawned.countConsumption() }
        spawned.activate(
            output: { [weak self] bytes in self?.onOutput?(bytes) },
            exit: { [weak self] code in self?.processExited(code) }
        )
    }

    public func write(_ bytes: ArraySlice<UInt8>) {
        channel?.write(Array(bytes))
    }

    /// Opts into flow control by consumption: once called, PTY reads pause while more than 4 MB of delivered output
    /// has not been reported through `outputConsumed(_:)`. Consumers that feed output synchronously in `onOutput`
    /// need not call it.
    public func enableConsumptionFlowControl() {
        consumptionFlowControl = true
        channel?.countConsumption()
    }

    public func outputConsumed(_ byteCount: Int) {
        channel?.consumed(byteCount)
    }

    public func resize(_ size: TerminalSize) {
        channel?.resize(size)
    }

    public func terminate() async {
        guard let channel, !hasExited else { return }
        guard !isTerminating else {
            // A second caller waits for the sequence the first one runs.
            await waitForExit(timeout: terminationGracePeriod + .seconds(5))
            return
        }
        // Keep the PTY allocated until the sweep below, so its device number still names only this session. When
        // it is already closed the child was reaped and only the exit delivery is pending.
        guard channel.beginTermination() else {
            await waitForExit(timeout: .seconds(5))
            return
        }
        isTerminating = true
        defer {
            isTerminating = false
            channel.endTermination()
        }
        channel.signalSession(SIGHUP)
        await waitForExit(timeout: terminationGracePeriod)
        // The shell may be gone while jobs that ignore SIGHUP (nohup) are still attached to the PTY.
        channel.killSessionMembers()
        await waitForExit(timeout: .seconds(5))
    }

    private func processExited(_ code: Int32?) {
        guard !hasExited else { return }
        hasExited = true
        exitCode = code
        let waiters = exitWaiters
        exitWaiters.removeAll()
        waiters.forEach { $0.resume() }
        onExit?(code)
    }

    /// Returns once the exit was delivered or `timeout` passed.
    private func waitForExit(timeout: Duration) async {
        guard !hasExited else { return }
        let timer = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.releaseWaiters()
        }
        await withCheckedContinuation { exitWaiters.append($0) }
        timer.cancel()
    }

    private func releaseWaiters() {
        let waiters = exitWaiters
        exitWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
