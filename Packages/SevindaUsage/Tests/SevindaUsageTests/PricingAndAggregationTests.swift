import Foundation
import Testing
@testable import SevindaUsage

@Suite struct PricingTests {
    private func close(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 1e-9
    }

    @Test func claudeModelNormalization() {
        #expect(ModelPricing.normalizeClaudeModel("claude-opus-4-5-20251101") == "claude-opus-4-5")
        #expect(ModelPricing.normalizeClaudeModel("claude-sonnet-4-5") == "claude-sonnet-4-5")
        #expect(ModelPricing.normalizeClaudeModel("claude-opus-4-1-20250805") == "claude-opus-4-1")
        #expect(ModelPricing.normalizeClaudeModel("claude-sonnet-4-20250514") == "claude-sonnet-4")
        #expect(ModelPricing.normalizeClaudeModel("claude-3-5-sonnet-20241022") == "claude-sonnet-3-5")
        #expect(ModelPricing.normalizeClaudeModel("claude-haiku-4.5") == "claude-haiku-4-5")
        #expect(ModelPricing.normalizeClaudeModel("claude-opus-4-6[1m]") == "claude-opus-4-6")
        #expect(ModelPricing.normalizeClaudeModel("claude-opus-5-5") == "claude-opus-5-5")
        #expect(ModelPricing.normalizeClaudeModel("model_placeholder_m26") == "claude-opus-4-6")
        #expect(ModelPricing.normalizeClaudeModel("<synthetic>") == nil)
        #expect(ModelPricing.normalizeClaudeModel("claude-opus-9-9") == nil)
        #expect(ModelPricing.normalizeClaudeModel("") == nil)
    }

    @Test func claudeCostByHand() {
        // Opus 4.5: $5 input, $25 output, $0.50 cache read, $6.25 5m write, $10 1h write per million.
        let tokens = UsageTokens(input: 1_000_000, output: 100_000, cacheRead: 2_000_000, cacheWrite: 400_000)
        let cost = ModelPricing.cost(
            provider: .claude, model: "claude-opus-4-5-20251101", tokens: tokens, cacheWrite1h: 100_000,
            longContext: false)
        let expected: Double = 5 + 2.5 + 1 + 0.3 * 6.25 + 0.1 * 10
        #expect(close(cost, expected))
        #expect(ModelPricing.cost(provider: .claude, model: "mystery", tokens: tokens, cacheWrite1h: 0, longContext: false) == nil)
    }

    @Test func claudeLongContextPricesTheWholeRequest() {
        // Sonnet 4.5 above 200k prompt tokens: $6 input, $22.50 output, $0.60 cache read.
        let long = UsageTokens(input: 150_000, output: 10_000, cacheRead: 60_000, cacheWrite: 0)
        let longExpected: Double = (150_000.0 * 6 + 10_000.0 * 22.5 + 60_000.0 * 0.6) / 1_000_000
        let longCost = ModelPricing.cost(
            provider: .claude, model: "claude-sonnet-4-5", tokens: long, cacheWrite1h: 0, longContext: false)
        #expect(close(longCost, longExpected))
        let short = UsageTokens(input: 150_000, output: 10_000, cacheRead: 40_000, cacheWrite: 0)
        let shortExpected: Double = (150_000.0 * 3 + 10_000.0 * 15 + 40_000.0 * 0.3) / 1_000_000
        let shortCost = ModelPricing.cost(
            provider: .claude, model: "claude-sonnet-4-5", tokens: short, cacheWrite1h: 0, longContext: false)
        #expect(close(shortCost, shortExpected))
    }

    @Test func codexModelNormalization() {
        #expect(ModelPricing.normalizeCodexModel("gpt-5-codex") == "gpt-5")
        #expect(ModelPricing.normalizeCodexModel("gpt-5.1-codex-max-high") == "gpt-5.1-codex-max")
        #expect(ModelPricing.normalizeCodexModel("gpt-5.1-codex-mini") == "gpt-5.1-codex")
        #expect(ModelPricing.normalizeCodexModel("gpt-5.4-mini") == "gpt-5.4-mini")
        #expect(ModelPricing.normalizeCodexModel("GPT-5.5 (xhigh)") == "gpt-5.5")
        #expect(ModelPricing.normalizeCodexModel("gpt-5.5 (turbo)") == nil)
        #expect(ModelPricing.normalizeCodexModel("gpt-5.6") == "gpt-5.6-sol")
        #expect(ModelPricing.normalizeCodexModel("gpt-5.6-nova") == nil)
        #expect(ModelPricing.normalizeCodexModel("gpt-5-mini") == nil)
        #expect(ModelPricing.normalizeCodexModel("o3") == nil)
    }

    @Test func codexCostByHand() {
        // GPT-5.5: $5 input, $0.50 cached, $30 output; long context $10 / $1 / $45.
        let tokens = UsageTokens(input: 600_000, output: 100_000, cacheRead: 400_000, cacheWrite: 0)
        #expect(close(
            ModelPricing.cost(provider: .codex, model: "gpt-5.5", tokens: tokens, cacheWrite1h: 0, longContext: false),
            3 + 0.2 + 3))
        #expect(close(
            ModelPricing.cost(provider: .codex, model: "gpt-5.5", tokens: tokens, cacheWrite1h: 0, longContext: true),
            6 + 0.4 + 4.5))
        // No long-context tier: standard rates.
        #expect(close(
            ModelPricing.cost(provider: .codex, model: "gpt-5", tokens: tokens, cacheWrite1h: 0, longContext: true),
            0.75 + 0.05 + 1))
    }
}

