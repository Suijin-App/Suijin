import Foundation
import MercuryPTYHostKit
import MercuryPTYProtocol
import Synchronization

/// Accumulates a byte stream and an optional exit status; lets tests await a condition with a timeout.
final class OutputCollector: Sendable {
    private struct Waiter {
        let id: UUID
        let predicate: @Sendable (Data, Int32?) -> Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var data = Data()
        var exitStatus: Int32?
        var events: [String] = []
        var waiters: [Waiter] = []
    }

    private let state = Mutex(State())

    var data: Data { state.withLock { $0.data } }
    var exitStatus: Int32? { state.withLock { $0.exitStatus } }
    var events: [String] { state.withLock { $0.events } }
    var text: String { String(decoding: data, as: UTF8.self) }

    func append(_ chunk: Data) {
        update { $0.data.append(chunk); $0.events.append("output") }
    }

    func setExit(_ status: Int32) {
        update { $0.exitStatus = status; $0.events.append("exit") }
    }

    func record(event: String) {
        update { $0.events.append(event) }
    }

    func reset() {
        update { $0.data = Data(); $0.events = [] }
    }

    /// Waits until `predicate(data, exitStatus)` holds; false on timeout.
    func wait(timeout: TimeInterval = 10, until predicate: @escaping @Sendable (Data, Int32?) -> Bool) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let satisfied = state.withLock { state -> Bool in
                if predicate(state.data, state.exitStatus) { return true }
                state.waiters.append(Waiter(id: id, predicate: predicate, continuation: continuation))
                return false
            }
            if satisfied {
                continuation.resume(returning: true)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                let expired = self.state.withLock { state -> Waiter? in
                    guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                    return state.waiters.remove(at: index)
                }
                expired?.continuation.resume(returning: false)
            }
        }
    }

    func wait(timeout: TimeInterval = 10, forText needle: String, occurrences: Int = 1) async -> Bool {
        let bytes = Data(needle.utf8)
        return await wait(timeout: timeout) { data, _ in data.occurrences(of: bytes) >= occurrences }
    }

    /// Waits until `marker` appeared and the line after it is complete.
    func waitForLine(after marker: String, timeout: TimeInterval = 10) async -> Bool {
        await wait(timeout: timeout) { data, _ in
            let text = String(decoding: data, as: UTF8.self)
            guard let range = text.range(of: marker) else { return false }
            return text[range.upperBound...].utf8.contains(UInt8(ascii: "\n")) // "\r\n" is one Character
        }
    }

    func waitForExit(timeout: TimeInterval = 10) async -> Int32? {
        _ = await wait(timeout: timeout) { _, status in status != nil }
        return exitStatus
    }

    private func update(_ body: (inout State) -> Void) {
        let ready = state.withLock { state -> [Waiter] in
            body(&state)
            let data = state.data
            let status = state.exitStatus
            let done = state.waiters.filter { $0.predicate(data, status) }
            state.waiters.removeAll { waiter in done.contains { $0.id == waiter.id } }
            return done
        }
        ready.forEach { $0.continuation.resume(returning: true) }
    }
}

/// A `PTYOutputSink` that collects into an `OutputCollector`.
final class CollectingSink: PTYOutputSink {
    let collector: OutputCollector

    init(collector: OutputCollector = OutputCollector()) {
        self.collector = collector
    }

    func deliver(output: Data, sessionID: String) {
        collector.append(output)
    }

    func deliver(exitStatus: Int32, sessionID: String) {
        collector.setExit(exitStatus)
    }
}

/// A flow-controlled sink: acknowledges each chunk (optionally late) while `acknowledging` is on, and otherwise
/// holds the credit until `release()`, like an app that stopped draining its output.
final class AcknowledgingSink: PTYOutputSink {
    private struct State {
        var session: PTYSession?
        var token: UUID?
        var acknowledging = true
        var held = 0
    }

    let collector = OutputCollector()
    private let delay: TimeInterval
    private let state = Mutex(State())

    init(acknowledging: Bool = true, delay: TimeInterval = 0) {
        self.delay = delay
        state.withLock { $0.acknowledging = acknowledging }
    }

    func bind(_ session: PTYSession, token: UUID) {
        let held = state.withLock { state -> Int in
            state.session = session
            state.token = token
            defer { state.held = 0 }
            return state.acknowledging ? state.held : 0
        }
        if held > 0 { session.acknowledge(token, bytes: held) }
    }

    /// Turns acknowledging on and credits everything held so far.
    func release() {
        let (session, token, held) = state.withLock { state -> (PTYSession?, UUID?, Int) in
            state.acknowledging = true
            defer { state.held = 0 }
            return (state.session, state.token, state.held)
        }
        if let session, let token, held > 0 { session.acknowledge(token, bytes: held) }
    }

    func deliver(output: Data, sessionID: String) {
        collector.append(output)
        let target = state.withLock { state -> (PTYSession, UUID)? in
            guard state.acknowledging, let session = state.session, let token = state.token else {
                state.held += output.count
                return nil
            }
            return (session, token)
        }
        guard let (session, token) = target else { return }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { session.acknowledge(token, bytes: output.count) }
        } else {
            session.acknowledge(token, bytes: output.count)
        }
    }

    func deliver(exitStatus: Int32, sessionID: String) {
        collector.setExit(exitStatus)
    }
}

/// Exact `seq` output for byte-identity checks. Output post-processing is turned off first: with ONLCR, a writer that
/// blocks on a full tty queue mid-"\r\n" has the "\r" emitted twice by the kernel line discipline (seen as
/// "\r\r\n" under flow control), which is a terminal artifact, not a stream defect.
func rawSeqScript(_ count: Int) -> String {
    "/bin/stty -opost; /usr/bin/seq -f %.0f 1 \(count)"
}

func expectedSeqOutput(_ count: Int) -> Data {
    var data = Data()
    data.reserveCapacity(count * 8)
    for value in 1...count { data.append(contentsOf: "\(value)\n".utf8) }
    return data
}

extension Data {
    func occurrences(of needle: Data) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = startIndex..<endIndex
        while let found = range(of: needle, options: [], in: searchRange) {
            count += 1
            searchRange = found.upperBound..<endIndex
        }
        return count
    }

    func contains(text: String) -> Bool {
        range(of: Data(text.utf8)) != nil
    }
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mercury-ptyhost-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func shellRequest(_ script: String, cols: Int = 80, rows: Int = 24) -> PTYSpawnRequest {
    PTYSpawnRequest(
        executable: "/bin/sh", arguments: ["-c", script],
        environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8"],
        cwd: NSTemporaryDirectory(), cols: cols, rows: rows
    )
}

/// True once no process with `pid` exists (polls; orphans are reaped by launchd asynchronously).
func processIsGone(_ pid: pid_t, timeout: TimeInterval = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if kill(pid, 0) != 0, errno == ESRCH { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

func processGroupIsGone(_ pgid: pid_t, timeout: TimeInterval = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if killpg(pgid, 0) != 0, errno == ESRCH { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

func pidAfterMarker(_ marker: String, in text: String) -> pid_t? {
    guard let range = text.range(of: marker) else { return nil }
    let digits = text[range.upperBound...].prefix { $0.isNumber }
    return pid_t(digits)
}
