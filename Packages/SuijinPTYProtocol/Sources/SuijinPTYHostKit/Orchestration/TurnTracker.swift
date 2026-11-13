import Foundation

/// Whether each agent session is in a turn, from the agents' own signals: Claude's `Stop` / `UserPromptSubmit` /
/// `Notification` hooks and Codex's `notify` program (both reach the broker through `suijin hook …`). The broker
/// types a message into a session only when it is idle and the user has not typed there for a few seconds.
///
/// A session whose state no signal has told yet is `unknown` and never receives messages: guessing from output alone
/// could type into the middle of a turn.
struct TurnTracker {
    enum Phase: Equatable, Sendable {
        case unknown
        /// In a turn (a prompt was submitted, or Suijin just delivered a message).
        case busy
        /// The turn ended; the agent waits at its prompt.
        case idle
        /// Waiting on a permission prompt: typing would answer it, so nothing is delivered.
        case blocked
    }

    enum Readiness: Equatable, Sendable {
        case ready
        /// Idle, but the user typed recently; try again at the given time.
        case deferred(until: Date)
        case notIdle
    }

    struct State: Equatable, Sendable {
        var phase: Phase = .unknown
        var phaseSince: Date
        var lastUserInput: Date?
        /// Busy only because the user pressed Return; no agent signal confirmed a turn.
        var busyFromUserInput = false
        /// `bytesRead` of the PTY and when it last changed, to expire an unconfirmed busy state.
        var lastBytesRead: UInt64?
        var lastOutputChange: Date?
    }

    /// Quiet time required after the user's last keystroke.
    var inputQuietPeriod: TimeInterval = 3
    /// An unconfirmed busy state (Return pressed, no turn signal) ends after this long without output: a real turn
    /// keeps drawing (spinner, timer), an empty Return does not.
    var unconfirmedBusyExpiry: TimeInterval = 20

    private(set) var states: [String: State] = [:]

    func state(_ sessionID: String) -> State? { states[sessionID] }

    func phase(_ sessionID: String) -> Phase { states[sessionID]?.phase ?? .unknown }

    mutating func track(_ sessionID: String, now: Date) {
        if states[sessionID] == nil { states[sessionID] = State(phaseSince: now) }
    }

    mutating func forget(_ sessionID: String) {
        states[sessionID] = nil
    }

    mutating func turnStarted(_ sessionID: String, now: Date) {
        set(sessionID, .busy, now: now)
    }

    mutating func turnEnded(_ sessionID: String, now: Date) {
        set(sessionID, .idle, now: now)
    }

    mutating func blocked(_ sessionID: String, now: Date) {
        set(sessionID, .blocked, now: now)
    }

    /// Suijin typed a message and pressed Return: a turn starts.
    mutating func delivered(_ sessionID: String, now: Date) {
        set(sessionID, .busy, now: now)
    }

    /// Keystrokes from the user (through the app). Return while idle most likely starts a turn.
    mutating func userInput(_ sessionID: String, data: Data, now: Date) {
        track(sessionID, now: now)
        states[sessionID]?.lastUserInput = now
        let submits = data.contains(0x0D) || data.contains(0x0A)
        if submits, states[sessionID]?.phase == .idle {
            set(sessionID, .busy, now: now)
            states[sessionID]?.busyFromUserInput = true
        }
        // Answering a permission prompt resumes the turn.
        if submits, states[sessionID]?.phase == .blocked { set(sessionID, .busy, now: now) }
    }

    /// Feeds the PTY's read counter; ends an unconfirmed busy state once output stopped for `unconfirmedBusyExpiry`.
    mutating func observeOutput(_ sessionID: String, bytesRead: UInt64, now: Date) {
        guard var state = states[sessionID] else { return }
        if state.lastBytesRead != bytesRead {
            state.lastBytesRead = bytesRead
            state.lastOutputChange = now
        }
        if state.phase == .busy, state.busyFromUserInput,
           now.timeIntervalSince(max(state.lastOutputChange ?? state.phaseSince, state.phaseSince)) >= unconfirmedBusyExpiry {
            state.phase = .idle
            state.phaseSince = now
            state.busyFromUserInput = false
        }
        states[sessionID] = state
    }

    func readiness(_ sessionID: String, now: Date) -> Readiness {
        guard let state = states[sessionID], state.phase == .idle else { return .notIdle }
        if let typed = state.lastUserInput {
            let until = typed.addingTimeInterval(inputQuietPeriod)
            if until > now { return .deferred(until: until) }
        }
        return .ready
    }

    private mutating func set(_ sessionID: String, _ phase: Phase, now: Date) {
        track(sessionID, now: now)
        states[sessionID]?.phase = phase
        states[sessionID]?.phaseSince = now
        states[sessionID]?.busyFromUserInput = false
    }
}
