import Darwin
import Foundation
import Testing
@testable import SevindaUsage

@Suite struct TailReaderTests {
    private func read(_ url: URL, from checkpoint: FileCheckpoint?, tail: Bool = false) throws
        -> (lines: [String], tails: [String], outcome: JSONLTailReader.Outcome)
    {
        var lines: [String] = []
        var tails: [String] = []
        let outcome = try JSONLTailReader.read(
            path: url.path, from: checkpoint,
            onLine: { lines.append(String(decoding: $0, as: UTF8.self)) },
            onUnterminatedTail: {
                tails.append(String(decoding: $0, as: UTF8.self))
                return tail
            })
        return (lines, tails, outcome)
    }

    @Test func appendResumesAtTheCheckpoint() throws {
        let folder = Fixture.Folder()
        let url = folder.write("a.jsonl", lines: ["one", "two"])
        let first = try read(url, from: nil)
        #expect(first.lines == ["one", "two"])
        #expect(first.outcome.checkpoint.offset == 8 && !first.outcome.resumed)

        folder.append("a.jsonl", "three\n")
        let second = try read(url, from: first.outcome.checkpoint)
        #expect(second.lines == ["three"])
        #expect(second.outcome.resumed && second.outcome.bytesRead == 6)
        #expect(second.outcome.checkpoint.offset == 14)
    }

    @Test func partialLastLineWaitsForItsNewline() throws {
        let folder = Fixture.Folder()
        let url = folder.write("a.jsonl", lines: ["one"])
        folder.append("a.jsonl", "tw")
        let first = try read(url, from: nil)
        #expect(first.lines == ["one"] && first.tails == ["tw"])
        #expect(first.outcome.checkpoint.offset == 4)

        folder.append("a.jsonl", "o\n")
        let second = try read(url, from: first.outcome.checkpoint)
        #expect(second.lines == ["two"] && second.tails.isEmpty)
    }

    @Test func completeTailIsConsumedOnce() throws {
        let folder = Fixture.Folder()
        let url = folder.write("a.jsonl", lines: ["one", "{}"], trailingNewline: false)
        let first = try read(url, from: nil, tail: true)
        #expect(first.outcome.checkpoint.offset == 6)
        folder.append("a.jsonl", "\nnext\n")
        let second = try read(url, from: first.outcome.checkpoint)
        #expect(second.lines == ["", "next"])
    }

    @Test func truncationRereadsFromTheStart() throws {
        let folder = Fixture.Folder()
        let url = folder.write("a.jsonl", lines: ["one", "two", "three"])
        let first = try read(url, from: nil)
        folder.write("a.jsonl", lines: ["four"])
        let second = try read(url, from: first.outcome.checkpoint)
        #expect(second.lines == ["four"] && !second.outcome.resumed)
    }

