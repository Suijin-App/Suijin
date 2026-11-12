import Foundation
import SevindaPTYProtocol
import os

/// Types into a session's PTY on the broker's behalf. Writes through here are not user input.
public protocol OrchestrationSessionIO: AnyObject, Sendable {
    func injectInput(hostSessionID: String, data: Data)
    /// Bytes the session has produced so far, nil for an unknown session.
    func bytesRead(hostSessionID: String) -> UInt64?
}

/// The app's side of the broker connection (the XPC proxy in the helper, a fake in tests).
public protocol OrchestrationAppLink: AnyObject, Sendable {
    func startWorker(_ request: WorkerLaunchRequest)
    func stateChanged()
    func attention(_ event: OrchestrationAttention)
}

/// The orchestration broker of one data root.
///
/// Identifies callers by session token, keeps runs, tasks, dispatches and messages in its `DispatchStore`, asks the
/// connected app to start workers, and types each message into its recipient exactly once, when that agent ended its
/// turn and the user is not typing there. All state is confined to `queue` (hence `@unchecked Sendable`).
public final class Broker: @unchecked Sendable {
    public struct Tuning: Sendable {
        /// The user's last keystroke must be at least this old before Mercury types into the session.
        public var inputQuietPeriod: TimeInterval = 3
        /// How long `worker start` waits for the app to report the started worker before answering "starting".
        public var startReplyTimeout: TimeInterval = 45
        /// A Claude session that got a message but showed no `UserPromptSubmit` within this is sent Return once more.
        public var submitConfirmationTimeout: TimeInterval = 6
        public var tickInterval: TimeInterval = 1
        /// A worker's turn end escalates only if it still has not asked or reported this long after: an agent can end
        /// its turn while its last `mercury ask` / `done` is still on the way (Codex returns from a slow command early).
        public var escalationGrace: TimeInterval = 5
        /// Overrides `MessageDelivery.submitDelay` (tests).
        public var submitDelay: TimeInterval?

        public init() {}
    }

