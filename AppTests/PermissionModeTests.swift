import Foundation
import SuijinCore
import Testing
@testable import Suijin

/// Permission modes in the app: the default per agent and a choice for one session, the confirmation before an agent
/// starts without permission checks, and the mode a session keeps when it is resumed, started again or repeated.
/// Live checks run stand-in `claude` and `codex` scripts that record their arguments; no real agent starts.
@MainActor
@Suite(.endsHostedSessions, .serialized, .timeLimit(.minutes(2)))
struct PermissionModeTests {
    let root: URL
    let folder: URL
    let bin: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-perm-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("work", isDirectory: true)
        bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // Each launch appends its arguments, one per line, then a separator; a line typed into it ends the process.
        for agent in ["claude", "codex"] {
            let script = bin.appendingPathComponent(agent)
            try """
            #!/bin/sh
            for arg in "$@"; do printf '%s\\n' "$arg" >> '\(argumentsFile(agent).path)'; done
            printf -- '----\\n' >> '\(argumentsFile(agent).path)'
            IFS= read -r line
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
    }

    private func argumentsFile(_ agent: String) -> URL {
        root.appendingPathComponent("\(agent).args")
    }

    /// The argument lists of every launch of `agent` so far, oldest first.
    private func launches(_ agent: AgentKind) -> [[String]] {
        guard let text = try? String(contentsOf: argumentsFile(agent.rawValue), encoding: .utf8) else { return [] }
        return text.components(separatedBy: "----\n").dropLast().map { $0.split(separator: "\n").map(String.init) }
    }

    private func eventually(_ timeout: Duration = .seconds(10), _ condition: () throws -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if (try? condition()) == true { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return (try? condition()) == true
    }

    private func makeModel() async throws -> (AppModel, SessionContext) {
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        await model.addWorkspace(at: folder)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        await model.runtimes.bootstrap()
        model.runtimes.agentSearchPath = bin.path
        model.selection = context
        return (model, context)
    }

    private func record(_ id: UUID?, in model: AppModel) throws -> AgentSessionRecord {
        try #require(model.sessions.first { $0.id == id })
    }

    /// Ends a stand-in agent and waits for its session to be recorded as ended.
    private func end(_ id: UUID, in model: AppModel) async throws {
        model.runtimes.runtime(for: id)?.terminal.send("\n")
        #expect(await eventually {
            try model.runtimes.runtime(for: id) == nil && model.runtimes.activity(of: record(id, in: model)).isEnded
        })
    }

    private func tearDown(_ model: AppModel) async {
        await model.closeSessions(model.sessions.map(\.id))
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Defaults

    @Test func defaultsAreAskAndAChoiceOverridesTheSetting() async throws {
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.defaultPermissionMode(for: .claude) == .ask)
        #expect(model.defaultPermissionMode(for: .codex) == .ask)

        model.setDefaultPermissionMode(.plan, for: .claude)
        model.setDefaultPermissionMode(.readOnly, for: .codex)
        #expect(model.permissionMode(for: .claude, choice: nil) == .plan)
        #expect(model.permissionMode(for: .codex, choice: nil) == .readOnly)
        #expect(model.permissionMode(for: .claude, choice: .ask) == .ask)
        #expect(model.permissionMode(for: .codex, choice: .bypass) == .bypass)
        #expect(model.permissionMode(for: .shell, choice: nil) == .ask)
        // A mode the agent does not offer is never stored.
        model.setDefaultPermissionMode(.auto, for: .claude)
        #expect(model.defaultPermissionMode(for: .claude) == .plan)

        // Stored and read back at the next launch; ask is stored as no value.
        #expect(await eventually { try model.store.setting(SettingKey.claudePermissionMode.rawValue) == "plan" })
        let relaunched = AppModel(store: model.store, dataRoot: model.dataRoot)
        await relaunched.loadSettings()
        #expect(relaunched.defaultPermissionMode(for: .codex) == .readOnly)
        model.setDefaultPermissionMode(.ask, for: .claude)
        #expect(model.setting(.claudePermissionMode) == nil)
    }

    // MARK: Confirmation

    @Test func skippingChecksIsConfirmedUntilTheUserTurnsTheQuestionOff() async throws {
        let model = AppModel(store: try SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        defer { try? FileManager.default.removeItem(at: root) }
        var started: [AgentPermissionMode] = []

        // Modes with checks start at once.
        for mode in [AgentPermissionMode.ask, .acceptEdits, .plan] {
            model.confirmPermissions(mode, for: .claude) { started.append(mode) }
        }
        #expect(started == [.ask, .acceptEdits, .plan])
        #expect(model.pendingPermissionConfirmation == nil)

        // Skipping them asks first; cancelling starts nothing.
        model.confirmPermissions(.bypass, for: .claude) { started.append(.bypass) }
        #expect(model.pendingPermissionConfirmation?.mode == .bypass)
        #expect(started.count == 3)
        model.pendingPermissionConfirmation = nil
        #expect(started.count == 3)

        // Confirmed without "Don't ask again": it starts, and the next one asks again.
        model.confirmPermissions(.bypass, for: .codex) { started.append(.bypass) }
        #expect(model.pendingPermissionConfirmation?.agent == .codex)
        model.confirmPendingPermissions(dontAskAgain: false)
        #expect(started.last == .bypass && started.count == 4)
        model.confirmPermissions(.bypass, for: .codex) { started.append(.bypass) }
        #expect(model.pendingPermissionConfirmation != nil)

        // With "Don't ask again" the question is shown this once and never again.
        model.confirmPendingPermissions(dontAskAgain: true)
        #expect(started.count == 5)
        model.confirmPermissions(.bypass, for: .claude) { started.append(.bypass) }
        #expect(model.pendingPermissionConfirmation == nil)
        #expect(started.count == 6)
        #expect(await eventually { try model.store.setting(SettingKey.skipPermissionsConfirmed.rawValue) == "true" })
    }

    // MARK: Launches

    /// ⌘T and a new pane use the default; a choice from the menu wins; the record keeps it, ask as no value.
    @Test func newSessionsUseTheDefaultUnlessAModeIsChosen() async throws {
        let (model, context) = try await makeModel()
        model.setDefaultPermissionMode(.acceptEdits, for: .claude)
        model.setDefaultPermissionMode(.auto, for: .codex)

        let claude = try #require(await model.runtimes.start(in: context, agent: .claude, accountID: nil, prompt: nil))
        #expect(try record(claude, in: model).permissionMode == .acceptEdits)
        #expect(await eventually { launches(.claude).count == 1 })
        let claudeArguments = try #require(launches(.claude).first)
        let settings = try #require(claudeArguments.firstIndex(of: "--settings"))
        #expect(Array(claudeArguments[(settings + 2)...]) == ["--permission-mode", "acceptEdits"])

        let codex = try #require(await model.addPane(in: context, axis: .sideBySide, agent: .codex))
        #expect(try record(codex, in: model).permissionMode == .auto)
        #expect(await eventually { launches(.codex).count == 1 })
        #expect(try #require(launches(.codex).first).suffix(4) == ["--sandbox", "workspace-write", "--ask-for-approval", "on-request"])

        let chosen = try #require(await model.addPane(in: context, axis: .stacked, agent: .codex, permissionMode: .ask))
        #expect(try record(chosen, in: model).permissionMode == nil)
        #expect(await eventually { launches(.codex).count == 2 })
        #expect(!launches(.codex)[1].contains("--sandbox"))

        let shell = try #require(await model.runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil,
                                                             permissionMode: .bypass))
        #expect(try record(shell, in: model).permissionMode == nil)
        #expect(try !record(shell, in: model).skipsPermissions)
        await tearDown(model)
    }

    /// Start Again and New Session Like This repeat the mode even when the default changed meanwhile; Resume Session
    /// passes it again together with the conversation.
    @Test(arguments: [AgentKind.claude, .codex])
    func repeatingOrResumingASessionKeepsItsMode(_ agent: AgentKind) async throws {
        let (model, context) = try await makeModel()
        let first = try #require(await model.runtimes.start(in: context, agent: agent, accountID: nil, prompt: nil,
                                                             permissionMode: .bypass))
        #expect(try record(first, in: model).skipsPermissions)
        let skip = agent == .claude ? "--dangerously-skip-permissions" : "--dangerously-bypass-approvals-and-sandbox"
        #expect(await eventually { launches(agent).count == 1 })
        #expect(launches(agent)[0].contains(skip))

        // The default says otherwise; the session's own mode wins for everything that repeats it.
        model.setDefaultPermissionMode(agent == .claude ? .plan : .readOnly, for: agent)
        try await end(first, in: model)
        await model.startAgain(try record(first, in: model))
        let again = try #require(model.tabSessions(in: context).first)
        #expect(again.id != first && again.permissionMode == .bypass)
        #expect(await eventually { launches(agent).count == 2 })
        #expect(launches(agent)[1].contains(skip))

        // Resume Session: the same record runs again with its conversation and its mode.
        let conversation = "0f4c3a52-7d1e-4b8a-9c2d-5e6f7a8b9c0d"
        try await end(again.id, in: model)
        var ended = try record(again.id, in: model)
        ended.agentSessionID = conversation
        await model.upsert(ended)
        // The agent saved the conversation (something was said), in a stand-in own-login folder.
        let home = root.appendingPathComponent("home", isDirectory: true)
        model.accountsController.ownLoginHome = (home: home, environment: [:])
        let saved = agent == .claude
            ? ".claude/projects/-work/\(conversation).jsonl"
            : ".codex/sessions/2026/11/13/rollout-2026-11-13T10-00-00-\(conversation).jsonl"
        let file = home.appendingPathComponent(saved)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: file)
        await model.resume(ended)
        #expect(await eventually { launches(agent).count == 3 })
        let resumed = launches(agent)[2]
        let resumeFlag = agent == .claude ? "--resume" : "resume"
        let resumeIndex = try #require(resumed.firstIndex(of: resumeFlag))
        let skipIndex = try #require(resumed.firstIndex(of: skip))
        #expect(resumed[resumeIndex + 1] == conversation && skipIndex < resumeIndex)
        #expect(try record(again.id, in: model).permissionMode == .bypass)

        // New Session Like This (the same call its menu item makes).
        let like = try #require(await model.runtimes.start(in: context, agent: ended.agent, accountID: ended.accountID,
                                                            prompt: nil, permissionMode: ended.effectivePermissionMode))
        #expect(try record(like, in: model).permissionMode == .bypass)
        await tearDown(model)
    }
}
