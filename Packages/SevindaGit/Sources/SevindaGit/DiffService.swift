import Foundation

/// Changed files and per-file diffs of one checkout. `worktree` is the checkout root; paths are relative to it.
public struct DiffService: Sendable {
    public var worktree: URL
    public var runner: GitRunner

    public init(worktree: URL, runner: GitRunner = .init()) {
        self.worktree = worktree
        self.runner = runner
    }

    /// Options that override user config which would change the output format (prefixes, external diff tools,
    /// colors), and enable rename detection.
    private static let formatOptions = ["--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", "-M"]

    /// Files changed in `scope`, tracked and untracked, sorted by path.
    public func changedFiles(_ scope: DiffScope) async throws -> [ChangedFile] {
        let base = try await baseRevision(scope)
        if let tip = Self.tip(of: scope) {
            let committed = try await runner.run(["diff", "--name-status", "-z", "--no-color", "-M", "--end-of-options", base, tip, "--"],
                                                 in: worktree)
            return Self.parseNameStatus(committed).sorted { $0.path < $1.path }
        }
        let tracked = try await runner.run(["diff", "--name-status", "-z", "--no-color", "-M", "--end-of-options", base, "--"], in: worktree)
        var files = Self.parseNameStatus(tracked)
        files += try await untrackedFiles().map { ChangedFile(path: $0, kind: .added) }
        return files.sorted { $0.path < $1.path }
    }

    /// The commits on HEAD that `branch` does not have, newest first; empty when `branch` cannot be resolved.
    public func commits(notOn branch: String, limit: Int = 200) async -> [CommitSummary] {
        let format = "%H%x1f%h%x1f%s%x1f%an%x1f%at%x1e"
        guard let output = try? await runner.text(["log", "--no-color", "--max-count=\(limit)", "--format=\(format)",
                                                   "--end-of-options", "\(branch)..HEAD", "--"], in: worktree) else { return [] }
        return output.split(separator: "\u{1e}").compactMap { record in
            let fields = record.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, let seconds = TimeInterval(fields[4]) else { return nil }
            return CommitSummary(sha: fields[0], shortSHA: fields[1], subject: fields[2], author: fields[3],
                                 date: Date(timeIntervalSince1970: seconds))
        }
    }

    /// Commits on HEAD that `branch` does not have (`branch..HEAD`); nil when either cannot be resolved.
    public func commitsAhead(of branch: String) async -> Int? {
        guard let output = try? await runner.text(["rev-list", "--count", "--end-of-options", "\(branch)..HEAD"], in: worktree) else { return nil }
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The diff of one file in `scope` (3 lines of context). A file without changes yields a diff with no hunks.
    public func diff(for path: String, scope: DiffScope) async throws -> FileDiff {
        let unchanged = FileDiff(oldPath: path, newPath: path)
        guard let change = try await changedFiles(scope).first(where: { $0.path == path }) else { return unchanged }

        let output: Data
        if let tip = Self.tip(of: scope) {
            var pathspecs = [Self.literal(path)]
            switch change.kind {
            case .renamed(let from), .copied(let from): pathspecs.insert(Self.literal(from), at: 0)
            default: break
            }
            let base = try await baseRevision(scope)
            output = try await runner.run(["diff", "--unified=3"] + Self.formatOptions + ["--end-of-options", base, tip, "--"] + pathspecs,
                                          in: worktree)
        } else if case .added = change.kind, try await isUntracked(path) {
            // Exit code 1 means "differences found" for --no-index.
            output = try await runner.run(["diff", "--no-index", "--unified=3"] + Self.formatOptions + ["--", "/dev/null", path],
                                          in: worktree, allowedExitCodes: [0, 1]).stdout
        } else {
            var pathspecs = [Self.literal(path)]
            switch change.kind {
            case .renamed(let from), .copied(let from): pathspecs.insert(Self.literal(from), at: 0)
            default: break
            }
            let base = try await baseRevision(scope)
            output = try await runner.run(["diff", "--unified=3"] + Self.formatOptions + ["--end-of-options", base, "--"] + pathspecs, in: worktree)
        }
        let diffs = DiffParser.parse(String(decoding: output, as: UTF8.self))
        return diffs.first(where: { $0.newPath == path }) ?? diffs.first ?? unchanged
    }

    // MARK: Helpers

    /// The commit a committed-only scope ends at; nil for scopes that compare with the working tree.
    private static func tip(of scope: DiffScope) -> String? {
        switch scope {
        case .committed: "HEAD"
        case .commit(let sha): sha
        case .againstBase, .uncommitted: nil
        }
    }

    /// The revision the working tree is compared with: the merge base for `.againstBase`, HEAD for
    /// `.uncommitted` (the empty tree before the first commit).
    private func baseRevision(_ scope: DiffScope) async throws -> String {
        switch scope {
        case .againstBase(let branch), .committed(let branch):
            return try await runner.text(["merge-base", "--end-of-options", branch, "HEAD"], in: worktree).trimmingCharacters(in: .whitespacesAndNewlines)
        case .commit(let sha):
            let parent = try await runner.run(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(sha)^"], in: worktree,
                                              allowedExitCodes: [0, 1])
            if parent.exitCode == 0 { return String(decoding: parent.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            return try await runner.text(["hash-object", "-t", "tree", "/dev/null"], in: worktree)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .uncommitted:
            let head = try await runner.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: worktree, allowedExitCodes: [0, 1])
            if head.exitCode == 0 { return "HEAD" }
            return try await runner.text(["hash-object", "-t", "tree", "/dev/null"], in: worktree)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func untrackedFiles(_ pathspecs: [String] = []) async throws -> [String] {
        let data = try await runner.run(["ls-files", "--others", "--exclude-standard", "--full-name", "-z", "--"] + pathspecs,
                                        in: worktree)
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    private func isUntracked(_ path: String) async throws -> Bool {
        try await untrackedFiles([Self.literal(path)]).contains(path)
    }

    /// A pathspec that matches exactly `path` from the toplevel, with no glob interpretation.
    private static func literal(_ path: String) -> String { ":(top,literal)" + path }

    /// Parses `git diff --name-status -z`: `status NUL path NUL`, or `status NUL old NUL new NUL` for renames and copies.
    static func parseNameStatus(_ data: Data) -> [ChangedFile] {
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }[...]
        var result: [ChangedFile] = []
        while let status = fields.popFirst(), !status.isEmpty {
            guard let path = fields.popFirst() else { break }
            switch status.first {
            case "R", "C":
                guard let newPath = fields.popFirst() else { return result }
                result.append(ChangedFile(path: newPath, kind: status.first == "R" ? .renamed(from: path) : .copied(from: path)))
            case "A": result.append(ChangedFile(path: path, kind: .added))
            case "D": result.append(ChangedFile(path: path, kind: .deleted))
            case "T": result.append(ChangedFile(path: path, kind: .typeChanged))
            case "U": result.append(ChangedFile(path: path, kind: .unmerged))
            default: result.append(ChangedFile(path: path, kind: .modified))
            }
        }
        return result
    }
}
