import Foundation
import Testing
@testable import SevindaGit

@Suite struct StatusParserTests {
    @Test func parsesBranchHeadersAndRecords() {
        let records = [
            "# branch.oid 1234567890abcdef1234567890abcdef12345678",
            "# branch.head feature/x",
            "# branch.upstream origin/feature/x",
            "# branch.ab +3 -1",
            "1 M. N... 100644 100644 100644 aaaa bbbb staged.txt",
            "1 .M N... 100644 100644 100644 aaaa aaaa has space.txt",
            "1 MM N... 100644 100644 100644 aaaa bbbb both.txt",
            "2 R. N... 100644 100644 100644 aaaa aaaa R100 new name.txt", "old name.txt",
            "u UU N... 100644 100644 100644 100644 a b c conflict.txt",
            "? untracked/file.txt",
        ]
        let data = Data((records.joined(separator: "\0") + "\0").utf8)
        let status = SourceControlService.parseStatus(data)
        #expect(status.branch == "feature/x")
        #expect(status.upstream == "origin/feature/x")
        #expect(status.ahead == 3 && status.behind == 1)
        #expect(status.headOID == "1234567890abcdef1234567890abcdef12345678")
        #expect(status.staged.map(\.path) == ["both.txt", "new name.txt", "staged.txt"])
        #expect(status.unstaged.map(\.path) == ["both.txt", "conflict.txt", "has space.txt", "untracked/file.txt"])
        #expect(status.entries.first { $0.path == "new name.txt" }?.originalPath == "old name.txt")
        #expect(status.conflicted.map(\.path) == ["conflict.txt"])
    }

    @Test func initialAndDetachedHeads() {
        let initial = SourceControlService.parseStatus(Data("# branch.oid (initial)\0# branch.head main\0".utf8))
        #expect(initial.headOID == nil && initial.branch == "main" && !initial.hasCommits)
        let detached = SourceControlService.parseStatus(Data("# branch.oid abc\0# branch.head (detached)\0".utf8))
        #expect(detached.branch == nil && detached.hasCommits)
    }
}

@Suite struct StagingAndCommitTests {
    @Test func stagesUnstagesAndCommits() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        let service = SourceControlService(worktree: repo.url)
        try repo.write("README.md", "changed\n")
        try repo.write("-dash.txt", "leading dash\n")
        try repo.write("glob*.txt", "glob\n")
        try repo.write("globber.txt", "must stay unstaged\n")

        var status = try await service.status()
        #expect(status.unstaged.map(\.path) == ["-dash.txt", "README.md", "glob*.txt", "globber.txt"])
        #expect(status.staged.isEmpty)

        // `glob*.txt` must match only itself.
        try await service.stage(["-dash.txt", "README.md", "glob*.txt"])
        status = try await service.status()
        #expect(status.staged.map(\.path) == ["-dash.txt", "README.md", "glob*.txt"])
        #expect(status.unstaged.map(\.path) == ["globber.txt"])

        try await service.unstage(["README.md"])
        status = try await service.status()
        #expect(status.staged.map(\.path) == ["-dash.txt", "glob*.txt"])

        let diff = try await service.stagedDiff()
        #expect(diff.contains("+leading dash"))
        #expect(!diff.contains("changed"))

        let commit = try await withIdentity(repo) { try await service.commit(message: "  feat: add files\n\nBody line\n") }
        #expect(commit.summary == "feat: add files")
        #expect(commit.oid.count == 40)
        #expect(try await service.recentCommitSubjects(limit: 5) == ["feat: add files", "initial"])
        status = try await service.status()
        #expect(status.staged.isEmpty)
        #expect(Set(status.unstaged.map(\.path)) == ["README.md", "globber.txt"])
    }

    @Test func stagesDeletionsAndUnstagesBeforeFirstCommit() async throws {
        let repo = try await TestRepo(initialCommit: false)
        defer { repo.cleanUp() }
        let service = SourceControlService(worktree: repo.url)
        try repo.write("a.txt", "a\n")
        try await service.stage(["a.txt"])
        #expect(try await service.status().staged.map(\.path) == ["a.txt"])
        try await service.unstage(["a.txt"])
        let status = try await service.status()
        #expect(status.staged.isEmpty)
        #expect(status.unstaged.first?.isUntracked == true)
        #expect(try await service.recentCommitSubjects() == [])

        try await service.stage(["a.txt"])
        _ = try await withIdentity(repo) { try await service.commit(message: "first") }
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("a.txt"))
        try await service.stage(["a.txt"])
        #expect(try await service.status().staged.first?.index == .deleted)
    }

    @Test func failingHookKeepsOutputAndIndex() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        let service = SourceControlService(worktree: repo.url)
        // A global `core.hooksPath` would bypass the repository's hooks directory.
        try await repo.git("config", "core.hooksPath", ".git/hooks")
        let hook = repo.url.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\necho 'lint: 2 problems on stdout'\necho 'trailing whitespace on stderr' >&2\nexit 1\n"
            .write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try repo.write("README.md", "changed\n")
        try await service.stage(["README.md"])

        let error = await #expect(throws: GitError.self) {
            _ = try await withIdentity(repo) { try await service.commit(message: "feat: blocked") }
        }
        #expect(error?.stderr.contains("lint: 2 problems on stdout") == true)
        #expect(error?.stderr.contains("trailing whitespace on stderr") == true)
        #expect(try await service.status().staged.map(\.path) == ["README.md"])
        #expect(try await service.recentCommitSubjects() == ["initial"])
    }

    @Test func rejectsEmptyMessage() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        await #expect(throws: GitError.self) { _ = try await SourceControlService(worktree: repo.url).commit(message: " \n ") }
    }
}

