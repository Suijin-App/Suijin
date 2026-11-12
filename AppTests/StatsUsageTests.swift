import Foundation
import MercuryCore
import MercuryUsage
import Testing
@testable import Mercury

/// Settings → Stats & Usage: number formatting, the six-week heatmap, the range picker and the usage controller.
/// The controller tests read synthetic logs in a temporary folder, never the user's own logs.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct StatsUsageTests {
    private let english = Locale(identifier: "en_US")

    @Test func tokensAreCompact() {
        #expect(UsageFormat.tokens(950, locale: english) == "950")
        #expect(UsageFormat.tokens(12_400, locale: english) == "12.4K")
        #expect(UsageFormat.tokens(119_200_000, locale: english) == "119.2M")
        #expect(UsageFormat.tokens(18_300_000_000, locale: english) == "18.3B")
    }

    @Test func costPercentAndCountFormats() {
        #expect(UsageFormat.cost(8_397.484, locale: english) == "$8,397.48")
        #expect(UsageFormat.cost(nil, locale: english) == "n/a")
        #expect(UsageFormat.percent(0.4249, locale: english) == "42%")
        #expect(UsageFormat.percent(nil, locale: english) == "n/a")
        #expect(UsageFormat.percent(0.99994, locale: english) == ">99%", "almost all is not shown as all")
        #expect(UsageFormat.percent(1, locale: english) == "100%")
        #expect(UsageFormat.count(12_345, locale: english) == "12,345")
    }

    @Test func durationsShowTheTwoLargestUnits() {
        #expect(UsageFormat.duration(seconds: 69 * 86_400 + 9 * 3_600 + 59 * 60, locale: english) == "69d 9h")
        #expect(UsageFormat.duration(seconds: 3 * 3_600 + 12 * 60 + 30, locale: english) == "3h 12m")
        #expect(UsageFormat.duration(seconds: 12 * 60, locale: english) == "12m")
        #expect(UsageFormat.duration(seconds: 30, locale: english) == "0m")
        #expect(UsageFormat.duration(seconds: -5, locale: english) == "0m")
    }

    @Test func rangesStartAtTheFirstLocalDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Saigon"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 15)))
        let seven = try #require(UsageRange.sevenDays.since(now: now, calendar: calendar))
        #expect(calendar.dateComponents([.month, .day, .hour], from: seven) == DateComponents(month: 11, day: 6, hour: 0))
        let thirty = try #require(UsageRange.thirtyDays.since(now: now, calendar: calendar))
        #expect(calendar.dateComponents([.month, .day], from: thirty) == DateComponents(month: 10, day: 14))
        #expect(UsageRange.allTime.since(now: now, calendar: calendar) == nil)
    }

    @Test func heatmapCoversSixWeeksUpToToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Saigon"))
        calendar.firstWeekday = 2
        // Thursday 2026-11-12: the grid runs from Monday 2026-10-05 to today, so the last column has four days.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 15)))
        let busy = UsageCalendarDay(year: 2026, month: 11, day: 10)
        let totals = [
            busy: 1_000,
            UsageCalendarDay(year: 2026, month: 10, day: 5): 10,
            UsageCalendarDay(year: 2026, month: 9, day: 1): 5_000,
        ]
        let model = UsageHeatmapModel(totals: totals, now: now, calendar: calendar)

        #expect(model.cells.count == 5 * 7 + 4)
        let first = try #require(model.cells.first)
        #expect(first.day == UsageCalendarDay(year: 2026, month: 10, day: 5))
        #expect((first.week, first.weekday, first.level) == (0, 0, 1))
        let last = try #require(model.cells.last)
        #expect(last.day == UsageCalendarDay(year: 2026, month: 11, day: 12))
        #expect((last.week, last.weekday) == (5, 3))
        // The day outside the window does not set the scale.
        #expect(model.cells.first { $0.day == busy }?.level == 4)
        #expect(model.activeDays == 2)
    }

    @Test func heatmapLevelsUseASquareRootScale() {
        #expect(UsageHeatmapModel.level(0, peak: 100) == 0)
        #expect(UsageHeatmapModel.level(1, peak: 100) == 1)
        #expect(UsageHeatmapModel.level(25, peak: 100) == 2)
        #expect(UsageHeatmapModel.level(50, peak: 100) == 3)
        #expect(UsageHeatmapModel.level(100, peak: 100) == 4)
        #expect(UsageHeatmapModel.level(5, peak: 0) == 0)
    }

    @Test func accountHomesBecomeLogRoots() {
        let accounts = [
            ManagedAccountRecord(provider: .claude, label: "Work", homePath: "/tmp/mercury-a"),
            ManagedAccountRecord(provider: .codex, label: "Codex", homePath: "/tmp/mercury-b"),
        ]
        let sources = UsageController.sources(for: accounts)
        #expect(sources.claudeRoots.contains(URL(fileURLWithPath: "/tmp/mercury-a/projects", isDirectory: true)))
        #expect(sources.codexRoots.contains(URL(fileURLWithPath: "/tmp/mercury-b/sessions", isDirectory: true)))
        #expect(!sources.claudeRoots.contains { $0.path.hasPrefix("/tmp/mercury-b") })
    }

    // MARK: Controller

    /// A temporary folder with a Claude log root, an empty Codex root and a cache location.
    private final class LogFolder {
        let url: URL
        var claudeRoot: URL { url.appendingPathComponent("claude/projects", isDirectory: true) }
        var codexRoot: URL { url.appendingPathComponent("codex/sessions", isDirectory: true) }
        var cacheURL: URL { url.appendingPathComponent("data/usage/cache.json") }
        var sources: UsageSourceSet { UsageSourceSet(claudeRoots: [claudeRoot], codexRoots: [codexRoot]) }

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("mercury-usage-ui-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        /// Appends one Claude assistant turn with the given tokens.
        func appendClaudeTurn(id: String, input: Int, output: Int, timestamp: Date = Date()) throws {
            let record: [String: Any] = [
                "type": "assistant", "timestamp": ISO8601DateFormatter().string(from: timestamp),
                "sessionId": "session-1", "requestId": "req-\(id)", "cwd": "/Users/me/Code/alpha",
                "message": [
                    "id": "msg-\(id)", "model": "claude-opus-4-5-20251101", "role": "assistant", "content": [],
                    "usage": ["input_tokens": input, "output_tokens": output,
                              "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0],
                ],
            ]
            let line = try JSONSerialization.data(withJSONObject: record) + Data("\n".utf8)
            let file = claudeRoot.appendingPathComponent("alpha/session-1.jsonl")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: file)
            }
        }
    }

    private func controller(_ folder: LogFolder, stats: MercuryStats = MercuryStats(agentsSpawned: 3)) -> UsageController {
        UsageController(store: UsageStore(cacheURL: folder.cacheURL, sources: folder.sources),
                        sources: { folder.sources }, loadStats: { stats })
    }

    @Test func refreshReadsTheLogsAndPicksUpAppendedLines() async throws {
        let folder = try LogFolder()
        try folder.appendClaudeTurn(id: "1", input: 100, output: 50)
        let usage = controller(folder)
        #expect(usage.snapshot == nil)

        await usage.refresh().value
        #expect(!usage.isRefreshing)
        #expect(usage.refreshError == nil)
        #expect(usage.summary()?.tokens.total == 150)
        #expect(usage.summary()?.topProject?.name != nil)
        #expect(usage.snapshot?.updatedAt != nil)

        try folder.appendClaudeTurn(id: "2", input: 10, output: 5)
        await usage.refresh().value
        #expect(usage.summary()?.tokens.total == 165)
        usage.scope = .codex
        #expect(usage.summary()?.hasData == false)
    }

    @Test func aSecondControllerShowsTheCacheBeforeReadingLogs() async throws {
        let folder = try LogFolder()
        try folder.appendClaudeTurn(id: "1", input: 100, output: 50)
        await controller(folder).refresh().value

        let relaunched = controller(folder)
        await relaunched.showCachedUsage()
        #expect(relaunched.summary()?.tokens.total == 150)
        #expect(!relaunched.isRefreshing)
    }

    @Test func concurrentRefreshesJoinAndStatsLoad() async throws {
        let folder = try LogFolder()
        try folder.appendClaudeTurn(id: "1", input: 1, output: 1)
        let usage = controller(folder, stats: MercuryStats(agentsSpawned: 7, agentWorkSeconds: 60))
        let first = usage.refresh()
        let second = usage.refresh()
        await first.value
        await second.value
        #expect(usage.summary()?.tokens.total == 2)
        await usage.reloadStats()
        #expect(usage.stats?.agentsSpawned == 7)
        #expect(usage.statsError == nil)
    }

    @Test func closingThePageStopsTheRefresh() async throws {
        let folder = try LogFolder()
        try folder.appendClaudeTurn(id: "1", input: 1, output: 1)
        let usage = controller(folder)
        let task = usage.refresh()
        usage.pageDisappeared()
        #expect(!usage.isRefreshing)
        await task.value
        #expect(!usage.isRefreshing)
        #expect(usage.refreshError == nil)
    }

    @Test func aFailingStatsLoadIsReported() async {
        struct Broken: LocalizedError { var errorDescription: String? { "database is locked" } }
        let usage = UsageController(
            store: UsageStore(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID()).json"),
                              sources: UsageSourceSet(claudeRoots: [], codexRoots: [])),
            sources: { UsageSourceSet(claudeRoots: [], codexRoots: []) }, loadStats: { throw Broken() })
        await usage.reloadStats()
        #expect(usage.stats == nil)
        #expect(usage.statsError == "database is locked")
    }
}
