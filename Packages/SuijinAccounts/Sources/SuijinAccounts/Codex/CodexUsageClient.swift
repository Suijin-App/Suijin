import Foundation

/// Codex (ChatGPT plan) rate limits from the undocumented backend endpoint the Codex apps call.
///
/// Response: `{"plan_type": "plus", "rate_limit": {"primary_window": {"used_percent": 12, "limit_window_seconds":
/// 18000, "reset_at": 1762840000}, "secondary_window": {...}}}`. Windows are classified by length (300 minutes =
/// session, 10080 = weekly, one minute of drift tolerated); unknown lengths keep primary = session,
/// secondary = weekly.
public struct CodexUsageClient: Sendable {
    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let sessionMinutes = 300.0
    static let weeklyMinutes = 10080.0

    let transport: any HTTPTransport
    let now: @Sendable () -> Date

    public init(transport: any HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.now = now
    }

    public func fetch(accessToken: String, accountID: String?) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        if let accountID { request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        return try Self.parse(try await UsageHTTP.fetchJSON(request, transport: transport), fetchedAt: now())
    }

    public static func parse(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageError.invalidResponse
        }
        return try parse(object, fetchedAt: fetchedAt)
    }

    static func parse(_ object: [String: Any], fetchedAt: Date) throws -> UsageSnapshot {
        guard object["plan_type"] is String else { throw UsageError.invalidResponse }
        let limits = object["rate_limit"] as? [String: Any]
        let primary = Window(limits?["primary_window"])
        let secondary = Window(limits?["secondary_window"])
        var session: Window?
        var weekly: Window?
        for window in [primary, secondary].compactMap({ $0 }) {
            switch window.kind {
            case .session where session == nil: session = window
            case .weekly where weekly == nil: weekly = window
            default: break
            }
        }
        if session == nil, let primary, primary.kind == nil { session = primary }
        if weekly == nil, let secondary, secondary.kind == nil { weekly = secondary }
        return UsageSnapshot(fiveHour: session?.usage, sevenDay: weekly?.usage, fetchedAt: fetchedAt)
    }

    private struct Window {
        enum Kind { case session, weekly }
        var usedPercent: Double
        var minutes: Double?
        var resetAt: Double?

        init?(_ raw: Any?) {
            guard let raw = raw as? [String: Any], let used = JSONNumber.double(raw["used_percent"]) else { return nil }
            usedPercent = used
            if let seconds = JSONNumber.double(raw["limit_window_seconds"]), seconds > 0 {
                minutes = (seconds / 60).rounded(.up)
            }
            resetAt = JSONNumber.double(raw["reset_at"])
        }

        var kind: Kind? {
            guard let minutes else { return nil }
            if abs(minutes - CodexUsageClient.sessionMinutes) <= 1 { return .session }
            if abs(minutes - CodexUsageClient.weeklyMinutes) <= 1 { return .weekly }
            return nil
        }

        var usage: UsageWindow {
            // Codex reset epochs are seconds.
            let resets = resetAt.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            return UsageWindow(usedFraction: min(100, max(0, usedPercent)) / 100, resetsAt: resets)
        }
    }
}
