import Foundation
import SevindaCore
import Synchronization

/// One headless text generation: which agent, where, with which environment, and the prompt.
public struct HeadlessGenerationRequest: Sendable {
    /// `.claude` or `.codex`.
    public var agent: AgentKind
    public var binary: URL
    /// The checkout the text is about; the agent runs there read-only.
    public var workingDirectory: URL
    /// The complete environment of the process: the app's, with the login shell `PATH` and the account's `EnvPatch`
    /// applied.
    public var environment: [String: String]
    public var prompt: String
    public var timeout: Duration
    /// Pass `--no-daemon` to codex (the user's setting).
    public var codexNoDaemon: Bool

    public init(agent: AgentKind, binary: URL, workingDirectory: URL, environment: [String: String], prompt: String,
                timeout: Duration = .seconds(180), codexNoDaemon: Bool = false) {
        self.agent = agent
        self.binary = binary
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.prompt = prompt
        self.timeout = timeout
        self.codexNoDaemon = codexNoDaemon
    }
}

/// Why a generation produced no text. The descriptions are English diagnostics; the app shows its own localized
/// messages per case.
public enum HeadlessGenerationError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedAgent
    case launchFailed(String)
    case timedOut
    case cancelled
    /// The agent exited with an error; `output` is the end of what it printed.
    case failed(exitCode: Int32, output: String)
    case emptyOutput

    public var errorDescription: String? {
        switch self {
        case .unsupportedAgent: "Only Claude Code and Codex can write this text."
        case .launchFailed(let detail): "The agent could not be started: \(detail)"
        case .timedOut: "The agent did not answer in time."
        case .cancelled: "Generation was cancelled."
        case .failed(let code, let output):
            output.isEmpty ? "The agent failed with exit code \(code)." : output
        case .emptyOutput: "The agent returned no text."
        }
    }
}

