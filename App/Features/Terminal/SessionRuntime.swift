import AppKit
import Foundation
import SevindaAgents
import SevindaCore
import SevindaPTYProtocol
import SevindaTerminal
import SevindaUI
import Observation
import os
import SwiftUI

private let logger = Logger(subsystem: "com.tekmium.sevinda", category: "sessions")

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
    /// Sevinda itself is ending this session (tab closed, quit): its exit is expected and is not reported.
    var isEnding = false
    /// When the agent last started working (activity `running`); nil while it is not working. Feeds the work-time stat.
    var workingSince: Date?
    /// The agent's own conversation id, as far as Sevinda knows it (Claude's hooks report it; a resumed session starts
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
    @ObservationIgnored private unowned let model: AppModel
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
    @ObservationIgnored private var usesHost = true
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var hooks: ClaudeHooks.Installation?
    /// The link to the orchestration broker in the PTY host (worker starts, the worker tree, notifications).
    @ObservationIgnored private(set) lazy var orchestration = OrchestrationController(model: model)
    /// `--plugin-dir` for Claude sessions: the orchestration skill, unless the user installed it in `~/.claude/skills`.
    @ObservationIgnored private var claudePlugin: URL?

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
        do {
            try PTYHostClient.shared.register()
            _ = try await PTYHostClient.shared.handshake()
        } catch {
            usesHost = false
            hostProblem = error.localizedDescription
            logger.error("PTY host unavailable, sessions run in-process: \(error.localizedDescription, privacy: .public)")
        }
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

    /// Attaches to host sessions that belong to stored records and marks the others as ended. Host sessions no
    /// record knows about (the database was reset) are terminated so nothing runs unseen.
    private func restore() async {
        defer { isRestoring = false }
        guard usesHost else {
            for session in model.sessions where session.state != .exited && session.state != .failed {
                var ended = session
                ended.state = .exited
                ended.endedAt = ended.endedAt ?? Date()
                await model.upsert(ended)
            }
            return
        }
        let hostSessions = (try? await PTYHostClient.shared.listSessions()) ?? []
        var restorable: [(AgentSessionRecord, PTYSessionInfo)] = []
        var exitedWhileAway: [(AgentSessionRecord, PTYSessionInfo)] = []
        for session in model.sessions {
            guard let hostID = session.hostSessionID, let info = hostSessions.first(where: { $0.id == hostID }) else {
                if session.state != .exited && session.state != .failed {
                    var ended = session
                    ended.state = .exited
                    ended.endedAt = ended.endedAt ?? Date()
                    await model.upsert(ended)
                }
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
            && orphan.metadata["sevinda.dataRoot"] == model.dataRoot.path {
            PTYHostClient.shared.terminate(orphan.id)
        }
    }


    /// Attaches one stored session to its host session and shows its scrollback. Returns the host session id when it
    /// is shown, nil when it could not be (it is then terminated and marked ended).
    private func restore(_ session: AgentSessionRecord, info: PTYSessionInfo) async -> String? {
        let hostID = info.id
        let engine = HostedTerminalEngine(client: .shared)
        let runtime = makeRuntime(id: session.id, agent: session.agent, engine: engine)
        runtime.agentSessionID = session.agentSessionID
        reconnecting.insert(session.id)
        do {
            let scrollback = try await engine.attach(sessionID: hostID)
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
        } catch {
            // A session that cannot be shown must not keep running unseen.
            reconnecting.remove(session.id)
            runtimes[session.id] = nil
            activities[session.id] = nil
            PTYHostClient.shared.terminate(hostID)
            var ended = session
            ended.state = .exited
            ended.endedAt = ended.endedAt ?? Date()
            await model.upsert(ended)
        }
        return runtimes[session.id] == nil ? nil : hostID
    }

    /// Records the end of a session whose process exited while Sevinda was closed, without showing its terminal. Its
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

    /// Starts a session in `context`: an agent (with the chosen or default account) or the user's shell. With `select`
    /// it opens as the selected tab; a new pane is placed by its caller instead.
    @discardableResult
    func start(in context: SessionContext, agent: AgentKind, accountID: UUID?, prompt: String?, select: Bool = true) async -> UUID? {
        guard let workspaceID = model.workspaceID(of: context), let cwd = model.directory(of: context) else { return nil }
        let id = UUID()
        let worktreeID: UUID? = if case .worktree(let tree) = context { tree } else { nil }
        // The account actually used is stored, so removing the provider's default account later stops this session too.
        let accountID = accountID ?? agent.accountProvider.flatMap { model.defaultAccount(for: $0)?.id }
        let title = defaultTitle(agent: agent, accountID: accountID)
        let record = AgentSessionRecord(id: id, workspaceID: workspaceID, worktreeID: worktreeID, agent: agent,
                                        accountID: accountID, title: title, cwd: cwd.path)
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
                                                  message: error.localizedDescription)
            return nil
        }
    }

    /// Ended agent sessions being resumed, from the click until the agent runs again: a second click does not start
    /// it twice, and the session's place shows the resuming view at once instead of the ended view changing under it.
    private(set) var resuming: Set<UUID> = []

    /// Starts an ended Claude or Codex session again with its conversation (`claude --resume <id>`,
    /// `codex resume <id>`) under the same record, so it comes back in its own tab or pane with the same account and
    /// folder. Does nothing for a session that still runs or whose conversation id is unknown.
    func resume(_ session: AgentSessionRecord) async {
        guard let ended = model.sessions.first(where: { $0.id == session.id }), ended.agent != .shell,
              runtimes[ended.id] == nil, !resuming.contains(ended.id),
              let conversation = ended.agentSessionID.flatMap(AgentResume.validSessionID) else { return }
        resuming.insert(ended.id)
        defer { resuming.remove(ended.id) }
        do {
            let cwd = URL(fileURLWithPath: ended.cwd, isDirectory: true)
            let launch = try await makeLaunch(record: ended, cwd: cwd, accountID: ended.accountID, prompt: nil,
                                              resume: conversation)
            try await relaunch(ended, launch: launch, catchUp: true)
        } catch {
            model.presentedError = PresentedError(title: String(localized: "Could not resume \(ended.title)"),
                                                  message: error.localizedDescription)
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

    /// The launch of `record`'s agent; `resume` is the conversation to reopen instead of starting a new one.
    func makeLaunch(record: AgentSessionRecord, cwd: URL, accountID: UUID?, prompt: String?,
                    resume: String? = nil) async throws -> TerminalLaunch {
        var base = ["SEVINDA_DATA_ROOT": model.dataRoot.path, "SEVINDA_SESSION_ID": record.id.uuidString]
        // Orchestration: the session token (only ever in this environment, never in arguments) and the broker's
        // addresses. Only hosted sessions get them: the broker lives in the PTY host.
        if usesHost { base.merge(OrchestrationLaunch.environment(dataRoot: model.dataRoot)) { _, new in new } }
        guard record.agent != .shell else {
            // `sevinda` on the shell's PATH; the profile may reorder PATH but keeps entries it did not set.
            base["PATH"] = OrchestrationLaunch.path(prepending: ProcessInfo.processInfo.environment["PATH"])
            // A `claude` started in the shell gets the hooks through Sevinda's shell function.
            if let hooks, (try? hooks.prepareEventsFile(sessionID: record.id)) != nil {
                base.merge(hooks.shellEnv(sessionID: record.id).set) { _, new in new }
            }
            var launch = ShellLaunch.interactiveShell(cwd: cwd, environment: base)
            launch.metadata["sevinda.session"] = record.id.uuidString
            launch.metadata["sevinda.dataRoot"] = model.dataRoot.path
            return launch
        }
        let path = await AgentCatalog.loginShellPATH()
        guard let binary = AgentCatalog.resolveBinary(record.agent, path: path) else {
            throw SessionError.agentNotFound(AgentCatalog.definition(for: record.agent)?.binaryName ?? record.agent.rawValue)
        }
        // The PATH the agent was found on (interactive login shell, so nvm and .zshrc additions count) also runs it:
        // npm-installed CLIs need `node` from that PATH.
        let accountEnv = await model.accountsController.launchEnv(for: record.agent, accountID: accountID)
            .merging(EnvPatch(set: ["PATH": OrchestrationLaunch.path(prepending: path)]))
        if record.agent == .claude, let hooks { _ = try? hooks.prepareEventsFile(sessionID: record.id) }
        var spec = AgentLaunchSpecBuilder.make(kind: record.agent, binary: binary, cwd: cwd, env: accountEnv,
                                               initialPrompt: prompt, hooks: record.agent == .claude ? hooks : nil,
                                               sessionID: record.id, resume: resume)
        // Codex can share a background app server; without it (or with a broken install of it) `--no-daemon` runs the
        // session on its own.
        if record.agent == .codex, model.setting(.codexNoDaemon) == "true" { spec.arguments.insert("--no-daemon", at: 0) }
        if usesHost, record.agent == .codex {
            // Codex reports each finished turn through `notify` (`sevinda hook codex-notify`), set for this launch only.
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
        launch.metadata["sevinda.session"] = record.id.uuidString
        launch.metadata["agent"] = record.agent.rawValue
        launch.metadata["sevinda.dataRoot"] = model.dataRoot.path
        return launch
    }

    private func defaultTitle(agent: AgentKind, accountID: UUID?) -> String {
        let name = switch agent {
        case .claude: "Claude"
        case .codex: "Codex"
        case .shell: String(localized: "Shell")
        }
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
    /// first; Codex reports none to Sevinda, so the hint it prints as it exits counts first, and either falls back to
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

    /// Records and reports an exit Sevinda did not cause, once: a session already marked ended (a finished session
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
        if keep {
            // The agents keep working in the host, but only time Sevinda saw is counted; a relaunch that finds them
            // running opens a new interval.
            for runtime in runtimes.values {
                await finishWork(runtime)?.value
                (runtime.terminal.engine as? HostedTerminalEngine)?.detach()
            }
            return
        }
        for id in Array(runtimes.keys) {
            await terminate(id)
            if var record = model.sessions.first(where: { $0.id == id }), record.state != .exited, record.state != .failed {
                record.state = .exited
                record.endedAt = Date()
                await model.upsert(record)
            }
        }
        if usesHost { PTYHostClient.shared.shutdownHostIfIdle() }
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

    /// Posts a notification unless the user is looking at that session right now.
    private func notify(_ record: AgentSessionRecord, _ notice: SessionNotice) {
        guard model.setting(.notifyWhenWaiting) != "false" else { return }
        let context = model.context(of: record)
        guard !model.isShowing(record.id, in: context) else { return }
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
        case .starting: SevindaColor.idle
        case .running: SevindaColor.ok
        case .waitingForInput: SevindaColor.warning
        case .idle: SevindaColor.agent
        case .exited: SevindaColor.idle
        case .failed: SevindaColor.error
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
