import Foundation
import SuijinPTYProtocol
import os

/// Types into a session's PTY on the broker's behalf. Writes through here are not user input.
public protocol OrchestrationSessionIO: AnyObject, Sendable {
    func injectInput(hostSessionID: String, data: Data)
    /// Bytes the session has produced so far, nil for an unknown session.
    func bytesRead(hostSessionID: String) -> UInt64?
    /// Ends the session as closing its tab does (SIGHUP, then SIGKILL); its exit arrives as `sessionExited`.
    func terminateSession(hostSessionID: String)
}

/// The app's side of the broker connection (the XPC proxy in the helper, a fake in tests).
public protocol OrchestrationAppLink: AnyObject, Sendable {
    func startWorker(_ request: WorkerLaunchRequest)
    func stateChanged()
    func attention(_ event: OrchestrationAttention)
    /// Agents answered comments; sent only to an app that called `syncComments`.
    func commentsResolved(_ results: [CommentResult])
}

/// The orchestration broker of one data root.
///
/// Identifies callers by session token, keeps runs, tasks, dispatches and messages in its `DispatchStore`, asks the
/// connected app to start workers, and types each message into its recipient exactly once, when that agent ended its
/// turn and the user is not typing there. All state is confined to `queue` (hence `@unchecked Sendable`).
public final class Broker: @unchecked Sendable {
    public struct Tuning: Sendable {
        /// The user's last keystroke must be at least this old before Suijin types into the session.
        public var inputQuietPeriod: TimeInterval = 3
        /// How long `worker start` waits for the app to report the started worker before answering "starting".
        public var startReplyTimeout: TimeInterval = 45
        /// A Claude session that got a message but showed no `UserPromptSubmit` within this is sent Return once more.
        public var submitConfirmationTimeout: TimeInterval = 6
        public var tickInterval: TimeInterval = 1
        /// A worker's turn end escalates only if it still has not asked or reported this long after: an agent can end
        /// its turn while its last `suijin ask` / `done` is still on the way (Codex returns from a slow command early).
        public var escalationGrace: TimeInterval = 5
        /// Overrides `MessageDelivery.submitDelay` (tests).
        public var submitDelay: TimeInterval?

        public init() {}
    }

    private static let logger = Logger(subsystem: "com.tekmium.suijin.ptyhost", category: "orchestration")

    public let dataRoot: URL
    let queue: DispatchQueue
    private let tuning: Tuning
    private let now: @Sendable () -> Date
    private weak var io: (any OrchestrationSessionIO)?

    // Queue-confined state.
    private var store: DispatchStore
    private var identity = CallerIdentity()
    private var turns = TurnTracker()
    private var app: (any OrchestrationAppLink)?
    private var appID: UUID?
    /// The app connection that synced its comments: it understands comment results and receives them.
    private var commentSyncAppID: UUID?
    private var startReplies: [String: @Sendable (BrokerResponse) -> Void] = [:]
    /// Sessions with a paste typed but Return not yet sent.
    private var submitting: Set<String> = []
    /// Claude sessions whose delivered paste has not been confirmed by `UserPromptSubmit` yet.
    private var awaitingSubmit: [String: Date] = [:]
    /// Coordinator -> questions delivered to it and not answered yet, checked when its turn ends.
    private var deliveredQuestions: [String: Set<String>] = [:]
    private var timer: DispatchSourceTimer?
    private var opened = false
    private var closed = false

