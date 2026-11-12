import Foundation
import MercuryAgents
import MercuryCore

/// Who a managed home is signed in as. Every field is optional: an API-key login has no identity claims.
public struct AccountIdentity: Sendable, Hashable {
    public var email: String?
    public var organization: String?
    public var accountID: String?

    public init(email: String? = nil, organization: String? = nil, accountID: String? = nil) {
        self.email = email
        self.organization = organization
        self.accountID = accountID
    }
}

/// One rate-limit window.
public struct UsageWindow: Sendable, Hashable {
    /// Share of the window already used, clamped to 0...1.
    public var usedFraction: Double
    public var resetsAt: Date?

    public init(usedFraction: Double, resetsAt: Date?) {
        self.usedFraction = min(1, max(0, usedFraction))
        self.resetsAt = resetsAt
    }
}

/// A weekly window that only counts one model, e.g. Claude's "Fable" limit.
public struct ModelUsageWindow: Sendable, Hashable {
    /// The model's display name as the provider reports it.
    public var model: String
    public var window: UsageWindow

    public init(model: String, window: UsageWindow) {
        self.model = model
        self.window = window
    }
}

/// The session (five hour) and weekly windows of one account, plus an optional model-scoped weekly window.
public struct UsageSnapshot: Sendable, Hashable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var modelWeekly: ModelUsageWindow?
    public var fetchedAt: Date

    public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, modelWeekly: ModelUsageWindow? = nil, fetchedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.modelWeekly = modelWeekly
        self.fetchedAt = fetchedAt
    }
}

/// A running CLI sign-in. `output` yields the CLI's output lines (ANSI stripped) so the UI can show and copy the
/// sign-in link; `wait()` returns once the login succeeded and throws `LoginError` otherwise.
public protocol LoginSession: AnyObject, Sendable {
    var output: AsyncStream<String> { get }
    func wait() async throws
    func cancel()
}

/// A login whose CLI reads stdin, e.g. Claude's "paste code here" fallback after signing in elsewhere.
public protocol InteractiveLoginSession: LoginSession {
    func send(_ text: String)
}

/// Managed accounts of one provider: one isolated config home per account.
public protocol ManagedAccountProvider: Sendable {
    var provider: AccountProvider { get }
    /// Creates (or repairs) the account's home: a safe directory, mode 700, owner marker written after setup.
    func createHome(accountID: UUID) throws -> URL
    /// Claude: re-runs profile provisioning. Codex: mirrors config and shared resources.
    func prepareForLaunch(home: URL) async throws
    /// Starts the provider CLI login inside `home` (10 minute timeout).
    func startLogin(home: URL) throws -> LoginSession
    func identity(home: URL) async -> AccountIdentity?
    /// Failures are thrown and must never block launching an agent.
    func usage(home: URL) async throws -> UsageSnapshot
    /// `nil` = the user's default login.
    func launchEnv(home: URL?) -> EnvPatch
    /// Selected-host pointer for the terminal shell functions; `nil` removes it (default login).
    func writePointer(home: URL?) throws
    /// Signs the home out (best effort), then deletes it.
    func removeHome(_ home: URL) async throws
}

/// Failures of account home management. Messages never contain credentials.
public enum AccountsError: Error, LocalizedError, Equatable, Sendable {
    /// The path is not a managed home, overlaps a default config home, or contains a symlink.
    case unsafePath(String)
    /// The home exists but its owner marker is missing or names another account.
    case notOwned(String)
    /// A file Mercury needs could not be read or parsed; the detail never quotes file contents.
    case unreadable(String)
    case executableNotFound(String)
    /// A precondition from the user's own configuration prevents the operation.
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .unsafePath(let detail): "Unsafe account folder: \(detail)"
        case .notOwned(let detail): "Account folder is not owned by Mercury: \(detail)"
        case .unreadable(let detail): "Could not read \(detail)"
        case .executableNotFound(let name): "Could not find the \(name) command line tool"
        case .refused(let detail): detail
        }
    }
}

/// Failures of a CLI login. `failed` carries the tail of the CLI output (sign-in links, never tokens).
public enum LoginError: Error, LocalizedError, Equatable, Sendable {
    case cancelled
    case timedOut
    case denied
    case failed(exitCode: Int32, output: String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Sign-in was cancelled."
        case .timedOut: "Sign-in took too long to finish. Please try again."
        case .denied: "Sign-in was denied. Please try again."
        case .failed(let code, let output):
            output.isEmpty ? "Sign-in exited with code \(code)." : "Sign-in failed: \(output)"
        case .launchFailed(let detail): "Could not start sign-in: \(detail)"
        }
    }
}

/// Failures of a usage request. The UI ignores them; they never carry tokens.
public enum UsageError: Error, LocalizedError, Equatable, Sendable {
    case notSignedIn
    case unauthorized(status: Int)
    /// HTTP 429; `retryAfter` (seconds, capped at a day) comes from the `Retry-After` header when present.
    case rateLimited(retryAfter: TimeInterval?)
    case httpStatus(Int)
    case invalidResponse
    case transport(String)
    case keychainUnavailable

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "The account is not signed in."
        case .unauthorized(let status): "The usage request was rejected (\(status)); sign in again."
        case .rateLimited: "The usage request was rate limited; it will be retried later."
        case .httpStatus(let status): "The usage request failed with status \(status)."
        case .invalidResponse: "The usage response could not be read."
        case .transport(let detail): "The usage request failed: \(detail)"
        case .keychainUnavailable: "The Keychain could not be read."
        }
    }
}
