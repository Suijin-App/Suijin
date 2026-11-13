import Foundation

extension SourceControlService {
    /// Stages `paths` (relative to the toplevel) as they are in the working tree: new, modified and deleted files.
    public func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await withPathspecFile(paths) { file in
            _ = try await runner.run(["--literal-pathspecs", "add", "--all", "--pathspec-from-file=\(file.path)", "--pathspec-file-nul"],
                                     in: worktree)
        }
    }

    /// Takes `paths` out of the index again, keeping the working tree. A staged rename needs its source path too, so
    /// pass `StatusEntry.originalPath` along. Before the first commit the paths are removed from the index instead.
    public func unstage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let hasHead = try await runner.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: worktree, allowedExitCodes: [0, 1]).exitCode == 0
        try await withPathspecFile(paths) { file in
            let spec = ["--pathspec-from-file=\(file.path)", "--pathspec-file-nul"]
            if hasHead {
                _ = try await runner.run(["--literal-pathspecs", "restore", "--staged"] + spec, in: worktree)
            } else {
                _ = try await runner.run(["--literal-pathspecs", "rm", "--cached", "-r", "--quiet", "--ignore-unmatch"] + spec,
                                         in: worktree)
            }
        }
    }

    /// Paths go through a NUL-separated file, so any number of paths with any characters (a leading `-`, newlines,
    /// glob characters under `--literal-pathspecs`) is passed safely.
    private func withPathspecFile(_ paths: [String], _ body: (URL) async throws -> Void) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-pathspec-\(UUID().uuidString)")
        var data = Data()
        for path in paths {
            data.append(contentsOf: Array(path.utf8))
            data.append(0)
        }
        try data.write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        try await body(file)
    }
}
