import Foundation
import Testing
@testable import SevindaUsage

@Suite struct ClaudeParserTests {
    let utc = TimeZone(identifier: "UTC")!

    private func parse(_ lines: [String], path: String = "/logs/fallback-session.jsonl") -> ClaudeFileParser {
        var parser = ClaudeFileParser(path: path, timeZone: utc)
        for line in lines { UnsafeRawBufferPointer.with(line) { parser.consume($0) } }
        return parser
    }

    @Test func readsAssistantUsage() throws {
        let parser = parse([
            Fixture.claude(input: 10, output: 20, cacheRead: 30, cacheWrite: 40, cacheWrite1h: 15),
            Fixture.json(["type": "user", "timestamp": "2026-11-10T12:00:00Z", "message": ["content": "assistant"]]),
        ])
        #expect(parser.turns.count == 1)
        let turn = try #require(parser.turns.first)
        #expect(turn.tokens == UsageTokens(input: 10, output: 20, cacheRead: 30, cacheWrite: 40))
        #expect(turn.cacheWrite1h == 15)
        #expect(turn.model == "claude-opus-4-5-20251101")
        #expect(turn.project == "alpha")
        #expect(turn.day == UsageCalendarDay(year: 2026, month: 11, day: 10))
        #expect(turn.key == StableHash.hash("claude:msg_1:req_1"))
        #expect(parser.skippedLines == 0)
    }

    @Test func streamingRowsOfOneResponseKeepTheLargestCounters() throws {
        let parser = parse([
            Fixture.claude(output: 5, cacheRead: 1_000),
            Fixture.claude(output: 80, cacheRead: 900),
            Fixture.claude(messageID: "msg_2", output: 7),
        ])
        #expect(parser.turns.count == 2)
        let first = try #require(parser.turns.first)
        #expect(first.tokens.output == 80)
        #expect(first.tokens.cacheRead == 1_000)
    }

    @Test func dedupeKeyFallsBackToMessageThenUUID() {
        let message: [String: Any] = ["id": "m"]
        #expect(ClaudeFileParser.dedupeKey(record: ["requestId": "r"], message: message) == "m:r")
        #expect(ClaudeFileParser.dedupeKey(record: [:], message: message) == "msg:m")
        #expect(ClaudeFileParser.dedupeKey(record: ["uuid": "u"], message: [:]) == "uuid:u")
        #expect(ClaudeFileParser.dedupeKey(record: [:], message: nil) == nil)
        let parser = parse([
            Fixture.claude(messageID: nil, requestID: nil, uuid: nil),
            Fixture.claude(messageID: nil, requestID: nil, uuid: nil),
        ])
        // Rows with no identity are always counted.
        #expect(parser.turns.count == 2)
    }

    @Test func ignoresZeroUsageAndOtherTypes() {
        let parser = parse([
            Fixture.claude(model: "<synthetic>", input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            Fixture.claude(type: "user"),
            #"{"type":"summary","summary":"assistant"}"#,
        ])
        #expect(parser.turns.isEmpty)
        #expect(parser.skippedLines == 0)
    }

    @Test func countsMalformedCandidatesAsSkipped() {
        let parser = parse([
            #"{"type":"assistant","message":{"usage":"#,
            Fixture.claude(timestamp: "yesterday"),
        ])
        #expect(parser.turns.isEmpty)
        #expect(parser.skippedLines == 2)
    }

    @Test func usesTheFileNameWhenTheSessionIsMissing() throws {
        let parser = parse([Fixture.claude(session: nil)], path: "/logs/abc-123.jsonl")
        #expect(try #require(parser.turns.first).session == StableHash.hash("claude-session:abc-123"))
    }

    @Test func localDayFollowsTheTimeZone() throws {
        var parser = ClaudeFileParser(path: "/x.jsonl", timeZone: TimeZone(identifier: "Asia/Saigon")!)
        UnsafeRawBufferPointer.with(Fixture.claude(timestamp: "2026-11-10T18:30:00Z")) { parser.consume($0) }
        #expect(try #require(parser.turns.first).day == UsageCalendarDay(year: 2026, month: 11, day: 11))
    }

    @Test func projectLabels() {
        #expect(ProjectLabel.from(cwd: "/Users/me/Code/alpha") == "alpha")
        #expect(ProjectLabel.from(cwd: "/Users/me/Code/alpha/.claude/worktrees/fix-bug") == "alpha")
        #expect(ProjectLabel.from(cwd: "/Users/me/Code/Mercury-worktrees/feat/usage") == "Mercury")
        #expect(ProjectLabel.from(cwd: "/Users/me/Self-Works") == "Self-Works")
        #expect(ProjectLabel.from(cwd: nil) == "")
    }

    @Test func timestamps() {
        #expect(ISOTimestamp.epochSeconds("1970-01-01T00:00:00Z") == 0)
        #expect(ISOTimestamp.epochSeconds("2026-11-12T03:04:05.250Z") == 1_794_452_645.25)
        #expect(ISOTimestamp.epochSeconds("2026-11-12T10:04:05+07:00") == 1_794_452_645)
        #expect(ISOTimestamp.epochSeconds("2026-11-12") == nil)
        #expect(ISOTimestamp.epochSeconds("2026-13-12T03:04:05Z") == nil)
    }
}

@Suite struct CodexParserTests {
    let utc = TimeZone(identifier: "UTC")!

