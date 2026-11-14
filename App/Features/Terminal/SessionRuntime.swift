import AppKit
import Foundation
import SuijinAccounts
import SuijinAgents
import SuijinCore
import SuijinPTYProtocol
import SuijinTerminal
import SuijinUI
import Observation
import os
import SwiftUI

private let logger = Logger(subsystem: "com.tekmium.suijin", category: "sessions")

/// One live session: its terminal (engine + view) and, for agents, the status tracker fed by output, input,
/// Claude hook events and the exit.
@MainActor
final class SessionRuntime {
    let id: UUID
    let agent: AgentKind
    let terminal: TerminalSession
    let tracker = AgentStatusTracker()
    var watcher: HookEventWatcher?
    var title: String?
    /// Suijin itself is ending this session (tab closed, quit): its exit is expected and is not reported.
    var isEnding = false
    /// When the agent last started working (activity `running`); nil while it is not working. Feeds the work-time stat.
    var workingSince: Date?
    /// The agent's own conversation id, as far as Suijin knows it (Claude's hooks report it; a resumed session starts
    /// with the id it resumed).
    var agentSessionID: String?
    /// For a shell: the agents started in it that still run (`ShellAgentSessions.swift`).
    var shellAgentStack = ShellAgentStack()

    init(id: UUID, agent: AgentKind, terminal: TerminalSession) {
        self.id = id
        self.agent = agent
        self.terminal = terminal
    }
}

/// Starts, restores and ends sessions. Every terminal runs in the PTY host helper so it outlives the app; when the
/// helper cannot be registered (an unsigned debug build outside /Applications, the user turned it off in Login Items)
/// sessions run inside the app instead and end with it.
@Observable
@MainActor
final class SessionRuntimeRegistry {
    @ObservationIgnored unowned let model: AppModel
    /// Observed: a session restored or started after a view rendered must replace its placeholder.
    private var runtimes: [UUID: SessionRuntime] = [:]
    /// Observable mirror of each runtime's activity, so rows and badges update.
    private(set) var activities: [UUID: AgentActivity] = [:]
    private(set) var titles: [UUID: String] = [:]
    /// Observable mirror of the agent running in each shell session; only `ShellAgentSessions.swift` changes it.
    var shellAgents: [UUID: AgentKind] = [:]
    /// True from launch until the sessions that kept running in the PTY host are attached again.
    private(set) var isRestoring = true
    /// Sessions whose screen is not ready yet: attaching to the host or replaying their scrollback.
    private(set) var reconnecting: Set<UUID> = []
    /// Resumed agents whose screen stays hidden while they re-print their conversation (`TerminalSession.catchUp`).
    private(set) var catchingUp: Set<UUID> = []
    /// Why sessions do not survive quitting, when the PTY host is unavailable.
    private(set) var hostProblem: String?
    /// The last lines a session printed before it failed, for its ended view (memory only: it can hold anything).
    private(set) var endedOutput: [UUID: String] = [:]
    /// The email of the user's own login when each own-login agent session started (memory only: unknown for sessions
    /// started before the app launched), so a login changed since then can be told apart.
    private(set) var launchLogins: [UUID: String] = [:]
    @ObservationIgnored private var usesHost = true
    /// The launch's attempt to reach the PTY host. Sessions started meanwhile wait for it, so they neither go to a host
    /// that is still being repaired nor fail with its timeout.
    @ObservationIgnored private var hostConnecting: Task<Void, Never>?
    /// Why launch could not reach the PTY host, while sessions run in the app.
    @ObservationIgnored private var hostFailure: (any Error)?
    /// Stored running sessions the helper did not answer for (it may still run them): shown as reconnecting, not
    /// resumable, attached again once the helper answers (`reattachNotConnected`).
    private(set) var notConnected: Set<UUID> = []
    @ObservationIgnored private var isReattaching = false
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var hooks: ClaudeHooks.Installation?
    /// The link to the orchestration broker in the PTY host (worker starts, the worker tree, notifications).
    @ObservationIgnored private(set) lazy var orchestration = OrchestrationController(model: model)
    /// `--plugin-dir` for Claude sessions: the orchestration skill, unless the user installed it in `~/.claude/skills`.
    @ObservationIgnored private var claudePlugin: URL?
    /// Where agents are looked up instead of the login shell's PATH; nil in the app. Tests point it at stand-in
    /// `claude` and `codex` scripts so no real agent starts.
    @ObservationIgnored var agentSearchPath: String?

    init(model: AppModel) {
        self.model = model
    }

    var liveCount: Int { activities.values.filter { !$0.isTerminal }.count }

    func runtime(for id: UUID) -> SessionRuntime? { runtimes[id] }

    func activity(of session: AgentSessionRecord) -> SessionActivityDisplay {
        if let live = activities[session.id] {
            // A shell has no turns: while it runs it is simply running, whatever its output does.
            if displayAgent(of: session) == .shell, !live.isTerminal { return .running }
            return SessionActivityDisplay(live)
        }
        return session.state == .failed ? .failed : .exited
    }

    // MARK: Launch

    /// Registers the PTY host, installs the shell integration and the Claude hooks, then attaches to the sessions
    /// that kept running while the app was closed.
    func bootstrap() async {
        let connecting = Task { await self.connectHost() }
        hostConnecting = connecting
        await connecting.value
        hooks = try? ClaudeHooks.install(dataRoot: model.dataRoot)
        _ = try? ShellIntegration.install(in: model.dataRoot)
        claudePlugin = OrchestrationLaunch.installClaudePlugin(dataRoot: model.dataRoot)
        // Orchestration needs the broker in the PTY host; in-process sessions have none.
        if usesHost { orchestration.start() }
        await restore()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Not awaited: the first request shows a system prompt and must not hold up the sessions.
        Task { await UserNotifier.shared.requestPermission() }
    }