/// Runs `claude -p` or `codex exec` once with a prompt on stdin and returns the text it answered, under
/// `ReadOnlyAgentPolicy`. The process leads its own session; on timeout or task cancellation its whole process group
/// gets SIGTERM, then SIGKILL two seconds later.
public enum HeadlessTextGenerator {
    public static func generate(_ request: HeadlessGenerationRequest) async throws -> String {
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mercury-headless-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputFile) }
        let arguments: [String]
        switch request.agent {
        case .claude: arguments = ReadOnlyAgentPolicy.claudeArguments()
        case .codex: arguments = ReadOnlyAgentPolicy.codexArguments(outputFile: outputFile, noDaemon: request.codexNoDaemon)
        case .shell: throw HeadlessGenerationError.unsupportedAgent
        }
        var environment = request.environment
        for key in ReadOnlyAgentPolicy.isolatedVariables { environment.removeValue(forKey: key) }

        let result = try await ChildProcess.run(executable: request.binary, arguments: arguments,
                                                directory: request.workingDirectory, environment: environment,
                                                stdin: Data(request.prompt.utf8), timeout: request.timeout)
        guard result.exitCode == 0 else {
            let text = String(decoding: result.stderr.isEmpty ? result.stdout : result.stderr, as: UTF8.self)
            throw HeadlessGenerationError.failed(exitCode: result.exitCode, output: tail(of: text))
        }
        var answer = String(decoding: result.stdout, as: UTF8.self)
        if request.agent == .codex, let last = try? String(contentsOf: outputFile, encoding: .utf8),
           !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            answer = last
        }
        let cleaned = clean(answer)
        guard !cleaned.isEmpty else { throw HeadlessGenerationError.emptyOutput }
        return cleaned
    }

    /// Trims the answer and removes a code fence or quotes wrapped around the whole of it.
    static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            var lines = result.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for quote in ["\"", "'", "`"] where result.count > 1 && result.hasPrefix(quote) && result.hasSuffix(quote)
            && !result.dropFirst().dropLast().contains(quote) {
            result = String(result.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    /// The last 4000 characters, so a chatty failure still fits an alert.
    static func tail(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 4000 ? "…" + String(trimmed.suffix(4000)) : trimmed
    }
}

/// Spawns a process with stdin, stdout and stderr pipes as the leader of a new session, writes `stdin`, and
/// collects both outputs until it exits.
enum ChildProcess {
    struct Output: Sendable {
        var exitCode: Int32
        var stdout: Data
        var stderr: Data
    }

    /// The child's pid and whether it was stopped (and why); guarded by the mutex.
    private final class Control: Sendable {
        enum Stop: Sendable { case none, timedOut, cancelled }
        struct State: Sendable {
            var pid: pid_t = 0
            var exited = false
            var stop = Stop.none
        }
        let state = Mutex(State())

        func started(_ pid: pid_t) -> Bool {
            state.withLock { state in
                state.pid = pid
                return state.stop == .none
            }
        }

        /// Signals the process group unless the child already exited; the first reason wins.
        func stop(_ reason: Stop) {
            let pid: pid_t? = state.withLock { state in
                if state.stop == .none { state.stop = reason }
                return state.exited || state.pid == 0 ? nil : state.pid
            }
            guard let pid else { return }
            kill(-pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                let alive = self.state.withLock { !$0.exited }
                if alive { kill(-pid, SIGKILL) }
            }
        }

        func exited() -> Stop {
            state.withLock { state in
                state.exited = true
                return state.stop
            }
        }
    }

    static func run(executable: URL, arguments: [String], directory: URL, environment: [String: String], stdin: Data,
                    timeout: Duration) async throws -> Output {
        let control = Control()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, any Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try runBlocking(executable: executable, arguments: arguments, directory: directory,
                                        environment: environment, stdin: stdin, timeout: timeout, control: control)
                    })
                }
            }
        } onCancel: {
            control.stop(.cancelled)
        }
    }

    private static func runBlocking(executable: URL, arguments: [String], directory: URL, environment: [String: String],
                                    stdin: Data, timeout: Duration, control: Control) throws -> Output {
        var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1], errors: [Int32] = [-1, -1]
        guard pipe(&input) == 0 else { throw HeadlessGenerationError.launchFailed(String(cString: strerror(errno))) }
        guard pipe(&output) == 0 else {
            input.forEach { close($0) }
            throw HeadlessGenerationError.launchFailed(String(cString: strerror(errno)))
        }
        guard pipe(&errors) == 0 else {
            (input + output).forEach { close($0) }
            throw HeadlessGenerationError.launchFailed(String(cString: strerror(errno)))
        }
        // A reader that went away must not kill the app with SIGPIPE while the prompt is written.
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)

        let pid = spawn(executable: executable.path, arguments: arguments, directory: directory.path, environment: environment,
                        stdin: input[0], stdout: output[1], stderr: errors[1])
        close(input[0]); close(output[1]); close(errors[1])
        guard let pid else {
            close(input[1]); close(output[0]); close(errors[0])
            throw HeadlessGenerationError.launchFailed(executable.path)
        }
        if !control.started(pid) { control.stop(.cancelled) }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { control.stop(.timedOut) }

        let group = DispatchGroup()
        let stdoutBox = DataBox(), stderrBox = DataBox()
        let stdinFD = input[1], stdoutFD = output[0], stderrFD = errors[0]
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            stdin.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = write(stdinFD, base + offset, buffer.count - offset)
                    if written < 0 { if errno == EINTR { continue }; break }
                    offset += written
                }
            }
            close(stdinFD)
        }
        DispatchQueue.global(qos: .userInitiated).async(group: group) { stdoutBox.data = readAll(stdoutFD) }
        DispatchQueue.global(qos: .userInitiated).async(group: group) { stderrBox.data = readAll(stderrFD) }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        let stop = control.exited()
        // Whatever the agent left running in its group would keep the pipes open.
        kill(-pid, SIGKILL)
        group.wait()

        switch stop {
        case .timedOut: throw HeadlessGenerationError.timedOut
        case .cancelled: throw HeadlessGenerationError.cancelled
        case .none: break
        }
        let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return Output(exitCode: exitCode, stdout: stdoutBox.data, stderr: stderrBox.data)
    }

    private static func readAll(_ fd: Int32) -> Data {
        defer { close(fd) }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 { data.append(contentsOf: chunk[0..<count]); continue }
            if count < 0, errno == EINTR { continue }
            return data
        }
    }

    private static func spawn(executable: String, arguments: [String], directory: String, environment: [String: String],
                              stdin: Int32, stdout: Int32, stderr: Int32) -> pid_t? {
        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }

        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)

        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))

        let argv = ([executable] + arguments).map { strdup($0) }
        let envp = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv + [nil], envp + [nil])
        return result == 0 ? pid : nil
    }

    /// Written by one reader block and read only after `DispatchGroup.wait()`, which orders the accesses.
    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }
}