@Suite struct AggregationTests {
    private func turn(
        _ day: Int, session: UInt64, model: String = "claude-opus-4-5", project: String = "alpha", key: UInt64?,
        input: Int = 100, output: Int = 10, cacheRead: Int = 300, cacheWrite: Int = 0
    ) -> ParsedTurn {
        ParsedTurn(
            key: key, day: UsageCalendarDay(year: 2026, month: 11, day: day), session: session, model: model,
            project: project,
            tokens: UsageTokens(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite),
            cacheWrite1h: 0, longContext: false)
    }

    private func result(_ path: String, _ provider: UsageProvider, _ turns: [ParsedTurn], skipped: Int = 0)
        -> FileScanResult
    {
        FileScanResult(
            path: path, provider: provider,
            outcome: .init(
                checkpoint: FileCheckpoint(
                    identity: FileIdentity(device: 1, inode: 1, size: 10, modified: 0), offset: 10, boundaryHash: 0),
                resumed: false, bytesRead: 10),
            turns: turns, skippedLines: skipped, codex: nil)
    }

    private func ledger() -> UsageLedger {
        var ledger = UsageLedger()
        ledger.apply(result("/a.jsonl", .claude, [
            turn(1, session: 1, key: 11),
            turn(1, session: 1, model: "claude-haiku-4-5", key: 12, input: 1_000),
            turn(5, session: 2, project: "beta", key: 13),
            turn(10, session: 2, project: "beta", key: 14, input: 5_000, cacheWrite: 1_000),
        ], skipped: 2))
        // A resumed session copying the first turn into another file is not counted twice.
        ledger.apply(result("/b.jsonl", .claude, [turn(1, session: 3, key: 11)]))
        ledger.apply(result("/c.jsonl", .codex, [
            turn(10, session: 9, model: "gpt-5.5", project: "gamma", key: 21, input: 600, output: 100, cacheRead: 400),
            turn(10, session: 9, model: "unknown-model", project: "gamma", key: 22, input: 1, output: 1, cacheRead: 0),
        ]))
        return ledger
    }

    @Test func overviewOfAllTime() throws {
        let summary = ledger().snapshot(unreadableFiles: 0).summary(provider: nil, since: nil)
        #expect(summary.tokens == UsageTokens(input: 6_801, output: 141, cacheRead: 1_600, cacheWrite: 1_000))
        #expect(summary.turns == 6)
        #expect(summary.activeDays == 3)
        #expect(summary.sessions == 3)  // Claude sessions 1 and 2 (3 had only a duplicate), Codex session 9.
        #expect(summary.skippedLines == 2)
        #expect(summary.hasUnpricedUsage)
        let share = try #require(summary.cacheShare)
        #expect(abs(share - 2_600.0 / 9_401.0) < 1e-12)
        #expect(summary.bestDay?.day == UsageCalendarDay(year: 2026, month: 11, day: 10))
        #expect(summary.topProject == UsageRankedItem(name: "beta", tokens: 410 + 6_310))
        #expect(summary.topModel?.name == "claude-opus-4-5")
        #expect(summary.daily.map(\.day.day) == [1, 5, 10])
    }

    @Test func rangeAndProviderFilters() throws {
        let snapshot = ledger().snapshot(unreadableFiles: 0)
        let recent = snapshot.summary(provider: .claude, sinceDay: UsageCalendarDay(year: 2026, month: 11, day: 5))
        #expect(recent.turns == 2)
        #expect(recent.sessions == 1)
        #expect(recent.tokens.total == 410 + 6_310)
        let expected: Double = (5_100.0 * 5 + 20.0 * 25 + 600.0 * 0.5 + 1_000.0 * 6.25) / 1_000_000
        #expect(abs(try #require(recent.costUSD) - expected) < 1e-12)
        #expect(!recent.hasUnpricedUsage)

        let codex = snapshot.summary(provider: .codex, since: nil)
        #expect(codex.sessions == 1)
        #expect(codex.topProject?.name == "gamma")
        let codexExpected: Double = (600.0 * 5 + 400.0 * 0.5 + 100.0 * 30) / 1_000_000
        #expect(abs(try #require(codex.costUSD) - codexExpected) < 1e-12)
        #expect(codex.hasUnpricedUsage)

        let empty = snapshot.summary(provider: .codex, sinceDay: UsageCalendarDay(year: 2026, month: 12, day: 1))
        #expect(!empty.hasData)
        #expect(empty.costUSD == nil && empty.cacheShare == nil && empty.bestDay == nil && empty.topModel == nil)
    }

    @Test func dateRangeUsesTheLocalDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Saigon")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 23))!
        let summary = ledger().snapshot(unreadableFiles: 0).summary(provider: .claude, since: date, calendar: calendar)
        #expect(summary.since == UsageCalendarDay(year: 2026, month: 11, day: 5))
        #expect(summary.turns == 2)
    }

    @Test func calendarDayConversions() {
        #expect(CivilDate.fromDays(0) == (1970, 1, 1))
        #expect(CivilDate.toDays(year: 2026, month: 11, day: 12) == 20_769)
        #expect(CivilDate.fromDays(20_769) == (2026, 11, 12))
        #expect(CivilDate.fromDays(CivilDate.toDays(year: 2024, month: 2, day: 29)) == (2024, 2, 29))
        #expect(UsageCalendarDay(year: 2026, month: 3, day: 9).description == "2026-03-09")
    }
}
