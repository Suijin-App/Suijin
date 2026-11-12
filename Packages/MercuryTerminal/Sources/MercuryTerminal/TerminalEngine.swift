import Foundation

/// Columns and rows of a terminal grid.
public struct TerminalSize: Sendable, Hashable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }

    /// The same size with both dimensions at least 1, since a PTY rejects a zero-sized window.
    var clamped: TerminalSize { TerminalSize(cols: max(1, cols), rows: max(1, rows)) }
}

/// What to run in a terminal. `arguments` excludes argv[0]; the engine passes `executable` as argv[0].
public struct TerminalLaunch: Sendable, Hashable {
    public var executable: String
    public var arguments: [String]
    /// The complete environment of the child; nothing is inherited implicitly.
    public var environment: [String: String]
    public var cwd: String
    /// Opaque key/values kept with the session (the PTY host stores them; the in-process engine ignores them).
    public var metadata: [String: String]

    public init(executable: String, arguments: [String] = [], environment: [String: String], cwd: String,
                metadata: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
        self.metadata = metadata
    }
}

/// One process running under a pseudo-terminal. Every call happens on the main actor; output and exit are delivered
/// there too, in order: all output of the process is delivered before `onExit`.
@MainActor public protocol TerminalEngine: AnyObject {
    var onOutput: (@MainActor (ArraySlice<UInt8>) -> Void)? { get set }
    /// The exit code; a process killed by a signal reports 128 + the signal number, `nil` when the status is unknown.
    var onExit: (@MainActor (Int32?) -> Void)? { get set }
    /// PTY host id for hosted engines, nil in-process.
    var sessionID: String? { get }
    func start(_ launch: TerminalLaunch, size: TerminalSize) async throws
    func write(_ bytes: ArraySlice<UInt8>)
    func resize(_ size: TerminalSize)
    /// SIGHUP → wait → SIGKILL; no orphan processes.
    func terminate() async
    /// The consumer finished feeding `byteCount` bytes of output it received through `onOutput` to the emulator.
    /// Engines may use it for flow control (stop reading the PTY while too much output waits); the default does nothing.
    func outputConsumed(_ byteCount: Int)
}

public extension TerminalEngine {
    func outputConsumed(_ byteCount: Int) {}
}

/// Why an engine could not start its process.
public enum TerminalEngineError: Error, LocalizedError, Equatable, Sendable {
    case alreadyStarted
    case executableNotFound(String)
    case invalidWorkingDirectory(String)
    /// `forkpty` failed; the associated value is `errno`.
    case spawnFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted: "The terminal process was already started."
        case .executableNotFound(let path): "No executable at \(path)."
        case .invalidWorkingDirectory(let path): "The working directory \(path) does not exist."
        case .spawnFailed(let code): "Could not start the terminal process (\(String(cString: strerror(code))))."
        }
    }
}
