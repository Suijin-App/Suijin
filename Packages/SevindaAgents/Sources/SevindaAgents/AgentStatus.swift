import Foundation
import SevindaCore

/// Live activity of an agent session.
public enum AgentActivity: Sendable, Equatable {
    case starting
    case running
    case waitingForInput
    case idle
    case exited(Int32)
    case failed(String)

    public var sessionState: SessionState {
        switch self {
        case .starting: .starting
        case .running: .running
        case .waitingForInput: .waitingForInput
        case .idle: .idle
        case .exited: .exited
        case .failed: .failed
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .exited, .failed: true
        default: false
        }
    }
}

/// Derives an `AgentActivity` from terminal output timing, Claude hook events and process exit.
///
/// - starting → running on the first output.
/// - running → idle after `idleThreshold` seconds without output (checked by `tick`).
/// - Notification hook → waitingForInput; Stop hook → idle ("turn done"). Both are *quiet* states:
///   output alone (redraws, status lines) does not leave them. They end on UserPromptSubmit, or on
///   output that follows user input (`noteInput`) given after the state was entered.
/// - idle reached by timeout leaves on any output.
/// - exit → exited(code), or failed when there is no exit status; terminal states never change.
@MainActor
public final class AgentStatusTracker {
    public private(set) var activity: AgentActivity = .starting {
        didSet { if activity != oldValue { onChange?(activity) } }
    }
    public var onChange: ((AgentActivity) -> Void)?

    public let idleThreshold: TimeInterval
    private let clock: () -> Date
    private var lastOutput: Date?
    private var quietSince: Date?
    private var lastInput: Date?

    /// Notification types that are informational and do not mean the agent waits for the user.
    static let nonBlockingNotificationTypes: Set<String> = ["auth_success"]

    public init(idleThreshold: TimeInterval = 8, clock: @escaping () -> Date = Date.init) {
        self.idleThreshold = idleThreshold
        self.clock = clock
    }

    public func noteOutput(at date: Date) {
        guard !activity.isTerminal else { return }
        lastOutput = date
        if let quietSince {
            guard let lastInput, lastInput >= quietSince, date >= lastInput else { return }
            self.quietSince = nil
        }
        activity = .running
    }

    /// The user typed into the session; the next output counts as the agent resuming work.
    public func noteInput(at date: Date) {
        guard !activity.isTerminal else { return }
        lastInput = date
    }

    public func noteHookEvent(_ event: ClaudeHookEvent) {
        guard !activity.isTerminal else { return }
        let now = clock()
        switch event.name {
        case "UserPromptSubmit":
            quietSince = nil
            lastOutput = now
            activity = .running
        case "Notification":
            if let type = event.notificationType, Self.nonBlockingNotificationTypes.contains(type) { return }
            enterQuiet(.waitingForInput, at: now)
        case "PermissionRequest":
            enterQuiet(.waitingForInput, at: now)
        case "Stop", "StopFailure":
            enterQuiet(.idle, at: now)
        default:
            break
        }
    }

    public func noteExit(_ code: Int32?) {
        guard !activity.isTerminal else { return }
        activity = code.map(AgentActivity.exited) ?? .failed("The process ended without an exit status.")
    }

    /// The session could not start or broke for a reason other than a normal exit.
    public func noteFailure(_ message: String) {
        guard !activity.isTerminal else { return }
        activity = .failed(message)
    }

    /// Another program took over the terminal (an agent started in a shell, or the shell came back): the session is
    /// `starting` again and nothing from before (a quiet state, the last output) carries over. Does nothing after the
    /// exit.
    public func restart() {
        guard !activity.isTerminal else { return }
        lastOutput = nil
        quietSince = nil
        lastInput = nil
        activity = .starting
    }

    /// Call periodically (about once a second) to apply the idle timeout.
    public func tick(now: Date) {
        guard activity == .running, let lastOutput, now.timeIntervalSince(lastOutput) >= idleThreshold else { return }
        activity = .idle
    }

    private func enterQuiet(_ state: AgentActivity, at date: Date) {
        quietSince = date
        activity = state
    }
}
