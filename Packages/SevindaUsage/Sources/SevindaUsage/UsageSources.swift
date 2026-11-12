import Foundation

/// The folders whose `*.jsonl` logs are read: Claude `projects` folders and Codex `sessions` folders.
public struct UsageSourceSet: Sendable, Hashable {
    public var claudeRoots: [URL]
    public var codexRoots: [URL]

    public init(claudeRoots: [URL], codexRoots: [URL]) {
        self.claudeRoots = claudeRoots
        self.codexRoots = codexRoots
    }

    /// The user's own logs (`~/.claude/projects`, `$CLAUDE_CONFIG_DIR/projects`, `~/.codex/sessions`,
    /// `$CODEX_HOME/sessions`) plus each Sevinda-managed home: a Claude home is a `CLAUDE_CONFIG_DIR`
    /// (`<home>/projects`), a Codex home is a `CODEX_HOME` (`<home>/sessions`). Duplicates are removed later, after
    /// symlinks are resolved.
    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        managedClaudeHomes: [URL] = [],
        managedCodexHomes: [URL] = []
    ) -> UsageSourceSet {
        func configured(_ key: String) -> URL? {
            guard let value = environment[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            let expanded = (value as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        let claudeHomes =
            [homeDirectory.appendingPathComponent(".claude", isDirectory: true)]
            + [configured("CLAUDE_CONFIG_DIR")].compactMap { $0 } + managedClaudeHomes
        let codexHomes =
            [homeDirectory.appendingPathComponent(".codex", isDirectory: true)]
            + [configured("CODEX_HOME")].compactMap { $0 } + managedCodexHomes
        return UsageSourceSet(
            claudeRoots: claudeHomes.map { $0.appendingPathComponent("projects", isDirectory: true) },
            codexRoots: codexHomes.map { $0.appendingPathComponent("sessions", isDirectory: true) })
    }

    /// Every root with symlinks resolved, in order and without duplicates.
    var resolvedRoots: [(UsageProvider, URL)] {
        var seen = Set<String>()
        var result: [(UsageProvider, URL)] = []
        for (provider, roots) in [(UsageProvider.claude, claudeRoots), (.codex, codexRoots)] {
            for root in roots {
                let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
                if seen.insert("\(provider.rawValue):\(resolved.path)").inserted { result.append((provider, resolved)) }
            }
        }
        return result
    }
}

/// A log file found under a root. One entry per physical file: hard links and symlinks (Codex accounts share rollouts
/// that way) are reported once, under the first path found.
struct DiscoveredLogFile: Sendable, Hashable {
    let path: String
    let provider: UsageProvider
    let identity: FileIdentity
}

enum UsageFileDiscovery {
    /// Lists `*.jsonl` files under every root. A root that does not exist is skipped; nothing is written.
    static func discover(_ sources: UsageSourceSet) -> [DiscoveredLogFile] {
        var physical = Set<PhysicalID>()
        var result: [DiscoveredLogFile] = []
        for (provider, root) in sources.resolvedRoots {
            for path in jsonlPaths(under: root) {
                guard let identity = FileIdentity.current(path: path) else { continue }
                guard physical.insert(PhysicalID(device: identity.device, inode: identity.inode)).inserted else {
                    continue
                }
                result.append(DiscoveredLogFile(path: path, provider: provider, identity: identity))
            }
        }
        return result
    }

    private struct PhysicalID: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private static func jsonlPaths(under root: URL) -> [String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [],
                errorHandler: { _, _ in true })
        else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            paths.append(url.path)
        }
        return paths.sorted()
    }
}
