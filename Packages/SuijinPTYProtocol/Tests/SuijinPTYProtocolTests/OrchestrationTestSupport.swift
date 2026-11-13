import Foundation
@testable import SuijinPTYHostKit
import SuijinPTYProtocol
import Synchronization

/// A clock tests move by hand.
final class TestClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    var now: Date { current.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// Records what the broker typed into each session.
final class RecordingSessionIO: OrchestrationSessionIO, Sendable {
    private let writes = Mutex<[String: [Data]]>([:])
    private let counters = Mutex<[String: UInt64]>([:])

    func injectInput(hostSessionID: String, data: Data) {
        writes.withLock { $0[hostSessionID, default: []].append(data) }
    }

    func bytesRead(hostSessionID: String) -> UInt64? {
        counters.withLock { $0[hostSessionID] ?? 0 }
    }

    func setBytesRead(_ value: UInt64, for hostSessionID: String) {
        counters.withLock { $0[hostSessionID] = value }
    }

    func written(_ hostSessionID: String) -> [Data] {
        writes.withLock { $0[hostSessionID] ?? [] }
    }

    /// Every paste typed into the session, decoded.
    func pastes(_ hostSessionID: String) -> [String] {
        written(hostSessionID).compactMap { data in
            guard data.starts(with: MessageDelivery.pasteStart), data.suffix(6) == MessageDelivery.pasteEnd else { return nil }
            return String(decoding: data.dropFirst(6).dropLast(6), as: UTF8.self)
        }
    }

    func submits(_ hostSessionID: String) -> Int {
        written(hostSessionID).filter { $0 == MessageDelivery.submit }.count
    }
}

/// The app side: records worker starts and attention events.
final class RecordingAppLink: OrchestrationAppLink, Sendable {
    private let requests = Mutex<[WorkerLaunchRequest]>([])
    private let events = Mutex<[OrchestrationAttention]>([])
    private let changes = Mutex(0)

    func startWorker(_ request: WorkerLaunchRequest) { requests.withLock { $0.append(request) } }
    func stateChanged() { changes.withLock { $0 += 1 } }
    func attention(_ event: OrchestrationAttention) { events.withLock { $0.append(event) } }

    var started: [WorkerLaunchRequest] { requests.withLock { $0 } }
    var attentions: [OrchestrationAttention] { events.withLock { $0 } }
}

/// Collects a reply that may come later.
final class ReplyBox: Sendable {
    private let value = Mutex<BrokerResponse?>(nil)

    var response: BrokerResponse? { value.withLock { $0 } }

    func set(_ response: BrokerResponse) { value.withLock { $0 = response } }

    func wait(timeout: TimeInterval = 5) async -> BrokerResponse? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let response { return response }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return response
    }
}

/// A broker in memory with a fake clock, fake PTYs and a fake app, plus helpers to play sessions.
struct BrokerHarness {
    static let coordinatorToken = String(repeating: "c", count: 64)
    static let workerToken = String(repeating: "w", count: 64)
    static let shellToken = String(repeating: "s", count: 64)

    let clock = TestClock()
    let io = RecordingSessionIO()
    let app = RecordingAppLink()
    let broker: Broker
    let stateFile: URL?

    init(stateFile: URL? = nil, attachApp: Bool = true, quietPeriod: TimeInterval = 3) {
        self.stateFile = stateFile
        var tuning = Broker.Tuning()
        tuning.submitDelay = 0.01
        tuning.inputQuietPeriod = quietPeriod
        tuning.startReplyTimeout = 2
        tuning.escalationGrace = 0.05
        let clock = self.clock
        broker = Broker(dataRoot: URL(fileURLWithPath: "/tmp/suijin-test-root"), stateFile: stateFile, io: io, tuning: tuning,
                        now: { clock.now })
        broker.open(tick: false)
        broker.sessionSpawned(hostSessionID: "host-coordinator", sessionID: "coordinator", agent: .claude, token: Self.coordinatorToken)
        if attachApp { broker.attachApp(app, id: UUID()) }
    }

    func call(_ command: String, token: String = BrokerHarness.coordinatorToken, _ options: [String: String] = [:],
              wait: Bool = true) async -> BrokerResponse? {
        let box = ReplyBox()
        broker.handle(BrokerRequest(token: token, command: command, options: options)) { box.set($0) }
        return wait ? await box.wait() : nil
    }

    /// `worker start` by the coordinator, answered by the fake app with a running worker session.
    func startWorker(agent: String = "codex", spec: String = "Fix the login bug", name: String? = "fix-login") async -> (BrokerResponse?, WorkerLaunchRequest?) {
        let box = ReplyBox()
        var options = ["agent": agent, "spec": spec, "worktree": "new"]
        if let name { options["name"] = name }
        broker.handle(BrokerRequest(token: Self.coordinatorToken, command: "worker.start", options: options)) { box.set($0) }
        _ = broker.sync { 0 }
        guard let request = app.started.last else { return (await box.wait(timeout: 0.5), nil) }
        broker.sessionSpawned(hostSessionID: "host-worker", sessionID: "worker", agent: agent == "claude" ? .claude : .codex,
                              token: Self.workerToken)
        broker.workerStartFinished(WorkerLaunchResult(dispatchID: request.dispatchID, workerSessionID: "worker", directory: "/tmp/wt"))
        return (await box.wait(), request)
    }

    func hook(_ event: String, token: String = BrokerHarness.coordinatorToken, type: String? = nil) async {
        var options = ["event": event]
        if let type { options["notificationType"] = type }
        _ = await call("hook.claude", token: token, options)
    }

    func codexTurnEnded(token: String = BrokerHarness.workerToken) async {
        _ = await call("hook.codex", token: token, ["type": "agent-turn-complete"])
    }

    var snapshot: OrchestrationSnapshot { broker.snapshot() }

    /// Waits out the escalation grace period.
    func graceElapses() async {
        try? await Task.sleep(for: .milliseconds(120))
        _ = broker.sync { 0 }
    }

    /// Waits for the delayed Return of a delivery.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(80))
        _ = broker.sync { 0 }
    }
}
