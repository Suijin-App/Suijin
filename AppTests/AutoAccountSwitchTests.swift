import Foundation
import SuijinAccounts
import SuijinAgents
import SuijinCore
import Testing
@testable import Suijin

/// Automatic account switching: running sessions follow a new default account and leave an account at its limit for
/// the first account with room, between turns only, never bouncing back and never touching shells. Stand-in `claude`
/// and `codex` scripts record their arguments and account folder; account folders are temporary, and the user's own
/// login is a temporary home.
@MainActor
@Suite(.endsHostedSessions, .serialized, .timeLimit(.minutes(2)))
struct AutoAccountSwitchTests {
    let root: URL
    let folder: URL
    let bin: URL
    let conversation = "7b1d3f0a-2c4e-4f6a-9b8c-0d1e2f3a4b5c"

    init() throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("suijin-autoswitch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        root = raw.resolvingSymlinksInPath()
        folder = root.appendingPathComponent("work", isDirectory: true)
        bin = root.appendingPathComponent("bin", isDirectory: true)
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

    // MARK: Helpers

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

    /// Gives anything that would wrongly start time to show.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(600))
    }

    private func makeModel(store: SuijinStore? = nil) async throws -> (AppModel, SessionContext) {
        let model = AppModel(store: try store ?? SuijinStore.inMemory(), dataRoot: root.appendingPathComponent("data"))
        model.accountsController.ownLoginHome = (home: root.appendingPathComponent("home", isDirectory: true), environment: [:])
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

    /// A running Claude session on `account` whose conversation is known and saved in that account's folder.
    private func claudeSession(on account: ManagedAccountRecord, in model: AppModel, context: SessionContext) async throws -> UUID {
        let resolved = realpath(folder.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        }
        let transcript = URL(fileURLWithPath: account.homePath)
            .appendingPathComponent("projects/\(ConversationTransfer.claudeProjectFolder(forCwd: resolved ?? folder.path))/\(conversation).jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"type\":\"user\"}\n".utf8).write(to: transcript)
        let before = launches(.claude).count
        let id = try #require(await model.runtimes.start(in: context, agent: .claude, accountID: account.id, prompt: nil))
        #expect(await eventually { launches(.claude).count == before + 1 })
        model.runtimes.storeConversation(conversation, for: id)
        #expect(await eventually { try record(id, in: model).agentSessionID == conversation })
        return id
    }

    private func hook(_ name: String, _ id: UUID, in model: AppModel) {
        model.runtimes.runtime(for: id)?.tracker.noteHookEvent(ClaudeHookEvent(name: name))
    }

    private func record(_ id: UUID, in model: AppModel) throws -> AgentSessionRecord {
        try #require(model.sessions.first { $0.id == id })
    }

    private func usage(_ fraction: Double, now: Date = .now) -> UsageSnapshot {
        UsageSnapshot(fiveHour: UsageWindow(usedFraction: fraction, resetsAt: now.addingTimeInterval(3600)),
                      sevenDay: UsageWindow(usedFraction: 0.3, resetsAt: now.addingTimeInterval(86_400)), fetchedAt: now)
    }

    /// The session runs again on `account`, resumed: its record, its runtime and the last launch agree.
    private func isOn(_ id: UUID, _ account: ManagedAccountRecord, in model: AppModel) -> Bool {
        (try? record(id, in: model).accountID) == account.id && model.runtimes.runtime(for: id) != nil
            && launches(.claude).last.map { $0.contains("account=\(account.homePath)") && $0.contains("--resume") } == true
    }

    private func tearDown(_ model: AppModel) async {
        await model.closeSessions(model.sessions.map(\.id))
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Default account changes

    @Test func aNewDefaultMovesOtherAccountSessionsOnceTheirTurnEnds() async throws {
        let (model, context) = try await makeModel()
        let first = try await account(.claude, "first", in: model)
        let second = try await account(.claude, "second", in: model)
        model.setMovesOnDefaultChange(.claude, true)
        let moving = try await claudeSession(on: first, in: model, context: context)
        let staying = try await claudeSession(on: second, in: model, context: context)
        let stayingRuntime = model.runtimes.runtime(for: staying)

        await model.accountsController.setDefault(second.id, for: .claude)
        hook("UserPromptSubmit", moving, in: model)
        await settle()
        // In the middle of its turn: still on its account, nothing relaunched.
        #expect(try record(moving, in: model).accountID == first.id)
        #expect(launches(.claude).count == 2)

        hook("Stop", moving, in: model)
        #expect(await eventually { isOn(moving, second, in: model) })
        let arguments = try #require(launches(.claude).last)
        let resume = try #require(arguments.firstIndex(of: "--resume"))
        #expect(arguments[resume + 1] == conversation)
        #expect(model.autoSwitcher.notes[moving]?.text.contains("new default account") == true)
        // The session already on the new default is left alone.
        #expect(model.runtimes.runtime(for: staying) === stayingRuntime)
        #expect(model.autoSwitcher.notes[staying] == nil)
        #expect(launches(.claude).count == 3)
        #expect(model.presentedError == nil)
        await tearDown(model)
    }

    @Test func aSessionWaitingAtAPromptIsNeverMoved() async throws {
        let (model, context) = try await makeModel()
        let first = try await account(.claude, "first", in: model)
        let second = try await account(.claude, "second", in: model)
        model.setMovesOnDefaultChange(.claude, true)
        await model.setSwitchesAtLimit(.claude, true)?.value
        let id = try await claudeSession(on: first, in: model, context: context)
        let runtime = model.runtimes.runtime(for: id)
        // A finished turn, then Claude asks for permission: the request is pending.
        hook("Stop", id, in: model)
        hook("PermissionRequest", id, in: model)

        await model.accountsController.setDefault(second.id, for: .claude)
        model.accountsController.setUsageForPreview(first.id, usage(1))
        model.accountsController.setUsageForPreview(second.id, usage(0.2))
        await model.autoSwitcher.usageChanged()
        await settle()
        #expect(model.runtimes.runtime(for: id) === runtime && launches(.claude).count == 1)

        // A question or permission notification is no different.
        model.runtimes.runtime(for: id)?.tracker.noteHookEvent(
            ClaudeHookEvent(name: "Notification", notificationType: "permission_prompt"))
        await model.autoSwitcher.usageChanged()
        await settle()
        #expect(try model.runtimes.runtime(for: id) === runtime && record(id, in: model).accountID == first.id)

        // The user answered and the turn finished: now it moves.
        hook("Stop", id, in: model)
        #expect(await eventually { isOn(id, second, in: model) })
        await tearDown(model)
    }

    @Test func withTheSettingOffADefaultChangeMovesNothing() async throws {
        let (model, context) = try await makeModel()
        let first = try await account(.claude, "first", in: model)
        let second = try await account(.claude, "second", in: model)
        let id = try await claudeSession(on: first, in: model, context: context)
        hook("Stop", id, in: model)

        await model.accountsController.setDefault(second.id, for: .claude)
        await settle()

        #expect(try record(id, in: model).accountID == first.id)
        #expect(launches(.claude).count == 1)
        #expect(model.autoSwitcher.notes.isEmpty)
        await tearDown(model)
    }

    @Test func aRunningCodexWithoutAKnownConversationStaysWithANote() async throws {
        let (model, context) = try await makeModel()
        let first = try await account(.codex, "first", in: model)
        let second = try await account(.codex, "second", in: model)
        model.setMovesOnDefaultChange(.codex, true)
        let id = try #require(await model.runtimes.start(in: context, agent: .codex, accountID: first.id, prompt: nil))
        #expect(await eventually { launches(.codex).count == 1 })
        let runtime = model.runtimes.runtime(for: id)

        await model.accountsController.setDefault(second.id, for: .codex)
        await settle()

        let note = try #require(model.autoSwitcher.notes[id])
        #expect(note.kind == .skipped && note.text.contains("Quit Codex to move it to \(second.displayName)"))
        #expect(model.runtimes.runtime(for: id) === runtime && launches(.codex).count == 1)
        #expect(try record(id, in: model).accountID == first.id)
        await tearDown(model)
    }

    // MARK: Limits

    @Test func atItsLimitASessionMovesToTheFirstAccountWithRoomAfterItsTurn() async throws {
        let (model, context) = try await makeModel()
        let busy = try await account(.claude, "busy", in: model)
        let full = try await account(.claude, "full", in: model)
        let spare = try await account(.claude, "spare", in: model)
        model.setFallbackOrder([.managed(full.id), .ownLogin, .managed(spare.id), .managed(busy.id)], for: .claude)
        await model.setSwitchesAtLimit(.claude, true)?.value
        let id = try await claudeSession(on: busy, in: model, context: context)
        hook("UserPromptSubmit", id, in: model)
        model.accountsController.setUsageForPreview(busy.id, usage(1))
        model.accountsController.setUsageForPreview(full.id, usage(1))
        model.accountsController.setUsageForPreview(spare.id, usage(0.2))
        // The own login's usage is unknown, so it is passed over.
        model.accountsController.setDefaultLoginUsageForPreview(.claude, nil)

        await model.autoSwitcher.usageChanged()
        await settle()
        #expect(try record(id, in: model).accountID == busy.id)

        hook("Stop", id, in: model)
        #expect(await eventually { isOn(id, spare, in: model) })
        let note = try #require(model.autoSwitcher.notes[id])
        #expect(note.kind == .moved)
        #expect(note.text == "Moved to \(spare.displayName) because \(busy.displayName) hit its 5-hour limit.")
        #expect(!note.text.contains("\u{2014}"))
        if model.notifiesUser {
            // Other suites post to the same notifier at the same time, so only this session's notices count.
            let notice = UserNotifier.shared.withheld.last { $0.identifier == id.uuidString }
            #expect(notice?.title == "Claude switched accounts")
            #expect(notice?.body.contains(note.text) == true)
        }
        await tearDown(model)
    }

    @Test func aMovedSessionDoesNotBounceBack() async throws {
        let (model, context) = try await makeModel()
        let first = try await account(.claude, "first", in: model)
        let second = try await account(.claude, "second", in: model)
        model.setFallbackOrder([.managed(first.id), .managed(second.id)], for: .claude)
        await model.setSwitchesAtLimit(.claude, true)?.value
        var clock = Date()
        model.autoSwitcher.now = { clock }
        let id = try await claudeSession(on: first, in: model, context: context)
        hook("Stop", id, in: model)
        model.accountsController.setUsageForPreview(first.id, usage(1, now: clock))
        model.accountsController.setUsageForPreview(second.id, usage(0.5, now: clock))
        await model.autoSwitcher.usageChanged()
        #expect(await eventually { isOn(id, second, in: model) })
        let runtime = model.runtimes.runtime(for: id)

        // Now the second is used up too, and the first has room again, but the session just moved.
        model.accountsController.setUsageForPreview(second.id, usage(1, now: clock))
        model.accountsController.setUsageForPreview(first.id, usage(0.1, now: clock))
        hook("Stop", id, in: model)
        await model.autoSwitcher.usageChanged()
        await settle()
        #expect(model.runtimes.runtime(for: id) === runtime)
        #expect(try record(id, in: model).accountID == second.id)

        // Past the cooldown it may move, but never to an account still at its limit.
        clock = clock.addingTimeInterval(AutoAccountSwitcher.limitCooldown + 60)
        model.accountsController.setUsageForPreview(second.id, usage(1, now: clock))
        model.accountsController.setUsageForPreview(first.id, usage(1, now: clock))
        await model.autoSwitcher.usageChanged()
        await settle()
        #expect(model.runtimes.runtime(for: id) === runtime)

        model.accountsController.setUsageForPreview(first.id, usage(0.1, now: clock))
        await model.autoSwitcher.usageChanged()
        #expect(await eventually { isOn(id, first, in: model) })
        #expect(launches(.claude).count == 3)
        await tearDown(model)
    }

    @Test func withNoAccountWithRoomTheSessionStaysAndItsBannerShows() async throws {
        let (model, context) = try await makeModel()
        let first = try await account(.claude, "first", in: model)
        let second = try await account(.claude, "second", in: model)
        await model.setSwitchesAtLimit(.claude, true)?.value
        let id = try await claudeSession(on: first, in: model, context: context)
        hook("Stop", id, in: model)
        let runtime = model.runtimes.runtime(for: id)
        model.accountsController.setUsageForPreview(first.id, usage(1))
        model.accountsController.setUsageForPreview(second.id, usage(1))
        model.accountsController.setDefaultLoginUsageForPreview(.claude, usage(1))

        await model.autoSwitcher.usageChanged()
        await settle()

        #expect(model.runtimes.runtime(for: id) === runtime && launches(.claude).count == 1)
        #expect(model.autoSwitcher.notes[id] == nil)
        // What `UsageLimitBanner` shows from: a used-up window and accounts to offer.
        let session = try record(id, in: model)
        #expect(model.reachedLimit(of: session) != nil && !model.continueTargets(for: session).isEmpty)
        await tearDown(model)
    }

    // MARK: Shells

    @Test func shellsAreNeverMoved() async throws {
        let (model, context) = try await makeModel()
        let first = try await account(.claude, "first", in: model)
        let second = try await account(.claude, "second", in: model)
        model.setMovesOnDefaultChange(.claude, true)
        await model.setSwitchesAtLimit(.claude, true)?.value
        let shell = try #require(await model.runtimes.start(in: context, agent: .shell, accountID: nil, prompt: nil))
        #expect(await eventually { model.runtimes.runtime(for: shell) != nil })
        let runtime = model.runtimes.runtime(for: shell)
        model.accountsController.setUsageForPreview(first.id, usage(1))
        model.accountsController.setUsageForPreview(second.id, usage(0.1))

        await model.accountsController.setDefault(second.id, for: .claude)
        await model.autoSwitcher.usageChanged()
        await settle()

        #expect(model.runtimes.runtime(for: shell) === runtime)
        #expect(model.autoSwitcher.notes[shell] == nil && model.autoSwitcher.pendingDefault[shell] == nil)
        #expect(try record(shell, in: model).accountID == nil && launches(.claude).isEmpty)
        await tearDown(model)
    }

    // MARK: Settings

    @Test func settingsAreStoredAndTheOrderFollowsTheAccounts() async throws {
        let store = try SuijinStore.inMemory()
        let (model, _) = try await makeModel(store: store)
        let alpha = try await account(.claude, "alpha", in: model)
        let beta = try await account(.claude, "beta", in: model)
        // Off by default; the own login comes last.
        #expect(!model.movesOnDefaultChange(.claude) && !model.switchesAtLimit(.claude))
        #expect(model.fallbackOrder(for: .claude) == [.managed(alpha.id), .managed(beta.id), .ownLogin])

        model.setMovesOnDefaultChange(.codex, true)
        await model.setSwitchesAtLimit(.claude, true)?.value
        model.setFallbackOrder([.ownLogin, .managed(beta.id), .managed(UUID()), .managed(alpha.id)], for: .claude)

        let reloaded = AppModel(store: store, dataRoot: root.appendingPathComponent("data"))
        let stored = await eventually {
            (try? store.setting(SettingKey.claudeFallbackOrder.rawValue))??.isEmpty == false
                && (try? store.setting(SettingKey.codexMoveOnDefaultChange.rawValue)) == "true"
                && (try? store.setting(SettingKey.claudeSwitchAtLimit.rawValue)) == "true"
        }
        #expect(stored)
        await reloaded.load()
        await reloaded.loadSettings()
        #expect(reloaded.movesOnDefaultChange(.codex) && !reloaded.movesOnDefaultChange(.claude))
        #expect(reloaded.switchesAtLimit(.claude) && !reloaded.switchesAtLimit(.codex))
        // An account that no longer exists is dropped; one added later joins the end, before nothing it was not in.
        #expect(reloaded.fallbackOrder(for: .claude) == [.ownLogin, .managed(beta.id), .managed(alpha.id)])
        let gamma = try await account(.claude, "gamma", in: reloaded)
        #expect(reloaded.fallbackOrder(for: .claude) == [.ownLogin, .managed(beta.id), .managed(alpha.id), .managed(gamma.id)])
        #expect(reloaded.fallbackOrder(for: .codex) == [.ownLogin])

        model.setSwitchesAtLimit(.claude, false)
        #expect(model.setting(.claudeSwitchAtLimit) == nil && !model.switchesAtLimit(.claude))
        await tearDown(model)
    }
}
