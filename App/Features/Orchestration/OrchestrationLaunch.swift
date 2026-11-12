import Foundation
import MercuryAccounts
import MercuryCore
import MercuryPTYProtocol
import os

private let logger = Logger(subsystem: "com.tekmium.mercury", category: "orchestration")

/// What every terminal Mercury opens gets for orchestration: the bundled `mercury` on `PATH`, the session token and
/// the broker's addresses in the environment, the orchestration skill, and for Codex the `notify` hook.
enum OrchestrationLaunch {
    static let skillName = "mercury-orchestration"

    /// `Mercury.app/Contents/Helpers`: holds only `mercury`, so only it joins `PATH`.
    static var cliDirectory: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
    }

    static var cliPath: String { cliDirectory.appendingPathComponent("mercury").path }

    static var isCLIAvailable: Bool { FileManager.default.isExecutableFile(atPath: cliPath) }

    static var bundledSkill: URL? {
        Bundle.main.url(forResource: "SKILL", withExtension: "md", subdirectory: "Skills/\(skillName)")
    }

    /// The variables for one session: its token (a fresh secret, only ever in this environment) and where the broker
    /// and the CLI are. Empty when the CLI is missing from the bundle.
    static func environment(dataRoot: URL) -> [String: String] {
        guard isCLIAvailable else { return [:] }
        return [
            OrchestrationEnvironment.sessionToken: OrchestrationToken.make(),
            OrchestrationEnvironment.socket: OrchestrationPaths.socketPath(dataRoot: dataRoot),
            OrchestrationEnvironment.spool: OrchestrationPaths.spoolDirectory(dataRoot: dataRoot).path,
            OrchestrationEnvironment.cli: cliPath,
        ]
    }

    /// `PATH` with Mercury's CLI folder first.
    static func path(prepending base: String?) -> String {
        guard isCLIAvailable else { return base ?? "/usr/bin:/bin:/usr/sbin:/sbin" }
        let parts = (base ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init).filter { $0 != cliDirectory.path }
        return ([cliDirectory.path] + parts).joined(separator: ":")
    }

    // MARK: Claude

    /// `<dataRoot>/orchestration/claude-plugin`, a plugin holding the skill. Claude loads it with `--plugin-dir`, so
    /// every Mercury Claude session (managed profile or the user's own login) sees the skill and nothing is written
    /// into a profile's `skills` folder, which is a link to the user's `~/.claude/skills`.
    static func claudePluginDirectory(dataRoot: URL) -> URL {
        OrchestrationPaths.directory(dataRoot: dataRoot).appendingPathComponent("claude-plugin", isDirectory: true)
    }

    /// Writes the plugin (manifest and skill) when its content changed; nil when the bundle has no skill.
    @discardableResult
    static func installClaudePlugin(dataRoot: URL) -> URL? {
        guard let skill = bundledSkill, let text = try? Data(contentsOf: skill) else { return nil }
        let root = claudePluginDirectory(dataRoot: dataRoot)
        let manifest = Data(#"{"name":"mercury","description":"Mercury agent orchestration: start worker agents and get their results back.","version":"1.0.0"}"#.utf8)
        do {
            try writeIfChanged(manifest, to: root.appendingPathComponent(".claude-plugin/plugin.json"))
            try writeIfChanged(text, to: root.appendingPathComponent("skills/\(skillName)/SKILL.md"))
            return root
        } catch {
            logger.error("cannot write the Claude orchestration plugin: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The user-level skill (`~/.claude/skills/mercury-orchestration`) when the user turned it on in Settings.
    static func userClaudeSkill(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".claude/skills/\(skillName)/SKILL.md")
    }

    /// Installs or removes the user-level skill. Only the Settings toggle calls this.
    static func setUserClaudeSkill(installed: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let file = userClaudeSkill(home: home)
        if installed {
            guard let skill = bundledSkill else { throw CocoaError(.fileNoSuchFile) }
            try writeIfChanged(try Data(contentsOf: skill), to: file, private: false)
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
    }

    // MARK: Codex

    /// Copies the skill into a managed Codex home's `skills` folder when that folder is the home's own. A `skills`
    /// that links to the user's `~/.codex/skills` is left alone (writing through it would change the user's folder);
    /// those sessions read the guide with `mercury skills get orchestration`, and workers get it in their prompt.
    static func installCodexSkill(home: URL) {
        guard let skill = bundledSkill, let text = try? Data(contentsOf: skill) else { return }
        let skills = home.appendingPathComponent("skills", isDirectory: true)
        guard let values = try? skills.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
              values.isSymbolicLink != true, values.isDirectory == true else { return }
        try? writeIfChanged(text, to: skills.appendingPathComponent("\(skillName)/SKILL.md"))
    }

    /// `-c notify=[…]` for a Codex launch with `home` (nil: the user's own login).
    static func codexNotifyArguments(home: URL?) -> [String] {
        guard isCLIAvailable else { return [] }
        let config = CodexNotifyConfig.effectiveConfig(home: home, environment: ProcessInfo.processInfo.environment,
                                                       realHome: FileManager.default.homeDirectoryForCurrentUser)
        return CodexNotifyConfig.launchArguments(cli: cliPath, config: config)
    }

    /// For a Codex worker in `directory`: `-c projects={"<repository root>"={trust_level="trusted"}}`. Nobody watches
    /// a worker's terminal to answer Codex's folder-trust screen; the coordinator chose this folder of a workspace the
    /// user added. The override holds for this launch only: no `config.toml` is written. Codex keys trust by the real
    /// path of the repository root (`/private/var/…`, not `/var/…`), shared by all its worktrees.
    static func codexWorkerArguments(directory: URL, repositoryRoot: URL?) -> [String] {
        let paths = Set([directory, repositoryRoot].compactMap { $0 }.compactMap(realPath)).sorted()
        guard !paths.isEmpty else { return [] }
        let entries = paths.map { "\(CodexNotifyConfig.tomlQuoted($0))={trust_level=\"trusted\"}" }.joined(separator: ",")
        return ["-c", "projects={\(entries)}"]
    }

    private static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: Files

    private static func writeIfChanged(_ data: Data, to file: URL, private isPrivate: Bool = true) throws {
        if (try? Data(contentsOf: file)) == data { return }
        let attributes: [FileAttributeKey: Any]? = isPrivate ? [.posixPermissions: 0o700] : nil
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: attributes)
        try data.write(to: file, options: .atomic)
    }
}
