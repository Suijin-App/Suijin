import Foundation

/// A commit made by `SourceControlService.commit(message:)`.
public struct CommitResult: Hashable, Sendable {
    public var oid: String
    public var summary: String
}

extension SourceControlService {
    /// Every exit status (a signal number for a killed git), so failures can be reported with git's full output.
    static let anyExitCode = Set<Int32>(0...255)

    /// Commits the index with `message` (`git commit -F <file>`). Hooks run as usual; when one fails, or git refuses
    /// (nothing staged, no identity), the thrown `GitError.stderr` holds git's whole output, stdout included, because
    /// hooks such as pre-commit write their report to either stream.
    public func commit(message: String) async throws -> CommitResult {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitError(args: ["commit"], exitCode: 1, stderr: "The commit message is empty.")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-commit-\(UUID().uuidString).txt")
        try Data((trimmed + "\n").utf8).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        defer { try? FileManager.default.removeItem(at: file) }

        let args = ["commit", "--file", file.path]
        try await runReportingOutput(args)
        let line = try await runner.text(["log", "-n", "1", "--no-color", "--format=%H%x00%s"], in: worktree)
        let parts = line.trimmingCharacters(in: .newlines).split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
        return CommitResult(oid: parts.first.map(String.init) ?? "", summary: parts.count > 1 ? String(parts[1]) : "")
    }

    /// Runs `args`; a non-zero exit throws `GitError` whose `stderr` is stdout and stderr joined.
    @discardableResult
    func runReportingOutput(_ args: [String]) async throws -> GitResult {
        let result = try await runner.run(args, in: worktree, allowedExitCodes: Self.anyExitCode)
        guard result.exitCode == 0 else {
            throw GitError(args: args, exitCode: result.exitCode, stderr: Self.joinedOutput(result))
        }
        return result
    }

    static func joinedOutput(_ result: GitResult) -> String {
        let out = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        let err = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .newlines)
        return [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
