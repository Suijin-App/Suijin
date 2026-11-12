import Foundation

/// A pull request as `gh pr view --json` reports it.
public struct PullRequest: Hashable, Sendable, Decodable {
    public enum State: String, Hashable, Sendable, Decodable {
        case open = "OPEN", closed = "CLOSED", merged = "MERGED"
    }

    public var number: Int
    public var url: URL
    public var title: String
    public var state: State
    public var isDraft: Bool
    /// `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`; nil when the repository requires no review.
    public var reviewDecision: String?
    /// `CLEAN`, `BLOCKED`, `BEHIND`, `DIRTY`, `UNSTABLE`, `HAS_HOOKS`, `DRAFT`, `UNKNOWN`.
    public var mergeStateStatus: String?
    public var headRefName: String?
    public var baseRefName: String?

    public init(number: Int, url: URL, title: String, state: State, isDraft: Bool, reviewDecision: String? = nil,
                mergeStateStatus: String? = nil, headRefName: String? = nil, baseRefName: String? = nil) {
        self.number = number
        self.url = url
        self.title = title
        self.state = state
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.mergeStateStatus = mergeStateStatus
        self.headRefName = headRefName
        self.baseRefName = baseRefName
    }

    private enum CodingKeys: String, CodingKey {
        case number, url, title, state, isDraft, reviewDecision, mergeStateStatus, headRefName, baseRefName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        url = try container.decode(URL.self, forKey: .url)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        state = try container.decode(State.self, forKey: .state)
        isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        // gh reports "no decision" as an empty string.
        reviewDecision = try container.decodeIfPresent(String.self, forKey: .reviewDecision).flatMap { $0.isEmpty ? nil : $0 }
        mergeStateStatus = try container.decodeIfPresent(String.self, forKey: .mergeStateStatus).flatMap { $0.isEmpty ? nil : $0 }
        headRefName = try container.decodeIfPresent(String.self, forKey: .headRefName)
        baseRefName = try container.decodeIfPresent(String.self, forKey: .baseRefName)
    }
}

/// One CI check of a pull request (`gh pr checks --json`).
public struct PullRequestCheck: Hashable, Sendable, Decodable, Identifiable {
    /// gh's summary of `state`.
    public enum Bucket: String, Hashable, Sendable, Decodable {
        case pass, fail, pending, skipping, cancel
    }

    public var name: String
    /// The raw state, e.g. `SUCCESS`, `FAILURE`, `IN_PROGRESS`, `QUEUED`.
    public var state: String
    public var bucket: Bucket
    public var link: URL?
    public var workflow: String?

    public var id: String { [workflow ?? "", name, link?.absoluteString ?? ""].joined(separator: "\u{1F}") }

    public init(name: String, state: String, bucket: Bucket, link: URL? = nil, workflow: String? = nil) {
        self.name = name
        self.state = state
        self.bucket = bucket
        self.link = link
        self.workflow = workflow
    }

    private enum CodingKeys: String, CodingKey { case name, state, bucket, link, workflow }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        // An unknown bucket from a newer gh counts as pending rather than failing the whole list.
        bucket = (try? container.decode(Bucket.self, forKey: .bucket)) ?? .pending
        link = (try container.decodeIfPresent(String.self, forKey: .link)).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        workflow = try container.decodeIfPresent(String.self, forKey: .workflow).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Whether `gh` can talk to a host.
public enum GitHubAuthStatus: Hashable, Sendable {
    case loggedIn(login: String)
    case notLoggedIn
}

/// A failed `gh` invocation. `output` is gh's stderr (or stdout when stderr is empty).
public struct GitHubCLIError: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: Hashable, Sendable {
        case failed(exitCode: Int32)
        case timedOut
        case launchFailed
        case invalidOutput
    }

    public var kind: Kind
    public var output: String

    public init(kind: Kind, output: String) {
        self.kind = kind
        self.output = output
    }

    public var errorDescription: String? {
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .failed(let code): return detail.isEmpty ? "gh failed with exit code \(code)" : detail
        case .timedOut: return "gh did not answer in time."
        case .launchFailed: return detail.isEmpty ? "gh could not be started." : detail
        case .invalidOutput: return "gh returned output Sevinda could not read."
        }
    }
}

/// The user's GitHub CLI behind a typed API. Sevinda never holds a GitHub token: `gh` uses its own login.
public struct GitHubCLI: Sendable {
    public var executable: URL
    public var environment: [String: String]
    public var timeout: Duration

    /// `environment` is the base environment (normally the app's, with the login shell `PATH`). Repository overrides
    /// in the `GIT_` namespace are removed as for git itself, and prompts, colors and update checks are turned off.
    public init(executable: URL, environment: [String: String] = ProcessInfo.processInfo.environment, timeout: Duration = .seconds(30)) {
        self.executable = executable
        self.environment = Self.environment(inheriting: environment)
        self.timeout = timeout
    }

