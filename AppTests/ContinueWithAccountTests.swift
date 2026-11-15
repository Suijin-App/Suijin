import Foundation
import SuijinAccounts
import SuijinCore
import Testing
@testable import Suijin

/// Continuing a conversation on another account: the history is placed in the target account's folder, the agent is
/// resumed there in the same record (tab or pane, folder, permission mode), and a failure leaves the session and its
/// history as they were. Stand-in `claude` and `codex` scripts record their arguments and account folder; account
/// folders are temporary, and the user's own login is a temporary home.
@MainActor
@Suite(.endsHostedSessions, .serialized, .timeLimit(.minutes(2)))
struct ContinueWithAccountTests {
    let root: URL
    let folder: URL
    let bin: URL
    let ownHome: URL
    let conversation = "5a0c2f9e-1b3d-4e5f-8a7b-9c0d1e2f3a4b"

    init() throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-continue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        root = raw.resolvingSymlinksInPath()
        folder = root.appendingPathComponent("work", isDirectory: true)
        bin = root.appendingPathComponent("bin", isDirectory: true)
        ownHome = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // Each launch appends its arguments, then the account folder it got, then a separator; a typed line ends it.
        for agent in ["claude", "codex"] {
            let script = bin.appendingPathComponent(agent)
            let file = root.appendingPathComponent("\(agent).args").path
            try """
            #!/bin/sh
            for arg in "$@"; do printf '%s\\n' "$arg" >> '\(file)'; done
            printf 'account=%s%s\\n' "$CLAUDE_CONFIG_DIR" "$CODEX_HOME" >> '\(file)'
            printf -- '----\\n' >> '\(file)'
            IFS= read -r line
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
    }

    private func launches(_ agent: AgentKind) -> [[String]] {
        let file = root.appendingPathComponent("\(agent.rawValue).args")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
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
        model.accountsController.ownLoginHome = (home: ownHome, environment: [:])
        await model.addWorkspace(at: folder)
        let context = SessionContext.workspace(try #require(model.workspaces.first).id)
        await model.runtimes.bootstrap()
        model.runtimes.agentSearchPath = bin.path
        model.selection = context
        return (model, context)
    }

    /// A managed account whose folder exists. Not a real profile path, so Suijin does not set it up from `~/.claude`.
    private func account(_ provider: AccountProvider, _ name: String, in model: AppModel) async throws -> ManagedAccountRecord {
        let parent = provider == .claude ? "claude-profiles" : "codex-homes"
        let home = model.dataRoot.appendingPathComponent("\(parent)/\(name)/home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let record = ManagedAccountRecord(provider: provider, label: name, email: "\(name)@example.invalid", homePath: home.path)
        await model.upsert(record)
        return record
    }

    /// Claude files conversations under its working directory with links resolved (`/private/var`, not `/var`).
    private var projectFolder: String {
        let resolved = realpath(folder.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        }
        return "projects/" + ConversationTransfer.claudeProjectFolder(forCwd: resolved ?? folder.path)
    }

    private func claudeTranscript(in home: URL) -> URL {
        home.appendingPathComponent("\(projectFolder)/\(conversation).jsonl")
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func record(_ id: UUID, in model: AppModel) throws -> AgentSessionRecord {
        try #require(model.sessions.first { $0.id == id })
    }

    private func tearDown(_ model: AppModel) async {
        await model.closeSessions(model.sessions.map(\.id))
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Managed to managed

    @Test func anEndedClaudeSessionContinuesOnAnotherAccountInTheSamePlace() async throws {
        let (model, context) = try await makeModel()
        let first = try await account(.claude, "first", in: model)
        let second = try await account(.claude, "second", in: model)
        let source = claudeTranscript(in: URL(fileURLWithPath: first.homePath))
        try write("{\"type\":\"user\"}\n", to: source)
        let ended = AgentSessionRecord(workspaceID: try #require(model.workspaces.first).id, agent: .claude,
                                       accountID: first.id, title: "Claude · \(first.displayName)", cwd: folder.path,
                                       state: .exited, agentSessionID: conversation, permissionMode: .plan)
        await model.upsert(ended)
        let tabBefore = model.tab(of: ended.id)

        let targets = model.continueTargets(for: ended)
        #expect(targets.map(\.accountID) == [second.id, nil])
        #expect(model.continueUnavailableReason(for: ended) == nil)
        await model.continueConversation(ended, on: try #require(targets.first))

        #expect(await eventually { model.runtimes.runtime(for: ended.id) != nil && launches(.claude).count == 1 })
        let arguments = try #require(launches(.claude).last)
        #expect(arguments.contains("account=\(second.homePath)"))
        let resume = try #require(arguments.firstIndex(of: "--resume"))
        #expect(arguments[resume + 1] == conversation)
        let mode = try #require(arguments.firstIndex(of: "--permission-mode"))
        #expect(arguments[mode + 1] == "plan")
        // Same record, tab, folder and mode; the account and its default title changed.
        let moved = try record(ended.id, in: model)
        #expect(moved.accountID == second.id && moved.title == "Claude · \(second.displayName)")
        #expect(moved.cwd == folder.path && moved.permissionMode == .plan && moved.agentSessionID == conversation)
        #expect(model.tab(of: ended.id) == tabBefore && model.tabList(in: context).count == 1)
        // Both accounts have the history; the original is where it was.
        #expect(try String(contentsOf: claudeTranscript(in: URL(fileURLWithPath: second.homePath)), encoding: .utf8) == "{\"type\":\"user\"}\n")
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(model.presentedError == nil)
        await tearDown(model)
    }

    @Test func aRunningCodexSessionEndsAndResumesOnTheTarget() async throws {
        let (model, context) = try await makeModel()
        let first = try await account(.codex, "first", in: model)
        let second = try await account(.codex, "second", in: model)
        let id = try #require(await model.runtimes.start(in: context, agent: .codex, accountID: first.id, prompt: nil,
                                                          permissionMode: .readOnly))
        #expect(await eventually { launches(.codex).count == 1 })
        // Codex reports its conversation only as it exits.
        #expect(model.continueUnavailableReason(for: try record(id, in: model))?.contains("Quit Codex") == true)
        let rollout = "sessions/2026/11/12/rollout-2026-11-12T16-57-21-\(conversation).jsonl"
        try write("{\"type\":\"session_meta\"}\n", to: URL(fileURLWithPath: first.homePath).appendingPathComponent(rollout))
        var known = try record(id, in: model)
        known.agentSessionID = conversation
        await model.upsert(known)
        let firstRuntime = model.runtimes.runtime(for: id)

        await model.continueConversation(known, on: ContinueTarget(accountID: second.id, name: second.displayName))

        #expect(await eventually { launches(.codex).count == 2 && model.runtimes.runtime(for: id) != nil })
        #expect(model.runtimes.runtime(for: id) !== firstRuntime)
        let arguments = try #require(launches(.codex).last)
        #expect(arguments.contains("account=\(second.homePath)"))
        let resume = try #require(arguments.firstIndex(of: "resume"))
        #expect(arguments[resume + 1] == conversation)
        #expect(arguments.contains("read-only"))
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: second.homePath).appendingPathComponent(rollout).path))
        #expect(try record(id, in: model).accountID == second.id)
        await tearDown(model)
    }

    // MARK: Failures

    @Test func aConflictKeepsTheRunningSessionAndBothHistories() async throws {
        let (model, context) = try await makeModel()
        let first = try await account(.claude, "first", in: model)
        let second = try await account(.claude, "second", in: model)
        let id = try #require(await model.runtimes.start(in: context, agent: .claude, accountID: first.id, prompt: nil))
        #expect(await eventually { launches(.claude).count == 1 })
        let source = claudeTranscript(in: URL(fileURLWithPath: first.homePath))
        let target = claudeTranscript(in: URL(fileURLWithPath: second.homePath))
        try write("mine\n", to: source)
        try write("theirs\n", to: target)
        model.runtimes.storeConversation(conversation, for: id)
        #expect(await eventually { try record(id, in: model).agentSessionID == conversation })
        let runtime = model.runtimes.runtime(for: id)

        await model.continueConversation(try record(id, in: model), on: ContinueTarget(accountID: second.id, name: "second"))

        #expect(model.presentedError?.message.contains("different copy") == true)
        // Nothing ended or changed: same process, same account, both files as they were.
        #expect(model.runtimes.runtime(for: id) === runtime && launches(.claude).count == 1)
        #expect(try record(id, in: model).accountID == first.id)
        #expect(try String(contentsOf: source, encoding: .utf8) == "mine\n")
        #expect(try String(contentsOf: target, encoding: .utf8) == "theirs\n")
        #expect(model.runtimes.movingConversation.isEmpty && !model.runtimes.resuming.contains(id))
        await tearDown(model)
    }

    @Test func aSessionWithNothingSaidYetStartsAfreshOnTheTarget() async throws {
        let (model, context) = try await makeModel()
        let first = try await account(.claude, "first", in: model)
        let second = try await account(.claude, "second", in: model)
        let id = try #require(await model.runtimes.start(in: context, agent: .claude, accountID: first.id, prompt: nil,
                                                          permissionMode: .plan))
        #expect(await eventually { launches(.claude).count == 1 })
        // Claude reported its conversation as it started, but saves it only once something is said.
        model.runtimes.storeConversation(conversation, for: id)
        #expect(await eventually { try record(id, in: model).agentSessionID == conversation })
        let tabBefore = model.tab(of: id)
        let firstRuntime = model.runtimes.runtime(for: id)

        await model.continueConversation(try record(id, in: model), on: ContinueTarget(accountID: second.id, name: "second"))

        #expect(model.presentedError == nil)
        #expect(await eventually { launches(.claude).count == 2 && model.runtimes.runtime(for: id) != nil })
        #expect(model.runtimes.runtime(for: id) !== firstRuntime)
        let arguments = try #require(launches(.claude).last)
        #expect(arguments.contains("account=\(second.homePath)"))
        #expect(!arguments.contains("--resume"))
        let mode = try #require(arguments.firstIndex(of: "--permission-mode"))
        #expect(arguments[mode + 1] == "plan")
        let moved = try record(id, in: model)
        #expect(moved.accountID == second.id && moved.agentSessionID != conversation)
        #expect(model.tab(of: id) == tabBefore && model.tabList(in: context).count == 1)
        // Nothing was copied into the other account's history.
        #expect(!FileManager.default.fileExists(atPath: second.homePath + "/projects"))
        await tearDown(model)
    }

    @Test func resumingAConversationNothingWasSaidInStartsAfreshInPlace() async throws {
        let (model, context) = try await makeModel()
        let first = try await account(.claude, "first", in: model)
        let ended = AgentSessionRecord(workspaceID: try #require(model.workspaces.first).id, agent: .claude,
                                       accountID: first.id, title: "Claude · \(first.displayName)", cwd: folder.path,
                                       state: .exited, exitCode: 1, agentSessionID: conversation, permissionMode: .plan)
        await model.upsert(ended)
        let tabBefore = model.tab(of: ended.id)

        await model.resume(ended)

        #expect(model.presentedError == nil)
        #expect(await eventually { launches(.claude).count == 1 && model.runtimes.runtime(for: ended.id) != nil })
        let arguments = try #require(launches(.claude).last)
        #expect(!arguments.contains("--resume") && arguments.contains("account=\(first.homePath)"))
        let mode = try #require(arguments.firstIndex(of: "--permission-mode"))
        #expect(arguments[mode + 1] == "plan")
        let restarted = try record(ended.id, in: model)
        #expect(restarted.accountID == first.id && restarted.agentSessionID != conversation && restarted.exitCode == nil)
        #expect(model.tab(of: ended.id) == tabBefore && model.tabList(in: context).count == 1)
        await tearDown(model)
    }

    // MARK: The user's own login

    @Test func ownLoginGetsOnlyTheConversationsHistoryFile() async throws {
        let (model, _) = try await makeModel()
        let first = try await account(.claude, "first", in: model)
        let ownClaude = ownHome.appendingPathComponent(".claude", isDirectory: true)
        try write("{}", to: ownClaude.appendingPathComponent("settings.json"))
        try write("history\n", to: claudeTranscript(in: URL(fileURLWithPath: first.homePath)))
        let ended = AgentSessionRecord(workspaceID: try #require(model.workspaces.first).id, agent: .claude,
                                       accountID: first.id, title: "Claude · \(first.displayName)", cwd: folder.path,
                                       state: .exited, agentSessionID: conversation)
        await model.upsert(ended)

        let own = try #require(model.continueTargets(for: ended).last)
        #expect(own.accountID == nil)
        await model.continueConversation(ended, on: own)

        #expect(await eventually { launches(.claude).count == 1 })
        #expect(try #require(launches(.claude).last).contains("account="))
        let written = try FileManager.default.subpathsOfDirectory(atPath: ownClaude.path).sorted()
        #expect(written == ["projects", projectFolder, "\(projectFolder)/\(conversation).jsonl", "settings.json"])
        #expect(try String(contentsOf: ownClaude.appendingPathComponent("settings.json"), encoding: .utf8) == "{}")
        let moved = try record(ended.id, in: model)
        #expect(moved.accountID == nil && moved.title == "Claude")
        // An own-login session offers the managed accounts only.
        #expect(model.continueTargets(for: moved).map(\.accountID) == [first.id])
        await tearDown(model)
    }

    // MARK: Limit

    @Test func aUsedUpWindowOfTheSessionsAccountIsReported() async throws {
        let (model, context) = try await makeModel()
        let first = try await account(.claude, "first", in: model)
        let id = try #require(await model.runtimes.start(in: context, agent: .claude, accountID: first.id, prompt: nil))
        let session = try record(id, in: model)
        let now = Date()
        model.accountsController.setUsageForPreview(first.id, UsageSnapshot(
            fiveHour: UsageWindow(usedFraction: 0.4, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: nil, fetchedAt: now))
        #expect(model.reachedLimit(of: session, now: now) == nil)
        model.accountsController.setUsageForPreview(first.id, UsageSnapshot(
            fiveHour: UsageWindow(usedFraction: 1, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: UsageWindow(usedFraction: 0.5, resetsAt: now.addingTimeInterval(86_400)), fetchedAt: now))
        #expect(model.reachedLimit(of: session, now: now)?.kind == .session)
        // A window past its reset no longer counts.
        #expect(model.reachedLimit(of: session, now: now.addingTimeInterval(7200)) == nil)
        await tearDown(model)
    }
}
