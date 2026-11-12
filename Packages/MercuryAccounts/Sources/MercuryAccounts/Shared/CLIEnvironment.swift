import Foundation

/// Locates CLI tools and builds the environment for the login and logout processes.
enum CLIEnvironment {
    /// Finds `name` on `PATH`, then in the usual install locations (an app started from the Dock has a short PATH).
    static func locate(_ name: String, realHome: URL, environment: [String: String]) -> URL? {
        let home = realHome.path
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += [
            "\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin", "/usr/bin",
        ]
        for directory in directories where !directory.isEmpty {
            let candidate = FileOps.join(directory, name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Variables a launching Claude stamps on its children; they do not belong to independent processes.
    static let claudeSessionStampKeys: [String] = [
        "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_BRIDGE_SESSION_ID",
        "CLAUDE_CODE_HOST_SESSION_ID", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_DESKTOP_APP_VERSION", "CLAUDE_EFFORT", "CLAUDE_PID", "CLAUDE_AGENT_SDK_VERSION",
    ]

    /// `base` without `removed`, with `set` applied and the executable's folder first on PATH.
    static func processEnvironment(
        base: [String: String], removing removed: [String], setting set: [String: String], executable: URL
    ) -> [String: String] {
        var env = base
        for key in removed { env.removeValue(forKey: key) }
        for (key, value) in set { env[key] = value }
        let folder = executable.deletingLastPathComponent().path
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !path.split(separator: ":").contains(Substring(folder)) {
            env["PATH"] = "\(folder):\(path)"
        }
        return env
    }
}
