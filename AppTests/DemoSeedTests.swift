import Foundation
import SuijinCore
import SuijinGit
import Testing
@testable import Suijin

/// Builds a demo data root for looking at the real app: `TEST_RUNNER_SUIJIN_SEED_ROOT=<dir> xcodebuild test
/// -only-testing:SuijinAppTests/DemoSeedTests`, then launch Suijin with `SUIJIN_DATA_ROOT=<dir>/data`. It holds a
/// git workspace with two worktrees, a folder workspace, and shell sessions left running in the PTY host, so the app
/// attaches to them on launch.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SUIJIN_SEED_ROOT"] != nil))
struct DemoSeedTests {
    @Test func seed() async throws {
        let base = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SUIJIN_SEED_ROOT"]), isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        let repo = base.appendingPathComponent("suijin-api", isDirectory: true)
        let folder = base.appendingPathComponent("design-notes", isDirectory: true)
        for dir in [repo, folder] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let git = GitRunner()
        let identity = ["-c", "user.name=Suijin Demo", "-c", "user.email=demo@example.invalid"]
        _ = try await git.run(["init", "-b", "main"], in: repo)
        try "import Foundation\n\nstruct UsageBar {\n    var fraction: Double\n}\n".write(to: repo.appendingPathComponent("UsageBar.swift"), atomically: true, encoding: .utf8)
        try "# suijin-api\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "."], in: repo)
        _ = try await git.run(identity + ["commit", "-m", "initial"], in: repo)
        try "notes\n".write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        let dataRoot = base.appendingPathComponent("data", isDirectory: true)
        let model = AppModel(store: try SuijinStore(url: SuijinPaths.database(in: dataRoot)), dataRoot: dataRoot)
        await model.addWorkspace(at: repo)
        await model.addWorkspace(at: folder)
        let gitID = try #require(model.workspaces.first).id
        await model.setAppearance(of: gitID, icon: .symbol("server.rack"), color: nil)
        let first = try await model.createWorktree(workspaceID: gitID, branch: "feature/usage-bar", base: "main",
                                                   path: WorktreeService.defaultPath(repository: repo, branch: "feature/usage-bar"))
        let second = try await model.createWorktree(workspaceID: gitID, branch: "fix/login-timeout", base: "main",
                                           path: WorktreeService.defaultPath(repository: repo, branch: "fix/login-timeout"))
        // A change in the first worktree for the Changes tab.
        try "import Foundation\n\n/// The usage of an account window.\nstruct UsageBar {\n    var fraction: Double\n    var resetsAt: Date?\n}\n"
            .write(to: URL(fileURLWithPath: first.path).appendingPathComponent("UsageBar.swift"), atomically: true, encoding: .utf8)

        await model.runtimes.bootstrap()
        let shell = try #require(await model.runtimes.start(in: .worktree(first.id), agent: .shell, accountID: nil, prompt: nil))
        model.runtimes.runtime(for: shell)?.terminal.send("git status --short && ls -la\n")
        _ = await model.runtimes.start(in: .workspace(model.workspaces[1].id), agent: .shell, accountID: nil, prompt: nil)
        // Enough tabs in one worktree to overflow the title-bar tab group.
        for _ in 0..<9 { _ = await model.runtimes.start(in: .worktree(second.id), agent: .shell, accountID: nil, prompt: nil) }
        _ = await model.runtimes.start(in: .worktree(first.id), agent: .claude, accountID: nil, prompt: nil)
        _ = await model.runtimes.start(in: .worktree(first.id), agent: .codex, accountID: nil, prompt: nil)
        try await Task.sleep(for: .seconds(4))
        await model.runtimes.prepareForQuit()
    }
}