    /// Registers the PTY host and connects to it, repairing its registration once when it cannot be reached
    /// (`PTYHostClient.connect`). When that fails, sessions run in the app instead and `hostProblem` says why.
    private func connectHost() async {
        do {
            try await PTYHostClient.shared.connect()
        } catch {
            usesHost = false
            hostFailure = error
            hostProblem = error.localizedDescription
            logger.error("PTY host unavailable, sessions run in-process: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Waits until launch found out whether sessions run in the PTY host.
    private func hostSettled() async {
        await hostConnecting?.value
    }

    /// The Repair button for the background helper in Settings: connects to the helper, renewing its registration when
    /// it cannot be reached and no helper runs (`PTYHostClient.repair`). Once it answers, sessions started from now on
    /// run in it again (and survive quitting), and sessions it kept running are shown again; sessions already running
    /// in the app stay there.
    func repairHost() async {
        await hostSettled()
        do {
            try await PTYHostClient.shared.repair()
        } catch {
            logger.error("Repairing the PTY host failed: \(error.localizedDescription, privacy: .public)")
            if !usesHost { hostProblem = error.localizedDescription }
            return
        }
        if !usesHost {
            usesHost = true
            hostFailure = nil
            hostProblem = nil
            orchestration.start()
            logger.notice("PTY host repaired; new sessions run in it again")
        }
        await reattachNotConnected()
    }

    /// What an alert says when a session could not start or resume: for a helper that cannot be reached or is turned
    /// off, what the user can do about it rather than the bare error.
    static func alertMessage(for error: any Error) -> String {
        if PTYHostClient.isUnreachable(error) || (error as? PTYHostClientError) == .registeredElsewhere {
            return String(localized: "Suijin's background helper does not start or does not answer, so the session cannot run. Open Suijin › Settings › General and click Repair next to Background helper under Permissions. If that does not help, restart your Mac.")
        }
        if (error as? PTYHostClientError) == .requiresApproval {
            return String(localized: "Suijin's background helper is turned off. Turn Suijin on in System Settings › General › Login Items, or click Open Login Items next to Background helper in Suijin › Settings › General.")
        }
        return error.localizedDescription
    }

    /// What becomes of a stored running session that could not be attached.
    enum UnattachedFate: Equatable {
        /// Its process is gone (or the helper answered that it cannot be shown): it is ended.
        case ended
        /// The helper did not answer while a helper process runs (or that is unknown): the session may well be alive.
        /// Its record keeps its state, it shows as reconnecting, cannot be resumed (that would start a second agent on
        /// the same conversation), and is attached again once the helper answers.
        case notConnected
    }

    /// The fate after `error`, given whether a helper process runs (nil: unknown).
    static func fateOfUnattached(after error: (any Error)?, helperRunning: Bool?) -> UnattachedFate {
        guard let error, PTYHostClient.isUnreachable(error) || (error as? PTYHostClientError) == .registeredElsewhere
        else { return .ended }
        return helperRunning == false ? .ended : .notConnected
    }

    /// Attaches to host sessions that belong to stored records and marks the others as ended. Host sessions no
    /// record knows about (the database was reset) are terminated so nothing runs unseen. When the helper did not
    /// answer, sessions it may still run are kept as not connected instead (`UnattachedFate`).
    private func restore() async {
        defer { isRestoring = false }
        let live = model.sessions.filter { $0.state != .exited && $0.state != .failed }
        guard usesHost else {
            let fate = Self.fateOfUnattached(after: hostFailure, helperRunning: PTYHostClient.shared.registration.helperRunning())
            for session in live {
                if fate == .notConnected, session.hostSessionID != nil {
                    notConnected.insert(session.id)
                    continue
                }
                await markEnded(session)
            }
            return
        }
        let hostSessions: [PTYSessionInfo]
        do {
            hostSessions = try await PTYHostClient.shared.listSessions()
        } catch {
            // Without the list nothing is known about any of them.
            let fate = Self.fateOfUnattached(after: error, helperRunning: PTYHostClient.shared.registration.helperRunning())
            for session in live {
                if fate == .notConnected, session.hostSessionID != nil { notConnected.insert(session.id) } else { await markEnded(session) }
            }
            return
        }
        var restorable: [(AgentSessionRecord, PTYSessionInfo)] = []
        var exitedWhileAway: [(AgentSessionRecord, PTYSessionInfo)] = []
        for session in model.sessions {
            guard let hostID = session.hostSessionID, let info = hostSessions.first(where: { $0.id == hostID }) else {
                if session.state != .exited && session.state != .failed { await markEnded(session) }
                continue
            }
            // A process that is gone is never attached: the host keeps an exited session and its scrollback for a
            // day, and attaching it showed a dead terminal (behind the reconnecting view) before the ended view on
            // every launch. A session already recorded as ended needs nothing more.
            guard info.isRunning else {
                if session.state != .exited && session.state != .failed { exitedWhileAway.append((session, info)) }
                continue
            }
            restorable.append((session, info))
        }
        // The session on screen first; all of them attach at once rather than one after another, each with its
        // scrollback, so a window with many sessions comes back as fast as its slowest one.
        let shown = Set(model.selection.map { model.visiblePanes(in: $0) } ?? [])
        restorable.sort { lhs, rhs in shown.contains(lhs.0.id) && !shown.contains(rhs.0.id) }
        var claimed = Set<String>()
        await withTaskGroup(of: String?.self) { group in
            for (session, info) in restorable {
                group.addTask { await self.restore(session, info: info) }
            }
            for (session, info) in exitedWhileAway {
                group.addTask {
                    await self.recordExitWhileAway(session, info: info)
                    return nil
                }
            }
            for await hostID in group {
                if let hostID { claimed.insert(hostID) }
            }
        }
        // Only sessions this data root started are ours to clean up: another data root (a second install, the tests)
        // shares the same host, and its sessions must keep running.
        for orphan in hostSessions where !claimed.contains(orphan.id) && orphan.isRunning
            && orphan.metadata["suijin.dataRoot"] == model.dataRoot.path {
            PTYHostClient.shared.terminate(orphan.id)
        }
    }

    private func markEnded(_ session: AgentSessionRecord) async {
        var ended = session
        ended.state = .exited
        ended.endedAt = ended.endedAt ?? Date()
        await model.upsert(ended)
    }

    /// Attaches the sessions kept as not connected, once the helper answers again (after Repair, or a later successful
    /// connection): running ones come back on screen, ones that exited meanwhile end as usual, and ones the helper no
    /// longer has are ended.
    func reattachNotConnected() async {
        guard usesHost, !notConnected.isEmpty, !isReattaching else { return }
        isReattaching = true
        defer { isReattaching = false }
        guard let hostSessions = try? await PTYHostClient.shared.listSessions() else { return }
        for id in notConnected {
            notConnected.remove(id)
            guard let record = model.sessions.first(where: { $0.id == id }), runtimes[id] == nil,
                  record.state != .exited, record.state != .failed else { continue }
            let info = record.hostSessionID.flatMap { hostID in hostSessions.first { $0.id == hostID } }
            if let info, info.isRunning {
                _ = await restore(record, info: info)
            } else if let info {
                await recordExitWhileAway(record, info: info)
            } else {
                await markEnded(record)
            }
        }
    }

    /// Attaches one stored session to its host session and shows its scrollback. Returns the host session id when it
    /// is shown, or when it is kept as not connected (the helper did not answer; it keeps running and is attached
    /// again later), nil when it could not be shown otherwise (it is then terminated and marked ended).
    private func restore(_ session: AgentSessionRecord, info: PTYSessionInfo) async -> String? {
        let hostID = info.id
        let engine = HostedTerminalEngine(client: .shared)
        let runtime = makeRuntime(id: session.id, agent: session.agent, engine: engine)
        runtime.agentSessionID = session.agentSessionID
        reconnecting.insert(session.id)
        do {
            let scrollback: [UInt8]
            do {
                scrollback = try await engine.attach(sessionID: hostID)
            } catch where PTYHostClient.isUnreachable(error) {
                // A busy helper (many sessions attaching at once) gets a second chance before anything is given up.
                scrollback = try await engine.attach(sessionID: hostID)
            }
            runtime.terminal.attached(scrollback: scrollback)
            // Still listed while the scrollback replays; the view reports the end (`onReplayChange`).
            if !runtime.terminal.view.isReplayingScrollback { reconnecting.remove(session.id) }
            if info.isRunning {
                runtime.tracker.noteOutput(at: Date())
            } else {
                runtime.tracker.noteExit(info.exitStatus)
            }
            // A shell's events come from a `claude` started in it.
            if session.agent != .codex, let hooks {
                startWatching(runtime, file: hooks.eventsFile(sessionID: session.id), readExisting: false)
            }
            return hostID
        } catch {
            reconnecting.remove(session.id)
            runtimes[session.id] = nil
            activities[session.id] = nil
            // A session that cannot be shown must not keep running unseen; but one the helper merely did not answer
            // for may be alive, and a slow helper is no reason to end the user's agent.
            if Self.fateOfUnattached(after: error, helperRunning: PTYHostClient.shared.registration.helperRunning())
                == .notConnected {
                logger.error("Could not attach session \(hostID, privacy: .public): the helper did not answer; it keeps running")
                notConnected.insert(session.id)
                return hostID
            }
            PTYHostClient.shared.terminate(hostID)
            await markEnded(session)
            return nil
        }
    }

    /// Records the end of a session whose process exited while Suijin was closed, without showing its terminal. Its
    /// scrollback is fed to a terminal that never goes on screen, for what the ended view needs: the last lines of a
    /// failure and the conversation to resume (Codex prints it as it exits). Until then the session's place shows the
    /// reconnecting view, as for any session that is not back yet, and then the ended view, once.
    private func recordExitWhileAway(_ session: AgentSessionRecord, info: PTYSessionInfo) async {
        let engine = HostedTerminalEngine(client: .shared)
        let terminal = TerminalSession(engine: engine)
        let runtime = SessionRuntime(id: session.id, agent: session.agent, terminal: terminal)
        runtime.agentSessionID = session.agentSessionID
        var code = info.exitStatus
        var output: String?
        var conversation = session.agentSessionID
        if let scrollback = try? await engine.attach(sessionID: info.id) {
            terminal.onExit = { code = $0 }
            terminal.attached(scrollback: scrollback)
            // Returns once the scrollback was fed and the exit delivered after it.
            await terminal.terminate(exitTimeout: .seconds(3))
            if (code ?? 0) != 0 { output = terminal.view.recentText(lineCount: Self.endedOutputLines) }
            conversation = Self.conversationID(of: runtime)
        }
        terminal.view.removeHandlers()
        await sessionExited(session.id, code: code, output: output, agentSessionID: conversation)
    }

    // MARK: Start

    /// Starts a session in `context`: an agent (with the chosen or default account, in the chosen or default
    /// permission mode) or the user's shell. With `select` it opens as the selected tab; a new pane is placed by its
    /// caller instead.
    @discardableResult
    func start(in context: SessionContext, agent: AgentKind, accountID: UUID?, prompt: String?, select: Bool = true,
               permissionMode: AgentPermissionMode? = nil) async -> UUID? {
        guard let workspaceID = model.workspaceID(of: context), let cwd = model.directory(of: context) else { return nil }
        let id = UUID()
        let worktreeID: UUID? = if case .worktree(let tree) = context { tree } else { nil }
        // The account actually used is stored, so removing the provider's default account later stops this session too.
        let accountID = accountID ?? agent.accountProvider.flatMap { model.defaultAccount(for: $0)?.id }
        let title = defaultTitle(agent: agent, accountID: accountID)
        // Stored for resuming and repeating the session; ask is stored as no value, as for sessions from before modes.
        let mode = model.permissionMode(for: agent, choice: permissionMode)
        let record = AgentSessionRecord(id: id, workspaceID: workspaceID, worktreeID: worktreeID, agent: agent,
                                        accountID: accountID, title: title, cwd: cwd.path,
                                        permissionMode: mode == .ask ? nil : mode)
        do {
            let launch = try await makeLaunch(record: record, cwd: cwd, accountID: accountID, prompt: prompt)
            try await run(record, launch: launch)
            if select {
                model.selection = context
                model.selectedTab[context] = .session(id)
            }
            return id
        } catch {
            model.presentedError = PresentedError(title: String(localized: "Could not start \(title)"),
                                                  message: Self.alertMessage(for: error))
            return nil
        }
    }

    /// Ended agent sessions being resumed, from the click until the agent runs again: a second click does not start
    /// it twice, and the session's place shows the resuming view at once instead of the ended view changing under it.
    private(set) var resuming: Set<UUID> = []

    /// Starts an ended Claude or Codex session again with its conversation (`claude --resume <id>`,
    /// `codex resume <id>`) under the same record, so it comes back in its own tab or pane with the same account and
    /// folder. A conversation the agent never saved (nothing was said) starts afresh there instead. Does nothing for a
    /// session that still runs or whose conversation id is unknown.
    func resume(_ session: AgentSessionRecord) async {
        guard let ended = model.sessions.first(where: { $0.id == session.id }), ended.agent != .shell,
              runtimes[ended.id] == nil, !resuming.contains(ended.id), !notConnected.contains(ended.id),
              let conversation = ended.agentSessionID.flatMap(AgentResume.validSessionID) else { return }
        resuming.insert(ended.id)
        defer { resuming.remove(ended.id) }
        // Nothing was said in it, so the agent never saved it and would stop with "No conversation found": start a
        // new conversation in the same place instead.
        if let provider = ended.agent.accountProvider,
           let home = model.accountsController.conversationHome(provider, accountID: ended.accountID) {
            let transfer = ConversationTransfer(provider: provider, conversationID: conversation, cwd: ended.cwd,
                                                source: home, target: home)
            if await !Task.detached(operation: { transfer.sourceHasHistory }).value {
                if case .failed(let message) = await relaunch(ended, onAccount: ended.accountID, resume: nil) {
                    model.presentedError = PresentedError(title: String(localized: "Could not resume \(ended.title)"),
                                                          message: message)
                }
                return
            }
        }
        do {
            let cwd = URL(fileURLWithPath: ended.cwd, isDirectory: true)
            let launch = try await makeLaunch(record: ended, cwd: cwd, accountID: ended.accountID, prompt: nil,
                                              resume: conversation)
            try await relaunch(ended, launch: launch, catchUp: true)
        } catch {
            model.presentedError = PresentedError(title: String(localized: "Could not resume \(ended.title)"),
                                                  message: Self.alertMessage(for: error))
        }
    }

    /// Sessions whose conversation is moving to another account, with that account's name, from the click until the
    /// agent runs under it. Their place shows a progress view meanwhile.
    private(set) var movingConversation: [UUID: String] = [:]

    /// Shows `id`'s moving progress toward `name` (nil hides it) without moving anything: for screenshots, whose
    /// real move is over before it can be captured.
    func previewMovingConversation(_ id: UUID, to name: String?) {
        movingConversation[id] = name
    }

    /// The conversation `record` would continue with: what the running agent reported (or printed), else the one
    /// stored on the record. Nil for a shell or an unknown or malformed id.
    func continuableConversation(of record: AgentSessionRecord) -> String? {
        guard record.agent != .shell else { return nil }
        let live = runtimes[record.id].flatMap { $0.agent == .shell ? nil : Self.conversationID(of: $0) }
        return (live ?? record.agentSessionID).flatMap(AgentResume.validSessionID)
    }

    /// Continues `session`'s conversation under another account of the same agent (`accountID` nil = the user's own
    /// login), in the same tab or pane with the same folder and permission mode, and shows an error when it could not.
    func continueConversation(_ session: AgentSessionRecord, onAccount accountID: UUID?, named targetName: String) async {
        let title = displayTitle(of: model.sessions.first { $0.id == session.id } ?? session)
        if case .failed(let message) = await moveConversation(session, onAccount: accountID, named: targetName) {
            model.presentedError = PresentedError(title: String(localized: "Could not continue \(title) with \(targetName)"),
                                                  message: message)
        }
    }

    /// Moves `session`'s conversation to another account of the same agent (`accountID` nil = the user's own login) and
    /// resumes it there, in the same tab or pane with the same folder and permission mode. The history files are
    /// checked first, then the agent is ended if it runs, its history placed in the target account's folder
    /// (`ConversationTransfer`: linked or copied, never moved or replacing anything), and the agent resumed there. A
    /// conversation the agent has not saved yet (nothing was said) starts afresh on the target instead. On
    /// failure the session is left ended on its own account with its history as it was (or still running, when the
    /// check failed). Returns what happened, so the caller decides how to tell the user.
    func moveConversation(_ session: AgentSessionRecord, onAccount accountID: UUID?,
                          named targetName: String) async -> ConversationMoveOutcome {
        guard let current = model.sessions.first(where: { $0.id == session.id }),
              let provider = current.agent.accountProvider, current.accountID != accountID,
              !resuming.contains(current.id), movingConversation[current.id] == nil, !notConnected.contains(current.id),
              let conversation = continuableConversation(of: current) else { return .notStarted }
        let id = current.id
        movingConversation[id] = targetName
        resuming.insert(id)
        defer {
            movingConversation[id] = nil
            resuming.remove(id)
        }
        guard let source = model.accountsController.conversationHome(provider, accountID: current.accountID),
              let target = model.accountsController.conversationHome(provider, accountID: accountID) else {
            return .failed(String(localized: "That account is no longer in Suijin."))
        }
        let transfer = ConversationTransfer(provider: provider, conversationID: conversation, cwd: current.cwd,
                                            source: source, target: target)
        do {
            // Before the agent is ended: a conversation that cannot move keeps running where it is.
            _ = try await Task.detached { try transfer.plan() }.value
        } catch ConversationTransferError.historyNotFound {
            // The agent saves a conversation only once something was said in it (it searches every project folder
            // of the account), so there is nothing to carry over: start it afresh on the other account instead.
            let original = await endForMove(current, conversation: nil)
            return await relaunch(original, onAccount: accountID, resume: nil)
        } catch {
            return .failed(ConversationMove.message(for: error, agent: current.agent))
        }
        let original = await endForMove(current, conversation: conversation)
        do {
            _ = try await Task.detached { try transfer.run() }.value
        } catch {
            return .failed(ConversationMove.message(for: error, agent: current.agent))
        }
        return await relaunch(original, onAccount: accountID, resume: conversation)
    }

    /// Ends `current`'s agent when it runs and stores the record as ended (Suijin ended it, so no notification, and it
    /// can still be resumed where it was). Returns the stored record.
    private func endForMove(_ current: AgentSessionRecord, conversation: String?) async -> AgentSessionRecord {
        guard runtimes[current.id] != nil else { return current }
        await release(current.id)
        var original = model.sessions.first(where: { $0.id == current.id }) ?? current
        original.state = .exited
        original.endedAt = Date()
        if let conversation { original.agentSessionID = conversation }
        await model.upsert(original)
        return original
    }

    /// Runs the ended `original` again under `accountID`, reopening `resume` or (nil) starting a new conversation, in
    /// the same tab or pane. On failure the record goes back to `original`.
    private func relaunch(_ original: AgentSessionRecord, onAccount accountID: UUID?,
                          resume conversation: String?) async -> ConversationMoveOutcome {
        var moved = original
        moved.accountID = accountID
        moved.agentSessionID = conversation
        if original.title == defaultTitle(agent: original.agent, accountID: original.accountID) {
            moved.title = defaultTitle(agent: moved.agent, accountID: accountID)
        }
        if accountID != nil { launchLogins[original.id] = nil }
        do {
            let launch = try await makeLaunch(record: moved, cwd: URL(fileURLWithPath: moved.cwd, isDirectory: true),
                                              accountID: accountID, prompt: nil, resume: conversation)
            try await relaunch(moved, launch: launch, catchUp: conversation != nil)
            return .moved
        } catch {
            await model.upsert(original)
            return .failed(Self.alertMessage(for: error))
        }
    }

    /// Runs `launch` as the ended session `ended` again: same record, so its tab or pane, title, account and folder
    /// stay; the exit of the previous run is cleared. With `catchUp` (a resumed conversation, which the agent prints
    /// again as it starts) the screen waits for that output to settle and shows at its end.
    func relaunch(_ ended: AgentSessionRecord, launch: TerminalLaunch, catchUp: Bool = false) async throws {
        guard runtimes[ended.id] == nil else { return }
        // Covers the record stored as starting below, before the runtime exists.
        let marked = catchUp && resuming.insert(ended.id).inserted
        defer { if marked { resuming.remove(ended.id) } }
        var record = ended
        record.state = .starting
        record.exitCode = nil
        record.endedAt = nil
        endedOutput[record.id] = nil
        // Stored as starting first: an exit right after the launch must not find the previous run's ended record.
        await model.upsert(record)
        do {
            try await run(record, launch: launch, catchUp: catchUp)
        } catch {
            await model.upsert(ended)
            throw error
        }
    }

    /// Runs `launch` for `record` in a new runtime and stores the record with its host session, as running (or ended,
    /// when the process is already gone). On failure nothing is left behind and the record is not stored. With
    /// `catchUp` the screen stays hidden until the burst of output the program starts with settles.
    func run(_ record: AgentSessionRecord, launch: TerminalLaunch, catchUp: Bool = false) async throws {
        var record = record
        let id = record.id
        await hostSettled()
        // A helper that went away since launch is reached (and its registration repaired) before anything is spawned,
        // so a failure here never leaves a process behind and never starts one twice.
        if usesHost {
            try await PTYHostClient.shared.reconnect()
            // The helper answers: sessions it did not answer for before can be shown again.
            if !notConnected.isEmpty { Task { await reattachNotConnected() } }
        }
        let engine: any TerminalEngine = usesHost ? HostedTerminalEngine(client: .shared) : SwiftTermEngine()
        let runtime = makeRuntime(id: id, agent: record.agent, engine: engine)
        runtime.agentSessionID = record.agentSessionID
        // Before the process starts, so none of its output is fed while the screen shows.
        if catchUp { runtime.terminal.catchUp() }
        // A shell's events come from a `claude` started in it.
        if record.agent != .codex, let hooks {
            startWatching(runtime, file: hooks.eventsFile(sessionID: id), readExisting: true)
        }
        do {
            try await runtime.terminal.start(launch)
        } catch {
            runtime.watcher?.stop()
            runtimes[id] = nil
            activities[id] = nil
            catchingUp.remove(id)
            if let hooks { try? FileManager.default.removeItem(at: hooks.eventsFile(sessionID: id)) }
            throw error
        }
        record.hostSessionID = engine.sessionID
        record.state = runtime.terminal.hasExited ? .exited : .running
        // A hook may have reported the conversation while the record was not stored yet.
        record.agentSessionID = runtime.agentSessionID ?? record.agentSessionID
        await model.upsert(record)
        await countStart(of: record.agent)
    }

    /// The launch of `record`'s agent in its permission mode; `resume` is the conversation to reopen instead of starting
    /// a new one.
    func makeLaunch(record: AgentSessionRecord, cwd: URL, accountID: UUID?, prompt: String?,
                    resume: String? = nil) async throws -> TerminalLaunch {
        // Whether the session runs in the host decides its environment.
        await hostSettled()
        var base = ["SUIJIN_DATA_ROOT": model.dataRoot.path, "SUIJIN_SESSION_ID": record.id.uuidString]
        // Orchestration: the session token (only ever in this environment, never in arguments) and the broker's
        // addresses. Only hosted sessions get them: the broker lives in the PTY host.
        if usesHost { base.merge(OrchestrationLaunch.environment(dataRoot: model.dataRoot)) { _, new in new } }
        guard record.agent != .shell else {
            // `suijin` on the shell's PATH; the profile may reorder PATH but keeps entries it did not set.
            base["PATH"] = OrchestrationLaunch.path(prepending: ProcessInfo.processInfo.environment["PATH"])
            // A `claude` started in the shell gets the hooks through Suijin's shell function.
            if let hooks, (try? hooks.prepareEventsFile(sessionID: record.id)) != nil {
                base.merge(hooks.shellEnv(sessionID: record.id).set) { _, new in new }
            }
            var launch = ShellLaunch.interactiveShell(cwd: cwd, environment: base)
            launch.metadata["suijin.session"] = record.id.uuidString
            launch.metadata["suijin.dataRoot"] = model.dataRoot.path
            return launch
        }
        let path: String
        if let agentSearchPath { path = agentSearchPath } else { path = await AgentCatalog.loginShellPATH() }
        guard let binary = AgentCatalog.resolveBinary(record.agent, path: path) else {
            throw SessionError.agentNotFound(AgentCatalog.definition(for: record.agent)?.binaryName ?? record.agent.rawValue)
        }
        // The PATH the agent was found on (interactive login shell, so nvm and .zshrc additions count) also runs it:
        // npm-installed CLIs need `node` from that PATH.
        if let provider = record.agent.accountProvider, accountID == nil {
            launchLogins[record.id] = await model.accountsController.refreshDefaultLoginEmail(provider)
        }
        // The account was settled when the session started: nil is the user's own login, not today's default account.
        let accountEnv = await model.accountsController.launchEnv(for: record.agent, accountID: accountID,
                                                                  fallsBackToDefault: false)
            .merging(EnvPatch(set: ["PATH": OrchestrationLaunch.path(prepending: path)]))
        if record.agent == .claude, let hooks { _ = try? hooks.prepareEventsFile(sessionID: record.id) }
        var spec = AgentLaunchSpecBuilder.make(kind: record.agent, binary: binary, cwd: cwd, env: accountEnv,
                                               initialPrompt: prompt, hooks: record.agent == .claude ? hooks : nil,
                                               sessionID: record.id, resume: resume,
                                               permissionMode: record.effectivePermissionMode)
        // Codex can share a background app server; without it (or with a broken install of it) `--no-daemon` runs the
        // session on its own.
        if record.agent == .codex, model.setting(.codexNoDaemon) == "true" { spec.arguments.insert("--no-daemon", at: 0) }
        if usesHost, record.agent == .codex {
            // Codex reports each finished turn through `notify` (`suijin hook codex-notify`), set for this launch only.
            let home = spec.env.set["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            if let home { OrchestrationLaunch.installCodexSkill(home: home) }
            spec.arguments.insert(contentsOf: OrchestrationLaunch.codexNotifyArguments(home: home), at: 0)
            if let prompt, orchestration.launchingWorkerPrompts.contains(prompt) {
                let root = model.workspace(record.workspaceID).map { URL(fileURLWithPath: $0.path, isDirectory: true) }
                spec.arguments.insert(contentsOf: OrchestrationLaunch.codexWorkerArguments(directory: cwd, repositoryRoot: root),
                                      at: 0)
            }
        }
        // The skill as a session plugin. Placed before `--settings`, which ends the option's list of directories.
        if record.agent == .claude, let claudePlugin, spec.arguments.first == "--settings",
           !FileManager.default.fileExists(atPath: OrchestrationLaunch.userClaudeSkill().path) {
            spec.arguments.insert(contentsOf: ["--plugin-dir", claudePlugin.path], at: 0)
        }
        // The patch goes through `env` after the login shell ran the user's profile, so a key the profile exports
        // (an API key that would override the account) is still removed.
        var envArguments: [String] = []
        for key in spec.env.unset.sorted() where spec.env.set[key] == nil { envArguments += ["-u", key] }
        for (key, value) in spec.env.set.sorted(by: { $0.key < $1.key }) { envArguments.append("\(key)=\(value)") }
        var launch = ShellLaunch.command("/usr/bin/env", envArguments + [spec.binary.path] + spec.arguments,
                                         cwd: spec.cwd, environment: base, interactive: false)
        launch.metadata["suijin.session"] = record.id.uuidString
        launch.metadata["agent"] = record.agent.rawValue
        launch.metadata["suijin.dataRoot"] = model.dataRoot.path
        return launch
    }

    private func defaultTitle(agent: AgentKind, accountID: UUID?) -> String {
        let name = agent.sessionTitle
        guard let accountID, let account = model.accounts.first(where: { $0.id == accountID }) else { return name }
        return "\(name) · \(account.displayName)"
    }

    private func makeRuntime(id: UUID, agent: AgentKind, engine: any TerminalEngine) -> SessionRuntime {
        // The theme goes on before the process starts, so its first color query (OSC 11) gets the real background;
        // the pane applies it again (and on every change) once it shows.
        let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let terminal = TerminalSession(engine: engine,
                                       theme: TerminalThemes.resolve(id: model.setting(.terminalTheme), isDark: isDark))
        // An agent's multi-line paste is a prompt, not shell commands; agents turn bracketed paste on, so only a
        // shell (or a program without bracketed paste) gets the confirmation.
        terminal.view.pasteGuardPolicy = agent == .shell ? .always : .unlessBracketedPaste
        let runtime = SessionRuntime(id: id, agent: agent, terminal: terminal)
        runtimes[id] = runtime
        observeShellAgents(runtime)
        activities[id] = runtime.tracker.activity
        runtime.tracker.onTurnFinished = { [weak self] in self?.model.autoSwitcher.turnFinished(id) }
        runtime.tracker.onChange = { [weak self, weak runtime] activity in
            if let runtime { self?.trackWork(runtime, activity) }
            self?.activityChanged(id, activity)
        }
        let view = terminal.view
        view.onReplayChange = { [weak self] replaying in
            if replaying { self?.reconnecting.insert(id) } else { self?.reconnecting.remove(id) }
        }
        view.onCatchUpChange = { [weak self] catching in
            if catching { self?.catchingUp.insert(id) } else { self?.catchingUp.remove(id) }
        }
        let forwardInput = view.onInput
        view.onInput = { [weak runtime] bytes in
            forwardInput?(bytes)
            runtime?.tracker.noteInput(at: Date())
        }
        let forwardOutput = engine.onOutput
        engine.onOutput = { [weak runtime] bytes in
            forwardOutput?(bytes)
            runtime?.tracker.noteOutput(at: Date())
        }
        view.onTitleChange = { [weak self] title in
            guard let self else { return }
            // Agents animate a spinner in their title many times a second; only a change the tab shows is stored,
            // so the tabs and sidebar rows that read `titles` are not invalidated for every frame.
            let title: String? = title.isEmpty ? nil : title
            guard Self.shownTitle(title) != Self.shownTitle(titles[id]) else { return }
            titles[id] = title
        }
        let forwardExit = terminal.onExit
        terminal.onExit = { [weak self, weak runtime] code in
            forwardExit?(code)
            runtime?.watcher?.stop()
            runtime?.tracker.noteExit(code)
            guard let runtime, !runtime.isEnding else { return }
            // Read now: the screen goes with the runtime.
            let output = (code ?? 0) == 0 ? nil : runtime.terminal.view.recentText(lineCount: Self.endedOutputLines)
            let conversation = Self.conversationID(of: runtime)
            Task { await self?.sessionExited(id, code: code, output: output, agentSessionID: conversation) }
        }
        return runtime
    }

    /// The conversation an exited agent can be resumed with. Claude's hooks report its id as it runs, so that comes
    /// first; Codex reports none to Suijin, so the hint it prints as it exits counts first, and either falls back to
    /// the other.
    static func conversationID(of runtime: SessionRuntime) -> String? {
        let agent = runtime.activeAgent
        guard agent != .shell else { return nil }
        let printed = AgentResume.sessionID(inExitText: runtime.terminal.view.recentText(lineCount: Self.exitHintLines),
                                            kind: agent)
        return agent == .claude ? runtime.agentSessionID ?? printed : printed ?? runtime.agentSessionID
    }

    /// Lines at the end of an exited agent's screen searched for its resume hint.
    static let exitHintLines = 40

    private func startWatching(_ runtime: SessionRuntime, file: URL, readExisting: Bool) {
        let watcher = HookEventWatcher(fileURL: file, readExisting: readExisting) { [weak self, weak runtime] events in
            Task { @MainActor in
                // In a shell, only while the `claude` it started runs.
                guard let runtime, runtime.activeAgent == .claude else { return }
                for event in events {
                    runtime.tracker.noteHookEvent(event)
                    if let conversation = event.sessionID { self?.noteConversation(conversation, of: runtime) }
                }
            }
        }
        watcher.start()
        runtime.watcher = watcher
    }

    /// Keeps the conversation id Claude reported, on the record too, so the session can be resumed after it ended,
    /// even after a relaunch. It only changes when the conversation does.
    private func noteConversation(_ conversation: String, of runtime: SessionRuntime) {
        guard runtime.agentSessionID != conversation else { return }
        runtime.agentSessionID = conversation
        storeConversation(conversation, for: runtime.id)
    }

    func storeConversation(_ conversation: String, for id: UUID) {
        // The record is read when the write starts, so a state stored meanwhile (the exit) is not overwritten.
        Task {
            guard var record = model.sessions.first(where: { $0.id == id }), record.agentSessionID != conversation else { return }
            record.agentSessionID = conversation
            await model.upsert(record)
        }
    }

    // MARK: Status

    private func tick() {
        let now = Date()
        for runtime in runtimes.values { runtime.tracker.tick(now: now) }
    }

    private func activityChanged(_ id: UUID, _ activity: AgentActivity) {
        let previous = activities[id]
        activities[id] = activity
        guard previous != activity, let record = model.sessions.first(where: { $0.id == id }),
              displayAgent(of: record) != .shell else { return }
        switch activity {
        case .waitingForInput:
            notify(record, .waitingForInput)
        case .idle where previous == .running:
            notify(record, .finishedTurn)
        default:
            break
        }
    }

    /// Lines of a failed session's last output its ended view shows.
    static let endedOutputLines = 8

    /// Records and reports an exit Suijin did not cause, once: a session already marked ended (a finished session
    /// re-attached after a relaunch) stays as it is and notifies nobody. Either way the runtime goes, so the session's
    /// place shows its ended view instead of a terminal no process reads any more, and the host forgets the session.
    private func sessionExited(_ id: UUID, code: Int32?, output: String?, agentSessionID: String?) async {
        if let output, !output.isEmpty { endedOutput[id] = output }
        if let agentSessionID, var record = model.sessions.first(where: { $0.id == id }), record.agentSessionID != agentSessionID {
            record.agentSessionID = agentSessionID
            await model.upsert(record)
        }
        if var record = model.sessions.first(where: { $0.id == id }), record.state != .exited, record.state != .failed {
            record.state = (code ?? 0) == 0 ? .exited : .failed
            record.exitCode = code
            record.endedAt = Date()
            await model.upsert(record)
            if record.agent != .shell {
                notify(record, (code ?? 0) == 0 ? .ended(resumable: model.canResume(record)) : .failed(code: code))
            }
        }
        await release(id)
    }

    // MARK: End

    /// Ends the session's process (SIGHUP, then SIGKILL) and forgets everything kept about it.
    func terminate(_ id: UUID) async {
        await release(id)
        endedOutput[id] = nil
        titles[id] = nil
        launchLogins[id] = nil
        model.autoSwitcher.forget(id)
    }

    /// Ends the session's process if it still runs (SIGHUP, then SIGKILL) and drops its runtime. The title stays, so
    /// an ended session's tab keeps its name.
    private func release(_ id: UUID) async {
        guard let runtime = runtimes[id] else { return }
        runtime.isEnding = true
        await finishWork(runtime)?.value
        runtime.watcher?.stop()
        await runtime.terminal.terminate()
        runtime.terminal.view.removeHandlers()
        runtimes[id] = nil
        activities[id] = nil
        shellAgents[id] = nil
        reconnecting.remove(id)
        catchingUp.remove(id)
        if let hooks { try? FileManager.default.removeItem(at: hooks.eventsFile(sessionID: id)) }
    }

    /// On quit: hosted sessions keep running unless the user turned that off; in-process ones always end.
    func prepareForQuit() async {
        let keep = usesHost && model.setting(.keepSessionsOnQuit) != "false"
        // Sessions that ran in the app (started while the host was unavailable, before a repair) end with it either way.
        var ending = Array(runtimes.keys)
        if keep {
            // The agents keep working in the host, but only time Suijin saw is counted; a relaunch that finds them
            // running opens a new interval.
            for runtime in runtimes.values {
                guard let hosted = runtime.terminal.engine as? HostedTerminalEngine else { continue }
                await finishWork(runtime)?.value
                hosted.detach()
            }
            ending = runtimes.filter { !($0.value.terminal.engine is HostedTerminalEngine) }.map(\.key)
        }
        for id in ending {
            await terminate(id)
            if var record = model.sessions.first(where: { $0.id == id }), record.state != .exited, record.state != .failed {
                record.state = .exited
                record.endedAt = Date()
                await model.upsert(record)
            }
        }
        if usesHost, !keep { PTYHostClient.shared.shutdownHostIfIdle() }
    }

    // MARK: Stats

    /// Counts a session that started; a shell is not an agent and is not counted.
    func countStart(of agent: AgentKind) async {
        guard agent != .shell else { return }
        await addStat(.agentsSpawned, 1)
    }

    /// Working time of an agent: becoming `running` opens an interval, any other activity (including the exit) closes
    /// it and adds its length. Returns the write, if one was started, so callers that need it finished can wait.
    @discardableResult
    func trackWork(_ runtime: SessionRuntime, _ activity: AgentActivity, at now: Date = Date()) -> Task<Void, Never>? {
        guard runtime.activeAgent != .shell else { return nil }
        if activity == .running {
            if runtime.workingSince == nil { runtime.workingSince = now }
            return nil
        }
        return finishWork(runtime, at: now)
    }

    /// Closes the runtime's open working interval, if any, and stores its seconds off the main thread.
    @discardableResult
    private func finishWork(_ runtime: SessionRuntime, at now: Date = Date()) -> Task<Void, Never>? {
        guard let since = runtime.workingSince else { return nil }
        runtime.workingSince = nil
        let seconds = Int64(max(0, now.timeIntervalSince(since)).rounded())
        return Task { await self.addStat(.agentWorkSeconds, seconds) }
    }

    private func addStat(_ key: StatKey, _ amount: Int64) async {
        do {
            try await model.io { try $0.incrementStat(key, by: amount) }
        } catch {
            logger.error("Could not update the \(key.rawValue, privacy: .public) stat: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Notifications

    /// Posts a notification while Suijin is in the background (never while the user is working in it).
    private func notify(_ record: AgentSessionRecord, _ notice: SessionNotice) {
        guard model.setting(.notifyWhenWaiting) != "false", model.notifiesUser else { return }
        let place = model.worktree(record.worktreeID ?? UUID())?.branch ?? model.workspace(record.workspaceID)?.name ?? ""
        let text = notice.text(agent: displayAgent(of: record), session: displayTitle(of: record), place: place)
        // One notification per session: a newer state replaces the older banner instead of stacking.
        UserNotifier.shared.post(identifier: record.id.uuidString, title: text.title, body: text.body, session: record.id)
    }
}

/// What a session notification tells the user, in plain sentences: which agent, what happened and what to do.
enum SessionNotice: Equatable {
    case waitingForInput
    case finishedTurn
    /// The agent quit normally; `resumable` when its conversation can be resumed.
    case ended(resumable: Bool)
    /// The agent quit with an error; `code` is its exit status when there is one.
    case failed(code: Int32?)

    /// Title and body for the session titled `session` in `place` (a branch or workspace name, empty when none).
    func text(agent: AgentKind, session: String, place: String) -> (title: String, body: String) {
        let name = Self.name(of: agent)
        let subject = place.isEmpty ? session : String(localized: "\(session) in \(place)")
        switch self {
        case .waitingForInput:
            return (String(localized: "\(name) needs your input"), String(localized: "\(subject) is waiting for you."))
        case .finishedTurn:
            return (String(localized: "\(name) finished"), String(localized: "\(subject) is done with its turn."))
        case .ended(let resumable):
            return (String(localized: "\(name) stopped"),
                    resumable ? String(localized: "\(subject) has ended. Open it to resume or start again.")
                              : String(localized: "\(subject) has ended. Open it to start it again."))
        case .failed(let code):
            let body = if let code {
                String(localized: "\(subject) quit with an error (code \(code)). Open it to see what happened.")
            } else {
                String(localized: "\(subject) quit with an error. Open it to see what happened.")
            }
            return (String(localized: "\(name) stopped unexpectedly"), body)
        }
    }

    /// The agent as notifications name it.
    static func name(of agent: AgentKind) -> String {
        switch agent {
        case .claude: "Claude"
        case .codex: "Codex"
        case .shell: String(localized: "Shell")
        }
    }
}

/// What became of a request to move a conversation to another account.
enum ConversationMoveOutcome: Equatable {
    /// The agent runs on the other account now.
    case moved
    /// Nothing was tried: the session is gone, already on that account, already moving, or its conversation is unknown.
    case notStarted
    /// The move failed with this plain-language reason; the session stays on its own account.
    case failed(String)
}

enum SessionError: LocalizedError {
    case agentNotFound(String)

    var errorDescription: String? {
        switch self {
        case .agentNotFound(let name):
            String(localized: "`\(name)` was not found on your login shell's PATH. Install it, or check your shell profile.")
        }
    }
}

/// How a session's activity looks in the sidebar, tabs and inspector.
enum SessionActivityDisplay: Equatable {
    case starting, running, waitingForInput, idle, exited, failed

    init(_ activity: AgentActivity) {
        switch activity {
        case .starting: self = .starting
        case .running: self = .running
        case .waitingForInput: self = .waitingForInput
        case .idle: self = .idle
        case .exited(let code): self = code == 0 ? .exited : .failed
        case .failed: self = .failed
        }
    }

    /// Higher is more urgent: a row shows its most urgent session.
    var urgency: Int {
        switch self {
        case .exited: 0
        case .idle: 1
        case .starting: 2
        case .running: 3
        case .failed: 4
        case .waitingForInput: 5
        }
    }

    var systemImage: String {
        switch self {
        case .starting: "circle.dotted"
        case .running: "circle.fill"
        case .waitingForInput: "exclamationmark.bubble.fill"
        case .idle: "checkmark.circle"
        case .exited: "stop.circle"
        case .failed: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .starting: SuijinColor.idle
        case .running: SuijinColor.ok
        case .waitingForInput: SuijinColor.warning
        case .idle: SuijinColor.agent
        case .exited: SuijinColor.idle
        case .failed: SuijinColor.error
        }
    }

    var label: Text {
        switch self {
        case .starting: Text("Starting")
        case .running: Text("Running")
        case .waitingForInput: Text("Waiting for input")
        case .idle: Text("Idle")
        case .exited: Text("Exited")
        case .failed: Text("Failed")
        }
    }
}
