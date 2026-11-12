import Foundation

/// One side of a porcelain v2 status code (`X` for the index, `Y` for the working tree).
public enum StatusCode: Character, Hashable, Sendable {
    case unmodified = "."
    case modified = "M"
    case typeChanged = "T"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case updatedButUnmerged = "U"
    case untracked = "?"
    case ignored = "!"
}

/// A path reported by `git status`, relative to the repository toplevel.
public struct StatusEntry: Hashable, Sendable, Identifiable {
    public var path: String
    /// The source path of a staged rename or copy.
    public var originalPath: String?
    public var index: StatusCode
    public var worktree: StatusCode
    /// An unmerged path (`u` record): both sides changed it and the conflict is not resolved yet.
    public var isConflicted: Bool

    public var id: String { path }

    public init(path: String, originalPath: String? = nil, index: StatusCode, worktree: StatusCode, isConflicted: Bool = false) {
        self.path = path
        self.originalPath = originalPath
        self.index = index
        self.worktree = worktree
        self.isConflicted = isConflicted
    }

    public var isUntracked: Bool { index == .untracked }
    /// The index differs from HEAD for this path.
    public var hasStagedChange: Bool { !isConflicted && !isUntracked && index != .unmodified }
    /// The working tree differs from the index for this path (untracked files included).
    public var hasUnstagedChange: Bool { isConflicted || isUntracked || worktree != .unmodified }
}

/// Branch facts and changed paths of one checkout.
public struct RepositoryStatus: Hashable, Sendable {
    /// The checked-out branch; nil when HEAD is detached.
    public var branch: String?
    /// The commit HEAD points at; nil before the first commit.
    public var headOID: String?
    /// The upstream branch, e.g. `origin/main`; nil when none is configured.
    public var upstream: String?
    /// Commits on HEAD not on the upstream, and the reverse. Zero without an upstream.
    public var ahead: Int
    public var behind: Int
    public var entries: [StatusEntry]

    public init(branch: String? = nil, headOID: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0,
                entries: [StatusEntry] = []) {
        self.branch = branch
        self.headOID = headOID
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.entries = entries
    }

    public var staged: [StatusEntry] { entries.filter(\.hasStagedChange) }
    public var unstaged: [StatusEntry] { entries.filter(\.hasUnstagedChange) }
    public var conflicted: [StatusEntry] { entries.filter(\.isConflicted) }
    public var hasCommits: Bool { headOID != nil }
}

/// Status, staging, commits and pushes of one checkout. `worktree` is the checkout root.
public struct SourceControlService: Sendable {
    public var worktree: URL
    public var runner: GitRunner

    public init(worktree: URL, runner: GitRunner = .init()) {
        self.worktree = worktree
        self.runner = runner
    }

    /// `git status --porcelain=v2 -z --branch`, with every untracked file listed (not just its directory).
    public func status() async throws -> RepositoryStatus {
        let data = try await runner.run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"], in: worktree)
        return Self.parseStatus(data)
    }

