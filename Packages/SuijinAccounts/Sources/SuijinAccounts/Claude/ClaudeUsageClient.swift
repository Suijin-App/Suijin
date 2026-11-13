import Foundation

/// Claude subscription usage from the (undocumented) OAuth usage endpoint Claude Code itself calls.
///
/// Response windows look like `{"five_hour": {"utilization": 52.0, "resets_at": "2025-11-11T05:00:00+00:00"},
/// "seven_day": {...}}`; `utilization` (or `used_percentage`) is a percentage 0...100.
public struct ClaudeUsageClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    let transport: any HTTPTransport
    let now: @Sendable () -> Date

    public init(transport: any HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.now = now
    }

    public func fetch(accessToken: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try Self.parse(try await UsageHTTP.fetchJSON(request, transport: transport), fetchedAt: now())
    }

    static func parse(_ object: [String: Any], fetchedAt: Date) throws -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: window(object["five_hour"]), sevenDay: window(object["seven_day"]),
            modelWeekly: modelWeekly(object), fetchedAt: fetchedAt)
    }

    /// The model-scoped weekly limit: a `limits` entry of kind `weekly_scoped` naming a model (Fable first, as
    /// Orca shows it), else the older `fable_weekly` / `fable_seven_day` / `seven_day_fable` windows.
    static func modelWeekly(_ object: [String: Any]) -> ModelUsageWindow? {
        let scoped = (object["limits"] as? [Any] ?? []).compactMap { raw -> ModelUsageWindow? in
            guard let limit = raw as? [String: Any], limit["kind"] as? String == "weekly_scoped",
                  let percent = JSONNumber.double(limit["percent"]),
                  let scope = limit["scope"] as? [String: Any], let model = scope["model"] as? [String: Any],
                  let name = (model["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { return nil }
            let window = UsageWindow(
                usedFraction: min(100, max(0, percent)) / 100, resetsAt: UsageDates.claudeReset(limit["resets_at"]))
            return ModelUsageWindow(model: name, window: window)
        }
        if let fable = scoped.first(where: { $0.model.lowercased() == "fable" }) ?? scoped.first { return fable }
        for key in ["fable_weekly", "fable_seven_day", "seven_day_fable"] {
            if let window = window(object[key]) { return ModelUsageWindow(model: "Fable", window: window) }
        }
        return nil
    }

    public static func parse(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageError.invalidResponse
        }
        return try parse(object, fetchedAt: fetchedAt)
    }

    static func window(_ raw: Any?) -> UsageWindow? {
        guard let raw = raw as? [String: Any],
              let percent = JSONNumber.double(raw["utilization"]) ?? JSONNumber.double(raw["used_percentage"])
        else { return nil }
        return UsageWindow(usedFraction: min(100, max(0, percent)) / 100, resetsAt: UsageDates.claudeReset(raw["resets_at"]))
    }
}
