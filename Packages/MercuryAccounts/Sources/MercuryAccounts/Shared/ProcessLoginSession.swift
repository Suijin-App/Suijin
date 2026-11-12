import Darwin
import Foundation
import Synchronization

/// How a CLI login process is run and judged.
struct LoginProcessConfiguration: Sendable {
    var executable: URL
    var arguments: [String]
    var environment: [String: String]
    var currentDirectory: URL?
    var timeout: Duration = .seconds(600)
    /// Keeps stdin open so `ProcessLoginSession.send(_:)` can answer a pasted-code prompt.
    var keepStdinOpen = false
    /// Polled while the process runs; once true the login counts as authenticated, cancellation is refused, and
    /// the process gets `postAuthGrace` to exit before it is stopped and the login still succeeds.
    var completionProbe: (@Sendable () -> Bool)?
    var probeInterval: Duration = .milliseconds(500)
    var postAuthGrace: Duration = .seconds(5)
    /// Output (ANSI stripped, last 4000 characters) that proves the sign-in was refused.
    var deniedDetector: (@Sendable (String) -> Bool)?
    /// Runs before success is reported; a throw turns the result into that error.
    var onSuccess: (@Sendable () throws -> Void)?
    /// Runs once after the result is settled, success or not.
    var onFinish: (@Sendable () -> Void)?
}