    private static let logger = Logger(subsystem: "com.tekmium.mercury.ptyhost", category: "orchestration")

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
        self.queue = DispatchQueue(label: "com.tekmium.mercury.ptyhost.orchestration")
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
                    state.dispatches[index].lastError = "Mercury's terminal host restarted, which ended the worker."
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
            let pending = startReplies.values
            startReplies.removeAll()
            for reply in pending { reply(.failure(Self.closedFailure)) }
            store.stopSaving()
        }
    }

    private static let closedFailure = BrokerFailure(code: "unavailable", message: "Mercury's broker for this data root has closed.")

    public func snapshot() -> OrchestrationSnapshot {
        queue.sync { store.state }
    }

    /// Runs `body` on the broker queue and waits (tests, and callers that need ordering).
    func sync<T>(_ body: () -> T) -> T {
        queue.sync(execute: body)
    }

    // MARK: Sessions

    /// A terminal Mercury opened started in the helper. Sessions without a token (other data roots' older builds, a
    /// terminal launched by something else) never get a binding, so they cannot call the broker.
    public func sessionSpawned(hostSessionID: String, sessionID: String, agent: OrchestrationAgent?, token: String) {
        queue.async {
            self.identity.register(
                token: token, binding: SessionBinding(hostSessionID: hostSessionID, sessionID: sessionID, agent: agent))
            self.turns.track(sessionID, now: self.now())
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
        }
    }

    public func detachApp(id: UUID) {
        queue.async {
            guard self.appID == id else { return }
            self.app = nil
            self.appID = nil
            // A start the app took but never answered may or may not have launched; never start it twice.
            for dispatch in self.store.state.dispatches where dispatch.status == .starting {
                self.startFailedLocked(dispatch.id, error: "Mercury quit before the worker started.")
            }
        }
    }

    public func workerStartFinished(_ result: WorkerLaunchResult) {
        queue.async { self.workerStartFinishedLocked(result) }
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
                                         message: "This `mercury` speaks request version \(request.version); Mercury's terminal host speaks \(BrokerRequest.currentVersion).",
                                         hint: "Restart the agent from Mercury after updating.")))
            return
        }
        guard let caller = identity.caller(token: request.token) else {
            reply(.failure(BrokerFailure(
                code: "unknown_session",
                message: "This terminal was not opened by Mercury (or it already ended), so it cannot use `mercury`.",
                hint: "Run `mercury` from an agent or shell session that Mercury started.")))
            return
        }
        let options = request.options
        switch request.command {
        case "whoami": reply(whoami(caller))
        case "worker.start": workerStart(caller, options, reply: reply)
        case "worker.list": reply(workerList(caller))
        case "send": reply(send(caller, options))
        case "ask": reply(ask(caller, options))
        case "reply": reply(answer(caller, options))
        case "done": reply(done(caller, options))
        case "inbox": reply(inbox(caller, options))
        case "hook.claude": reply(claudeHook(caller, options))
        case "hook.codex": reply(codexHook(caller, options))
        default:
            reply(.failure(BrokerFailure(code: "unknown_command", message: "Unknown command `\(request.command)`.",
                                         hint: "Run `mercury help`.")))
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
                        text: leads ? "You coordinate workers. Run `mercury worker list`." : "No orchestration yet. Start a worker with `mercury worker start`.")
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
                                         hint: "mercury worker start --agent codex --spec \"<self-contained task>\"")))
            return
        }
        guard let agent = (options["agent"]?.lowercased()).flatMap(OrchestrationAgent.init(rawValue:)) else {
            reply(.failure(BrokerFailure(code: "invalid_agent", message: "`--agent` must be `claude` or `codex`.",
                                         hint: "mercury worker start --agent codex --spec \"…\"")))
            return
        }
        guard let worktree = WorktreeMode(rawValue: (options["worktree"] ?? "current").lowercased()) else {
            reply(.failure(BrokerFailure(code: "invalid_worktree", message: "`--worktree` must be `current` or `new`.",
                                         hint: "mercury worker start --worktree new --name <short-name> …")))
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
            Queued worker "\(name)" (dispatch \(dispatch.id), task \(task.id)): the Mercury app is not open, so it starts \
            when Mercury opens. End your turn; Mercury wakes you when the worker reports or fails to start.
            """))
            return
        }
        startReplies[dispatch.id] = reply
        sendStartLocked(dispatch)
        queue.asyncAfter(deadline: .now() + tuning.startReplyTimeout) { [weak self] in
            guard let self, let pending = self.startReplies.removeValue(forKey: dispatch.id) else { return }
            let current = self.dispatch(dispatch.id) ?? dispatch
            pending(.success(self.view(current), text: """
            Mercury is still starting worker "\(name)" (dispatch \(dispatch.id)). Do not start it again. End your turn; \
            Mercury wakes you when it reports or if it fails to start.
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
                Start any other independent workers now, then END YOUR TURN. Do not poll: Mercury types the worker's \
                questions and results into this terminal when they arrive.
                """))
            }
        } else {
            startFailedLocked(dispatch.id, error: result.error ?? "Mercury did not start the worker.")
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
                                           hint: "Fix the cause, then run `mercury worker start` again (dispatch \(dispatchID) is closed).")))
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
            return .success(views, text: "No workers. Start one with: mercury worker start --agent codex --spec \"<task>\"")
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
                                          hint: "mercury send --to <dispatch-id> --body \"<message>\""))
        }
        guard let dispatch = dispatch(target) else {
            return .failure(BrokerFailure(code: "unknown_dispatch", message: "No dispatch `\(target)`.",
                                          hint: "Run `mercury worker list` for your workers' dispatch IDs."))
        }
        guard dispatch.coordinatorSessionID == caller.sessionID else {
            return .failure(BrokerFailure(code: "not_coordinator", message: "Only the coordinator that started dispatch \(dispatch.id) can send to it.",
                                          hint: activeDispatch(worker: caller.sessionID) != nil
                                            ? "As a worker, use `mercury ask --body …` or `mercury done …`." : nil))
        }
        let gone = BrokerFailure(code: "worker_gone", message: "Worker \"\(dispatch.name)\" (\(dispatch.id)) no longer runs.",
                                 hint: "Start a new worker: mercury worker start --agent \(dispatch.agent.rawValue) --spec \"…\"")
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
                            text: "Worker \"\(dispatch.name)\" had finished; it gets this as follow-up task \(task.id) (dispatch \(followUp.id)). End your turn; Mercury wakes you when it reports.")
        }
        let message = enqueue(kind: .send, dispatch: dispatch, from: caller.sessionID, to: workerID, body: body)
        pumpLocked()
        return .success(Receipt(messageID: message.id, dispatchID: dispatch.id, kind: "send", delivery: deliveryState(message.id)),
                        text: "Message \(message.id) for worker \"\(dispatch.name)\": it gets it when its current turn ends. End your turn.")
    }

    private func ask(_ caller: SessionBinding, _ options: [String: String]) -> BrokerResponse {
        let body = (options["body"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return .failure(BrokerFailure(code: "missing_body", message: "`ask` needs a question.", hint: "mercury ask --body \"<question>\""))
        }
        guard let dispatch = activeDispatch(worker: caller.sessionID) else { return notWorker(caller) }
        let message = enqueue(kind: .question, dispatch: dispatch, from: caller.sessionID, to: dispatch.coordinatorSessionID, body: body)
        setStatus(dispatch.id, .asking)
        notifyApp()
        pumpLocked()
        return .success(Receipt(messageID: message.id, dispatchID: dispatch.id, kind: "question", delivery: deliveryState(message.id)),
                        text: "Question \(message.id) sent to your coordinator. END YOUR TURN now; Mercury types the answer here.")
    }

    private func answer(_ caller: SessionBinding, _ options: [String: String]) -> BrokerResponse {
        let questionID = OrchestrationID.normalize(options["id"] ?? "")
        let body = (options["body"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return .failure(BrokerFailure(code: "missing_body", message: "`reply` needs an answer.",
                                          hint: "mercury reply --id <question-id> --body \"<answer>\""))
        }
        guard let question = store.state.messages.first(where: { $0.id == questionID && $0.kind == .question }) else {
            return .failure(BrokerFailure(code: "unknown_question", message: "No question `\(questionID)`.",
                                          hint: "Run `mercury inbox` for the questions sent to you."))
        }
        guard question.toSessionID == caller.sessionID, let dispatch = dispatch(question.dispatchID) else {
            return .failure(BrokerFailure(code: "not_coordinator", message: "Question \(questionID) was not sent to you."))
        }
        guard question.answeredBy == nil else {
            return .failure(BrokerFailure(code: "already_answered", message: "Question \(questionID) already has a reply (\(question.answeredBy ?? "")).",
                                          hint: "To add something, use: mercury send --to \(dispatch.id) --body \"…\""))
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
                                          hint: "mercury done --status success --summary \"…\""))
        }
        let summary = (options["summary"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            return .failure(BrokerFailure(code: "missing_summary", message: "`done` needs a summary.",
                                          hint: "mercury done --status success --summary \"<what you did, found, left>\""))
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
                                      hint: "To delegate work, run: mercury worker start --agent codex --spec \"<task>\""))
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
              binding.agent != nil, // a shell has no turns; its messages wait in `mercury inbox`
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