    public init(
        dataRoot: URL, stateFile: URL?, io: (any OrchestrationSessionIO)?, tuning: Tuning = Tuning(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
        self.queue = DispatchQueue(label: "com.tekmium.suijin.ptyhost.orchestration")
        self.store = DispatchStore(fileURL: stateFile)
        self.io = io
        self.tuning = tuning
        self.now = now
        turns.inputQuietPeriod = tuning.inputQuietPeriod
    }

    deinit {
        timer?.cancel()
    }

    /// Loads the state. Work left unsettled by an earlier helper process cannot continue (its terminals died with
    /// that process), so it is closed here. Starts the delivery timer when `tick` is true.
    public func open(tick: Bool = true) {
        queue.sync {
            guard !opened else { return }
            opened = true
            store.load()
            let at = now()
            store.update { state in
                for index in state.dispatches.indices where !state.dispatches[index].status.isSettled {
                    state.dispatches[index].status = state.dispatches[index].workerSessionID == nil ? .startFailed : .exited
                    state.dispatches[index].lastError = "Suijin's terminal host restarted, which ended the worker."
                    state.dispatches[index].updatedAt = at
                }
                for index in state.messages.indices where state.messages[index].status == .pending {
                    state.messages[index].status = .undeliverable
                }
            }
            store.prune(now: at)
            guard tick else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + tuning.tickInterval, repeating: tuning.tickInterval)
            timer.setEventHandler { [weak self] in self?.tickLocked() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Stops the broker for good: work already queued finishes (each change is saved as it happens), then the timer
    /// stops, waiting replies are failed and the state file is never written again, so a data root deleted after this
    /// is not recreated. A later session of the same data root gets a new broker that loads the saved state.
    public func close() {
        queue.sync {
            guard !closed else { return }
            closed = true
            timer?.cancel()
            timer = nil
            app = nil
            appID = nil
            commentSyncAppID = nil
            let pending = startReplies.values
            startReplies.removeAll()
            for reply in pending { reply(.failure(Self.closedFailure)) }
            store.stopSaving()
        }
    }

    private static let closedFailure = BrokerFailure(code: "unavailable", message: "Suijin's broker for this data root has closed.")

    public func snapshot() -> OrchestrationSnapshot {
        queue.sync { store.state }
    }

    /// The comment ledger as stored (tests).
    func commentRecords() -> [CommentRecord] {
        queue.sync { store.comments }
    }

    /// Runs `body` on the broker queue and waits (tests, and callers that need ordering).
    func sync<T>(_ body: () -> T) -> T {
        queue.sync(execute: body)
    }

    // MARK: Sessions

    /// A terminal Suijin opened started in the helper. Sessions without a token (other data roots' older builds, a
    /// terminal launched by something else) never get a binding, so they cannot call the broker.
    public func sessionSpawned(hostSessionID: String, sessionID: String, agent: OrchestrationAgent?, token: String) {
        queue.async {
            self.identity.register(
                token: token, binding: SessionBinding(hostSessionID: hostSessionID, sessionID: sessionID, agent: agent))
            self.turns.track(sessionID, now: self.now())
            // A session resumed under the same id owns its comments again: they stay until withdrawn or it ends.
            self.store.updateComments { records in
                for index in records.indices
                where records[index].sessionEnded && CommentLedger.sameSession(records[index].comment.sessionID, sessionID) {
                    records[index].sessionEnded = false
                }
            }
        }
    }

    public func sessionExited(hostSessionID: String, status: Int32) {
        queue.async { self.sessionExitedLocked(hostSessionID: hostSessionID, status: status) }
    }

    /// Keystrokes the user sent to a session through the app.
    public func userInput(hostSessionID: String, data: Data) {
        queue.async {
            guard let binding = self.identity.binding(hostSessionID: hostSessionID) else { return }
            self.turns.userInput(binding.sessionID, data: data, now: self.now())
        }
    }

    // MARK: App

    /// The app connected for this data root; queued worker starts go to it now.
    public func attachApp(_ link: any OrchestrationAppLink, id: UUID) {
        queue.async {
            self.app = link
            self.appID = id
            let queued = self.store.state.dispatches.filter { $0.status == .queued }
            for dispatch in queued { self.sendStartLocked(dispatch) }
            link.stateChanged()
            // The app synced its comments before saying hello.
            self.deliverCommentResultsLocked(self.store.comments.filter(\.awaitsDelivery).compactMap(\.result))
        }
    }

    public func detachApp(id: UUID) {
        queue.async {
            if self.commentSyncAppID == id { self.commentSyncAppID = nil }
            guard self.appID == id else { return }
            self.app = nil
            self.appID = nil
            // A start the app took but never answered may or may not have launched; never start it twice.
            for dispatch in self.store.state.dispatches where dispatch.status == .starting {
                self.startFailedLocked(dispatch.id, error: "Suijin quit before the worker started.")
            }
        }
    }

    public func workerStartFinished(_ result: WorkerLaunchResult) {
        queue.async { self.workerStartFinishedLocked(result) }
    }

    // MARK: Review comments

    /// The app pasted `comments` into their sessions. A comment registered again replaces its entry and forgets the
    /// answer stored for it: it was sent again.
    public func registerComments(_ comments: [PendingComment]) {
        queue.async {
            let incoming = Self.validComments(comments)
            guard !incoming.isEmpty else { return }
            let ids = Set(incoming.map(\.id))
            self.store.updateComments { records in
                records.removeAll { ids.contains($0.comment.id) }
                records.append(contentsOf: incoming.map(CommentRecord.init(comment:)))
            }
        }
    }

    /// The user deleted, reopened or edited these comments: they and any answer to them are forgotten.
    public func withdrawComments(_ ids: [String]) {
        queue.async {
            let withdrawn = Set(ids.map { $0.lowercased() })
            self.store.updateComments { records in records.removeAll { withdrawn.contains($0.comment.id) } }
        }
    }

    /// The app's complete list of comments still waiting for an answer, sent by connection `appID` after `hello`.
    /// Waiting entries the app no longer lists are dropped and missing ones added; answers are kept. That connection
    /// then receives every answer it has not acknowledged, and new ones as they come.
    public func syncComments(_ comments: [PendingComment], appID: UUID) {
        queue.async {
            guard !self.closed else { return }
            let listed = Self.validComments(comments)
            let byID = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            self.store.updateComments { records in
                records = records.compactMap { record in
                    let current = byID[record.comment.id]
                    if let result = record.result {
                        // An answer older than the comment the app lists answered an earlier sending of it (the
                        // user edited and resent it while the link was down): the listed comment waits again.
                        guard let current, result.resolvedAt < current.createdAt else { return record }
                        return CommentRecord(comment: current)
                    }
                    guard let current else { return nil }
                    var updated = record
                    updated.comment = current
                    return updated
                }
                let known = Set(records.map(\.comment.id))
                for comment in listed where !known.contains(comment.id) {
                    records.append(CommentRecord(comment: comment))
                }
            }
            self.commentSyncAppID = appID
            self.deliverCommentResultsLocked(self.store.comments.filter(\.awaitsDelivery).compactMap(\.result))
        }
    }

    /// The app applied (or deliberately ignored) these results. The answer is still remembered, so a second
    /// `resolve` is refused, until the comment is withdrawn or its session has ended.
    public func commentResultsApplied(_ ids: [String]) {
        queue.async {
            let applied = Set(ids.map { $0.lowercased() })
            self.store.updateComments { records in
                for index in records.indices where records[index].result != nil && applied.contains(records[index].comment.id) {
                    records[index].acknowledged = true
                }
                records.removeAll { $0.acknowledged && $0.sessionEnded }
            }
        }
    }

    /// Comments with an id and a session, ids lowercased, the last of each id kept.
    private static func validComments(_ comments: [PendingComment]) -> [PendingComment] {
        var seen: [String: Int] = [:]
        var result: [PendingComment] = []
        for var comment in comments {
            comment.id = comment.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !comment.id.isEmpty, !comment.sessionID.isEmpty else { continue }
            if let index = seen[comment.id] {
                result[index] = comment
            } else {
                seen[comment.id] = result.count
                result.append(comment)
            }
        }
        return result
    }

    private func deliverCommentResultsLocked(_ results: [CommentResult]) {
        guard !results.isEmpty, let app, let appID, appID == commentSyncAppID else { return }
        app.commentsResolved(results)
    }

    private func commentList(_ caller: SessionBinding) -> BrokerResponse {
        let waiting = store.comments
            .filter { $0.result == nil && CommentLedger.sameSession($0.comment.sessionID, caller.sessionID) }
            .map(\.comment)
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        return .success(waiting, text: CommentLedger.listText(waiting))
    }

    /// `caller` is nil for a token no running Suijin session holds; it gets the same answer as an unknown id.
    private func commentResolve(_ caller: SessionBinding?, _ options: [String: String]) -> BrokerResponse {
        let outcome = (options["outcome"] ?? "").lowercased()
        guard CommentLedger.outcomes.contains(outcome) else {
            return .failure(BrokerFailure(code: "invalid_outcome", message: "Say whether you fixed the comment or declined it.",
                                          hint: "suijin comment resolve <id> --fixed --reply \"what you changed\""))
        }
        let typed = options["id"] ?? ""
        guard let caller, let query = CommentLedger.query(typed) else { return .failure(CommentLedger.noSuchComment) }
        let matches = store.comments.filter {
            CommentLedger.sameSession($0.comment.sessionID, caller.sessionID) && CommentLedger.compact($0.comment.id).hasPrefix(query)
        }
        guard matches.count == 1, let record = matches.first else { return .failure(CommentLedger.noSuchComment) }
        if let existing = record.result {
            return .failure(BrokerFailure(code: "already-resolved",
                                          message: "That comment was already reported as \(existing.outcome).",
                                          hint: "Nothing to do. The user can reopen it in Suijin if it needs another look."))
        }
        let result = CommentResult(id: record.comment.id, sessionID: record.comment.sessionID, outcome: outcome,
                                   reply: CommentLedger.sanitizeReply(options["reply"]), resolvedAt: now())
        store.updateComments { records in
            guard let index = records.firstIndex(where: { $0.comment.id == record.comment.id }) else { return }
            records[index].result = result
            records[index].acknowledged = false
        }
        Self.logger.info("comment \(record.comment.id, privacy: .public) reported \(outcome, privacy: .public) by \(caller.sessionID, privacy: .public)")
        deliverCommentResultsLocked([result])
        return .success(result, text: "Marked \(CommentLedger.displayID(typed)) as \(outcome).")
    }

    // MARK: Requests

    /// Answers one CLI request; `reply` runs on the broker queue, possibly later (`worker.start` waits for the app).
    public func handle(_ request: BrokerRequest, reply: @escaping @Sendable (BrokerResponse) -> Void) {
        queue.async { self.handleLocked(request, reply: reply) }
    }

    private func handleLocked(_ request: BrokerRequest, reply: @escaping @Sendable (BrokerResponse) -> Void) {
        guard !closed else {
            reply(.failure(Self.closedFailure))
            return
        }
        guard request.version == BrokerRequest.currentVersion else {
            reply(.failure(BrokerFailure(code: "version_mismatch",
                                         message: "This `suijin` speaks request version \(request.version); Suijin's terminal host speaks \(BrokerRequest.currentVersion).",
                                         hint: "Restart the agent from Suijin after updating.")))
            return
        }
        if request.command == "comment.resolve" {
            // Checked before the caller: a stranger learns no more than a session naming another session's comment.
            reply(commentResolve(identity.caller(token: request.token), request.options))
            return
        }
        guard let caller = identity.caller(token: request.token) else {
            reply(.failure(BrokerFailure(
                code: "unknown_session",
                message: "This terminal was not opened by Suijin (or it already ended), so it cannot use `suijin`.",
                hint: "Run `suijin` from an agent or shell session that Suijin started.")))
            return
        }
        let options = request.options
        switch request.command {
        case "whoami": reply(whoami(caller))
        case "worker.start": workerStart(caller, options, reply: reply)
        case "worker.list": reply(workerList(caller))
        case "worker.stop": reply(workerStop(caller, options))
        case "send": reply(send(caller, options))
        case "ask": reply(ask(caller, options))
        case "reply": reply(answer(caller, options))
        case "done": reply(done(caller, options))
        case "inbox": reply(inbox(caller, options))
        case "hook.claude": reply(claudeHook(caller, options))
        case "hook.codex": reply(codexHook(caller, options))
        case "comment.list": reply(commentList(caller))
        default:
            reply(.failure(BrokerFailure(code: "unknown_command", message: "Unknown command `\(request.command)`.",
                                         hint: "Run `suijin help`.")))
        }
    }

    // MARK: Commands

    private struct WhoAmI: Encodable {
        var sessionID: String
        var role: String
        var dispatchID: String?
        var taskID: String?
    }

    private func whoami(_ caller: SessionBinding) -> BrokerResponse {
        if let dispatch = activeDispatch(worker: caller.sessionID) ?? latestDispatch(worker: caller.sessionID) {
            return .success(WhoAmI(sessionID: caller.sessionID, role: "worker", dispatchID: dispatch.id, taskID: dispatch.taskID),
                            text: "You are worker \"\(dispatch.name)\": dispatch \(dispatch.id), task \(dispatch.taskID).")
        }
        let leads = store.state.dispatches.contains { $0.coordinatorSessionID == caller.sessionID }
        return .success(WhoAmI(sessionID: caller.sessionID, role: leads ? "coordinator" : "none"),
                        text: leads ? "You coordinate workers. Run `suijin worker list`." : "No orchestration yet. Start a worker with `suijin worker start`.")
    }

    private struct DispatchView: Encodable {
        var dispatchID: String
        var taskID: String
        var runID: String
        var name: String
        var agent: String
        var worktree: String
        var status: String
        var summary: String?
        var lastError: String?
        var workerSessionID: String?
        var openQuestions: [String]
        var spec: String
    }

    private func view(_ dispatch: OrchestrationDispatch) -> DispatchView {
        let spec = store.state.tasks.first { $0.id == dispatch.taskID }?.spec ?? ""
        let open = store.state.messages.filter { $0.dispatchID == dispatch.id && $0.kind == .question && $0.answeredBy == nil }
        return DispatchView(dispatchID: dispatch.id, taskID: dispatch.taskID, runID: dispatch.runID, name: dispatch.name,
                            agent: dispatch.agent.rawValue, worktree: dispatch.worktree.rawValue, status: dispatch.status.rawValue,
                            summary: dispatch.summary, lastError: dispatch.lastError, workerSessionID: dispatch.workerSessionID,
                            openQuestions: open.map(\.id), spec: spec)
    }

    private func workerStart(_ caller: SessionBinding, _ options: [String: String],
                             reply: @escaping @Sendable (BrokerResponse) -> Void) {
        let spec = (options["spec"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spec.isEmpty else {
            reply(.failure(BrokerFailure(code: "missing_spec", message: "`worker start` needs a task.",
                                         hint: "suijin worker start --agent codex --spec \"<self-contained task>\"")))
            return
        }
        guard let agent = (options["agent"]?.lowercased()).flatMap(OrchestrationAgent.init(rawValue:)) else {
            reply(.failure(BrokerFailure(code: "invalid_agent", message: "`--agent` must be `claude` or `codex`.",
                                         hint: "suijin worker start --agent codex --spec \"…\"")))
            return
        }
        guard let worktree = WorktreeMode(rawValue: (options["worktree"] ?? "current").lowercased()) else {
            reply(.failure(BrokerFailure(code: "invalid_worktree", message: "`--worktree` must be `current` or `new`.",
                                         hint: "suijin worker start --worktree new --name <short-name> …")))
            return
        }
        let name = Self.workerName(options["name"], spec: spec)
        let at = now()
        let run = store.state.runs.first { $0.coordinatorSessionID == caller.sessionID }
            ?? OrchestrationRun(id: uniqueID("r"), coordinatorSessionID: caller.sessionID, createdAt: at)
        let task = OrchestrationTask(id: uniqueID("t"), runID: run.id, spec: spec, createdAt: at)
        let dispatch = OrchestrationDispatch(
            id: uniqueID("d"), taskID: task.id, runID: run.id, coordinatorSessionID: caller.sessionID, name: name,
            agent: agent, worktree: worktree, accountID: options["account"].flatMap { $0.isEmpty ? nil : $0 },
            status: .queued, createdAt: at, updatedAt: at)
        store.update { state in
            if !state.runs.contains(where: { $0.id == run.id }) { state.runs.append(run) }
            state.tasks.append(task)
            state.dispatches.append(dispatch)
        }
        notifyApp()
        guard app != nil else {
            reply(.success(view(dispatch), text: """
            Queued worker "\(name)" (dispatch \(dispatch.id), task \(task.id)): the Suijin app is not open, so it starts \
            when Suijin opens. End your turn; Suijin wakes you when the worker reports or fails to start.
            """))
            return
        }
        startReplies[dispatch.id] = reply
        sendStartLocked(dispatch)
        queue.asyncAfter(deadline: .now() + tuning.startReplyTimeout) { [weak self] in
            guard let self, let pending = self.startReplies.removeValue(forKey: dispatch.id) else { return }
            let current = self.dispatch(dispatch.id) ?? dispatch
            pending(.success(self.view(current), text: """
            Suijin is still starting worker "\(name)" (dispatch \(dispatch.id)). Do not start it again. End your turn; \
            Suijin wakes you when it reports or if it fails to start.
            """))
        }
    }

    private func sendStartLocked(_ dispatch: OrchestrationDispatch) {
        guard let app, let task = store.state.tasks.first(where: { $0.id == dispatch.taskID }) else { return }
        setStatus(dispatch.id, .starting)
        let prompt = WorkerPreamble.build(taskID: task.id, dispatchID: dispatch.id, name: dispatch.name, spec: task.spec,
                                          followUp: false)
        app.startWorker(WorkerLaunchRequest(
            dispatchID: dispatch.id, coordinatorSessionID: dispatch.coordinatorSessionID, agent: dispatch.agent,
            worktree: dispatch.worktree, name: dispatch.name, accountID: dispatch.accountID, prompt: prompt))
    }

    private func workerStartFinishedLocked(_ result: WorkerLaunchResult) {
        guard let dispatch = dispatch(result.dispatchID), dispatch.status == .starting || dispatch.status == .queued else { return }
        if let sessionID = result.workerSessionID, result.error == nil {
            store.update { state in
                guard let index = state.dispatches.firstIndex(where: { $0.id == dispatch.id }) else { return }
                state.dispatches[index].workerSessionID = sessionID
                state.dispatches[index].status = .running
                state.dispatches[index].updatedAt = now()
            }
            turns.turnStarted(sessionID, now: now()) // it starts on its first prompt
            notifyApp()
            if let pending = startReplies.removeValue(forKey: dispatch.id), let started = self.dispatch(dispatch.id) {
                let place = result.directory.map { " in \($0)" } ?? ""
                pending(.success(view(started), text: """
                Started worker "\(started.name)" (\(started.agent.rawValue), dispatch \(started.id), task \(started.taskID))\(place). \
                Start any other independent workers now, then END YOUR TURN. Do not poll: Suijin types the worker's \
                questions and results into this terminal when they arrive.
                """))
            }
        } else {
            startFailedLocked(dispatch.id, error: result.error ?? "Suijin did not start the worker.")
        }
    }

    private func startFailedLocked(_ dispatchID: String, error: String) {
        guard let dispatch = dispatch(dispatchID) else { return }
        store.update { state in
            guard let index = state.dispatches.firstIndex(where: { $0.id == dispatchID }) else { return }
            state.dispatches[index].status = .startFailed
            state.dispatches[index].lastError = error
            state.dispatches[index].updatedAt = now()
        }
        if let pending = startReplies.removeValue(forKey: dispatchID) {
            pending(.failure(BrokerFailure(code: "start_failed", message: "Worker \"\(dispatch.name)\" could not start: \(error)",
                                           hint: "Fix the cause, then run `suijin worker start` again (dispatch \(dispatchID) is closed).")))
        } else {
            enqueue(kind: .escalation, dispatch: dispatch, from: nil, to: dispatch.coordinatorSessionID,
                    body: Escalation.reasonForStartFailure(error))
        }
        notifyApp()
        pumpLocked()
    }

    private func workerList(_ caller: SessionBinding) -> BrokerResponse {
        let led = store.state.dispatches.filter { $0.coordinatorSessionID == caller.sessionID }
        let own = store.state.dispatches.filter { $0.workerSessionID == caller.sessionID }
        let dispatches = (led.isEmpty ? own : led).sorted { $0.createdAt < $1.createdAt }
        let views = dispatches.map(view)
        guard !views.isEmpty else {
            return .success(views, text: "No workers. Start one with: suijin worker start --agent codex --spec \"<task>\"")
        }
        let lines = views.map { item in
            var line = "\(item.dispatchID)  \(item.name)  \(item.agent)  \(item.status)"
            if !item.openQuestions.isEmpty { line += "  open questions: \(item.openQuestions.joined(separator: ", "))" }
            if let summary = item.summary { line += "\n    summary: \(summary)" }
            if let error = item.lastError { line += "\n    note: \(error)" }
            return line
        }
        return .success(views, text: lines.joined(separator: "\n"))
    }

    /// Ends a worker the caller started: its open dispatch settles as stopped, nothing more is typed into it, and its
    /// terminal ends as closing its tab would. The app sees `stoppedAt` and closes the worker's tab.
    private func workerStop(_ caller: SessionBinding, _ options: [String: String]) -> BrokerResponse {
        let target = OrchestrationID.normalize(options["to"] ?? "")
        guard !target.isEmpty else {
            return .failure(BrokerFailure(code: "missing_target", message: "`worker stop` needs the worker to stop.",
                                          hint: "suijin worker stop --to <dispatch-id or worker name>"))
        }
        let resolved: OrchestrationDispatch
        switch resolveWorker(target, coordinator: caller.sessionID) {
        case .success(let dispatch): resolved = dispatch
        case .failure(let failure): return .failure(failure)
        }
        let ended = BrokerFailure(code: "worker_gone", message: "Worker \"\(resolved.name)\" (\(resolved.id)) already ended.",
                                  hint: "Run `suijin worker list` to see your workers.")
        guard resolved.status != .starting else {
            return .failure(BrokerFailure(code: "worker_starting", message: "Suijin is still starting worker \"\(resolved.name)\".",
                                          hint: "Run `suijin worker stop --to \(resolved.id)` again once it has started."))
        }
        let workerID = resolved.workerSessionID
        let binding = workerID.flatMap { identity.binding(sessionID: $0) }
        if let workerID {
            // A worker whose terminal ended is gone even when a session with its id runs again: the user may have
            // resumed that tab for their own work, and it is no longer the coordinator's to end. `send` draws the
            // same line.
            let last = store.state.dispatches.filter { $0.workerSessionID == workerID }.max { $0.createdAt < $1.createdAt } ?? resolved
            guard binding?.isRunning == true, last.status != .exited, last.status != .startFailed else { return .failure(ended) }
        } else {
            guard resolved.status == .queued else { return .failure(ended) }
        }
        // The worker's dispatches (several after follow-ups) settle; `stoppedAt` goes on the newest, the one the
        // sidebar shows. A worker that already reported keeps its status and summary.
        let dispatches = workerID.map { id in store.state.dispatches.filter { $0.workerSessionID == id } } ?? [resolved]
        let newest = dispatches.max { $0.createdAt < $1.createdAt } ?? resolved
        let ids = Set(dispatches.map(\.id))
        let note = "Stopped by its coordinator."
        let at = now()
        store.update { state in
            for index in state.dispatches.indices where ids.contains(state.dispatches[index].id) {
                if !state.dispatches[index].status.isSettled {
                    // A queued worker never starts now; a started one ended without `done`.
                    state.dispatches[index].status = workerID == nil ? .startFailed : .exited
                    state.dispatches[index].summary = note
                    state.dispatches[index].lastError = note
                    state.dispatches[index].updatedAt = at
                }
                if state.dispatches[index].id == newest.id {
                    state.dispatches[index].stoppedAt = at
                    state.dispatches[index].updatedAt = at
                }
            }
        }
        if let workerID, let binding {
            // Gone from here on: its token stops working and nothing pending is typed into it. Its exit, which follows,
            // escalates nothing because its dispatches are settled.
            _ = identity.markExited(hostSessionID: binding.hostSessionID)
            turns.forget(workerID)
            submitting.remove(workerID)
            awaitingSubmit[workerID] = nil
            store.update { state in
                for index in state.messages.indices
                where state.messages[index].toSessionID == workerID && state.messages[index].status == .pending {
                    state.messages[index].status = .undeliverable
                }
            }
            io?.terminateSession(hostSessionID: binding.hostSessionID)
        }
        notifyApp()
        pumpLocked()
        let stopped = dispatch(newest.id) ?? newest
        let how = workerID == nil ? "it had not started and will not start" : "its terminal is closing"
        return .success(view(stopped), text: "Stopped worker \"\(stopped.name)\" (dispatch \(stopped.id)): \(how). "
                        + "Messages it had not received were dropped.")
    }

    /// A dispatch the coordinator started, by dispatch ID or by worker name (the newest dispatch of that name).
    private func resolveWorker(_ target: String, coordinator: String) -> Result<OrchestrationDispatch, BrokerFailure> {
        if let dispatch = dispatch(target) {
            guard dispatch.coordinatorSessionID == coordinator else {
                return .failure(BrokerFailure(code: "not_coordinator",
                                              message: "Only the coordinator that started dispatch \(dispatch.id) can stop it."))
            }
            return .success(dispatch)
        }
        let named = store.state.dispatches.filter { $0.coordinatorSessionID == coordinator && $0.name == target }
        guard let newest = named.max(by: { $0.createdAt < $1.createdAt }) else {
            return .failure(BrokerFailure(code: "unknown_dispatch", message: "No worker `\(target)` of yours.",
                                          hint: "Run `suijin worker list` for your workers' dispatch IDs and names."))
        }
        return .success(newest)
    }

    private struct Receipt: Encodable {
        var messageID: String
        var dispatchID: String
        var kind: String
        var delivery: String
        var taskID: String?
    }

    private func send(_ caller: SessionBinding, _ options: [String: String]) -> BrokerResponse {
        let target = OrchestrationID.normalize(options["to"] ?? "")
        let body = (options["body"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return .failure(BrokerFailure(code: "missing_body", message: "`send` needs a message.",
                                          hint: "suijin send --to <dispatch-id> --body \"<message>\""))
        }
        guard let dispatch = dispatch(target) else {
            return .failure(BrokerFailure(code: "unknown_dispatch", message: "No dispatch `\(target)`.",
                                          hint: "Run `suijin worker list` for your workers' dispatch IDs."))
        }
        guard dispatch.coordinatorSessionID == caller.sessionID else {
            return .failure(BrokerFailure(code: "not_coordinator", message: "Only the coordinator that started dispatch \(dispatch.id) can send to it.",
                                          hint: activeDispatch(worker: caller.sessionID) != nil
                                            ? "As a worker, use `suijin ask --body …` or `suijin done …`." : nil))
        }
        let gone = BrokerFailure(code: "worker_gone", message: "Worker \"\(dispatch.name)\" (\(dispatch.id)) no longer runs.",
                                 hint: "Start a new worker: suijin worker start --agent \(dispatch.agent.rawValue) --spec \"…\"")
        guard dispatch.status != .exited, dispatch.status != .startFailed else { return .failure(gone) }
        guard let workerID = dispatch.workerSessionID else {
            return .failure(BrokerFailure(code: "worker_starting", message: "Worker \"\(dispatch.name)\" has not started yet.",
                                          hint: "End your turn; send it after it starts, or put the message in its spec."))
        }
        guard identity.binding(sessionID: workerID)?.isRunning == true else { return .failure(gone) }
        if dispatch.status == .succeeded || dispatch.status == .failed {
            // A finished worker takes the message as its next Task.
            let at = now()
            let task = OrchestrationTask(id: uniqueID("t"), runID: dispatch.runID, spec: body, followUpOf: dispatch.taskID, createdAt: at)
            let followUp = OrchestrationDispatch(
                id: uniqueID("d"), taskID: task.id, runID: dispatch.runID, coordinatorSessionID: dispatch.coordinatorSessionID,
                workerSessionID: workerID, name: dispatch.name, agent: dispatch.agent, worktree: dispatch.worktree,
                accountID: dispatch.accountID, status: .running, createdAt: at, updatedAt: at)
            store.update { state in
                state.tasks.append(task)
                state.dispatches.append(followUp)
            }
            let message = enqueue(kind: .send, dispatch: followUp, from: caller.sessionID, to: workerID, body: body,
                                  followUpTaskID: task.id)
            notifyApp()
            pumpLocked()
            return .success(Receipt(messageID: message.id, dispatchID: followUp.id, kind: "send", delivery: "follow_up", taskID: task.id),
                            text: "Worker \"\(dispatch.name)\" had finished; it gets this as follow-up task \(task.id) (dispatch \(followUp.id)). End your turn; Suijin wakes you when it reports.")
        }
        let message = enqueue(kind: .send, dispatch: dispatch, from: caller.sessionID, to: workerID, body: body)
        pumpLocked()
        return .success(Receipt(messageID: message.id, dispatchID: dispatch.id, kind: "send", delivery: deliveryState(message.id)),
                        text: "Message \(message.id) for worker \"\(dispatch.name)\": it gets it when its current turn ends. End your turn.")
    }

    private func ask(_ caller: SessionBinding, _ options: [String: String]) -> BrokerResponse {
        let body = (options["body"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return .failure(BrokerFailure(code: "missing_body", message: "`ask` needs a question.", hint: "suijin ask --body \"<question>\""))
        }
        guard let dispatch = activeDispatch(worker: caller.sessionID) else { return notWorker(caller) }
        let message = enqueue(kind: .question, dispatch: dispatch, from: caller.sessionID, to: dispatch.coordinatorSessionID, body: body)
        setStatus(dispatch.id, .asking)
        notifyApp()
        pumpLocked()
        return .success(Receipt(messageID: message.id, dispatchID: dispatch.id, kind: "question", delivery: deliveryState(message.id)),
                        text: "Question \(message.id) sent to your coordinator. END YOUR TURN now; Suijin types the answer here.")
    }

    private func answer(_ caller: SessionBinding, _ options: [String: String]) -> BrokerResponse {
        let questionID = OrchestrationID.normalize(options["id"] ?? "")
        let body = (options["body"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return .failure(BrokerFailure(code: "missing_body", message: "`reply` needs an answer.",
                                          hint: "suijin reply --id <question-id> --body \"<answer>\""))
        }
        guard let question = store.state.messages.first(where: { $0.id == questionID && $0.kind == .question }) else {
            return .failure(BrokerFailure(code: "unknown_question", message: "No question `\(questionID)`.",
                                          hint: "Run `suijin inbox` for the questions sent to you."))
        }
        guard question.toSessionID == caller.sessionID, let dispatch = dispatch(question.dispatchID) else {
            return .failure(BrokerFailure(code: "not_coordinator", message: "Question \(questionID) was not sent to you."))
        }
        guard question.answeredBy == nil else {
            return .failure(BrokerFailure(code: "already_answered", message: "Question \(questionID) already has a reply (\(question.answeredBy ?? "")).",
                                          hint: "To add something, use: suijin send --to \(dispatch.id) --body \"…\""))
        }
        guard let workerID = dispatch.workerSessionID, identity.binding(sessionID: workerID)?.isRunning == true else {
            return .failure(BrokerFailure(code: "worker_gone", message: "Worker \"\(dispatch.name)\" no longer runs."))
        }
        let message = enqueue(kind: .reply, dispatch: dispatch, from: caller.sessionID, to: workerID, body: body, inReplyTo: question.id)
        store.update { state in
            if let index = state.messages.firstIndex(where: { $0.id == question.id }) { state.messages[index].answeredBy = message.id }
        }
        deliveredQuestions[caller.sessionID]?.remove(question.id)
        if dispatch.status == .asking, openQuestions(dispatch.id).isEmpty { setStatus(dispatch.id, .running) }
        notifyApp()
        pumpLocked()
        return .success(Receipt(messageID: message.id, dispatchID: dispatch.id, kind: "reply", delivery: deliveryState(message.id)),
                        text: "Reply \(message.id) sent; worker \"\(dispatch.name)\" gets it when its turn ends. End your turn.")
    }

    private func done(_ caller: SessionBinding, _ options: [String: String]) -> BrokerResponse {
        let status: DispatchStatus
        switch (options["status"] ?? "").lowercased() {
        case "success", "succeeded", "ok": status = .succeeded
        case "failed", "failure", "fail": status = .failed
        default:
            return .failure(BrokerFailure(code: "invalid_status", message: "`--status` must be `success` or `failed`.",
                                          hint: "suijin done --status success --summary \"…\""))
        }
        let summary = (options["summary"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            return .failure(BrokerFailure(code: "missing_summary", message: "`done` needs a summary.",
                                          hint: "suijin done --status success --summary \"<what you did, found, left>\""))
        }
        guard let dispatch = activeDispatch(worker: caller.sessionID) else { return notWorker(caller) }
        store.update { state in
            guard let index = state.dispatches.firstIndex(where: { $0.id == dispatch.id }) else { return }
            state.dispatches[index].status = status
            state.dispatches[index].summary = summary
            state.dispatches[index].updatedAt = now()
        }
        let message = enqueue(kind: .done, dispatch: dispatch, from: caller.sessionID, to: dispatch.coordinatorSessionID, body: summary)
        notifyApp()
        pumpLocked()
        return .success(Receipt(messageID: message.id, dispatchID: dispatch.id, kind: "done", delivery: deliveryState(message.id)),
                        text: "Reported \(status == .succeeded ? "success" : "failure") to your coordinator. End your turn now.")
    }

    private func notWorker(_ caller: SessionBinding) -> BrokerResponse {
        if let finished = latestDispatch(worker: caller.sessionID) {
            return .failure(BrokerFailure(code: "already_done", message: "Dispatch \(finished.id) is already \(finished.status.rawValue); nothing is open.",
                                          hint: "End your turn. Your coordinator can send you a follow-up task."))
        }
        return .failure(BrokerFailure(code: "not_worker", message: "This session is not a worker, so it has no coordinator to ask or report to.",
                                      hint: "To delegate work, run: suijin worker start --agent codex --spec \"<task>\""))
    }

    private struct InboxItem: Encodable {
        var messageID: String
        var dispatchID: String
        var kind: String
        var direction: String
        var status: String
        var body: String
        var inReplyTo: String?
        var answeredBy: String?
        var createdAt: Date
    }

    private func inbox(_ caller: SessionBinding, _ options: [String: String]) -> BrokerResponse {
        let limit = options["all"] == "true" ? Int.max : max(1, Int(options["limit"] ?? "") ?? 20)
        let mine = store.state.messages
            .filter { $0.toSessionID == caller.sessionID || $0.fromSessionID == caller.sessionID }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
        let items = mine.map { message in
            InboxItem(messageID: message.id, dispatchID: message.dispatchID, kind: message.kind.rawValue,
                      direction: message.toSessionID == caller.sessionID ? "in" : "out", status: message.status.rawValue,
                      body: message.body, inReplyTo: message.inReplyTo, answeredBy: message.answeredBy, createdAt: message.createdAt)
        }
        guard !items.isEmpty else { return .success(items, text: "No messages.") }
        let text = items.map { item in
            let arrow = item.direction == "in" ? "←" : "→"
            let answered = item.kind == "question" ? (item.answeredBy == nil ? " (unanswered)" : " (answered by \(item.answeredBy ?? ""))") : ""
            return "\(arrow) \(item.messageID) \(item.kind) \(item.dispatchID) [\(item.status)]\(answered)\n    \(item.body.replacingOccurrences(of: "\n", with: "\n    "))"
        }.joined(separator: "\n")
        return .success(items, text: text)
    }

    private struct Ack: Encodable { var accepted: Bool }

    private func claudeHook(_ caller: SessionBinding, _ options: [String: String]) -> BrokerResponse {
        let at = now()
        switch options["event"] ?? "" {
        case "UserPromptSubmit":
            turns.turnStarted(caller.sessionID, now: at)
            awaitingSubmit[caller.sessionID] = nil
        case "Stop":
            turnEndedLocked(caller.sessionID)
        case "Notification":
            let type = options["notificationType"] ?? ""
            let message = options["message"] ?? ""
            if type == "permission_prompt" || (type.isEmpty && message.localizedCaseInsensitiveContains("permission")) {
                turns.blocked(caller.sessionID, now: at)
                if leadsWorkers(caller.sessionID) {
                    attention(caller.sessionID, kind: .permission,
                              body: message.isEmpty ? "Your coordinating agent waits for you to approve an action." : message)
                }
            } else if type == "idle_prompt" || (type.isEmpty && message.localizedCaseInsensitiveContains("waiting for your input")) {
                turnEndedLocked(caller.sessionID)
            }
        default:
            break
        }
        return .success(Ack(accepted: true), text: "")
    }

    private func codexHook(_ caller: SessionBinding, _ options: [String: String]) -> BrokerResponse {
        if options["type"] == "agent-turn-complete" { turnEndedLocked(caller.sessionID) }
        return .success(Ack(accepted: true), text: "")
    }

    // MARK: Turns and delivery

    private func turnEndedLocked(_ sessionID: String) {
        turns.turnEnded(sessionID, now: now())
        awaitingSubmit[sessionID] = nil
        if let dispatch = activeDispatch(worker: sessionID), Escalation.reasonForTurnEnd(dispatch) != nil {
            let endedAt = turns.state(sessionID)?.phaseSince
            queue.asyncAfter(deadline: .now() + tuning.escalationGrace) { [weak self] in
                self?.escalateIfStillStalled(dispatchID: dispatch.id, worker: sessionID, turnEndedAt: endedAt)
            }
        }
        // A coordinator that ends its turn with a delivered question still unanswered is asking the user.
        if let questions = deliveredQuestions.removeValue(forKey: sessionID) {
            let open = store.state.messages.filter { questions.contains($0.id) && $0.answeredBy == nil }
            if let first = open.first {
                let worker = dispatch(first.dispatchID)?.name ?? "A worker"
                attention(sessionID, kind: .decision, body: "\(worker) asked: \(first.body.prefix(160))")
            }
        }
        pumpLocked()
    }

    /// The worker ended a turn a while ago and is still idle in that same turn end, without asking or reporting.
    private func escalateIfStillStalled(dispatchID: String, worker sessionID: String, turnEndedAt: Date?) {
        guard let dispatch = dispatch(dispatchID), let reason = Escalation.reasonForTurnEnd(dispatch),
              identity.binding(sessionID: sessionID)?.isRunning == true,
              turns.phase(sessionID) == .idle, turns.state(sessionID)?.phaseSince == turnEndedAt,
              !hasPendingMessages(to: sessionID) else { return }
        setStatus(dispatch.id, .stalled)
        enqueue(kind: .escalation, dispatch: dispatch, from: nil, to: dispatch.coordinatorSessionID, body: reason)
        notifyApp()
        pumpLocked()
    }

    private func sessionExitedLocked(hostSessionID: String, status: Int32) {
        guard let binding = identity.markExited(hostSessionID: hostSessionID) else { return }
        turns.forget(binding.sessionID)
        submitting.remove(binding.sessionID)
        awaitingSubmit[binding.sessionID] = nil
        let at = now()
        for dispatch in store.state.dispatches where dispatch.workerSessionID == binding.sessionID {
            guard let reason = Escalation.reasonForExit(dispatch, status: status) else { continue }
            store.update { state in
                guard let index = state.dispatches.firstIndex(where: { $0.id == dispatch.id }) else { return }
                state.dispatches[index].status = .exited
                state.dispatches[index].lastError = reason
                state.dispatches[index].updatedAt = at
            }
            enqueue(kind: .escalation, dispatch: dispatch, from: nil, to: dispatch.coordinatorSessionID, body: reason)
        }
        store.update { state in
            for index in state.messages.indices
            where state.messages[index].toSessionID == binding.sessionID && state.messages[index].status == .pending {
                state.messages[index].status = .undeliverable
            }
        }
        // Nobody can answer the session's waiting comments now; answers the app has not applied yet stay for it.
        store.updateComments { records in
            records.removeAll { CommentLedger.sameSession($0.comment.sessionID, binding.sessionID) && !$0.awaitsDelivery }
            for index in records.indices where CommentLedger.sameSession(records[index].comment.sessionID, binding.sessionID) {
                records[index].sessionEnded = true
            }
        }
        notifyApp()
        pumpLocked()
    }

    /// Runs every tick: expires unconfirmed busy states, re-sends an unconfirmed Return, delivers.
    private func tickLocked() {
        let at = now()
        for (sessionID, binding) in identity.sessions where binding.isRunning {
            if let bytes = io?.bytesRead(hostSessionID: binding.hostSessionID) {
                turns.observeOutput(sessionID, bytesRead: bytes, now: at)
            }
        }
        for (sessionID, deadline) in awaitingSubmit where deadline <= at {
            awaitingSubmit[sessionID] = nil
            guard turns.phase(sessionID) == .busy, let binding = identity.binding(sessionID: sessionID), binding.isRunning else { continue }
            Self.logger.info("delivery to \(sessionID, privacy: .public) not confirmed; pressing Return again")
            io?.injectInput(hostSessionID: binding.hostSessionID, data: MessageDelivery.submit)
        }
        pumpLocked()
    }

    /// Exposed for tests: one delivery pass.
    func pump() {
        queue.sync { pumpLocked() }
    }

    func tick() {
        queue.sync { tickLocked() }
    }

    private func pumpLocked() {
        let pending = store.state.messages.filter { $0.status == .pending }
        let recipients = Set(pending.map(\.toSessionID))
        for recipient in recipients.sorted() {
            deliverLocked(to: recipient, messages: pending.filter { $0.toSessionID == recipient }.sorted { $0.createdAt < $1.createdAt })
        }
    }

    private func deliverLocked(to recipient: String, messages: [OrchestrationMessage]) {
        guard !messages.isEmpty, !submitting.contains(recipient),
              let binding = identity.binding(sessionID: recipient), binding.isRunning,
              binding.agent != nil, // a shell has no turns; its messages wait in `suijin inbox`
              turns.readiness(recipient, now: now()) == .ready,
              let io
        else { return }
        let text = MessageDelivery.compose(messages, recipient: recipient, state: store.state)
        let ids = Set(messages.map(\.id))
        let at = now()
        // Marked delivered before typing: a crash in between loses the paste (the message stays in the inbox) rather
        // than typing it twice.
        store.update { state in
            for index in state.messages.indices where ids.contains(state.messages[index].id) {
                state.messages[index].status = .delivered
                state.messages[index].deliveredAt = at
            }
            for message in messages where message.kind == .reply || message.kind == .send {
                if let index = state.dispatches.firstIndex(where: { $0.id == message.dispatchID }),
                   state.dispatches[index].status == .stalled {
                    state.dispatches[index].status = .running
                    state.dispatches[index].updatedAt = at
                }
            }
        }
        let questions = messages.filter { $0.kind == .question }.map(\.id)
        if !questions.isEmpty { deliveredQuestions[recipient, default: []].formUnion(questions) }
        turns.delivered(recipient, now: at)
        submitting.insert(recipient)
        let paste = MessageDelivery.pastePayload(text)
        io.injectInput(hostSessionID: binding.hostSessionID, data: paste)
        let delay = tuning.submitDelay ?? MessageDelivery.submitDelay(forPasteBytes: paste.count)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.submitting.remove(recipient)
            guard let current = self.identity.binding(sessionID: recipient), current.isRunning else { return }
            self.io?.injectInput(hostSessionID: current.hostSessionID, data: MessageDelivery.submit)
            if current.agent == .claude {
                self.awaitingSubmit[recipient] = self.now().addingTimeInterval(self.tuning.submitConfirmationTimeout)
            }
        }
        Self.logger.info("delivered \(messages.count) message(s) to \(recipient, privacy: .public)")
        notifyApp()
    }

    // MARK: Helpers

    @discardableResult
    private func enqueue(kind: MessageKind, dispatch: OrchestrationDispatch, from: String?, to: String, body: String,
                         inReplyTo: String? = nil, followUpTaskID: String? = nil) -> OrchestrationMessage {
        let message = OrchestrationMessage(
            id: uniqueID("m"), runID: dispatch.runID, dispatchID: dispatch.id, kind: kind, fromSessionID: from,
            toSessionID: to, body: body, inReplyTo: inReplyTo, followUpTaskID: followUpTaskID, createdAt: now())
        store.update { $0.messages.append(message) }
        return message
    }

    private func deliveryState(_ messageID: String) -> String {
        store.state.messages.first { $0.id == messageID }?.status == .delivered ? "delivered" : "queued_until_turn_end"
    }

    private func dispatch(_ id: String) -> OrchestrationDispatch? {
        store.state.dispatches.first { $0.id == id }
    }

    /// The worker's open dispatch (the newest unsettled one).
    private func activeDispatch(worker sessionID: String) -> OrchestrationDispatch? {
        store.state.dispatches.filter { $0.workerSessionID == sessionID && !$0.status.isSettled }.max { $0.createdAt < $1.createdAt }
    }

    private func latestDispatch(worker sessionID: String) -> OrchestrationDispatch? {
        store.state.dispatches.filter { $0.workerSessionID == sessionID }.max { $0.createdAt < $1.createdAt }
    }

    private func leadsWorkers(_ sessionID: String) -> Bool {
        store.state.dispatches.contains { $0.coordinatorSessionID == sessionID && !$0.status.isSettled }
    }

    private func openQuestions(_ dispatchID: String) -> [OrchestrationMessage] {
        store.state.messages.filter { $0.dispatchID == dispatchID && $0.kind == .question && $0.answeredBy == nil }
    }

    private func hasPendingMessages(to sessionID: String) -> Bool {
        store.state.messages.contains { $0.toSessionID == sessionID && $0.status == .pending }
    }

    private func setStatus(_ dispatchID: String, _ status: DispatchStatus) {
        store.update { state in
            guard let index = state.dispatches.firstIndex(where: { $0.id == dispatchID }) else { return }
            state.dispatches[index].status = status
            state.dispatches[index].updatedAt = now()
        }
    }

    private func uniqueID(_ prefix: String) -> String {
        let state = store.state
        while true {
            let id = OrchestrationID.make(prefix)
            let taken = state.runs.contains { $0.id == id } || state.tasks.contains { $0.id == id }
                || state.dispatches.contains { $0.id == id } || state.messages.contains { $0.id == id }
            if !taken { return id }
        }
    }

    private func notifyApp() {
        app?.stateChanged()
    }

    private func attention(_ sessionID: String, kind: OrchestrationAttention.Kind, body: String) {
        app?.attention(OrchestrationAttention(sessionID: sessionID, kind: kind, body: body))
    }

    /// `--name`, or the first words of the spec: lowercase letters, digits and dashes, at most 32 characters.
    static func workerName(_ requested: String?, spec: String) -> String {
        let source = requested.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ?? spec.split(whereSeparator: { $0.isWhitespace }).prefix(4).joined(separator: "-")
        var slug = ""
        for character in source.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(character)
            } else if !slug.hasSuffix("-"), !slug.isEmpty {
                slug.append("-")
            }
        }
        let trimmed = String(slug.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "worker" : trimmed
    }
}
