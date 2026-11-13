import Foundation
@testable import SuijinTerminal

/// A throwaway HOME and Suijin data root with fake `claude` and `codex` binaries that print the environment they see.
struct ShellFixture {
    let base: URL
    let home: URL
    let dataRoot: URL
    let fakeBin: URL
    let integration: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appending(path: "suijin-shell-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        home = base.appending(path: "home dir", directoryHint: .isDirectory)
        // A space, as in "Application Support".
        dataRoot = base.appending(path: "Application Support/Suijin", directoryHint: .isDirectory)
        fakeBin = base.appending(path: "bin", directoryHint: .isDirectory)
        for directory in [home, dataRoot, fakeBin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Self.writeExecutable(fakeBin.appending(path: "claude"), """
            #!/bin/sh
            printf 'claude-config=%s\\n' "${CLAUDE_CONFIG_DIR-<unset>}"
            printf 'claude-key=%s\\n' "${ANTHROPIC_API_KEY-<unset>}"
            printf 'claude-token=%s\\n' "${CLAUDE_CODE_OAUTH_TOKEN-<unset>}"
            printf 'claude-args=%s\\n' "$*"
            """)
        try Self.writeExecutable(fakeBin.appending(path: "codex"), """
            #!/bin/sh
            printf 'codex-home=%s\\n' "${CODEX_HOME-<unset>}"
            printf 'codex-key=%s\\n' "${OPENAI_API_KEY-<unset>}"
            """)
        integration = try ShellIntegration.install(in: dataRoot)
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }

    func write(_ text: String, to relativePath: String, in directory: URL? = nil) throws {
        let url = (directory ?? home).appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func selectAccount(_ path: String?, provider: String = "claude-profiles") throws {
        try write(path ?? "", to: "\(provider)/selected-host", in: dataRoot)
    }

    /// A startup-file line that puts the fake binaries first, after macOS's path_helper reordered PATH.
    var pathLine: String { "export PATH=\"\(fakeBin.path):$PATH\"\n" }

    /// The environment a Suijin terminal gets, with this fixture's HOME and data root.
    func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var env = ShellLaunch.baseEnvironment(from: [
            "HOME": home.path, "USER": NSUserName(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory(),
        ])
        env["SUIJIN_DATA_ROOT"] = dataRoot.path
        env["BASH_SILENCE_DEPRECATION_WARNING"] = "1"
        return env.merging(extra) { _, new in new }
    }

    /// Runs Suijin's interactive `shell` launch with `-c script` appended and returns its standard output.
    func run(shell: String, script: String, environment extra: [String: String] = [:]) throws -> String {
        let launch = ShellLaunch.interactiveShell(shell, cwd: home, environment: environment(extra))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments + (shell.hasSuffix("zsh") ? ["-i", "-c", script] : ["-c", script])
        process.environment = launch.environment
        process.currentDirectoryURL = home
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func writeExecutable(_ url: URL, _ text: String) throws {
        try Data((text + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

extension String {
    /// The value of the first `key=value` line.
    func value(of key: String) -> String? {
        split(separator: "\n").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }
}