/// A login CLI child process: output lines as an `AsyncStream`, a timeout, cancellation, and optional completion
/// detection from a credential file. Thread-safe; callbacks arrive on Foundation's pipe and process queues.
final class ProcessLoginSession: InteractiveLoginSession {
    let output: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let configuration: LoginProcessConfiguration
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "mercury.accounts.login")

    private struct State {
        var process: Process?
        var stdin: FileHandle?
        var buffers = ["", ""]
        var tail = ""
        var openStreams = 2
        var exitStatus: Int32?
        var authenticated = false
        var stoppedAfterAuth = false
        var settling = false
        var result: Result<Void, LoginError>?
        var waiters: [CheckedContinuation<Void, any Error>] = []
        var probeTimer: DispatchSourceTimer?
    }

    private static let tailLimit = 4000

    init(_ configuration: LoginProcessConfiguration) throws {
        self.configuration = configuration
        (output, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(500))
        try start()
    }

    // MARK: LoginSession

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                let settled = state.withLock { state -> Result<Void, LoginError>? in
                    if let result = state.result { return result }
                    state.waiters.append(waiter)
                    return nil
                }
                if let settled { waiter.resume(with: settled.mapError { $0 as any Error }) }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        let refuse = state.withLock { $0.authenticated || $0.result != nil || $0.settling }
        // A login whose credentials already changed must not be rolled back.
        if refuse { return }
        stopProcess()
        settle(.failure(.cancelled))
    }

    /// Writes to the CLI's stdin (pasted sign-in code); ignored once the login settled.
    func send(_ text: String) {
        let handle = state.withLock { $0.result == nil ? $0.stdin : nil }
        try? handle?.write(contentsOf: Data(text.utf8))
    }

    // MARK: Process lifecycle

    private func start() throws {
        let process = Process()
        process.executableURL = configuration.executable
        process.arguments = configuration.arguments
        process.environment = configuration.environment
        if let directory = configuration.currentDirectory { process.currentDirectoryURL = directory }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        var stdinHandle: FileHandle?
        if configuration.keepStdinOpen {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            stdinHandle = stdinPipe.fileHandleForWriting
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        for (index, pipe) in [stdoutPipe, stderrPipe].enumerated() {
            // Strong captures keep the session alive until the process is gone, so it can never be orphaned.
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    self.streamClosed(index)
                } else {
                    self.received(data, stream: index)
                }
            }
        }
        process.terminationHandler = { process in
            self.exited(process.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            throw LoginError.launchFailed(error.localizedDescription)
        }
        state.withLock {
            $0.process = process
            $0.stdin = stdinHandle
        }
        queue.asyncAfter(deadline: .now() + configuration.timeout.timeInterval) {
            self.timedOut()
        }
        if let probe = configuration.completionProbe { startProbe(probe) }
    }

    private func startProbe(_ probe: @escaping @Sendable () -> Bool) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = configuration.probeInterval.timeInterval
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, probe() else { return }
            let first = self.state.withLock { state -> Bool in
                guard !state.authenticated, state.result == nil else { return false }
                state.authenticated = true
                state.probeTimer?.cancel()
                state.probeTimer = nil
                return true
            }
            guard first else { return }
            self.queue.asyncAfter(deadline: .now() + self.configuration.postAuthGrace.timeInterval) { [weak self] in
                self?.stopAfterAuthentication()
            }
        }
        state.withLock { $0.probeTimer = timer }
        timer.resume()
    }

    private func stopAfterAuthentication() {
        let running = state.withLock { state -> Bool in
            guard state.result == nil, state.exitStatus == nil else { return false }
            state.stoppedAfterAuth = true
            return true
        }
        guard running else { return }
        stopProcess()
        // Credentials are in place; a lingering CLI does not make the login fail.
        settle(.success(()))
    }

    private func timedOut() {
        guard state.withLock({ $0.result == nil && !$0.settling }) else { return }
        stopProcess()
        settle(.failure(.timedOut))
    }

    /// SIGTERM, then SIGKILL if the process is still alive two seconds later.
    private func stopProcess() {
        let pid = state.withLock { state -> pid_t? in
            guard let process = state.process, process.isRunning else { return nil }
            process.terminate()
            return process.processIdentifier
        }
        guard let pid else { return }
        queue.asyncAfter(deadline: .now() + 2) {
            // The exit status is recorded by the termination handler, so a live pid is still our child.
            if self.state.withLock({ $0.exitStatus == nil }) { kill(pid, SIGKILL) }
        }
    }

    // MARK: Output

    private func received(_ data: Data, stream: Int) {
        let text = ANSI.strip(String(decoding: data, as: UTF8.self))
        let (lines, denied) = state.withLock { state -> ([String], Bool) in
            state.tail = String((state.tail + text).suffix(Self.tailLimit))
            var buffer = state.buffers[stream] + text
            var lines: [String] = []
            while let index = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                lines.append(String(buffer[..<index]))
                buffer = String(buffer[buffer.index(after: index)...])
            }
            state.buffers[stream] = buffer
            let denied = state.result == nil && (configuration.deniedDetector?(state.tail) ?? false)
            return (lines, denied)
        }
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            continuation.yield(line)
        }
        if denied {
            stopProcess()
            settle(.failure(.denied))
        }
    }

    private func streamClosed(_ stream: Int) {
        let (partial, ready) = state.withLock { state -> (String, Bool) in
            let partial = state.buffers[stream]
            state.buffers[stream] = ""
            state.openStreams -= 1
            return (partial, state.openStreams == 0 && state.exitStatus != nil)
        }
        if !partial.trimmingCharacters(in: .whitespaces).isEmpty { continuation.yield(partial) }
        if ready { evaluateExit() }
    }

    private func exited(_ status: Int32) {
        let ready = state.withLock { state -> Bool in
            state.exitStatus = status
            return state.openStreams == 0
        }
        if ready {
            evaluateExit()
        } else {
            // A grandchild holding the pipes open must not keep the login pending.
            queue.asyncAfter(deadline: .now() + 1) { self.evaluateExit() }
        }
    }

    private func evaluateExit() {
        let verdict = state.withLock { state -> Result<Void, LoginError>? in
            guard state.result == nil, !state.settling, let status = state.exitStatus else { return nil }
            if status == 0 || state.stoppedAfterAuth { return .success(()) }
            let output = state.tail.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.failed(exitCode: status, output: String(output.suffix(600))))
        }
        if let verdict { settle(verdict) }
    }

    // MARK: Settlement

    private func settle(_ proposed: Result<Void, LoginError>) {
        let proceed = state.withLock { state -> Bool in
            guard state.result == nil, !state.settling else { return false }
            state.settling = true
            state.probeTimer?.cancel()
            state.probeTimer = nil
            return true
        }
        guard proceed else { return }
        var final = proposed
        if case .success = proposed, let onSuccess = configuration.onSuccess {
            do {
                try onSuccess()
            } catch let error as LoginError {
                final = .failure(error)
            } catch {
                final = .failure(.failed(exitCode: 0, output: error.localizedDescription))
            }
        }
        let (waiters, stdin) = state.withLock { state -> ([CheckedContinuation<Void, any Error>], FileHandle?) in
            state.result = final
            let waiters = state.waiters
            state.waiters = []
            let stdin = state.stdin
            state.stdin = nil
            return (waiters, stdin)
        }
        try? stdin?.close()
        configuration.onFinish?()
        continuation.finish()
        for waiter in waiters { waiter.resume(with: final.mapError { $0 as any Error }) }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

enum ANSI {
    // CSI sequences, OSC sequences (terminated by BEL or ST), and lone two-byte escapes.
    private static let pattern = "\u{1B}\\[[0-?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|\u{1B}[@-Z\\\\-_]"

    static func strip(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
}
