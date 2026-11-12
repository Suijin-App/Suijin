import Foundation
import Synchronization

/// Output of one short command. `stdout` may hold a credential (Keychain reads): keep it in memory only and never
/// put it into an error, a log, or a file.
public struct CommandResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: Data, stderr: Data, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Runs short non-interactive commands (`security`, `claude auth logout`, `codex logout`). Injected in tests so
/// nothing touches the real Keychain or a real login.
public protocol CommandRunning: Sendable {
    func run(
        _ executable: URL, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval
    ) async throws -> CommandResult
}

/// `Process`-backed runner: stdin closed, both pipes drained concurrently, terminated on timeout.
public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(
        _ executable: URL, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval
    ) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            // Process waits and pipe reads block; keep them off the cooperative pool.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try Self.runBlocking(executable, arguments, environment: environment, timeout: timeout)
                })
            }
        }
    }

    private static func runBlocking(
        _ executable: URL, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        let outputs = OutputBox()
        let group = DispatchGroup()
        for (index, pipe) in [stdoutPipe, stderrPipe].enumerated() {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                outputs.set(index, data)
                group.leave()
            }
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        // A grandchild holding the pipes open must not hang the caller.
        _ = group.wait(timeout: .now() + 2)
        let (stdout, stderr) = outputs.values()
        return CommandResult(
            exitCode: process.terminationStatus, stdout: stdout, stderr: stderr, timedOut: timedOut)
    }
}

private final class OutputBox: Sendable {
    // Written by the two pipe reader threads, read after both finish.
    private let outputs = Mutex([Data(), Data()])

    func set(_ index: Int, _ data: Data) {
        outputs.withLock { $0[index] = data }
    }

    func values() -> (Data, Data) {
        outputs.withLock { ($0[0], $0[1]) }
    }
}
