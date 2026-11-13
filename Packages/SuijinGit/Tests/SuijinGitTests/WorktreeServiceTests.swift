import Foundation
import Testing
@testable import SuijinGit

@Suite struct WorktreeServiceTests {
    @Test func addListAndRemoveWorktrees() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        let service = WorktreeService(repository: repo.url)
        let path = WorktreeService.defaultPath(repository: repo.url, branch: "feature/one")
        #expect(path.path == repo.root.appendingPathComponent("repo-worktrees/feature/one").path)

        try await service.add(branch: "feature/one", at: path, base: "main")
        let spaced = repo.root.appendingPathComponent("with space", isDirectory: true)
        try await service.add(branch: "two", at: spaced, base: "main")

        let list = try await service.list()
        #expect(list.count == 3)
        #expect(list[0].isMain && list[0].path.path == repo.url.path && list[0].branch == "main")
        #expect(list[0].head?.count == 40)
        #expect(list[1].path.path == path.path && list[1].branch == "feature/one" && !list[1].isMain)
        #expect(list[2].path.path == spaced.path && list[2].branch == "two")
        #expect(list.allSatisfy { !$0.isDetached && !$0.isLocked && !$0.isPrunable })
        #expect(Set(try await service.localBranches()) == ["main", "feature/one", "two"])

        try await service.remove(at: path, force: false)
        #expect(try await service.list().map(\.path.path) == [repo.url.path, spaced.path])
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func removeWithChangesNeedsForce() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        let service = WorktreeService(repository: repo.url)
        let path = repo.root.appendingPathComponent("wt", isDirectory: true)
        try await service.add(branch: "wt", at: path, base: "main")
        #expect(try await service.hasUncommittedChanges(at: path) == false)

        try repo.write("scratch.txt", "untracked\n", in: path)
        #expect(try await service.hasUncommittedChanges(at: path))
        await #expect(throws: GitError.self) { try await service.remove(at: path, force: false) }
        try await service.remove(at: path, force: true)
        #expect(try await service.list().count == 1)
    }

    @Test func detachedLockedAndPrunableEntries() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        let service = WorktreeService(repository: repo.url)
        let detached = repo.root.appendingPathComponent("detached", isDirectory: true)
        try await repo.git("worktree", "add", "--detach", detached.path, "main")
        try await repo.git("worktree", "lock", detached.path)
        let gone = repo.root.appendingPathComponent("gone", isDirectory: true)
        try await service.add(branch: "gone", at: gone, base: "main")
        try FileManager.default.removeItem(at: gone)

        let list = try await service.list()
        let detachedEntry = try #require(list.first { $0.path.path == detached.path })
        #expect(detachedEntry.isDetached && detachedEntry.branch == nil && detachedEntry.isLocked)
        #expect(list.first { $0.path.path == gone.path }?.isPrunable == true)

        try await service.prune()
        #expect(try await service.list().contains { $0.path.path == gone.path } == false)
    }

    @Test func uncommittedChangesInMainCheckout() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        let service = WorktreeService(repository: repo.url)
        #expect(try await service.hasUncommittedChanges(at: repo.url) == false)
        try repo.write("README.md", "changed\n")
        #expect(try await service.hasUncommittedChanges(at: repo.url))
    }

    @Test func branchQueries() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        let service = WorktreeService(repository: repo.url)
        #expect(try await service.currentBranch() == "main")
        #expect(try await service.defaultBaseBranch() == "main")

        try await repo.git("checkout", "--quiet", "-b", "dev")
        try await repo.git("branch", "-m", "main", "trunk")
        #expect(try await service.defaultBaseBranch() == "dev")

        try await repo.git("checkout", "--quiet", "--detach")
        #expect(try await service.currentBranch() == nil)

        // origin/HEAD wins when present.
        try await repo.git("update-ref", "refs/remotes/origin/trunk", "HEAD")
        try await repo.git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk")
        #expect(try await service.defaultBaseBranch() == "origin/trunk")
    }

    @Test func parsesPorcelainOutput() {
        let raw = "worktree /r\0HEAD abc\0branch refs/heads/main\0\0worktree /r-wt/x\0HEAD def\0detached\0locked reason\0prunable gitdir file points to non-existent location\0\0worktree /bare\0bare\0\0"
        let list = WorktreeService.parseWorktreeList(Data(raw.utf8))
        #expect(list == [
            Worktree(path: URL(fileURLWithPath: "/r", isDirectory: true), head: "abc", branch: "main", isMain: true),
            Worktree(path: URL(fileURLWithPath: "/r-wt/x", isDirectory: true), head: "def", isDetached: true, isLocked: true, isPrunable: true),
            Worktree(path: URL(fileURLWithPath: "/bare", isDirectory: true)),
        ])
    }
}
