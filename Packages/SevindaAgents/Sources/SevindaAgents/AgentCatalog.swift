import Foundation
import SevindaCore
import Synchronization

/// Static description of a CLI agent Mercury knows how to launch.
public struct AgentDefinition: Sendable, Hashable {
    public var kind: AgentKind
    public var displayName: String
    /// Executable name looked up on `PATH`.
    public var binaryName: String
    /// SF Symbol name used in the sidebar and pickers.
    public var systemImage: String

    public init(kind: AgentKind, displayName: String, binaryName: String, systemImage: String) {
        self.kind = kind
        self.displayName = displayName
        self.binaryName = binaryName
        self.systemImage = systemImage
    }
}

public enum AgentCatalog {
    public static let claude = AgentDefinition(
        kind: .claude, displayName: "Claude Code", binaryName: "claude", systemImage: "sparkle")
    public static let codex = AgentDefinition(
        kind: .codex, displayName: "Codex", binaryName: "codex",
        systemImage: "chevron.left.forwardslash.chevron.right")
    public static let all: [AgentDefinition] = [claude, codex]

    /// The definition for `kind`, or nil for kinds that are not CLI agents (`.shell`).
    public static func definition(for kind: AgentKind) -> AgentDefinition? {
        all.first { $0.kind == kind }
    }

    /// Finds the agent's executable in a colon-separated `PATH` string. Empty entries and
    /// non-executable or directory matches are skipped; a leading `~` is expanded.
    public static func resolveBinary(_ kind: AgentKind, path: String) -> URL? {
        guard let definition = definition(for: kind) else { return nil }
        return resolveExecutable(named: definition.binaryName, path: path)
    }

    static func resolveExecutable(named name: String, path: String) -> URL? {
        let fileManager = FileManager.default
        for entry in path.split(separator: ":", omittingEmptySubsequences: true) {
            let directory = (String(entry) as NSString).expandingTildeInPath
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: candidate.path) else { continue }
            return candidate
        }
        return nil
    }

    // MARK: Login shell PATH

    /// Used when the login shell cannot report its `PATH` (timeout, crash, empty output).
    public static var fallbackPATH: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
    }


    private static let pathCache = Mutex<Task<String, Never>?>(nil)

    /// The `PATH` the user's terminal shell sets up (GUI apps inherit a minimal one).
    /// Computed once per process; concurrent callers share the same lookup.
    public static func loginShellPATH() async -> String {
        let task = pathCache.withLock { cached in
            if let cached { return cached }
            let task = Task { await resolveShellPATH(shell: userShell(), timeout: .seconds(5)) }
            cached = task
            return task
        }
        return await task.value
    }

    /// Interactive login shell first (zsh reads `.zshrc` only when interactive, and that is where
    /// nvm, volta or the `~/.local/bin` line usually live), then a plain login shell, then `fallbackPATH`.
    static func resolveShellPATH(shell: String, timeout: Duration) async -> String {
        if let path = await queryShellPATH(shell: shell, arguments: ["-l", "-i"], timeout: timeout) { return path }
        if let path = await queryShellPATH(shell: shell, arguments: ["-l"], timeout: timeout) { return path }
        return fallbackPATH
    }

    /// `$SHELL`, then the passwd entry, then `/bin/zsh`.
    static func userShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty,
           FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let shell = String(cString: raw)
            if !shell.isEmpty, FileManager.default.isExecutableFile(atPath: shell) { return shell }
        }
        return "/bin/zsh"
    }

    static let pathMarker = "__MERCURY_PATH__"
    /// Prints `PATH` between markers. The marker is assembled by printf, so the literal never
    /// appears in the command line itself (a shell or plugin echoing the command cannot fake it).
    static let pathScript = "printf '__MERCURY_%s__%s__MERCURY_%s__' PATH \"$PATH\" PATH"

    /// Runs `<shell> <arguments> -c <pathScript>` and extracts `PATH` between markers, so banners,
    /// motd lines and prompt escapes printed by the user's startup files do not pollute the result.
    /// The shell gets its own session (no controlling terminal), stdin from /dev/null and
    /// `TERM=dumb`, so instant prompts, `compinit` questions or job control cannot block it.
    /// Returns nil on timeout, launch failure or missing markers.
    static func queryShellPATH(
        shell: String, arguments: [String], timeout: Duration,
        environment base: [String: String] = ProcessInfo.processInfo.environment
    ) async -> String? {
        var environment = base
        environment["TERM"] = "dumb"
        guard let output = await ProcessCapture.run(
            executable: shell, arguments: arguments + ["-c", pathScript], environment: environment,
            timeout: timeout, isComplete: { extractPATH(from: $0) != nil })
        else { return nil }
        return extractPATH(from: output)
    }

    static func extractPATH(from data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: pathMarker),
              let end = text.range(of: pathMarker, range: start.upperBound..<text.endIndex)
        else { return nil }
        let value = String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// Runs a short-lived process and collects its stdout.