    static func environment(inheriting inherited: [String: String]) -> [String: String] {
        var env = GitRunner.environment(inheriting: inherited)
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["GH_SPINNER_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        env["CLICOLOR"] = "0"
        env["GH_PAGER"] = "cat"
        env.removeValue(forKey: "GH_FORCE_TTY")
        return env
    }

    /// Finds `gh` on a colon-separated `PATH`.
    public static func locate(path: String) -> URL? {
        for entry in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: (String(entry) as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("gh")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: Commands

    /// The active account on `host` (`gh auth status --active --json hosts`). Only the host, login and state fields
    /// are decoded; gh's token is never read.
    public func authStatus(host: String = "github.com") async throws -> GitHubAuthStatus {
        let output = try await run(["auth", "status", "--active", "--hostname", host, "--json", "hosts"], in: nil)
        return try Self.parseAuthStatus(output.stdout, host: host)
    }

    /// The pull request whose head is `branch` (open first; gh falls back to the latest closed or merged one), or nil
    /// when the branch has none.
    public func pullRequest(branch: String, in directory: URL) async throws -> PullRequest? {
        do {
            let output = try await run(["pr", "view", branch, "--json", Self.pullRequestFields], in: directory)
            return try Self.decode(PullRequest.self, from: output.stdout)
        } catch let error as GitHubCLIError where Self.isNoPullRequest(error) {
            return nil
        }
    }

    /// The checks of pull request `number`. A pull request without checks yields an empty list.
    public func checks(pullRequest number: Int, in directory: URL) async throws -> [PullRequestCheck] {
        // Exit code 8 means "checks pending" and 1 "some failed"; both still print the list.
        let output = try await run(["pr", "checks", String(number), "--json", "name,state,bucket,link,workflow"], in: directory,
                                   allowedExitCodes: [0, 1, 8])
        if output.exitCode != 0, output.stdout.allSatisfy({ $0 == 0x20 || $0 == 0x0A }) {
            if Self.mentionsNoChecks(output.stderr) { return [] }
            throw GitHubCLIError(kind: .failed(exitCode: output.exitCode), output: String(decoding: output.stderr, as: UTF8.self))
        }
        return try Self.decode([PullRequestCheck].self, from: output.stdout)
    }

    /// Creates a pull request from `head` into `base` and returns its URL. The body goes through a file, so any text
    /// is passed unchanged. When a pull request for the branch already exists, the error's `output` names it.
    public func createPullRequest(title: String, body: String, base: String, head: String, draft: Bool,
                                  in directory: URL) async throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sevinda-pr-body-\(UUID().uuidString).md")
        try Data(body.utf8).write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        var args = ["pr", "create", "--title", title, "--body-file", file.path, "--base", base, "--head", head]
        if draft { args.append("--draft") }
        let output = try await run(args, in: directory)
        guard let url = Self.lastURL(in: String(decoding: output.stdout, as: UTF8.self)) else {
            throw GitHubCLIError(kind: .invalidOutput, output: String(decoding: output.stdout, as: UTF8.self))
        }
        return url
    }

    static let pullRequestFields = "number,url,title,state,isDraft,reviewDecision,mergeStateStatus,headRefName,baseRefName"

    // MARK: Parsing

    static func parseAuthStatus(_ data: Data, host: String) throws -> GitHubAuthStatus {
        struct Account: Decodable {
            var state: String?
            var active: Bool?
            var login: String?
        }
        struct Status: Decodable { var hosts: [String: [Account]] }
        let status = try decode(Status.self, from: data)
        let accounts = status.hosts[host] ?? []
        guard let account = accounts.first(where: { $0.active ?? false }) ?? accounts.first,
              account.state == "success", let login = account.login, !login.isEmpty else { return .notLoggedIn }
        return .loggedIn(login: login)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw GitHubCLIError(kind: .invalidOutput, output: String(decoding: data.prefix(2000), as: UTF8.self))
        }
    }

    static func isNoPullRequest(_ error: GitHubCLIError) -> Bool {
        guard case .failed = error.kind else { return false }
        return error.output.lowercased().contains("no pull requests found")
    }

    static func mentionsNoChecks(_ data: Data) -> Bool {
        String(decoding: data, as: UTF8.self).lowercased().contains("no checks reported")
    }

    /// The URL of an existing pull request in gh's "already exists" refusal, if that is what `error` is.
    public static func existingPullRequestURL(in error: GitHubCLIError) -> URL? {
        guard error.output.lowercased().contains("already exists") else { return nil }
        return lastURL(in: error.output)
    }

    static func lastURL(in text: String) -> URL? {
        text.split(whereSeparator: \.isWhitespace).reversed()
            .first { $0.hasPrefix("https://") || $0.hasPrefix("http://") }
            .flatMap { URL(string: String($0)) }
    }

    // MARK: Remotes

    /// The host of a GitHub remote URL (`https://github.com/o/r.git`, `git@github.com:o/r.git`,
    /// `ssh://git@github.com/o/r`), or nil when the URL is not one. `github.com`, `*.github.com` and GitHub Enterprise
    /// Cloud (`*.ghe.com`) count; other hosts count when they are in `knownHosts` (hosts `gh` is logged in to).
    public static func gitHubHost(ofRemoteURL url: String, knownHosts: Set<String> = []) -> String? {
        // Only plain host names: the host is later passed to `gh --hostname` and shown in commands.
        guard let host = host(ofRemoteURL: url)?.lowercased(),
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
        if host == "github.com" || host.hasSuffix(".github.com") || host.hasSuffix(".ghe.com") || knownHosts.contains(host) {
            return host == "www.github.com" || host == "ssh.github.com" ? "github.com" : host
        }
        return nil
    }

    /// The host part of a git remote URL in URL or scp-like syntax; nil for local paths.
    static func host(ofRemoteURL raw: String) -> String? {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.contains("://") {
            return URLComponents(string: url)?.host.flatMap { $0.isEmpty ? nil : $0 }
        }
        // scp-like: [user@]host:path, where the part before the first colon has no slash.
        guard let colon = url.firstIndex(of: ":") else { return nil }
        let prefix = url[..<colon]
        guard !prefix.isEmpty, !prefix.contains("/") else { return nil }
        let host = prefix.split(separator: "@").last.map(String.init) ?? ""
        return host.isEmpty ? nil : host
    }

    // MARK: Running

    struct Output: Sendable {
        var exitCode: Int32
        var stdout: Data
        var stderr: Data
    }

    func run(_ args: [String], in directory: URL?, allowedExitCodes: Set<Int32> = [0]) async throws -> Output {
        let output = try await ProcessRunner.run(executable: executable, arguments: args, directory: directory,
                                                 environment: environment, timeout: timeout)
        guard allowedExitCodes.contains(output.exitCode) else {
            let err = String(decoding: output.stderr, as: UTF8.self)
            let text = err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(decoding: output.stdout, as: UTF8.self) : err
            throw GitHubCLIError(kind: .failed(exitCode: output.exitCode), output: text)
        }
        return output
    }
}

/// Runs a short command with a timeout, collecting stdout and stderr; stdin is closed. On timeout or task
/// cancellation the process gets SIGTERM, then SIGKILL two seconds later.
enum ProcessRunner {
    /// The process and its completion flags. `Process` is safe to signal from any thread; the flags are guarded by
    /// `lock`, hence `@unchecked Sendable`.
    private final class Running: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var timedOut = false
        private var finished = false

