import Foundation

/// Feeds buffered terminal output to the emulators of every `TerminalSession` without starving the main thread.
///
/// Parsing output in SwiftTerm runs on the main actor. Feeding every chunk the moment it arrives lets ten flooding
/// terminals keep the main thread busy for seconds. Instead, sessions buffer their output and the scheduler drains
/// them round-robin, `chunkSize` bytes at a time, until `budget` (measured with a monotonic clock) is spent. It then
/// yields for `yieldInterval` through a timer, so the run loop can sleep, draw (Core Animation commits before the run
/// loop waits) and handle input before the next turn. A main-queue loop would never let it wait.
@MainActor
public final class TerminalFeedScheduler {
    /// The scheduler all sessions use unless given another one.
    public static let shared = TerminalFeedScheduler()

    public let budget: Duration
    public let chunkSize: Int
    public let yieldInterval: Duration

    /// Sessions with output waiting, in round-robin order.
    private var queue: [WeakSession] = []
    private var queued: Set<ObjectIdentifier> = []
    private var isScheduled = false
    private var lastTurnEnd: ContinuousClock.Instant?

    /// The longest feeding turn so far (diagnostics and tests).
    public private(set) var longestTurn: Duration = .zero
    /// Turns run so far (diagnostics and tests).
    public private(set) var turnCount = 0
    /// Called after every chunk with the session and the byte count (tests).
    var chunkObserver: ((TerminalSession, Int) -> Void)?

    public init(budget: Duration = .milliseconds(5), chunkSize: Int = 16 * 1024, yieldInterval: Duration = .milliseconds(1)) {
        self.budget = budget
        self.chunkSize = max(1, chunkSize)
        self.yieldInterval = yieldInterval
    }

    /// Output waiting in every live session.
    public var pendingByteCount: Int {
        queue.reduce(0) { $0 + ($1.session?.pendingByteCount ?? 0) }
    }

    /// Puts a session with new pending output (or a pending exit) in line.
    func enqueue(_ session: TerminalSession) {
        if queued.insert(ObjectIdentifier(session)).inserted {
            queue.append(WeakSession(session: session))
        }
        scheduleTurn()
    }

    private func scheduleTurn() {
        guard !isScheduled, !queue.isEmpty else { return }
        isScheduled = true
        // Right after a turn, wait so the run loop gets its turn; after a quiet period, feed at once so a keystroke's
        // echo shows without delay.
        let sinceLastTurn = lastTurnEnd.map { ContinuousClock.now - $0 } ?? .seconds(1)
        if sinceLastTurn >= yieldInterval {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.runTurn() } }
        } else {
            let delay = yieldInterval - sinceLastTurn
            let nanoseconds = Int(delay.components.seconds) * 1_000_000_000 + Int(delay.components.attoseconds / 1_000_000_000)
            DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(max(nanoseconds, 100_000))) {
                MainActor.assumeIsolated { self.runTurn() }
            }
        }
    }

    private func runTurn() {
        isScheduled = false
        let clock = ContinuousClock()
        let start = clock.now
        while !queue.isEmpty, clock.now - start < budget {
            // A restored session's scrollback on screen goes first: it is what the user waits to see after launch.
            // So does a resumed agent's history while its screen waits for it (`TerminalSession.catchUp`). Only those
            // jump the line (a replay is finite, a catch-up ends within its limit); live output keeps the round-robin.
            let index = queue.firstIndex { $0.session.map(Self.isVisibleReplay) == true } ?? 0
            let entry = queue.remove(at: index)
            guard let session = entry.session else { continue }
            let id = ObjectIdentifier(session)
            let before = session.fedByteCount
            let more = session.feedNextChunk(maxBytes: chunkSize)
            if session.fedByteCount > before { chunkObserver?(session, session.fedByteCount - before) }
            if more {
                queue.append(entry)
            } else {
                queued.remove(id)
            }
        }
        // Drop sessions that went away while waiting.
        queue.removeAll { $0.session == nil }
        queued = Set(queue.compactMap { $0.session.map(ObjectIdentifier.init) })
        let end = clock.now
        longestTurn = max(longestTurn, end - start)
        turnCount += 1
        lastTurnEnd = end
        scheduleTurn()
    }

    private static func isVisibleReplay(_ session: TerminalSession) -> Bool {
        (session.isReplayingScrollback || session.view.isCatchingUp) && session.view.window != nil
    }

    private struct WeakSession {
        weak var session: TerminalSession?
    }
}
