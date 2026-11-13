import Foundation

/// Runs `claude auth login --claudeai` inside a profile.
///
/// The CLI gets the profile as `CLAUDE_CONFIG_DIR`, the inherited environment without credential variables or parent
/// session stamps, and an open stdin for the pasted-code fallback. Its output lines carry the sign-in link the UI
/// offers to copy (for a private window). Success is exit code 0; an access-denied message fails at once.
public struct ClaudeLoginRunner: Sendable {
    public static let arguments = ["auth", "login", "--claudeai"]
    public static let timeout: Duration = .seconds(600)

    let executable: URL
    let baseEnvironment: [String: String]
    let timeout: Duration

    public init(
        executable: URL, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: Duration = Self.timeout
    ) {
        self.executable = executable
        self.baseEnvironment = baseEnvironment
        self.timeout = timeout
    }

    public func start(home: URL) throws -> LoginSession {
        var configuration = LoginProcessConfiguration(
            executable: executable, arguments: Self.arguments, environment: environment(home: home),
            currentDirectory: home)
        configuration.timeout = timeout
        configuration.keepStdinOpen = true
        configuration.deniedDetector = Self.isDenied
        return try ProcessLoginSession(configuration)
    }

    func environment(home: URL) -> [String: String] {
        CLIEnvironment.processEnvironment(
            base: baseEnvironment,
            removing: ClaudeLaunchEnv.authEnvVars + CLIEnvironment.claudeSessionStampKeys
                + ["ANTHROPIC_CUSTOM_HEADERS", ClaudeLaunchEnv.injectedConfigDirEnv],
            setting: ["CLAUDE_CONFIG_DIR": home.path], executable: executable)
    }

    static func isDenied(_ output: String) -> Bool {
        output.range(
            of: #"\baccess_denied\b|authorization (?:request )?(?:was )?denied|sign-?in (?:was )?denied|login (?:was )?denied"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }
}
