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
import UserNotifications

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
    /// True from launch until the sessions that kept running in the PTY host are attached again.
    private(set) var isRestoring = true
    /// Sessions whose screen is not ready yet: attaching to the host or replaying their scrollback.
    private(set) var reconnecting: Set<UUID> = []
    /// Why sessions do not survive quitting, when the PTY host is unavailable.
    private(set) var hostProblem: String?
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
            if session.agent == .shell, !live.isTerminal { return .running }
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
        Task { await requestNotificationPermission() }
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
            if session.agent == .claude, let hooks {
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
        var record = AgentSessionRecord(id: id, workspaceID: workspaceID, worktreeID: worktreeID, agent: agent,
                                        accountID: accountID, title: title, cwd: cwd.path)
        do {
            let launch = try await makeLaunch(record: record, cwd: cwd, accountID: accountID, prompt: prompt)
            let engine: any TerminalEngine = usesHost ? HostedTerminalEngine(client: .shared) : SwiftTermEngine()
            let runtime = makeRuntime(id: id, agent: agent, engine: engine)
            if agent == .claude, let hooks {
                startWatching(runtime, file: hooks.eventsFile(sessionID: id), readExisting: true)
            }
            try await runtime.terminal.start(launch)
            record.hostSessionID = engine.sessionID
            record.state = runtime.terminal.hasExited ? .exited : .running
            await model.upsert(record)
            await countStart(of: agent)
            if select {
                model.selection = context
                model.selectedTab[context] = .session(id)
            }
            return id
        } catch {
            runtimes[id]?.watcher?.stop()
            runtimes[id] = nil
            activities[id] = nil
            if let hooks { try? FileManager.default.removeItem(at: hooks.eventsFile(sessionID: id)) }
            model.presentedError = PresentedError(title: String(localized: "Could not start \(title)"),
                                                  message: error.localizedDescription)
            return nil
        }
    }

    func makeLaunch(record: AgentSessionRecord, cwd: URL, accountID: UUID?, prompt: String?) async throws -> TerminalLaunch {
        var base = ["SEVINDA_DATA_ROOT": model.dataRoot.path, "SEVINDA_SESSION_ID": record.id.uuidString]
        // Orchestration: the session token (only ever in this environment, never in arguments) and the broker's
        // addresses. Only hosted sessions get them: the broker lives in the PTY host.
        if usesHost { base.merge(OrchestrationLaunch.environment(dataRoot: model.dataRoot)) { _, new in new } }
        guard record.agent != .shell else {
            // `sevinda` on the shell's PATH; the profile may reorder PATH but keeps entries it did not set.
            base["PATH"] = OrchestrationLaunch.path(prepending: ProcessInfo.processInfo.environment["PATH"])
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
                                               sessionID: record.id)
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
        activities[id] = runtime.tracker.activity
        runtime.tracker.onChange = { [weak self, weak runtime] activity in
            if let runtime { self?.trackWork(runtime, activity) }
            self?.activityChanged(id, activity)
        }
        let view = terminal.view
        view.onReplayChange = { [weak self] replaying in
            if replaying { self?.reconnecting.insert(id) } else { self?.reconnecting.remove(id) }
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
            guard runtime?.isEnding != true else { return }
            Task { await self?.sessionExited(id, code: code) }
        }
        return runtime
    }

    private func startWatching(_ runtime: SessionRuntime, file: URL, readExisting: Bool) {
        let watcher = HookEventWatcher(fileURL: file, readExisting: readExisting) { [weak runtime] events in
            Task { @MainActor in
                for event in events { runtime?.tracker.noteHookEvent(event) }
            }
        }
        watcher.start()
        runtime.watcher = watcher
    }

    // MARK: Status

    private func tick() {
        let now = Date()
        for runtime in runtimes.values { runtime.tracker.tick(now: now) }
    }

    private func activityChanged(_ id: UUID, _ activity: AgentActivity) {
        let previous = activities[id]
        activities[id] = activity
        guard previous != activity, let record = model.sessions.first(where: { $0.id == id }), record.agent != .shell else { return }
        switch activity {
        case .waitingForInput:
            notify(record, body: String(localized: "Waiting for your input"))
        case .idle where previous == .running:
            notify(record, body: String(localized: "Finished its turn"))
        default:
            break
        }
    }

    /// Records and reports an exit Sevinda did not cause, once: a session already marked ended (a finished session
    /// re-attached after a relaunch) stays as it is and notifies nobody.
    private func sessionExited(_ id: UUID, code: Int32?) async {
        guard var record = model.sessions.first(where: { $0.id == id }),
              record.state != .exited, record.state != .failed else { return }
        record.state = (code ?? 0) == 0 ? .exited : .failed
        record.exitCode = code
        record.endedAt = Date()
        await model.upsert(record)
        if record.agent != .shell {
            notify(record, body: (code ?? 0) == 0 ? String(localized: "Exited") : String(localized: "Exited with code \(code ?? -1)"))
        }
    }

    // MARK: End

    /// Ends the session's process (SIGHUP, then SIGKILL) and drops its runtime.
    func terminate(_ id: UUID) async {
        guard let runtime = runtimes[id] else { return }
        runtime.isEnding = true
        await finishWork(runtime)?.value
        runtime.watcher?.stop()
        await runtime.terminal.terminate()
        runtime.terminal.view.removeHandlers()
        runtimes[id] = nil
        activities[id] = nil
        titles[id] = nil
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
        guard runtime.agent != .shell else { return nil }
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

    private func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// Posts a notification unless the user is looking at that session right now.
    private func notify(_ record: AgentSessionRecord, body: String) {
        guard model.setting(.notifyWhenWaiting) != "false" else { return }
        let context = model.context(of: record)
        guard !model.isShowing(record.id, in: context) else { return }
        let content = UNMutableNotificationContent()
        let place = model.worktree(record.worktreeID ?? UUID())?.branch ?? model.workspace(record.workspaceID)?.name ?? ""
        content.title = place.isEmpty ? record.title : "\(record.title) — \(place)"
        content.body = body
        content.sound = .default
        content.userInfo = ["session": record.id.uuidString]
        // One notification per session: a newer state replaces the older banner instead of stacking.
        let request = UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
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