    private func parse(_ lines: [String], context: CodexContext = CodexContext(path: "/logs/rollout-x.jsonl"))
        -> CodexFileParser
    {
        var parser = CodexFileParser(context: context, timeZone: utc)
        for line in lines { UnsafeRawBufferPointer.with(line) { parser.consume($0) } }
        return parser
    }

    @Test func cumulativeTotalsBecomeDeltas() throws {
        let parser = parse([
            Fixture.codexMeta(),
            Fixture.codexTurn(turnID: "t1", model: "gpt-5.5"),
            Fixture.codexTokens(total: Fixture.usage(1_000, cached: 400, output: 100), last: nil),
            Fixture.codexRateLimitOnly(),
            Fixture.codexTurn(turnID: "t2", model: "gpt-5.4", cwd: "/Users/me/Code/gamma"),
            Fixture.codexTokens(total: Fixture.usage(1_800, cached: 1_000, output: 150), last: nil),
            // A repeated snapshot adds nothing.
            Fixture.codexTokens(total: Fixture.usage(1_800, cached: 1_000, output: 150), last: nil),
        ])
        #expect(parser.turns.count == 2)
        let first = parser.turns[0]
        #expect(first.tokens == UsageTokens(input: 600, output: 100, cacheRead: 400, cacheWrite: 0))
        #expect(first.model == "gpt-5.5")
        #expect(first.project == "beta")
        #expect(first.session == CodexContext.sessionHash("codex-session-1"))
        let second = parser.turns[1]
        #expect(second.tokens == UsageTokens(input: 200, output: 50, cacheRead: 600, cacheWrite: 0))
        #expect(second.model == "gpt-5.4")
        #expect(second.project == "gamma")
        #expect(parser.context.previousTotals == CodexRawUsage(Fixture.usage(1_800, cached: 1_000, output: 150)))
    }

    @Test func lastUsageIsTheIncrementWhenPresent() throws {
        let parser = parse([
            Fixture.codexTurn(),
            Fixture.codexTokens(
                total: Fixture.usage(500, cached: 0, output: 50), last: Fixture.usage(500, cached: 0, output: 50)),
            // Totals rewritten by compaction: the last usage is still billable.
            Fixture.codexTokens(
                total: Fixture.usage(300_000, cached: 10_000, output: 70),
                last: Fixture.usage(290_000, cached: 10_000, output: 20)),
        ])
        #expect(parser.turns.count == 2)
        let long = parser.turns[1]
        #expect(long.tokens == UsageTokens(input: 280_000, output: 20, cacheRead: 10_000, cacheWrite: 0))
        #expect(long.longContext)
        #expect(!parser.turns[0].longContext)
    }

    @Test func eventKeysIgnoreTheSessionButUseTheTurn() {
        let copy = parse([
            Fixture.codexMeta(id: "fork"),
            Fixture.codexTurn(turnID: "t1"),
            Fixture.codexTokens(total: Fixture.usage(1_000, cached: 400, output: 100), last: nil,
                                timestamp: "2026-11-11T09:00:00Z"),
        ])
        let original = parse([
            Fixture.codexMeta(id: "original"),
            Fixture.codexTurn(turnID: "t1"),
            Fixture.codexTokens(total: Fixture.usage(1_000, cached: 400, output: 100), last: nil),
        ])
        #expect(copy.turns.first?.key == original.turns.first?.key)
        #expect(copy.turns.first?.session != original.turns.first?.session)
    }

    @Test func deltaResolution() {
        let a = CodexRawUsage(input: 100, cachedInput: 10, output: 5, reasoningOutput: 0, total: 105)
        let b = CodexRawUsage(input: 150, cachedInput: 20, output: 9, reasoningOutput: 1, total: 159)
        let last = CodexRawUsage(input: 50, cachedInput: 10, output: 4, reasoningOutput: 1, total: 54)
        #expect(CodexTokenDelta.resolve(total: b, last: nil, previous: a) == .event(delta: b.subtracting(a), nextTotals: b))
        #expect(CodexTokenDelta.resolve(total: a, last: nil, previous: a) == nil)
        // Totals going backwards without a last usage start a new baseline.
        #expect(CodexTokenDelta.resolve(total: a, last: nil, previous: b) == .baseline(a))
        #expect(CodexTokenDelta.resolve(total: b, last: last, previous: a) == .event(delta: last, nextTotals: b))
        #expect(CodexTokenDelta.resolve(total: nil, last: last, previous: a) == .event(delta: last, nextTotals: a.adding(last)))
        #expect(CodexTokenDelta.resolve(total: nil, last: last, previous: nil) == .event(delta: last, nextTotals: nil))
        #expect(CodexTokenDelta.resolve(total: nil, last: nil, previous: a) == nil)
        // A slightly smaller replayed snapshot is stale, not a new request.
        let stale = CodexRawUsage(input: 149, cachedInput: 20, output: 9, reasoningOutput: 1, total: 158)
        #expect(CodexTokenDelta.resolve(total: stale, last: last, previous: b) == nil)
    }

    @Test func malformedCandidatesAreSkipped() {
        let parser = parse([#"{"type":"event_msg","payload":{"type":"token_count","#, #"{"type":"response_item"}"#])
        #expect(parser.skippedLines == 1)
        #expect(parser.turns.isEmpty)
    }
}
