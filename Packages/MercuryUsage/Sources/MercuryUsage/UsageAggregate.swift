import Foundation

/// Usage of one model in one project on one local day.
public struct UsageDay: Sendable, Hashable {
    public var day: UsageCalendarDay
    public var provider: UsageProvider
    /// Raw model ID as logged; nil when the log did not name one.
    public var model: String?
    /// Project folder name (the repository for a worktree); nil when unknown.
    public var project: String?
    public var tokens: UsageTokens
    /// Estimated cost of the priced turns; nil when no turn in this bucket has a known price.
    public var costUSD: Double?
    /// Some turns used a model with no known price, so `costUSD` undercounts.
    public var hasUnpricedTurns: Bool
    /// Claude: deduplicated API responses. Codex: token-count events.
    public var turns: Int

    /// Start of `day` in the current calendar.
    public var date: Date { day.date() }
}

/// Tokens and cost of one day, all buckets in scope summed.
public struct UsageDailyTotal: Sendable, Hashable {
    public var day: UsageCalendarDay
    public var tokens: UsageTokens
    public var costUSD: Double?

    public var date: Date { day.date() }
}

/// A model or project with its share of tokens.
public struct UsageRankedItem: Sendable, Hashable {
    public var name: String
    public var tokens: Int
}

/// Everything the Stats & Usage page shows for one provider (or all) over one range.
public struct UsageSummary: Sendable, Hashable {
    /// nil for the overview of every provider.
    public var provider: UsageProvider?
    /// First day included; nil for all time.
    public var since: UsageCalendarDay?
    /// Token mix: new input, output, cache read, cache write.
    public var tokens: UsageTokens
    /// Estimated cost at API list prices; nil when nothing in range has a known price.
    public var costUSD: Double?
    /// Some usage in range has no known price, so `costUSD` is a lower bound.
    public var hasUnpricedUsage: Bool
    public var activeDays: Int
    /// Cached prompt tokens over all prompt tokens, `(cacheRead + cacheWrite) / (input + cacheRead + cacheWrite)`,
    /// as Orca's overview defines it; nil without prompt tokens.
    public var cacheShare: Double?
    /// Days with usage, oldest first (for the heatmap).
    public var daily: [UsageDailyTotal]
    public var bestDay: UsageDailyTotal?
    public var topModel: UsageRankedItem?
    public var topProject: UsageRankedItem?
    /// Distinct sessions with usage in range, summed over providers.
    public var sessions: Int
    public var turns: Int
    /// Log lines that looked like usage records but could not be read (all time, not range-limited).
    public var skippedLines: Int

    public var hasData: Bool { tokens.total > 0 }
}

/// The aggregated result of a refresh. Immutable and cheap to query from the main actor.
public struct UsageSnapshot: Sendable {
    /// Every bucket, oldest day first.
    public let days: [UsageDay]
    /// When the last refresh finished; nil when nothing was ever scanned.
    public let updatedAt: Date?
    /// Log files currently known per provider.
    public let fileCounts: [UsageProvider: Int]
    /// Files that exist but could not be opened in the last refresh.
    public let unreadableFiles: Int
    let skippedLines: [UsageProvider: Int]
    let sessionDays: [UsageProvider: [UsageCalendarDay: Set<UInt64>]]

    init(
        days: [UsageDay], updatedAt: Date?, fileCounts: [UsageProvider: Int], unreadableFiles: Int,
        skippedLines: [UsageProvider: Int], sessionDays: [UsageProvider: [UsageCalendarDay: Set<UInt64>]]
    ) {
        self.days = days
        self.updatedAt = updatedAt
        self.fileCounts = fileCounts
        self.unreadableFiles = unreadableFiles
        self.skippedLines = skippedLines
        self.sessionDays = sessionDays
    }

    public static let empty = UsageSnapshot(
        days: [], updatedAt: nil, fileCounts: [:], unreadableFiles: 0, skippedLines: [:], sessionDays: [:])

    /// Totals for `provider` (nil: all providers) from the local day containing `since` (nil: all time).
    public func summary(provider: UsageProvider?, since: Date?, calendar: Calendar = .current) -> UsageSummary {
        summary(provider: provider, sinceDay: since.map { UsageCalendarDay($0, calendar: calendar) })
    }

    public func summary(provider: UsageProvider?, sinceDay since: UsageCalendarDay?) -> UsageSummary {
        let providers = provider.map { [$0] } ?? UsageProvider.allCases
        let inScope = days.filter { day in
            providers.contains(day.provider) && since.map { day.day >= $0 } ?? true
        }

        var tokens = UsageTokens.zero
        var cost = 0.0
        var hasCost = false
        var hasUnpriced = false
        var turns = 0
        var byDay: [UsageCalendarDay: UsageDailyTotal] = [:]
        var byModel: [String: Int] = [:]
        var byProject: [String: Int] = [:]
        for day in inScope {
            tokens += day.tokens
            turns += day.turns
            hasUnpriced = hasUnpriced || day.hasUnpricedTurns
            if let dayCost = day.costUSD {
                cost += dayCost
                hasCost = true
            }
            var total = byDay[day.day] ?? UsageDailyTotal(day: day.day, tokens: .zero, costUSD: nil)
            total.tokens += day.tokens
            if let dayCost = day.costUSD { total.costUSD = (total.costUSD ?? 0) + dayCost }
            byDay[day.day] = total
            if let model = day.model { byModel[model, default: 0] += day.tokens.total }
            if let project = day.project { byProject[project, default: 0] += day.tokens.total }
        }
        let daily = byDay.values.filter { $0.tokens.total > 0 }.sorted { $0.day < $1.day }
        let prompt = tokens.input + tokens.cacheRead + tokens.cacheWrite
        let sessions = providers.reduce(0) { sum, provider in
            var ids = Set<UInt64>()
            for (day, sessions) in sessionDays[provider] ?? [:] where since.map({ day >= $0 }) ?? true {
                ids.formUnion(sessions)
            }
            return sum + ids.count
        }
        return UsageSummary(
            provider: provider, since: since, tokens: tokens, costUSD: hasCost ? cost : nil,
            hasUnpricedUsage: hasUnpriced, activeDays: daily.count,
            cacheShare: prompt > 0 ? Double(tokens.cacheRead + tokens.cacheWrite) / Double(prompt) : nil,
            daily: daily,
            bestDay: daily.max { $0.tokens.total < $1.tokens.total || ($0.tokens.total == $1.tokens.total && $0.day > $1.day) },
            topModel: Self.top(byModel), topProject: Self.top(byProject), sessions: sessions, turns: turns,
            skippedLines: providers.reduce(0) { $0 + (skippedLines[$1] ?? 0) })
    }

    /// Whether `provider` has any usage at all.
    public func hasData(provider: UsageProvider) -> Bool {
        days.contains { $0.provider == provider && $0.tokens.total > 0 }
    }

    private static func top(_ totals: [String: Int]) -> UsageRankedItem? {
        totals.filter { $0.value > 0 }
            .max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }
            .map { UsageRankedItem(name: $0.key, tokens: $0.value) }
    }
}
