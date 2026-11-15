import Foundation
import SuijinCore
import SuijinGit
import Testing
@testable import Suijin

/// Data for measuring UI responsiveness with the real app: `TEST_RUNNER_SUIJIN_PERF_SEED_ROOT=<dir> xcodebuild test
/// -only-testing:SuijinAppTests/PerfSeedTests`, then launch Suijin with `SUIJIN_DATA_ROOT=<dir>/data` and
/// `SUIJIN_PERF_OUT=<file>` (see `PerfProbe`). A git workspace of a few hundred source files with three worktrees and a
/// folder workspace, and fourteen shells left running in the PTY host (no agents, so nothing reaches an account).
/// `TEST_RUNNER_SUIJIN_PERF_CLEANUP_ROOT=<dir>` ends the shells of such a data root again.
@MainActor
@Suite(.endsHostedSessions, .serialized)
struct PerfSeedTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUIJIN_PERF_SEED_ROOT"] != nil))
    func seed() async throws {
        let base = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SUIJIN_PERF_SEED_ROOT"]), isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        let repo = base.appendingPathComponent("suijin-api", isDirectory: true)
        let folder = base.appendingPathComponent("design-notes", isDirectory: true)
        for dir in [repo, folder] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Self.writeSourceTree(in: repo)
        try "notes\n".write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let git = GitRunner()
        let identity = ["-c", "user.name=Suijin Perf", "-c", "user.email=perf@example.invalid"]
        _ = try await git.run(["init", "-b", "main"], in: repo)
        _ = try await git.run(["add", "."], in: repo)
        _ = try await git.run(identity + ["commit", "-m", "initial"], in: repo)

        let dataRoot = base.appendingPathComponent("data", isDirectory: true)
        let model = AppModel(store: try SuijinStore(url: SuijinPaths.database(in: dataRoot)), dataRoot: dataRoot)
        await model.addWorkspace(at: repo)
        await model.addWorkspace(at: folder)
        let gitID = try #require(model.workspaces.first).id
        var trees: [WorktreeRecord] = []
        for branch in ["feature/usage-bar", "fix/login-timeout", "chore/cleanup"] {
            trees.append(try await model.createWorktree(workspaceID: gitID, branch: branch, base: "main",
                                                        path: WorktreeService.defaultPath(repository: repo, branch: branch)))
        }
        // Some uncommitted changes, so source control has something to list.
        for tree in trees {
            try "changed\n".write(to: URL(fileURLWithPath: tree.path).appendingPathComponent("CHANGED.md"), atomically: true, encoding: .utf8)
        }

        await model.runtimes.bootstrap()
        let plan: [(SessionContext, Int)] = [
            (.workspace(gitID), 2), (.worktree(trees[0].id), 3), (.worktree(trees[1].id), 8), (.workspace(model.workspaces[1].id), 1),
        ]
        for (context, count) in plan {
            for _ in 0..<count {
                let id = try #require(await model.runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil))
                // Scrollback and a full screen, as a terminal that has been used.
                model.runtimes.runtime(for: id)?.terminal.send("seq 1 3000; ls -la\n")
            }
        }
        model.selection = .worktree(trees[1].id)
        try await Task.sleep(for: .seconds(3))
        await model.runtimes.prepareForQuit()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUIJIN_PERF_CLEANUP_ROOT"] != nil))
    func cleanup() async throws {
        let base = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SUIJIN_PERF_CLEANUP_ROOT"]), isDirectory: true)
        let dataRoot = base.appendingPathComponent("data", isDirectory: true)
        let model = AppModel(store: try SuijinStore(url: SuijinPaths.database(in: dataRoot)), dataRoot: dataRoot)
        await model.loadSettings()
        await model.load()
        await model.runtimes.bootstrap()
        model.setSetting(.keepSessionsOnQuit, "false")
        await model.runtimes.prepareForQuit()
    }

    /// About 400 files in nested folders, the shape of a mid-sized app repository.
    static func writeSourceTree(in root: URL) throws {
        let modules = ["App", "Core", "Networking", "Storage", "UI", "Features", "Tests", "Scripts"]
        let folders = ["Models", "Views", "Services", "Support", "Resources"]
        for module in modules {
            for folder in folders {
                let dir = root.appendingPathComponent("Sources/\(module)/\(folder)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for index in 0..<10 {
                    let text = (0..<40).map { "// \(module).\(folder) line \($0)" }.joined(separator: "\n")
                    try text.write(to: dir.appendingPathComponent("\(module)\(folder)\(index).swift"), atomically: true, encoding: .utf8)
                }
            }
        }
        try "# suijin-api\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "{}\n".write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    }
}
