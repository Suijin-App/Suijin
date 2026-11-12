import Foundation

/// What `SourceControlService.push()` did.
public struct PushResult: Hashable, Sendable {
    /// The remote pushed to; nil when git chose it from the branch's upstream configuration.
    public var remote: String?
    /// True when the push also configured the upstream (`--set-upstream`).
    public var setUpstream: Bool
    /// Git's progress and summary output.
    public var output: String
}

extension SourceControlService {
    /// Pushes the checked-out branch. A branch with an upstream runs a plain `git push`, so the user's push
    /// configuration applies; a branch without one runs `git push --set-upstream <remote> <branch>` to `origin` (or
    /// the only remote). A rejected push throws `GitError` with git's whole output.
    public func push() async throws -> PushResult {
        let status = try await status()
        guard let branch = status.branch else {
            throw GitError(args: ["push"], exitCode: 1, stderr: "HEAD is detached; check out a branch before pushing.")
        }
        if status.upstream != nil {
            let result = try await runReportingOutput(["push"])
            return PushResult(remote: nil, setUpstream: false, output: Self.joinedOutput(result))
        }
        guard let remote = try await pushRemote() else {
            throw GitError(args: ["push"], exitCode: 1,
                           stderr: "This repository has no remote to push to. Add one with `git remote add origin <url>`.")
        }
        // The full ref keeps a branch named like a remote ref unambiguous.
        let result = try await runReportingOutput(["push", "--set-upstream", "--end-of-options", remote,
                                                   "refs/heads/\(branch):refs/heads/\(branch)"])
        return PushResult(remote: remote, setUpstream: true, output: Self.joinedOutput(result))
    }
}
