import Foundation
import SuijinAgents
import SuijinCore
import SuijinGit
import SuijinPTYProtocol
import SuijinTerminal
import Testing
@testable import Suijin

/// End to end inside the signed app: workspaces (git and folder), worktrees, a shell session in the PTY host over
/// launchd XPC, re-attaching after a simulated app restart with the scrollback, and clean teardown.
@MainActor
@Suite(.endsHostedSessions, .serialized, .timeLimit(.minutes(1)))
struct SessionFlowTests {
    let root: URL
    let dataRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-e2e-\(UUID().uuidString)", isDirectory: true)
        dataRoot = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    }

    private func git(_ args: [String], in dir: URL) async throws {
        _ = try await GitRunner().run(["-c", "user.name=Suijin Tests", "-c", "user.email=tests@example.invalid"] + args, in: dir)
    }

    private func makeRepository() async throws -> URL {
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await git(["init", "-b", "main"], in: repo)
        try "hello\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await git(["add", "."], in: repo)
        try await git(["commit", "-m", "initial"], in: repo)
        return repo
    }

    /// Polls `condition` every 50 ms until it holds or `timeout` passes.
    private func eventually(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func gitAndFolderWorkspacesAndWorktrees() async throws {
        let repo = try await makeRepository()
        let folder = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try SuijinStore(url: SuijinPaths.database(in: dataRoot))
        let model = AppModel(store: store, dataRoot: dataRoot)

        await model.addWorkspace(at: repo.appendingPathComponent("README.md").deletingLastPathComponent())
        await model.addWorkspace(at: folder)
        #expect(model.presentedError == nil)
        #expect(model.workspaces.map(\.kind) == [.git, .folder])
        let gitWorkspace = try #require(model.workspaces.first)

        let path = WorktreeService.defaultPath(repository: repo, branch: "feature-a")
        let worktree = try await model.createWorktree(workspaceID: gitWorkspace.id, branch: "feature-a", base: "main", path: path)
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        let listed = try await WorktreeService(repository: repo).list().filter { !$0.isMain }.map { $0.path.standardizedFileURL.path }
        #expect(listed == [worktree.path])

        // A second model on the same database sees both workspaces with their kinds, and the worktree.
        let reopened = AppModel(store: try SuijinStore(url: SuijinPaths.database(in: dataRoot)), dataRoot: dataRoot)
        await reopened.load()
        #expect(reopened.workspaces.map(\.kind) == [.git, .folder])
        #expect(reopened.worktrees[gitWorkspace.id]?.map(\.branch) == ["feature-a"])

        // `git init` in the folder turns it into a git workspace.
        try await git(["init", "-b", "main"], in: folder)
        await reopened.refreshKind(of: reopened.workspaces[1])
        #expect(reopened.workspaces[1].kind == .git)

        await reopened.removeWorktree(worktree.id, force: false)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        #expect(try await WorktreeService(repository: repo).list().filter { !$0.isMain }.isEmpty)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: repo.deletingLastPathComponent().appendingPathComponent("repo-worktrees"))
    }

    @Test func shellSessionSurvivesRestartInThePTYHost() async throws {
        let folder = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let databaseURL = SuijinPaths.database(in: dataRoot)
        let model = AppModel(store: try SuijinStore(url: databaseURL), dataRoot: dataRoot)
        await model.addWorkspace(at: folder)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)

        await model.runtimes.bootstrap()
        #expect(model.runtimes.hostProblem == nil, "PTY host unavailable: \(model.runtimes.hostProblem ?? "")")
        let id = try #require(await model.runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil))
        let runtime = try #require(model.runtimes.runtime(for: id))
        let hostID = try #require(runtime.terminal.engine.sessionID)
        #expect(model.sessions.first?.hostSessionID == hostID)

        runtime.terminal.send("echo SUIJIN_E2E_$((40+2))\n")
        #expect(await eventually { runtime.terminal.view.visibleText().contains("SUIJIN_E2E_42") })

        // Quit with sessions kept: detach only. The host still runs the shell.
        await model.runtimes.prepareForQuit()
        let running = try await PTYHostClient.shared.listSessions()
        #expect(running.contains { $0.id == hostID && $0.isRunning })

        // A new app model (as after a relaunch) re-attaches and replays the scrollback.
        let relaunched = AppModel(store: try SuijinStore(url: databaseURL), dataRoot: dataRoot)
        await relaunched.load()
        await relaunched.runtimes.bootstrap()
        let restored = try #require(relaunched.runtimes.runtime(for: id))
        #expect(await eventually { restored.terminal.view.visibleText().contains("SUIJIN_E2E_42") })
        restored.terminal.send("echo AFTER_$((1+1))\n")
        #expect(await eventually { restored.terminal.view.visibleText().contains("AFTER_2") })

        // Closing the tab ends the shell in the host.
        await relaunched.closeSession(id)
        let after = try await PTYHostClient.shared.listSessions()
        #expect(!after.contains { $0.id == hostID && $0.isRunning })
        #expect(relaunched.sessions.isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func anotherDataRootLeavesForeignSessionsRunning() async throws {
        let folder = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let owner = AppModel(store: try SuijinStore.inMemory(), dataRoot: dataRoot)
        await owner.addWorkspace(at: folder)
        await owner.runtimes.bootstrap()
        let workspace = try #require(owner.workspaces.first)
        let id = try #require(await owner.runtimes.start(in: .workspace(workspace.id), agent: .shell, accountID: nil, prompt: nil))
        let hostID = try #require(owner.runtimes.runtime(for: id)?.terminal.engine.sessionID)
        await owner.runtimes.prepareForQuit()

        // A second model with its own data root and no records restores: the first one's shell must survive.
        let stranger = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("other-data"))
        await stranger.runtimes.bootstrap()
        // Termination is SIGHUP now and SIGKILL 2 s later: wait past both before checking.
        try await Task.sleep(for: .seconds(3))
        let sessions = try await PTYHostClient.shared.listSessions()
        #expect(sessions.contains { $0.id == hostID && $0.isRunning })
        PTYHostClient.shared.terminate(hostID)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func agentLaunchAppliesAccountEnvironmentAfterTheLoginShell() async throws {
        let folder = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: dataRoot)
        await model.addWorkspace(at: folder)
        let workspace = try #require(model.workspaces.first)
        let path = await AgentCatalog.loginShellPATH()
        try #require(AgentCatalog.resolveBinary(.claude, path: path) != nil, "claude is not installed on this Mac")

        let home = dataRoot.appendingPathComponent("claude-profiles/fake/home", isDirectory: true)
        let account = ManagedAccountRecord(provider: .claude, label: "Test", email: "test@example.invalid", homePath: home.path)
        await model.upsert(account)
        let record = AgentSessionRecord(workspaceID: workspace.id, agent: .claude, accountID: account.id, title: "Claude", cwd: folder.path)
        let launch = try await model.runtimes.makeLaunch(record: record, cwd: folder, accountID: account.id, prompt: "fix the bug")

        // The login shell execs /usr/bin/env, which removes the API key variables and points Claude at the profile.
        let envIndex = try #require(launch.arguments.firstIndex(of: "/usr/bin/env"))
        let envArguments = Array(launch.arguments[(envIndex + 1)...])
        #expect(envArguments.contains("CLAUDE_CONFIG_DIR=\(home.path)"))
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"] {
            let index = try #require(envArguments.firstIndex(of: key), "\(key) is not removed")
            #expect(envArguments[index - 1] == "-u")
        }
        #expect(envArguments.last == "fix the bug")
        #expect(launch.cwd == folder.path)
        #expect(launch.environment["SUIJIN_DATA_ROOT"] == dataRoot.path)
        try? FileManager.default.removeItem(at: root)
    }
}