///
/// The child is spawned with `posix_spawn` as a new session leader (`POSIX_SPAWN_SETSID`), stdin
/// and stderr on /dev/null, no inherited descriptors and default signal dispositions. Capture
/// finishes when `isComplete` accepts the output so far, at end of file, or at the timeout; whatever
/// is left in the child's process group then gets SIGTERM, and SIGKILL one second later.
/// Reading never blocks on a pipe kept open by a background grandchild. The child is always reaped.
enum ProcessCapture {
    /// All mutable state is confined to `queue`, hence `@unchecked Sendable`.
    private final class Capture: @unchecked Sendable {
        let queue = DispatchQueue(label: "com.tekmium.mercury.process-capture")
        let pid: pid_t
        let isComplete: @Sendable (Data) -> Bool
        var buffer = Data()
        var continuation: CheckedContinuation<Data?, Never>?
        var finished = false
        var reaped = false
        var readSource: (any DispatchSourceRead)?
        var exitSource: (any DispatchSourceProcess)?

        init(pid: pid_t, isComplete: @escaping @Sendable (Data) -> Bool) {
            self.pid = pid
            self.isComplete = isComplete
        }

        func start(readFD: Int32, timeout: Duration, continuation: CheckedContinuation<Data?, Never>) {
            queue.async { [self] in
                self.continuation = continuation
                let read = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: queue)
                read.setEventHandler { [self] in drain(readFD) }
                read.setCancelHandler { close(readFD) }
                readSource = read
                read.resume()

                let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
                exit.setEventHandler { [self] in reap() }
                exitSource = exit
                exit.resume()
                reap() // The child may have exited before the source was armed.

                let nanoseconds = timeout.components.seconds * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000
                queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) { [self] in finish(timedOut: true) }
            }
        }

        private func drain(_ fd: Int32) {
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    buffer.append(contentsOf: chunk[0..<count])
                    continue
                }
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN { break }
                finish(timedOut: false) // EOF or a read error.
                return
            }
            if isComplete(buffer) { finish(timedOut: false) }
        }

        private func reap() {
            guard !reaped else { return }
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            guard result == pid || (result < 0 && errno == ECHILD) else { return }
            reaped = true
            exitSource?.cancel()
            exitSource = nil
        }

        private func finish(timedOut: Bool) {
            guard !finished else { return }
            finished = true
            readSource?.cancel()
            readSource = nil
            // The child leads its own session and process group, so signalling the group also stops
            // children it left behind (a group id cannot be reused while any member is alive).
            reap()
            if kill(-pid, SIGTERM) == 0 {
                queue.asyncAfter(deadline: .now() + 1) { [self] in
                    reap()
                    if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
                }
            }
            let result = timedOut && !isComplete(buffer) ? nil : buffer
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    static func run(
        executable: String, arguments: [String], environment: [String: String], timeout: Duration,
        isComplete: @escaping @Sendable (Data) -> Bool
    ) async -> Data? {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        let readFD = fds[0], writeFD = fds[1]
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)

        guard let pid = spawn(executable: executable, arguments: arguments, environment: environment, stdoutFD: writeFD) else {
            close(readFD)
            close(writeFD)
            return nil
        }
        close(writeFD)
        let capture = Capture(pid: pid, isComplete: isComplete)
        return await withCheckedContinuation { continuation in
            capture.start(readFD: readFD, timeout: timeout, continuation: continuation)
        }
    }

    private static func spawn(executable: String, arguments: [String], environment: [String: String], stdoutFD: Int32) -> pid_t? {
        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }

        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutFD, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

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
}
