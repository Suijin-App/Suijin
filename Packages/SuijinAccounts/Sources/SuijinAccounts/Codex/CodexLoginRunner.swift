import Darwin
import Foundation

/// Runs `codex login` (or `codex login --device-auth`) with `CODEX_HOME` set to an account home.
///
/// Success is exit code 0, or `auth.json` appearing or changing (compared byte for byte with a snapshot taken before
/// the CLI starts), after which the CLI gets a short grace period to exit and cancellation is refused so an
/// authenticated home is never rolled back. A home that already has credentials signs in through a staging folder,
/// because `codex login` revokes and deletes the current credentials first: only a finished login replaces them.
public struct CodexLoginRunner: Sendable {
    public static let timeout: Duration = .seconds(600)
    static let stagingName = ".suijin-login-staging"
    static let authURLMarker = "navigate to this url to authenticate:"

    let executable: URL
    let baseEnvironment: [String: String]
    let deviceAuth: Bool
    let timeout: Duration
    let postAuthGrace: Duration

    public init(
        executable: URL, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        deviceAuth: Bool = false, timeout: Duration = Self.timeout, postAuthGrace: Duration = .seconds(5)
    ) {
        self.executable = executable
        self.baseEnvironment = baseEnvironment
        self.deviceAuth = deviceAuth
        self.timeout = timeout
        self.postAuthGrace = postAuthGrace
    }

    public func start(home: URL) throws -> LoginSession {
        let finalAuth = home.appendingPathComponent("auth.json")
        let reauthenticating = (try? FileOps.lstatKind(finalAuth.path)) == .file
        var loginHome = home
        if reauthenticating {
            loginHome = home.appendingPathComponent(Self.stagingName, isDirectory: true)
            try FileOps.removeTree(loginHome.path)
            try FileOps.ensureDirectory(loginHome.path, mode: 0o700)
            // Carry forced-workspace and credential-store settings into the login.
            if let config = try FileOps.readData(home.appendingPathComponent("config.toml").path) {
                try FileOps.writeAtomically(config, to: loginHome.appendingPathComponent("config.toml").path, mode: 0o600)
            }
        }
        let authPath = loginHome.appendingPathComponent("auth.json").path
        let initial = Self.snapshot(authPath)
        let stagingPath = loginHome.path

        var configuration = LoginProcessConfiguration(
            executable: executable, arguments: deviceAuth ? ["login", "--device-auth"] : ["login"],
            environment: environment(home: loginHome), currentDirectory: home)
        configuration.timeout = timeout
        configuration.postAuthGrace = postAuthGrace
        configuration.probeInterval = min(.milliseconds(500), postAuthGrace)
        configuration.completionProbe = { Self.authChanged(from: initial, path: authPath) }
        configuration.onSuccess = {
            guard reauthenticating else {
                _ = chmod(authPath, 0o600)
                return
            }
            guard let data = try FileOps.readData(authPath) else {
                throw LoginError.failed(exitCode: 0, output: "Codex finished without writing credentials.")
            }
            try FileOps.writeAtomically(data, to: finalAuth.path, mode: 0o600)
        }
        if reauthenticating {
            configuration.onFinish = { try? FileOps.removeTree(stagingPath) }
        }
        do {
            return try ProcessLoginSession(configuration)
        } catch {
            if reauthenticating { try? FileOps.removeTree(stagingPath) }
            throw error
        }
    }

    func environment(home: URL) -> [String: String] {
        CLIEnvironment.processEnvironment(
            base: baseEnvironment, removing: ["OPENAI_API_KEY", "CODEX_API_KEY", CodexLaunchEnv.injectedHomeEnv],
            setting: ["CODEX_HOME": home.path], executable: executable)
    }

    /// Bytes of auth.json: `.some(nil)` when absent, `nil` when unreadable (which proves nothing).
    static func snapshot(_ path: String) -> Data?? {
        do {
            return .some(try FileOps.readData(path))
        } catch {
            return nil
        }
    }

    static func authChanged(from initial: Data??, path: String) -> Bool {
        guard let initial, let current = snapshot(path), let currentData = current else { return false }
        return currentData != initial
    }

    /// The browser sign-in link `codex login` prints after its marker line; nil until the link is complete.
    public static func authURL(in output: String) -> URL? {
        let plain = ANSI.strip(output)
        guard let marker = plain.range(of: authURLMarker, options: .caseInsensitive) else { return nil }
        let rest = String(plain[marker.upperBound...])
        guard let match = rest.range(of: #"https://\S+?[.,;:)\]]*\s"#, options: .regularExpression) else { return nil }
        var link = String(rest[match]).trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = link.last, ".,;:)]".contains(last) { link.removeLast() }
        return URL(string: link)
    }
}
