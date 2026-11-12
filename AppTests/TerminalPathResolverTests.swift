import Foundation
import SevindaGit
import Testing
@testable import Sevinda

/// Paths printed in a terminal resolved to files on disk, and elided paths matched against a workspace's files.
@MainActor
struct TerminalPathResolverTests {
    /// A clock the test moves by hand. Only the test's main actor reads and writes it; `@unchecked Sendable` because
    /// the resolver's clock closure must be `@Sendable`.
    final class ManualClock: @unchecked Sendable {
        var now = ContinuousClock.now
    }

    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sevinda-paths-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/feature", isDirectory: true),
                                                withIntermediateDirectories: true)
        try "let a = 1\n".write(to: root.appendingPathComponent("src/feature/x.swift"), atomically: true, encoding: .utf8)
        try "# Read\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        return root.standardizedFileURL
    }

    @Test func locationsSplitSuffixesExpandTildeAndTryEachBase() {
        let locations = TerminalPathResolver.locations(for: "src/a.ts:12:4", bases: ["/w", "/v"])
        #expect(locations == [
            .init(path: "/w/src/a.ts:12:4"), .init(path: "/v/src/a.ts:12:4"),
            .init(path: "/w/src/a.ts", line: 12, column: 4), .init(path: "/v/src/a.ts", line: 12, column: 4),
        ])
        #expect(TerminalPathResolver.locations(for: "~/x.md", bases: []).first?.path == NSHomeDirectory() + "/x.md")
        #expect(TerminalPathResolver.locations(for: "file:///tmp/a%20b.txt", bases: []).first?.path == "/tmp/a b.txt")
        #expect(TerminalPathResolver.locations(for: "https://example.com/a.md", bases: ["/w"]).isEmpty)
        #expect(TerminalPathResolver.locations(for: "mailto:a@b.c", bases: ["/w"]).isEmpty)
        #expect(TerminalPathResolver.namesPath("a.swift:12"))
        #expect(!TerminalPathResolver.namesPath("ssh://host/x"))
    }

    @Test func resolvesFilesFoldersAndSymlinksAndDropsMissingPaths() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("link.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("src/feature/x.swift"))
        let resolver = TerminalPathResolver()
        let answers = await resolver.resolve([
            .init(text: "src/feature/x.swift:3:2", bases: [root]),
            .init(text: "src", bases: [root]),
            .init(text: root.path + "/README.md", bases: []),
            .init(text: "link.swift", bases: [root]),
            .init(text: "src/missing.swift", bases: [root]),
            .init(text: "and/or", bases: [root]),
            .init(text: "x.swift", bases: [root], line: 9),
            .init(text: "x.swift", bases: [nil, root.appendingPathComponent("src/feature")], line: 9, column: 2),
        ])
        #expect(answers[0]?.path == root.path + "/src/feature/x.swift")
        #expect(answers[0]?.line == 3 && answers[0]?.column == 2 && answers[0]?.isDirectory == false)
        #expect(answers[1]?.isDirectory == true)
        #expect(answers[2]?.path == root.path + "/README.md")
        #expect(answers[3]?.path == link.path)
        #expect(answers[4] == nil && answers[5] == nil && answers[6] == nil)
        #expect(answers[7]?.line == 9 && answers[7]?.column == 2, "the match's own line suffix is kept")
    }

    @Test func answersComeFromTheCacheUntilTheyExpireOrTheFolderChanges() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = ManualClock()
        let resolver = TerminalPathResolver(capacity: 4, timeToLive: .seconds(2), clock: { clock.now })
        let query = TerminalPathResolver.Query(text: "README.md", bases: [root])
        #expect(await resolver.resolve(query) != nil)

        // Removed on disk, but the cached answer stands within its lifetime.
        try FileManager.default.removeItem(at: root.appendingPathComponent("README.md"))
        #expect(await resolver.resolve(query) != nil, "cache hit")

        // A change in the folder drops it at once.
        resolver.apply(FileSystemWatcher.Change(folders: [""]), root: root.path)
        #expect(await resolver.resolve(query) == nil)

        // Recreated: the stored "missing" answer expires after its lifetime.
        try "# Read\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        #expect(await resolver.resolve(query) == nil, "the cached miss stands")
        clock.now += .seconds(3)
        #expect(await resolver.resolve(query) != nil)

        // Lost events below the root clear what was probed below it.
        resolver.apply(FileSystemWatcher.Change(subtrees: ["src"]), root: root.path)
        #expect(resolver.cachedCount == 1, "an answer outside the subtree stays")

        // The cache stays bounded.
        _ = await resolver.resolve((0..<10).map { TerminalPathResolver.Query(text: "f\($0).md", bases: [root]) })
        #expect(resolver.cachedCount <= 4)
    }

    @Test func elidedPartsAndRanking() {
        let files = ["src/feature/x.swift", "old/feature/x.swift", "a/b/c/feature/x.swift", "src/feature/xx.swift",
                     "Sources/A.swift", "Packages/P/Sources/A.swift", "docs/c.md"]
        #expect(TerminalPathResolver.rank(elided: "…/feature/x.swift", among: files, root: "/r")
            == ["old/feature/x.swift", "src/feature/x.swift", "a/b/c/feature/x.swift"])
        #expect(TerminalPathResolver.rank(elided: "Packages/.../Sources/A.swift", among: files, root: "/r") == ["Packages/P/Sources/A.swift"])
        #expect(TerminalPathResolver.rank(elided: "/r/src/…/x.swift", among: files, root: "/r") == ["src/feature/x.swift"])
        // A cut name matches the end of a name, after whole-name matches.
        #expect(TerminalPathResolver.rank(elided: "…x.swift", among: files, root: "/r").last == "src/feature/xx.swift")
        #expect(TerminalPathResolver.rank(elided: "~/…/c.md", among: files, root: "/r") == ["docs/c.md"])
        #expect(TerminalPathResolver.rank(elided: "…/nothing.swift", among: files, root: "/r").isEmpty)
        #expect(TerminalPathResolver.rank(elided: "…/x.swift", among: files, root: "/r", limit: 2).count == 2)
    }

    @Test func candidatesComeFromGitFilesOrABoundedWalk() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/feature", isDirectory: true),
                                                withIntermediateDirectories: true)
        try "".write(to: root.appendingPathComponent("node_modules/feature/x.swift"), atomically: true, encoding: .utf8)
        let resolver = TerminalPathResolver()

        // A plain folder: walked, skipping node_modules.
        let walked = await resolver.candidates(forElided: "…/feature/x.swift", in: root, isGit: false)
        #expect(walked.map(\.path) == [root.path + "/src/feature/x.swift"])
        #expect(TerminalPathResolver.walk(root.path, limit: 1).count <= 1, "the walk stops at its limit")

        // A git repository: tracked and untracked files, ignored ones left out.
        let git = GitRunner()
        _ = try await git.run(["init", "-b", "main"], in: root)
        try "ignored/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ignored/feature", isDirectory: true),
                                                withIntermediateDirectories: true)
        try "".write(to: root.appendingPathComponent("ignored/feature/x.swift"), atomically: true, encoding: .utf8)
        // A fresh resolver: the first one keeps the walked list for a while.
        let listed = await TerminalPathResolver().candidates(forElided: "…/feature/x.swift", in: root, isGit: true)
        #expect(Set(listed.map(\.path)) == [root.path + "/src/feature/x.swift", root.path + "/node_modules/feature/x.swift"])
        #expect(await resolver.candidates(forElided: "…/none.md", in: root, isGit: true).isEmpty)
    }
}
