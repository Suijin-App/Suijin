import Foundation
import Testing
@testable import SuijinGit

@Suite struct DiffServiceTests {
    /// main has a.txt, b.txt, gone.txt, README.md; `feature` (checked out in the repo) then commits edits.
    private func makeFeatureRepo() async throws -> TestRepo {
        let repo = try await TestRepo()
        try repo.write("a.txt", "one\ntwo\nthree\n")
        try repo.write("b.txt", (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n")
        try repo.write("gone.txt", "bye\n")
        try await repo.commitAll("base files")
        try await repo.git("checkout", "--quiet", "-b", "feature")
        try repo.write("a.txt", "one\n2\nthree\n")
        try await repo.git("mv", "b.txt", "renamed b.txt")
        try await repo.git("rm", "--quiet", "gone.txt")
        try await repo.commitAll("feature work")
        return repo
    }

    @Test func changedFilesAgainstBaseIncludesCommittedWorkingTreeAndUntracked() async throws {
        let repo = try await makeFeatureRepo()
        defer { repo.cleanUp() }
        // main moves on; that change must not show up (merge-base semantics).
        try await repo.git("checkout", "--quiet", "main")
        try repo.write("main-only.txt", "x\n")
        try await repo.commitAll("main moves")
        try await repo.git("checkout", "--quiet", "feature")

        try repo.write("README.md", "edited\n")
        try repo.write("new dir/untracked file.txt", "fresh\n")
        try repo.write(".gitignore", "ignored.log\n")
        try repo.write("ignored.log", "noise\n")

        let files = try await DiffService(worktree: repo.url).changedFiles(.againstBase("main"))
        #expect(files == [
            ChangedFile(path: ".gitignore", kind: .added),
            ChangedFile(path: "README.md", kind: .modified),
            ChangedFile(path: "a.txt", kind: .modified),
            ChangedFile(path: "gone.txt", kind: .deleted),
            ChangedFile(path: "new dir/untracked file.txt", kind: .added),
            ChangedFile(path: "renamed b.txt", kind: .renamed(from: "b.txt")),
        ])
    }