    /// Parses `git status --porcelain=v2 -z --branch`. Records are NUL-terminated; a rename or copy (`2`) is followed
    /// by one more field holding its source path.
    static func parseStatus(_ data: Data) -> RepositoryStatus {
        var status = RepositoryStatus()
        var fields = data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }[...]
        while let record = fields.popFirst() {
            guard let kind = record.first else { continue }
            switch kind {
            case "#":
                parseHeader(record, into: &status)
            case "1":
                // 1 XY sub mH mI mW hH hI path
                let parts = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9, let codes = statusCodes(parts[1]) else { continue }
                status.entries.append(StatusEntry(path: String(parts[8]), index: codes.0, worktree: codes.1))
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore path NUL origPath
                let parts = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                let original = fields.popFirst()
                guard parts.count == 10, let codes = statusCodes(parts[1]) else { continue }
                status.entries.append(StatusEntry(path: String(parts[9]), originalPath: original, index: codes.0, worktree: codes.1))
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let parts = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11, let codes = statusCodes(parts[1]) else { continue }
                status.entries.append(StatusEntry(path: String(parts[10]), index: codes.0, worktree: codes.1, isConflicted: true))
            case "?":
                guard record.count > 2 else { continue }
                status.entries.append(StatusEntry(path: String(record.dropFirst(2)), index: .untracked, worktree: .untracked))
            default:
                continue // `!` (ignored) is not requested; unknown record kinds from newer git are skipped.
            }
        }
        status.entries.sort { $0.path < $1.path }
        return status
    }

    private static func parseHeader(_ record: String, into status: inout RepositoryStatus) {
        let parts = record.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return }
        let value = String(parts[2])
        switch parts[1] {
        case "branch.oid": status.headOID = value == "(initial)" ? nil : value
        case "branch.head": status.branch = value == "(detached)" ? nil : value
        case "branch.upstream": status.upstream = value
        case "branch.ab":
            for token in value.split(separator: " ") {
                if token.hasPrefix("+") { status.ahead = Int(token.dropFirst()) ?? 0 }
                if token.hasPrefix("-") { status.behind = Int(token.dropFirst()) ?? 0 }
            }
        default: break
        }
    }

    private static func statusCodes(_ field: Substring) -> (StatusCode, StatusCode)? {
        guard field.count == 2, let index = StatusCode(rawValue: field.first!), let tree = StatusCode(rawValue: field.last!) else {
            return nil
        }
        return (index, tree)
    }

    // MARK: Remotes and history

    /// Configured remote names, in git's order.
    public func remotes() async throws -> [String] {
        try await runner.text(["remote"], in: worktree).split(separator: "\n").map(String.init)
    }

    /// The fetch URL of `remote`; nil when the remote does not exist.
    public func remoteURL(_ remote: String) async throws -> String? {
        let result = try await runner.run(["remote", "get-url", "--end-of-options", remote], in: worktree, allowedExitCodes: [0, 2, 128])
        let url = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.exitCode == 0 && !url.isEmpty ? url : nil
    }

    /// The remote a push without upstream goes to: `origin`, else the only remote, else nil.
    public func pushRemote() async throws -> String? {
        let names = try await remotes()
        if names.contains("origin") { return "origin" }
        return names.count == 1 ? names[0] : nil
    }

    /// True when `revision` names a commit (`git rev-parse --verify --quiet <revision>^{commit}`).
    public func revisionExists(_ revision: String) async -> Bool {
        guard !revision.isEmpty, !revision.hasPrefix("-") else { return false }
        let result = try? await runner.run(["rev-parse", "--verify", "--quiet", "--end-of-options", revision + "^{commit}"],
                                           in: worktree, allowedExitCodes: [0, 1, 128])
        return result?.exitCode == 0
    }

    /// Subjects of the latest commits on HEAD, newest first; empty before the first commit.
    public func recentCommitSubjects(limit: Int = 10) async throws -> [String] {
        let result = try await runner.run(["log", "-n", String(max(limit, 0)), "--no-color", "--format=%s"], in: worktree,
                                          allowedExitCodes: [0, 128])
        guard result.exitCode == 0 else { return [] }
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// The staged changes as a unified diff (`git diff --cached`), with user config that changes the format overridden.
    public func stagedDiff() async throws -> String {
        try await runner.text(["diff", "--cached", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", "-M"],
                              in: worktree)
    }

    /// Subjects and bodies of commits on HEAD that `base` does not have, oldest first (`git log base..HEAD`).
    public func commitMessages(since base: String, limit: Int = 50) async throws -> [String] {
        let data = try await runner.run(["log", "--reverse", "-n", String(max(limit, 0)), "--no-color", "--format=%B%x00",
                                         "--end-of-options", "\(base)..HEAD"], in: worktree)
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The diff of HEAD against its merge base with `base` (what a pull request into `base` shows).
    public func diff(since base: String) async throws -> String {
        try await runner.text(["diff", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", "-M",
                               "--end-of-options", "\(base)...HEAD"], in: worktree)
    }
}
