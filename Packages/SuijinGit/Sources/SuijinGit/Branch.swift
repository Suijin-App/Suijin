import Foundation

extension WorktreeService {
    /// True when `name` is acceptable as a new branch name (`git check-ref-format --branch`). Also rejects names
    /// starting with `-` (git would read them as options), `HEAD` and `@` (both name HEAD in revisions), and
    /// shorthands such as `@{-1}` that git expands to another branch (its output then differs from the input).
    public func validateBranchName(_ name: String) async -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), name != "HEAD", name != "@" else { return false }
        guard let result = try? await runner.run(["check-ref-format", "--branch", name], in: repository,
                                                 allowedExitCodes: [0, 1, 128]),
              result.exitCode == 0 else { return false }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines) == name
    }

    /// Local branch names, short form.
    public func localBranches() async throws -> [String] {
        try await runner.text(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: repository)
            .split(separator: "\n").map(String.init)
    }

    /// The checked-out branch of the repository's main checkout; nil when HEAD is detached.
    public func currentBranch() async throws -> String? {
        let result = try await runner.run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: repository,
                                          allowedExitCodes: [0, 1])
        let name = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        return result.exitCode == 0 && !name.isEmpty ? name : nil
    }

    /// The branch new worktrees start from: `origin/HEAD`'s target, else `main`/`master`, else the current
    /// branch, else `HEAD`.
    public func defaultBaseBranch() async throws -> String {
        let remoteHead = try await runner.run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
                                              in: repository, allowedExitCodes: [0, 1, 128])
        let remote = String(decoding: remoteHead.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        if remoteHead.exitCode == 0, !remote.isEmpty { return remote }

        for candidate in ["main", "master"] {
            let check = try await runner.run(["show-ref", "--verify", "--quiet", "refs/heads/\(candidate)"],
                                             in: repository, allowedExitCodes: [0, 1])
            if check.exitCode == 0 { return candidate }
        }
        return try await currentBranch() ?? "HEAD"
    }
}
