import Foundation
import SevindaAccounts
import SevindaCore

/// Why the last usage refresh of a provider failed, mapped to Orca's status wording.
enum UsageFailure: Equatable, Sendable {
    /// Claude rejected an idle login's access token; Claude renews it the next time it runs.
    case staleToken
    /// HTTP 429; automated refreshes wait until `retryAt`.
    case rateLimited(retryAt: Date?)
    case network
    case keychainUnavailable
    /// A managed account's home has no login any more.
    case signedOut
    case failed

    init(_ error: Error, provider: AccountProvider, now: Date = .now) {
        switch error as? UsageError {
        case .unauthorized? where provider == .claude: self = .staleToken
        case .rateLimited(let delay)?: self = .rateLimited(retryAt: delay.map { now.addingTimeInterval($0) })
        case .transport?: self = .network
        case .keychainUnavailable?: self = .keychainUnavailable
        case .notSignedIn?: self = .signedOut
        default: self = .failed
        }
    }

    /// Not a problem the user has to act on, so no warning sign is shown.
    var isCalm: Bool { self == .staleToken }

    /// Short status bar label.
    var label: String {
        switch self {
        case .staleToken: String(localized: "Updates when Claude runs")
        case .rateLimited: String(localized: "Limited")
        case .network: String(localized: "Network issue")
        case .keychainUnavailable: String(localized: "Sign-in unavailable")
        case .signedOut: String(localized: "Sign in again")
        case .failed: String(localized: "Refresh failed")
        }
    }

    /// Full explanation for the tooltip and the details popover.
    func message(provider: String) -> String {
        switch self {
        case .staleToken: String(localized: "Claude usage updates the next time Claude runs.")
        case .rateLimited: String(localized: "The usage service is limiting requests. Mercury tries again later.")
        case .network: String(localized: "\(provider) usage could not be refreshed because the network request failed.")
        case .keychainUnavailable: String(localized: "\(provider) sign-in credentials could not be read.")
        case .signedOut: String(localized: "The selected \(provider) account needs you to sign in again in Settings.")
        case .failed: String(localized: "\(provider) usage could not be refreshed. Agent sessions may still be signed in.")
        }
    }

    var retryAt: Date? {
        if case .rateLimited(let date) = self { return date }
        return nil
    }
}

/// What the status bar shows for one provider: the last usable snapshot, the last failure, and whose usage it is.
struct ProviderUsageState: Equatable {
    var snapshot: UsageSnapshot?
    var failure: UsageFailure?
    var accountName: String?
    /// A Mercury-managed default account rather than the user's own login.
    var isManaged: Bool
}

/// One window as the status bar lists it.
struct UsageSection: Identifiable, Equatable {
    enum Kind: String { case session, weekly, model }
    let kind: Kind
    let window: UsageWindow
    /// The model name of a model-scoped weekly window.
    var model: String?
    var id: String { kind.rawValue }

    var percent: Int { Int((window.usedFraction * 100).rounded()) }
}

enum ProviderUsagePolicy {
    /// Recent usage stays visible through a transient failure for this long (a day for waits that fix themselves).
    static let staleLimit: TimeInterval = 30 * 60
    static let longStaleLimit: TimeInterval = 24 * 60 * 60

    /// Session, weekly and model windows, in display order. Windows already past their reset are dropped: they no
    /// longer describe the account.
    static func sections(_ snapshot: UsageSnapshot?, now: Date = .now) -> [UsageSection] {
        guard let snapshot else { return [] }
        let sections = [
            snapshot.fiveHour.map { UsageSection(kind: .session, window: $0) },
            snapshot.sevenDay.map { UsageSection(kind: .weekly, window: $0) },
            snapshot.modelWeekly.map { UsageSection(kind: .model, window: $0.window, model: $0.model) },
        ]
        return sections.compactMap { $0 }.filter { section in section.window.resetsAt.map { $0 > now } ?? true }
    }

    /// The most used window, which drives the bar and its color.
    static func tightest(_ sections: [UsageSection]) -> UsageSection? {
        sections.max { $0.window.usedFraction < $1.window.usedFraction }
    }

    /// The previous snapshot kept on screen after `failure`, or nil once it is too old or fully reset.
    static func retained(_ previous: UsageSnapshot?, after failure: UsageFailure, now: Date = .now) -> UsageSnapshot? {
        guard let previous else { return nil }
        let limit: TimeInterval = switch failure {
        case .staleToken, .rateLimited: longStaleLimit
        default: staleLimit
        }
        guard now.timeIntervalSince(previous.fetchedAt) <= limit, !sections(previous, now: now).isEmpty else { return nil }
        return previous
    }

    /// Floored compact countdown, as Orca prints it: "47m", "3h 20m", "5d 12h", "now".
    static func resetDuration(until date: Date, now: Date = .now) -> String {
        let minutes = Int(date.timeIntervalSince(now) / 60)
        guard date > now else { return String(localized: "now") }
        if minutes < 60 { return String(localized: "\(minutes)m") }
        let hours = minutes / 60
        if hours >= 24 {
            let rest = hours % 24
            return rest > 0 ? String(localized: "\(hours / 24)d \(rest)h") : String(localized: "\(hours / 24)d")
        }
        let rest = minutes % 60
        return rest > 0 ? String(localized: "\(hours)h \(rest)m") : String(localized: "\(hours)h")
    }

    /// "87% used 5d 12h" for a timed window, "14% used Fable" for a model window.
    static func inlineText(_ section: UsageSection, now: Date = .now) -> String {
        switch section.kind {
        case .model:
            return String(localized: "\(section.percent)% used \(section.model ?? "")")
        case .session, .weekly:
            let suffix = section.window.resetsAt.map { resetDuration(until: $0, now: now) }
                ?? (section.kind == .session ? String(localized: "5h") : String(localized: "week"))
            return String(localized: "\(section.percent)% used \(suffix)")
        }
    }

    /// Window name for the tooltip and popover.
    static func title(_ section: UsageSection) -> String {
        switch section.kind {
        case .session: String(localized: "5-hour limit")
        case .weekly: String(localized: "Weekly limit")
        case .model: String(localized: "Weekly \(section.model ?? "") limit")
        }
    }
}
