import Foundation
import Testing
@testable import MercuryUsage

/// Measures a refresh over this machine's real logs, read-only, into a temporary cache. Prints numbers only.
/// Run with `MERCURY_USAGE_REAL=1 swift test -c release --package-path Packages/MercuryUsage --filter RealDataTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MERCURY_USAGE_REAL"] == "1"))
struct RealDataTests {
    /// Managed homes as the app lays them out under its data root; only listed, never written.
    private func managedHomes(_ folder: String) -> [URL] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mercury/\(folder)", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return entries.sorted().map { root.appendingPathComponent($0).appendingPathComponent("home", isDirectory: true) }
    }

    @Test func refreshRealLogs() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mercury-usage-real-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sources = UsageSourceSet.standard(
            managedClaudeHomes: managedHomes("claude-profiles"), managedCodexHomes: managedHomes("codex-homes"))
        let cacheURL = scratch.appendingPathComponent("usage/cache.json")
        let store = UsageStore(cacheURL: cacheURL, sources: sources)

        let clock = ContinuousClock()
        var snapshot = UsageSnapshot.empty
        let first = try await clock.measure { snapshot = try await store.refresh() }
        let second = try await clock.measure { snapshot = try await store.refresh() }
        let reopened = UsageStore(cacheURL: cacheURL, sources: sources)
        let coldCache = try await clock.measure { snapshot = try await reopened.refresh() }

        let cacheBytes = (try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.size] as? Int) ?? 0
        print("usage-real first refresh: \(first)")
        print("usage-real second refresh: \(second)")
        print("usage-real refresh from cache file in a new store: \(coldCache)")
        print("usage-real cache bytes: \(cacheBytes), files: \(snapshot.fileCounts), unreadable: \(snapshot.unreadableFiles)")
        for provider in [nil] + UsageProvider.allCases.map(Optional.some) {
            let summary = snapshot.summary(provider: provider, since: nil)
            let tokens = summary.tokens
            print(
                "usage-real \(provider?.rawValue ?? "all"): input \(tokens.input) output \(tokens.output)"
                    + " cacheRead \(tokens.cacheRead) cacheWrite \(tokens.cacheWrite) total \(tokens.total)"
                    + " cost \(summary.costUSD.map { String(format: "%.2f", $0) } ?? "n/a")"
                    + " unpriced \(summary.hasUnpricedUsage) days \(summary.activeDays) sessions \(summary.sessions)"
                    + " turns \(summary.turns) skipped \(summary.skippedLines)"
                    + " cacheShare \(summary.cacheShare.map { String(format: "%.3f", $0) } ?? "n/a")")
        }
        let last30 = snapshot.summary(provider: nil, since: Date().addingTimeInterval(-29 * 86_400))
        print("usage-real last 30 days: total \(last30.tokens.total) cost \(last30.costUSD.map { String(format: "%.2f", $0) } ?? "n/a")")
        #expect(snapshot.summary(provider: nil, since: nil).hasData)
    }
}