    @Test func rewrittenPrefixRereadsFromTheStart() throws {
        let folder = Fixture.Folder()
        let url = folder.write("a.jsonl", lines: ["aaaa", "bbbb"])
        let first = try read(url, from: nil)
        // Same inode, longer, but the bytes before the checkpoint changed.
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data("cccc\ndddd\neeee\n".utf8))
        try handle.close()
        let second = try read(url, from: first.outcome.checkpoint)
        #expect(second.lines == ["cccc", "dddd", "eeee"] && !second.outcome.resumed)
    }

    @Test func replacedFileRereadsFromTheStart() throws {
        let folder = Fixture.Folder()
        let url = folder.write("a.jsonl", lines: ["one", "two"])
        let first = try read(url, from: nil)
        let replacement = folder.write("new.jsonl", lines: ["one", "two", "three"])
        #expect(rename(replacement.path, url.path) == 0)
        let second = try read(url, from: first.outcome.checkpoint)
        #expect(second.lines == ["one", "two", "three"] && !second.outcome.resumed)
    }

    @Test func linesLongerThanAChunk() throws {
        let folder = Fixture.Folder()
        let long = String(repeating: "x", count: JSONLTailReader.chunkSize + 123)
        let url = folder.write("a.jsonl", lines: ["a", long, "b"])
        let result = try read(url, from: nil)
        #expect(result.lines.map(\.count) == [1, long.count, 1])
    }

    @Test func missingFileIsReportedAsMissing() {
        #expect(throws: LogReadError.self) { try read(URL(fileURLWithPath: "/nonexistent/x.jsonl"), from: nil) }
        do {
            _ = try read(URL(fileURLWithPath: "/nonexistent/x.jsonl"), from: nil)
        } catch let error as LogReadError {
            #expect(error.isMissing)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

@Suite struct UsageStoreTests {
    private func store(_ folder: Fixture.Folder, cache: String = "data/usage/cache.json") -> UsageStore {
        UsageStore(
            cacheURL: folder.url.appendingPathComponent(cache),
            sources: UsageSourceSet(
                claudeRoots: [folder.url.appendingPathComponent("claude/projects")],
                codexRoots: [folder.url.appendingPathComponent("codex/sessions")]))
    }

    @Test func fullThenIncrementalRefresh() async throws {
        let folder = Fixture.Folder()
        folder.write("claude/projects/-Users-me-alpha/s1.jsonl", lines: [
            Fixture.claude(messageID: "m1", output: 10),
            Fixture.claude(messageID: "m1", output: 40),
            Fixture.claude(messageID: "m2", timestamp: "2026-11-11T12:00:00Z"),
        ])
        folder.write("codex/sessions/2026/11/10/rollout-1.jsonl", lines: [
            Fixture.codexMeta(), Fixture.codexTurn(),
            Fixture.codexTokens(total: Fixture.usage(1_000, cached: 400, output: 100), last: nil),
        ])
        let store = store(folder)
        let fractions = Fractions()
        let first = try await store.refresh { fractions.add($0) }
        let overview = first.summary(provider: nil, since: nil)
        #expect(overview.turns == 3)
        #expect(overview.tokens.output == 40 + 50 + 100)
        #expect(first.fileCounts == [.claude: 1, .codex: 1])
        #expect(fractions.values.first == 0 && fractions.values.last == 1)

        // Append to both files, including a streaming row of an already counted response.
        folder.append("claude/projects/-Users-me-alpha/s1.jsonl",
                      Fixture.claude(messageID: "m2", timestamp: "2026-11-11T12:00:00Z", output: 90) + "\n"
                      + Fixture.claude(messageID: "m3", session: "s2") + "\n")
        folder.append("codex/sessions/2026/11/10/rollout-1.jsonl",
                      Fixture.codexTokens(total: Fixture.usage(1_500, cached: 900, output: 160), last: nil) + "\n")
        let second = try await store.refresh()
        let claude = second.summary(provider: .claude, since: nil)
        #expect(claude.turns == 3)
        #expect(claude.tokens.output == 40 + 90 + 50)
        #expect(claude.sessions == 2)
        let codex = second.summary(provider: .codex, since: nil)
        #expect(codex.turns == 2)
        #expect(codex.tokens == UsageTokens(input: 600, output: 160, cacheRead: 900, cacheWrite: 0))
        #expect(codex.topModel?.name == "gpt-5.5")

        // Nothing changed: the same numbers.
        let third = try await store.refresh()
        #expect(third.days == second.days)
    }

    @Test func copiedHistoryAndSharedRolloutsCountOnce() async throws {
        let folder = Fixture.Folder()
        let original = [Fixture.claude(messageID: "m1"), Fixture.claude(messageID: "m2")]
        folder.write("claude/projects/p/original.jsonl", lines: original)
        // A resumed session starts with a copy of the earlier rows under a new session ID.
        folder.write("claude/projects/p/resumed.jsonl", lines: [
            Fixture.claude(messageID: "m1", session: "s2"), Fixture.claude(messageID: "m2", session: "s2"),
            Fixture.claude(messageID: "m3", session: "s2"),
        ])
        // Codex accounts share one physical rollout through a hard link.
        let rollout = folder.write("codex/sessions/2026/11/10/rollout-1.jsonl", lines: [
            Fixture.codexTurn(), Fixture.codexTokens(total: Fixture.usage(1_000, cached: 400, output: 100), last: nil),
        ])
        let linked = folder.file("codex/sessions/2026/11/10/rollout-1-link.jsonl")
        #expect(link(rollout.path, linked.path) == 0)
        let snapshot = try await store(folder).refresh()
        #expect(snapshot.summary(provider: .claude, since: nil).turns == 3)
        #expect(snapshot.summary(provider: .codex, since: nil).turns == 1)
        #expect(snapshot.fileCounts[.codex] == 1)
    }

    @Test func truncatedFileIsNotCountedTwice() async throws {
        let folder = Fixture.Folder()
        let path = "claude/projects/p/s.jsonl"
        folder.write(path, lines: [Fixture.claude(messageID: "m1"), Fixture.claude(messageID: "m2")])
        let store = store(folder)
        _ = try await store.refresh()
        // Rewritten shorter with one old row and one new row.
        folder.write(path, lines: [Fixture.claude(messageID: "m2"), Fixture.claude(messageID: "m9")])
        let snapshot = try await store.refresh()
        #expect(snapshot.summary(provider: .claude, since: nil).turns == 3)
    }

    @Test func deletedFileKeepsItsHistory() async throws {
        let folder = Fixture.Folder()
        let url = folder.write("claude/projects/p/s.jsonl", lines: [Fixture.claude()])
        let store = store(folder)
        _ = try await store.refresh()
        try FileManager.default.removeItem(at: url)
        let snapshot = try await store.refresh()
        #expect(snapshot.summary(provider: .claude, since: nil).turns == 1)
        #expect(snapshot.fileCounts[.claude] == nil)
    }

    @Test func cacheRoundTripAndPermissions() async throws {
        let folder = Fixture.Folder()
        folder.write("claude/projects/p/s.jsonl", lines: [Fixture.claude(), Fixture.claude(messageID: "m2")])
        folder.write("codex/sessions/r.jsonl", lines: [
            Fixture.codexMeta(), Fixture.codexTurn(),
            Fixture.codexTokens(total: Fixture.usage(1_000, cached: 400, output: 100), last: nil),
        ])
        let first = try await store(folder).refresh()

        let cacheURL = folder.url.appendingPathComponent("data/usage/cache.json")
        let fileMode = try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.posixPermissions] as? Int
        let directoryMode = try FileManager.default.attributesOfItem(
            atPath: cacheURL.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(directoryMode == 0o700)
        // Numbers and labels only: no message content, no full working directories.
        let text = try String(contentsOf: cacheURL, encoding: .utf8)
        #expect(!text.contains("assistant") && !text.contains("/Users/me/Code"))

        let reopened = store(folder)
        let cached = try #require(await reopened.cachedSnapshot())
        #expect(cached.days == first.days)
        #expect(cached.summary(provider: nil, since: nil)
                == first.summary(provider: nil, since: nil))
        // A second store resumes from the cache: an append is read without counting the old rows again.
        folder.append("codex/sessions/r.jsonl",
                      Fixture.codexTokens(total: Fixture.usage(1_200, cached: 400, output: 120), last: nil) + "\n")
        let refreshed = try await reopened.refresh()
        let codex = refreshed.summary(provider: .codex, since: nil)
        #expect(codex.turns == 2)
        #expect(codex.tokens == UsageTokens(input: 800, output: 120, cacheRead: 400, cacheWrite: 0))
        #expect(refreshed.summary(provider: .claude, since: nil).turns == 2)
    }

    @Test func largeHashesSurviveTheCache() throws {
        var ledger = UsageLedger()
        ledger.seenKeys = [UInt64.max, 1, 0x8000_0000_0000_0001]
        ledger.sessions[.claude] = [UsageCalendarDay(year: 2026, month: 1, day: 2): [UInt64.max - 7]]
        ledger.updatedAt = Date(timeIntervalSince1970: 1_000)
        let data = try JSONEncoder().encode(UsageCacheFile(ledger))
        let restored = try #require(try JSONDecoder().decode(UsageCacheFile.self, from: data).ledger())
        #expect(restored.seenKeys == ledger.seenKeys)
        #expect(restored.sessions == ledger.sessions)
    }

    @Test func corruptOrOutdatedCacheIsRebuilt() async throws {
        let folder = Fixture.Folder()
        folder.write("claude/projects/p/s.jsonl", lines: [Fixture.claude()])
        let cacheURL = folder.file("data/usage/cache.json")
        try Data("{not json".utf8).write(to: cacheURL)
        let store = store(folder)
        #expect(await store.cachedSnapshot() == nil)
        let snapshot = try await store.refresh()
        #expect(snapshot.summary(provider: nil, since: nil).turns == 1)
    }

    @Test func refusesACacheInsideALogFolder() async throws {
        let folder = Fixture.Folder()
        folder.write("claude/projects/p/s.jsonl", lines: [Fixture.claude()])
        let store = store(folder, cache: "claude/projects/cache.json")
        await #expect(throws: UsageStoreError.self) { try await store.refresh() }
        #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("claude/projects/cache.json").path))
    }

    @Test func standardSourcesIncludeEnvironmentAndManagedHomes() {
        let home = URL(fileURLWithPath: "/Users/me")
        let sources = UsageSourceSet.standard(
            environment: ["CLAUDE_CONFIG_DIR": "/opt/claude", "CODEX_HOME": "relative/ignored"], homeDirectory: home,
            managedClaudeHomes: [URL(fileURLWithPath: "/data/claude-profiles/a/home")],
            managedCodexHomes: [URL(fileURLWithPath: "/data/codex-homes/b/home")])
        #expect(sources.claudeRoots.map(\.path) == [
            "/Users/me/.claude/projects", "/opt/claude/projects", "/data/claude-profiles/a/home/projects",
        ])
        #expect(sources.codexRoots.map(\.path) == ["/Users/me/.codex/sessions", "/data/codex-homes/b/home/sessions"])
    }

    @Test func cancellationStopsTheScan() async throws {
        let folder = Fixture.Folder()
        for index in 0..<40 {
            folder.write("claude/projects/p/s\(index).jsonl", lines: (0..<200).map {
                Fixture.claude(messageID: "m\(index)-\($0)")
            })
        }
        let store = store(folder)
        let task = Task { try await store.refresh() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        // A later refresh still completes and counts every row once.
        let snapshot = try await store.refresh()
        #expect(snapshot.summary(provider: nil, since: nil).turns == 8_000)
    }
}

/// Collects progress values from a background thread.
final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    func add(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}
