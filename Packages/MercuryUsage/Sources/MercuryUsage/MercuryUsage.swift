import Foundation

// MercuryUsage reads the JSONL session logs that Claude Code and Codex write and turns them into token usage per
// local calendar day, provider, model and project, with an estimated cost at API list prices.
//
// Public API (what the app calls):
//
//   let sources = UsageSourceSet.standard(managedClaudeHomes: claudeHomes, managedCodexHomes: codexHomes)
//   let store = UsageStore(cacheURL: dataRoot.appending(path: "usage/cache.json"), sources: sources)
//   let cached: UsageSnapshot? = await store.cachedSnapshot()          // instant, from the cache file
//   let snapshot: UsageSnapshot = try await store.refresh { fraction in … } // incremental scan, cancellable
//   await store.updateSources(newSources)                               // accounts added or removed
//
//   let overview: UsageSummary = snapshot.summary(provider: nil, since: thirtyDaysAgo)  // nil `since` = all time
//   let claude: UsageSummary = snapshot.summary(provider: .claude, since: nil)
//   overview.tokens (input / output / cacheRead / cacheWrite / total), overview.costUSD, overview.activeDays,
//   overview.cacheShare, overview.daily (heatmap), overview.bestDay, overview.topModel, overview.topProject,
//   overview.sessions, overview.turns, overview.skippedLines, overview.hasData
//   snapshot.days: [UsageDay] — the raw buckets (day × provider × model × project)
//
// Safety: log files are only ever opened with `O_RDONLY`; nothing under the log roots is written, renamed or deleted.
// The cache holds numbers, checkpoints, model names and project folder names only, never prompt or response text and
// never credentials; it is written with mode 600 inside a 700 directory.
//
// Parsing, deduplication, Codex token deltas and pricing are ported from Orca (MIT), `src/main/claude-usage`,
// `src/main/codex-usage` and `src/main/usage`.

/// A coding agent whose logs Mercury reads.
public enum UsageProvider: String, Codable, Sendable, CaseIterable, Hashable {
    case claude
    case codex
}

/// Token counts in one bucket. `input` is new (uncached) input; for Codex, cached input is moved to `cacheRead`
/// and reasoning is already part of `output`, so the four fields never overlap.
public struct UsageTokens: Codable, Sendable, Hashable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public static let zero = UsageTokens()

    public var total: Int { input + output + cacheRead + cacheWrite }

    public static func + (lhs: UsageTokens, rhs: UsageTokens) -> UsageTokens {
        UsageTokens(
            input: lhs.input + rhs.input, output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite)
    }

    public static func - (lhs: UsageTokens, rhs: UsageTokens) -> UsageTokens {
        UsageTokens(
            input: lhs.input - rhs.input, output: lhs.output - rhs.output,
            cacheRead: lhs.cacheRead - rhs.cacheRead, cacheWrite: lhs.cacheWrite - rhs.cacheWrite)
    }

    public static func += (lhs: inout UsageTokens, rhs: UsageTokens) { lhs = lhs + rhs }

    /// Field-wise maximum, used to keep the most complete of several streaming rows of one response.
    func fieldMax(_ other: UsageTokens) -> UsageTokens {
        UsageTokens(
            input: max(input, other.input), output: max(output, other.output),
            cacheRead: max(cacheRead, other.cacheRead), cacheWrite: max(cacheWrite, other.cacheWrite))
    }
}
