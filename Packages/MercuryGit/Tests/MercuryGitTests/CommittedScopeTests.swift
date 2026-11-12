import Foundation
import Testing
@testable import MercuryGit

/// The Changes screen splits a checkout's changes into what is committed (not yet on the base) and what is not.
@Suite struct CommittedScopeTests {
    @Test func committedScopeHasOnlyCommitsAndUncommittedOnlyTheWorkingTree() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("base")
        try await repo.git("checkout", "--quiet", "-b", "feature")
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.commitAll("feature 1")
        try repo.write("b.txt", "b\n")
        try await repo.commitAll("feature 2")
        // Uncommitted on top: a.txt edited again, a new untracked file.
        try repo.write("a.txt", "one\ntwo\nthree\n")
        try repo.write("c.txt", "c\n")

        let service = DiffService(worktree: repo.url)
        #expect(try await service.changedFiles(.committed("main")) == [
            ChangedFile(path: "a.txt", kind: .modified),
            ChangedFile(path: "b.txt", kind: .added),
        ])
        #expect(try await service.changedFiles(.uncommitted) == [
            ChangedFile(path: "a.txt", kind: .modified),
            ChangedFile(path: "c.txt", kind: .added),
        ])
        #expect(await service.commitsAhead(of: "main") == 2)
        #expect(await service.commitsAhead(of: "no-such-branch") == nil)

        // The same file shows its committed part and its uncommitted part separately.
        let committed = try await service.diff(for: "a.txt", scope: .committed("main"))
        #expect(committed.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text) == ["two"])
        let uncommitted = try await service.diff(for: "a.txt", scope: .uncommitted)
        #expect(uncommitted.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text) == ["three"])

        // The commits themselves, newest first, and what each one changed.
        let commits = await service.commits(notOn: "main")
        #expect(commits.map(\.subject) == ["feature 2", "feature 1"])
        #expect(commits.allSatisfy { $0.author == "Mercury Tests" && $0.sha.count == 40 })
        #expect(try await service.changedFiles(.commit(commits[0].sha)) == [ChangedFile(path: "b.txt", kind: .added)])
        let first = try await service.diff(for: "a.txt", scope: .commit(commits[1].sha))
        #expect(first.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text) == ["two"])
        #expect(await service.commits(notOn: "no-such-branch").isEmpty)
    }

    @Test func rootCommitDiffsAgainstTheEmptyTree() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        let root = try await repo.git("rev-list", "--max-parents=0", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try await DiffService(worktree: repo.url).changedFiles(.commit(root)) == [ChangedFile(path: "README.md", kind: .added)])
    }
}
