import Foundation

/// A failed `git` invocation.
public struct GitError: Error, LocalizedError, Sendable {
    public var args: [String]
    public var exitCode: Int32
    public var stderr: String

    public init(args: [String], exitCode: Int32, stderr: String) {
        self.args = args
        self.exitCode = exitCode
        self.stderr = stderr
    }

    public var errorDescription: String? {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = "git " + args.joined(separator: " ")
        return detail.isEmpty ? "\(command) failed with exit code \(exitCode)" : "\(command) failed (\(exitCode)): \(detail)"
    }
}

/// Output of one `git` invocation.
public struct GitResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
}

/// Runs the `git` CLI. Output is machine-readable only: `LC_ALL=C`, no terminal prompts, no optional locks
/// (so status checks never contend with agents committing in the same worktree), stdin closed.
public struct GitRunner: Sendable {
    public var executable: URL

    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.executable = executable
    }

    /// Runs `git <args>` in `dir` and returns stdout; a non-zero exit throws `GitError`.
    public func run(_ args: [String], in dir: URL) async throws -> Data {
        try await run(args, in: dir, allowedExitCodes: [0]).stdout
    }

    /// Runs `git <args>` in `dir`; an exit code outside `allowedExitCodes` throws `GitError`.
    public func run(_ args: [String], in dir: URL, allowedExitCodes: Set<Int32>) async throws -> GitResult {
        let executable = executable
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GitResult, any Error>) in
            // `Process` and pipe reads block; keep them off the cooperative pool.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.runBlocking(executable: executable, args: args, in: dir) })
            }
        }
        guard allowedExitCodes.contains(result.exitCode) else {
            throw GitError(args: args, exitCode: result.exitCode, stderr: String(decoding: result.stderr, as: UTF8.self))
        }
        return result
    }

    /// Text output helper: stdout decoded as UTF-8 (invalid bytes replaced).
    func text(_ args: [String], in dir: URL) async throws -> String {
        String(decoding: try await run(args, in: dir), as: UTF8.self)
    }

    /// Inherited `GIT_*` variables that are kept: transport settings only. Everything else in the `GIT_`
    /// namespace (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_COMMON_DIR`, `GIT_OBJECT_DIRECTORY`,
    /// `GIT_CEILING_DIRECTORIES`, `GIT_CONFIG_*`, ...) could point commands at another repository or change
    /// their output, e.g. when the app is started from a git hook or an agent session in another repo.
    static let keptGitVariables: Set<String> = [
        "GIT_SSH", "GIT_SSH_COMMAND", "GIT_SSH_VARIANT", "GIT_ASKPASS", "GIT_SSL_CAINFO", "GIT_SSL_CAPATH",
    ]

    static func environment(inheriting inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = inherited.filter { key, _ in !key.hasPrefix("GIT_") || keptGitVariables.contains(key) }
        env["LC_ALL"] = "C"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_PAGER"] = "cat"
        return env
    }

    private static func runBlocking(executable: URL, args: [String], in dir: URL) throws -> GitResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.currentDirectoryURL = dir
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Drain both pipes at once; reading them one after the other deadlocks when git fills the other pipe.
        let stderrBox = DataBox()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return GitResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderrBox.data)
    }
}

/// Written by one reader block and read only after `DispatchGroup.wait()`, which orders the accesses.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

public enum GitRepository {
    /// The repository toplevel containing `dir`, or nil when `dir` is not inside a git work tree.
    public static func toplevel(of dir: URL, runner: GitRunner = .init()) async -> URL? {
        guard let output = try? await runner.text(["rev-parse", "--show-toplevel"], in: dir) else { return nil }
        let path = output.trimmingCharacters(in: .newlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }
}
