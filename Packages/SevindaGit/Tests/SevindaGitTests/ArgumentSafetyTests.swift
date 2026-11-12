import Foundation
import Testing
@testable import SevindaGit

@Suite struct ArgumentSafetyTests {
    @Test func environmentDropsRepositoryOverrides() {
        let inherited = [
            "PATH": "/usr/bin", "HOME": "/Users/x",
            "GIT_DIR": "/elsewhere/.git", "GIT_WORK_TREE": "/elsewhere", "GIT_INDEX_FILE": "/elsewhere/index",
            "GIT_COMMON_DIR": "/elsewhere/.git", "GIT_OBJECT_DIRECTORY": "/elsewhere/objects",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES": "/a", "GIT_CEILING_DIRECTORIES": "/", "GIT_DISCOVERY_ACROSS_FILESYSTEM": "1",
            "GIT_NAMESPACE": "ns", "GIT_CONFIG_PARAMETERS": "'core.bare'='true'", "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "core.bare", "GIT_CONFIG_VALUE_0": "true", "GIT_PREFIX": "sub/",
            "GIT_SSH_COMMAND": "ssh -i key", "GIT_TERMINAL_PROMPT": "1",
        ]
        let env = GitRunner.environment(inheriting: inherited)
        #expect(env == [
            "PATH": "/usr/bin", "HOME": "/Users/x", "GIT_SSH_COMMAND": "ssh -i key",
            "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_PAGER": "cat",
        ])
    }

    @Test func validatesBranchNames() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        let service = WorktreeService(repository: repo.url)
        for valid in ["feature/one", "fix-42", "agent/claude.1"] {
            #expect(await service.validateBranchName(valid), "\(valid)")
        }
        for invalid in ["", "-x", "--detach", "a..b", "a b", "a~1", "end.lock", "trailing/", "@", "@{-1}", "HEAD"] {
            #expect(await service.validateBranchName(invalid) == false, "\(invalid)")
        }
    }

    @Test func addRejectsOptionLikeBranchAndBase() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        let service = WorktreeService(repository: repo.url)
        await #expect(throws: GitError.self) {
            try await service.add(branch: "-f", at: repo.root.appendingPathComponent("a"), base: "main")
        }
        // Without an end-of-options marker git would take this as the `--no-checkout` flag and succeed.
        await #expect(throws: GitError.self) {
            try await service.add(branch: "ok", at: repo.root.appendingPathComponent("b"), base: "--no-checkout")
        }
        #expect(try await service.list().count == 1)
        #expect(try await service.localBranches() == ["main"])
    }

    @Test func optionLikeBaseIsNotAnOption() async throws {
        let repo = try await TestRepo()
        defer { repo.cleanUp() }
        // `git merge-base --fork-point HEAD` succeeds, so this only throws when the value is kept a revision.
        await #expect(throws: GitError.self) {
            _ = try await DiffService(worktree: repo.url).changedFiles(.againstBase("--fork-point"))
        }
    }
}
