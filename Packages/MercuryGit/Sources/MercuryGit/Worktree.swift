import Foundation

/// One entry of `git worktree list`.
public struct Worktree: Hashable, Sendable {
    public var path: URL
    public var head: String?
    /// Short branch name (`main`, not `refs/heads/main`); nil when detached or bare.
    public var branch: String?
    public var isMain: Bool
    public var isDetached: Bool
    public var isLocked: Bool
    public var isPrunable: Bool

    public init(path: URL, head: String? = nil, branch: String? = nil, isMain: Bool = false,
                isDetached: Bool = false, isLocked: Bool = false, isPrunable: Bool = false) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isMain = isMain
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

/// Worktree and branch operations on one repository.
public struct WorktreeService: Sendable {
    public var repository: URL
    public var runner: GitRunner

    public init(repository: URL, runner: GitRunner = .init()) {
        self.repository = repository
        self.runner = runner
    }

    public func list() async throws -> [Worktree] {
        Self.parseWorktreeList(try await runner.run(["worktree", "list", "--porcelain", "-z"], in: repository))
    }

    /// Creates `branch` from `base` and checks it out in a new worktree at `path`. Throws `GitError` for an
    /// invalid branch name (see `validateBranchName`) or an unknown base.
    public func add(branch: String, at path: URL, base: String) async throws {
        guard await validateBranchName(branch) else {
            throw GitError(args: ["check-ref-format", "--branch", branch], exitCode: 1,
                           stderr: "'\(branch)' is not a valid branch name")
        }
        // `--end-of-options` keeps a base such as `--no-checkout` a revision instead of a flag.
        _ = try await runner.run(["worktree", "add", "-b", branch, "--end-of-options", path.path, base], in: repository)
    }

    /// Removes the worktree at `path`; `force` discards its uncommitted changes.
    public func remove(at path: URL, force: Bool) async throws {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args += ["--end-of-options", path.path]
        _ = try await runner.run(args, in: repository)
    }

    public func prune() async throws {
        _ = try await runner.run(["worktree", "prune"], in: repository)
    }

    /// True when the checkout at `path` has staged, unstaged or untracked (non-ignored) changes.
    public func hasUncommittedChanges(at path: URL) async throws -> Bool {
        !(try await runner.run(["status", "--porcelain", "-z"], in: path)).isEmpty
    }

    /// `<repo>/../<repo>-worktrees/<branch>`.
    public static func defaultPath(repository: URL, branch: String) -> URL {
        repository.deletingLastPathComponent()
            .appendingPathComponent("\(repository.lastPathComponent)-worktrees", isDirectory: true)
            .appendingPathComponent(branch, isDirectory: true)
    }

    /// Parses `git worktree list --porcelain -z`: NUL-terminated attribute lines, an empty field between entries.
    static func parseWorktreeList(_ data: Data) -> [Worktree] {
        var result: [Worktree] = []
        var current: Worktree?
        for field in data.split(separator: 0, omittingEmptySubsequences: false) {
            let line = String(decoding: field, as: UTF8.self)
            if line.isEmpty {
                if let entry = current { result.append(entry) }
                current = nil
                continue
            }
            let (key, value) = splitAttribute(line)
            if key == "worktree" {
                if let entry = current { result.append(entry) }
                current = Worktree(path: URL(fileURLWithPath: value, isDirectory: true), isMain: result.isEmpty)
                continue
            }
            guard current != nil else { continue }
            switch key {
            case "HEAD": current?.head = value
            case "branch":
                let prefix = "refs/heads/"
                current?.branch = value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
            case "detached": current?.isDetached = true
            case "locked": current?.isLocked = true
            case "prunable": current?.isPrunable = true
            default: break
            }
        }
        if let entry = current { result.append(entry) }
        return result
    }

    private static func splitAttribute(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[..<space]), String(line[line.index(after: space)...]))
    }
}
