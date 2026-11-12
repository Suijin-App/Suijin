import Foundation
import SevindaCore
import SevindaGit
import Testing
@testable import Sevinda

/// Builds a data root for looking at the source control UI in the real app:
/// `TEST_RUNNER_MERCURY_SC_SEED_ROOT=<dir> xcodebuild test -only-testing:SevindaAppTests/SourceControlSeedTests`, then
/// launch Mercury with `MERCURY_DATA_ROOT=<dir>/data` (and, for pull request states, `MERCURY_GH_PATH=<fake gh>`).
///
/// - `mercury-api`: a git workspace whose `origin` is a GitHub URL that is never contacted. Its worktree
///   `feature/usage-bar` is one commit ahead of a seeded upstream and has staged, unstaged and untracked changes;
///   `fix/login-timeout` is unpublished and has a pre-commit hook that always fails, with a staged change.
/// - `local-only`: a git workspace whose remote is a local bare repository (not GitHub).
/// - `design-notes`: a folder workspace (no source control UI).
/// No sessions are started.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MERCURY_SC_SEED_ROOT"] != nil))
struct SourceControlSeedTests {
    private let git = GitRunner()
    private let identity = ["-c", "user.name=Mercury Demo", "-c", "user.email=demo@example.invalid", "-c", "commit.gpgsign=false"]

    @Test func seed() async throws {
        let base = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MERCURY_SC_SEED_ROOT"]), isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        let repo = base.appendingPathComponent("mercury-api", isDirectory: true)
        let localOnly = base.appendingPathComponent("local-only", isDirectory: true)
        let localRemote = base.appendingPathComponent("local-only-remote.git", isDirectory: true)
        let folder = base.appendingPathComponent("design-notes", isDirectory: true)
        for dir in [repo, localOnly, folder] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

        // mercury-api with a GitHub origin and a remote-tracking main.
        try await run(["init", "--quiet", "-b", "main"], in: repo)
        try write("Sources/UsageBar.swift", "import Foundation\n\nstruct UsageBar {\n    var fraction: Double\n}\n", in: repo)
        try write("README.md", "# mercury-api\n", in: repo)
        try await commitAll("chore: initial import", in: repo)
        try await run(["remote", "add", "origin", "https://github.com/acme/mercury-api.git"], in: repo)
        try await run(["update-ref", "refs/remotes/origin/main", "HEAD"], in: repo)
        try await run(["config", "core.hooksPath", repo.appendingPathComponent(".git/hooks").path], in: repo)
        // Fails only on fix/login-timeout, so the other worktree commits normally.
        let hook = repo.appendingPathComponent(".git/hooks/pre-commit")
        try write(".git/hooks/pre-commit", """
        #!/bin/sh
        [ "$(git symbolic-ref --short HEAD)" = "fix/login-timeout" ] || exit 0
        echo "swiftlint: Sources/Login.swift:12:5: error: Force unwrapping should be avoided (force_unwrapping)"
        echo "swiftlint: Sources/Login.swift:18:1: warning: Line should be 120 characters or less (line_length)"
        echo "Done linting! Found 2 violations, 1 serious in 1 file." >&2
        exit 1

        """, in: repo)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        // local-only with a bare remote on disk.
        try await run(["init", "--quiet", "--bare", "-b", "main", localRemote.path], in: base)
        try await run(["init", "--quiet", "-b", "main"], in: localOnly)
        try write("notes.txt", "local\n", in: localOnly)
        try await commitAll("initial", in: localOnly)
        try await run(["remote", "add", "origin", localRemote.path], in: localOnly)
        try await run(["push", "--quiet", "-u", "origin", "main"], in: localOnly)
        try write("notes.txt", "local, edited\n", in: localOnly)

        try write("notes.md", "notes\n", in: folder)

        let dataRoot = base.appendingPathComponent("data", isDirectory: true)
        let model = AppModel(store: try MercuryStore(url: MercuryPaths.database(in: dataRoot)), dataRoot: dataRoot)
        await model.addWorkspace(at: repo)
        await model.addWorkspace(at: localOnly)
        await model.addWorkspace(at: folder)
        let gitID = try #require(model.workspaces.first).id
        await model.setAppearance(of: gitID, icon: .symbol("server.rack"), color: nil)

        let fix = try await model.createWorktree(workspaceID: gitID, branch: "fix/login-timeout", base: "main",
                                                 path: WorktreeService.defaultPath(repository: repo, branch: "fix/login-timeout"))
        let fixDir = URL(fileURLWithPath: fix.path, isDirectory: true)
        try write("Sources/Login.swift", "struct Login {\n    var timeout: Duration = .seconds(30)\n}\n", in: fixDir)
        try await run(["add", "-A"], in: fixDir)

        let feature = try await model.createWorktree(workspaceID: gitID, branch: "feature/usage-bar", base: "main",
                                                     path: WorktreeService.defaultPath(repository: repo, branch: "feature/usage-bar"))
        let featureDir = URL(fileURLWithPath: feature.path, isDirectory: true)
        try write("Sources/UsageBar.swift", "import Foundation\n\nstruct UsageBar {\n    var fraction: Double\n    var label: String\n}\n",
                  in: featureDir)
        try await commitAll("feat: label the usage bar", in: featureDir)
        // The remote has this first commit; the next one is still to push.
        try await run(["update-ref", "refs/remotes/origin/feature/usage-bar", "HEAD"], in: featureDir)
        try await run(["config", "branch.feature/usage-bar.remote", "origin"], in: featureDir)
        try await run(["config", "branch.feature/usage-bar.merge", "refs/heads/feature/usage-bar"], in: featureDir)
        try write("Sources/UsageBar.swift",
                  "import Foundation\n\n/// The usage of an account window.\nstruct UsageBar {\n    var fraction: Double\n    var label: String\n    var resetsAt: Date?\n}\n",
                  in: featureDir)
        try await commitAll("feat: show when the usage window resets", in: featureDir)
        try write("Sources/UsageBar.swift",
                  "import Foundation\n\n/// The usage of an account window, 0...1.\nstruct UsageBar {\n    var fraction: Double\n    var label: String\n    var resetsAt: Date?\n}\n",
                  in: featureDir)
        try write("Sources/UsageFormatter.swift", "import Foundation\n\nenum UsageFormatter {}\n", in: featureDir)
        try await run(["add", "Sources/UsageBar.swift", "Sources/UsageFormatter.swift"], in: featureDir)
        try write("README.md", "# mercury-api\n\nUsage bars for every account.\n", in: featureDir)
        try write("Sources/UsageView.swift", "import SwiftUI\n\nstruct UsageView: View {\n    var body: some View { Text(\"Usage\") }\n}\n",
                  in: featureDir)
        try write("Tests/UsageBarTests.swift", "import Testing\n", in: featureDir)

        model.selection = .worktree(feature.id)
        // Settings are written in the background.
        try await Task.sleep(for: .milliseconds(500))
    }