@Suite struct PushTests {
    @Test func pushesSetsUpstreamAndReportsAheadBehind() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        let remote = repo.root.appendingPathComponent("remote.git", isDirectory: true)
        try await repo.git(["init", "--bare", "--quiet", "--initial-branch=main", remote.path], in: repo.root)
        try await repo.git("remote", "add", "origin", remote.path)
        try await repo.git("checkout", "--quiet", "-b", "feature/push")
        let service = SourceControlService(worktree: repo.url)
        #expect(try await service.status().upstream == nil)

        let first = try await service.push()
        #expect(first.setUpstream && first.remote == "origin")
        var status = try await service.status()
        #expect(status.upstream == "origin/feature/push")
        #expect(status.ahead == 0 && status.behind == 0)

        try repo.write("b.txt", "b\n")
        try await repo.commitAll("second")
        #expect(try await service.status().ahead == 1)
        let second = try await service.push()
        #expect(!second.setUpstream)
        status = try await service.status()
        #expect(status.ahead == 0)
        let remoteHead = try await repo.git(["rev-parse", "refs/heads/feature/push"], in: remote)
        #expect(remoteHead.trimmingCharacters(in: .newlines) == status.headOID)
        #expect(try await service.commitMessages(since: "main") == ["second"])
        #expect(await service.revisionExists("origin/feature/push"))
        #expect(await service.revisionExists("origin/nope") == false)
        #expect(await service.revisionExists("--all") == false)
        #expect(try await service.diff(since: "main").contains("+b"))
    }

    @Test func rejectedPushThrowsGitOutput() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        let remote = repo.root.appendingPathComponent("remote.git", isDirectory: true)
        try await repo.git(["init", "--bare", "--quiet", "--initial-branch=main", remote.path], in: repo.root)
        try await repo.git("remote", "add", "origin", remote.path)
        let service = SourceControlService(worktree: repo.url)
        _ = try await service.push()

        // Another clone moves the remote ahead; the local branch diverges.
        let other = repo.root.appendingPathComponent("other", isDirectory: true)
        try await repo.git(["clone", "--quiet", remote.path, other.path], in: repo.root)
        try repo.write("c.txt", "theirs\n", in: other)
        try await repo.commitAll("theirs", in: other)
        try await repo.git(["push", "--quiet"], in: other)
        try repo.write("c.txt", "ours\n")
        try await repo.commitAll("ours")
        try await repo.git("fetch", "--quiet")
        let status = try await service.status()
        #expect(status.ahead == 1 && status.behind == 1)

        let error = await #expect(throws: GitError.self) { _ = try await service.push() }
        #expect(error?.stderr.contains("rejected") == true)
    }

    @Test func pushWithoutRemoteExplains() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        let error = await #expect(throws: GitError.self) { _ = try await SourceControlService(worktree: repo.url).push() }
        #expect(error?.stderr.contains("no remote") == true)
    }
}

/// Runs `body` with a commit identity in the repository config (tests must not depend on the user's global config).
private func withIdentity<T>(_ repo: TestRepo, _ body: () async throws -> T) async throws -> T {
    try await repo.git("config", "user.name", "Mercury Tests")
    try await repo.git("config", "user.email", "tests@mercury.invalid")
    try await repo.git("config", "commit.gpgsign", "false")
    return try await body()
}