    @Test func uncommittedScopeOnlyShowsWorkingTreeChanges() async throws {
        let repo = try await makeFeatureRepo()
        defer { repo.cleanUp() }
        let service = DiffService(worktree: repo.url)
        #expect(try await service.changedFiles(.uncommitted).isEmpty)

        try repo.write("a.txt", "one\n2\nthree\nfour\n")
        try repo.write("staged.txt", "s\n")
        try await repo.git("add", "staged.txt")
        try repo.write("untracked.txt", "u\n")
        #expect(try await service.changedFiles(.uncommitted) == [
            ChangedFile(path: "a.txt", kind: .modified),
            ChangedFile(path: "staged.txt", kind: .added),
            ChangedFile(path: "untracked.txt", kind: .added),
        ])

        let diff = try await service.diff(for: "a.txt", scope: .uncommitted)
        #expect(diff.oldPath == "a.txt" && diff.newPath == "a.txt")
        #expect(diff.hunks.first?.lines.filter { $0.kind == .added }.map(\.text) == ["four"])
    }

    @Test func diffForEachKindOfFile() async throws {
        let repo = try await makeFeatureRepo()
        defer { repo.cleanUp() }
        try repo.write("untracked.txt", "first\nsecond")
        try repo.write("blob.bin", Data([0, 1, 2, 0, 255]))
        let service = DiffService(worktree: repo.url)
        let scope = DiffScope.againstBase("main")

        let modified = try await service.diff(for: "a.txt", scope: scope)
        #expect(modified.hunks.first?.lines.contains(DiffLine(kind: .added, text: "2", oldLine: nil, newLine: 2)) == true)

        let renamed = try await service.diff(for: "renamed b.txt", scope: scope)
        #expect(renamed.oldPath == "b.txt" && renamed.newPath == "renamed b.txt" && renamed.similarity == 100)

        let deleted = try await service.diff(for: "gone.txt", scope: scope)
        #expect(deleted.oldPath == "gone.txt" && deleted.newPath == nil)
        #expect(deleted.hunks.first?.lines == [DiffLine(kind: .deleted, text: "bye", oldLine: 1, newLine: nil)])

        let untracked = try await service.diff(for: "untracked.txt", scope: scope)
        #expect(untracked.oldPath == nil && untracked.newPath == "untracked.txt")
        #expect(untracked.hunks.first?.lines.map(\.kind) == [.added, .added, .noNewlineMarker])

        let binary = try await service.diff(for: "blob.bin", scope: .uncommitted)
        #expect(binary.isBinary && binary.oldPath == nil && binary.newPath == "blob.bin")

        let unchanged = try await service.diff(for: "README.md", scope: scope)
        #expect(unchanged == FileDiff(oldPath: "README.md", newPath: "README.md"))
    }

    /// Reading a listed file gives the diff that looking it up by path gives, for every kind of file and every scope.
    @Test func diffOfAListedFileMatchesTheDiffByPath() async throws {
        let repo = try await makeFeatureRepo()
        defer { repo.cleanUp() }
        try repo.write("untracked.txt", "first\nsecond")
        try repo.write("blob.bin", Data([0, 1, 2, 0, 255]))
        let service = DiffService(worktree: repo.url)
        let commit = try await repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)

        var compared = 0
        for scope in [DiffScope.againstBase("main"), .committed("main"), .uncommitted, .commit(commit)] {
            for change in try await service.changedFiles(scope) {
                let listed = try await service.diff(for: change, scope: scope)
                #expect(listed == (try await service.diff(for: change.path, scope: scope)))
                compared += 1
            }
        }
        // Modified, renamed, deleted, untracked and binary files were all among them.
        #expect(compared >= 8)
    }

    @Test func diffInLinkedWorktree() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        let path = repo.root.appendingPathComponent("wt", isDirectory: true)
        try await WorktreeService(repository: repo.url).add(branch: "agent", at: path, base: "main")
        try repo.write("README.md", "hello\nworld\n", in: path)
        try await repo.commitAll("agent edit", in: path)

        let service = DiffService(worktree: path)
        #expect(try await service.changedFiles(.againstBase("main")) == [ChangedFile(path: "README.md", kind: .modified)])
        #expect(try await service.changedFiles(.uncommitted).isEmpty)
        // The main checkout is unaffected.
        #expect(try await DiffService(worktree: repo.url).changedFiles(.uncommitted).isEmpty)
    }

    @Test func uncommittedBeforeFirstCommit() async throws {
        let repo = try await TestRepo(initialCommit: false)
        defer { repo.cleanUp() }
        try repo.write("first.txt", "1\n")
        try repo.write("staged.txt", "2\n")
        try await repo.git("add", "staged.txt")
        let service = DiffService(worktree: repo.url)
        #expect(try await service.changedFiles(.uncommitted) == [
            ChangedFile(path: "first.txt", kind: .added),
            ChangedFile(path: "staged.txt", kind: .added),
        ])
        #expect(try await service.diff(for: "staged.txt", scope: .uncommitted).hunks.first?.lines.first?.text == "2")
    }

    @Test func unknownBaseThrows() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        await #expect(throws: GitError.self) {
            _ = try await DiffService(worktree: repo.url).changedFiles(.againstBase("does-not-exist"))
        }
    }

    @Test func parsesNameStatus() {
        let raw = "M\0a\0R087\0old\0new\0C100\0src\0dst\0A\0b c\0D\0d\0T\0t\0U\0u\0"
        #expect(DiffService.parseNameStatus(Data(raw.utf8)) == [
            ChangedFile(path: "a", kind: .modified),
            ChangedFile(path: "new", kind: .renamed(from: "old")),
            ChangedFile(path: "dst", kind: .copied(from: "src")),
            ChangedFile(path: "b c", kind: .added),
            ChangedFile(path: "d", kind: .deleted),
            ChangedFile(path: "t", kind: .typeChanged),
            ChangedFile(path: "u", kind: .unmerged),
        ])
    }
}