    private func run(_ args: [String], in dir: URL) async throws {
        _ = try await git.run(identity + args, in: dir)
    }

    private func commitAll(_ message: String, in dir: URL) async throws {
        try await run(["add", "-A"], in: dir)
        try await run(["commit", "--quiet", "--no-verify", "-m", message], in: dir)
    }

    private func write(_ path: String, _ content: String, in dir: URL) throws {
        let file = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
    }
}

/// The source control state against a temporary repository with a bare remote: staging, a commit refused by a hook
/// (its output is reported and the draft kept), a successful commit, publishing the branch, and the pull request
/// state of a non-GitHub remote. Never contacts GitHub.
@MainActor
@Suite struct SourceControlFlowTests {
    @Test func stageCommitHookFailurePushAndRemoteKind() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mercury-sc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = GitRunner()
        _ = try await git.run(["init", "--quiet", "--bare", "-b", "main", remote.path], in: root)
        _ = try await git.run(["init", "--quiet", "-b", "main"], in: repo)
        for (key, value) in [("user.name", "Mercury Tests"), ("user.email", "tests@mercury.invalid"), ("commit.gpgsign", "false"),
                             ("core.hooksPath", repo.appendingPathComponent(".git/hooks").path)] {
            _ = try await git.run(["config", key, value], in: repo)
        }
        _ = try await git.run(["remote", "add", "origin", remote.path], in: repo)
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let model = AppModel(store: try MercuryStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: repo)
        let id = try #require(model.workspaces.first).id
        let state = SourceControlStore.shared(for: model).state(for: .workspace(id))

        await state.refreshStatus()
        let untracked = try #require(state.status?.unstaged.first)
        #expect(untracked.path == "a.txt" && untracked.isUntracked)
        await state.setStaged([untracked], staged: true, from: .inspector)
        #expect(state.status?.staged.map(\.path) == ["a.txt"])

        let hook = repo.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\necho 'hook says no'\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        state.draftMessage = "feat: add a"
        #expect(state.canCommit)
        await state.commit(from: .inspector)
        #expect(state.outputReport(on: .inspector)?.output.contains("hook says no") == true)
        #expect(state.outputReport(on: .toolbar) == nil)
        #expect(state.draftMessage == "feat: add a")
        #expect(state.status?.staged.map(\.path) == ["a.txt"])

        state.outputReport = nil
        try FileManager.default.removeItem(at: hook)
        await state.commit(from: .inspector)
        #expect(state.outputReport == nil)
        #expect(state.draftMessage.isEmpty)
        #expect(state.status?.hasCommits == true && state.status?.upstream == nil)

        await state.push(from: .toolbar)
        #expect(state.outputReport == nil)
        #expect(state.status?.upstream == "origin/main")
        #expect(state.status?.ahead == 0)

        await state.refreshPullRequest()
        #expect(state.pullRequest == .notGitHub(remoteURL: remote.path))
    }
}