        /// Marks a timeout unless the process already finished; true when it should be stopped.
        func markTimedOut() -> Bool {
            lock.withLock {
                if !finished { timedOut = true }
                return !finished
            }
        }

        /// Marks the process finished and reports whether the timeout fired first.
        func markFinished() -> Bool {
            lock.withLock {
                finished = true
                return timedOut
            }
        }

        func stop() {
            guard process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    static func run(executable: URL, arguments: [String], directory: URL?, environment: [String: String],
                    timeout: Duration) async throws -> GitHubCLI.Output {
        let running = Running()
        let process = running.process
        process.executableURL = executable
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GitHubCLI.Output, any Error>) in
                // `Process` and pipe reads block; keep them off the cooperative pool.
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try running.process.run() } catch {
                        continuation.resume(throwing: GitHubCLIError(kind: .launchFailed, output: error.localizedDescription))
                        return
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                        if running.markTimedOut() { running.stop() }
                    }
                    // Drain both pipes at once; reading them one after the other deadlocks when one fills up.
                    let stderrBox = Box()
                    let group = DispatchGroup()
                    DispatchQueue.global(qos: .userInitiated).async(group: group) {
                        stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    }
                    let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    running.process.waitUntilExit()
                    if running.markFinished() {
                        continuation.resume(throwing: GitHubCLIError(kind: .timedOut, output: ""))
                    } else {
                        continuation.resume(returning: GitHubCLI.Output(exitCode: running.process.terminationStatus,
                                                                        stdout: stdout, stderr: stderrBox.data))
                    }
                }
            }
        } onCancel: {
            running.stop()
        }
    }

    /// Written by one reader block and read only after `DispatchGroup.wait()`, which orders the accesses.
    private final class Box: @unchecked Sendable {
        var data = Data()
    }
}
