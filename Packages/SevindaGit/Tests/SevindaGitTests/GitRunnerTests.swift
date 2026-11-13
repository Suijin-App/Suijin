import Foundation
import Testing
@testable import SevindaGit

@Suite struct GitRunnerTests {
    @Test func failingCommandThrowsGitError() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        do {
            _ = try await repo.runner.run(["rev-parse", "--verify", "no-such-ref"], in: repo.url)
            Issue.record("expected an error")
        } catch let error as GitError {
            #expect(error.exitCode == 128)
            #expect(error.args == ["rev-parse", "--verify", "no-such-ref"])
            #expect(!error.stderr.isEmpty)
            #expect(error.errorDescription?.contains("git rev-parse") == true)
        }
    }

    @Test func largeOutputOnBothPipesDoesNotDeadlock() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        // About 2 MB of stdout, well past the 64 KB pipe buffer.
        let line = String(repeating: "x", count: 99) + "\n"
        try repo.write("big.txt", String(repeating: line, count: 20_000))
        let data = try await repo.runner.run(["diff", "--no-index", "--", "/dev/null", "big.txt"], in: repo.url,
                                             allowedExitCodes: [1]).stdout
        #expect(data.count > 2_000_000)
    }

    /// A command refused because another git holds the index lock runs again once the lock is gone.
    @Test func aHeldIndexLockIsWaitedFor() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "a\n")
        let lock = repo.url.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        Task.detached {
            try? await Task.sleep(for: .milliseconds(500))
            try? FileManager.default.removeItem(at: lock)
        }
        _ = try await repo.runner.run(["add", "a.txt"], in: repo.url)
        #expect(try await repo.git("diff", "--cached", "--name-only").contains("a.txt"))
    }

    @Test func aLockThatStaysIsReported() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "a\n")
        try Data().write(to: repo.url.appendingPathComponent(".git/index.lock"))
        let error = await #expect(throws: GitError.self) { _ = try await repo.runner.run(["add", "a.txt"], in: repo.url) }
        #expect(error?.stderr.contains("index.lock") == true)
    }

    @Test func environmentIsMachineReadable() {
        let env = GitRunner.environment()
        #expect(env["LC_ALL"] == "C")
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
    }

    @Test func missingExecutableThrows() async {
        let runner = GitRunner(executable: URL(fileURLWithPath: "/nonexistent/git"))
        await #expect(throws: (any Error).self) {
            _ = try await runner.run(["status"], in: FileManager.default.temporaryDirectory)
        }
    }

    @Test func toplevelOfRepositoryAndSubdirectory() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        let sub = repo.url.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(await GitRepository.toplevel(of: repo.url)?.path == repo.url.path)
        #expect(await GitRepository.toplevel(of: sub)?.path == repo.url.path)
    }

    @Test func toplevelOfPlainFolderIsNil() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sevinda-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(await GitRepository.toplevel(of: folder) == nil)
        #expect(await GitRepository.toplevel(of: folder.appendingPathComponent("missing")) == nil)
    }
}
