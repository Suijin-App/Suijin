import Foundation

/// Mirrors `~/.codex/config.toml` into account homes (mode 600: MCP environment tokens may be inside).
///
/// The mirror runs when the source changed since the home's last mirror (a digest record beside the home), so
/// settings Codex saved inside the home survive until the user edits their own config. Each mirror takes ordinary
/// settings from `~/.codex` and keeps what the home owns: project trust (`[projects."…"]`, where a system
/// `untrusted` revocation still wins), hook trust (`[hooks.state.…]`), and MCP servers only the home defines.
/// Relative path settings are rewritten against `~/.codex`. A blank or missing source never clears a home config.
/// The daemon socket guard is applied on every pass. `~/.codex` itself is never written.
struct CodexConfigMirror: Sendable {
    let store: CodexHomeStore

    /// Codex resolves these settings relative to config.toml.
    static let pathKeys: Set<String> = [
        "debug.config_lockfile.export_dir", "debug.config_lockfile.load_path", "experimental_compact_prompt_file",
        "experimental_instructions_file", "log_dir", "model_catalog_json", "model_instructions_file",
        "skills.config.path", "sqlite_home",
    ]

    static let daemonMarker = "# mercury: CODEX_HOME too long for the daemon socket"
    /// macOS `sun_path` is 104 bytes including the terminating NUL.
    static let socketPathByteLimit = 103

    /// Bumped whenever the filtering of mirrored settings changes, so existing homes are mirrored again.
    static let filterVersion = 2

    private struct Record: Codable {
        var filterVersion: Int?
        var sourceDigest: String
        var mirroredMCPServers: [String]
        var mirroredMCPRoot: Bool
    }

    enum Outcome: Equatable {
        case mirrored, unchanged, skippedMissingSource
    }

    var sourceConfig: URL { store.systemHome.appendingPathComponent("config.toml") }

    /// Refuses a new OAuth account while the user's config pins a custom provider: those credentials would be unused.
    func assertOAuthAccountAllowed() throws {
        guard let data = try? FileOps.readData(sourceConfig.path),
              let provider = CodexTOML.topLevelModelProvider(String(decoding: data, as: UTF8.self)),
              provider != "openai"
        else { return }
        throw AccountsError.refused(
            "~/.codex/config.toml pins the custom model provider \"\(provider)\". Remove model_provider (or set it to "
                + "\"openai\") before adding a Codex account. Mercury left your config unchanged.")
    }

    @discardableResult
    func sync(home: URL) throws -> Outcome {
        let runtimePath = home.appendingPathComponent("config.toml").path
        let recordPath = store.mirrorRecord(forHome: home).path
        let runtime = try FileOps.readData(runtimePath).map { String(decoding: $0, as: UTF8.self) }
        let source = try FileOps.readData(sourceConfig.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
        var record: Record?
        if let data = try? FileOps.readData(recordPath) { record = try? JSONDecoder().decode(Record.self, from: data) }

        var outcome = Outcome.unchanged
        var next = runtime
        var newRecord: Record?
        let digest = FileOps.sha256Hex(Data(source.utf8))
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A cloud-synced source may be unhydrated; never treat it as cleared.
            outcome = .skippedMissingSource
        } else if runtime == nil || record?.sourceDigest != digest || record?.filterVersion != Self.filterVersion {
            let prepared = Self.withoutAPIKeyLogin(Self.rewriteRelativePaths(source, sourceDir: store.systemHome.path))
            if let runtime {
                next = Self.merge(
                    runtime: runtime, system: prepared, systemHome: store.systemHome.path,
                    mirroredServers: Set(record?.mirroredMCPServers ?? []), mirroredRoot: record?.mirroredMCPRoot ?? false)
            } else {
                next = Self.fresh(system: prepared, systemHome: store.systemHome.path)
            }
            outcome = .mirrored
            let sections = CodexTOML.split(prepared).sections
            newRecord = Record(
                filterVersion: Self.filterVersion, sourceDigest: digest,
                mirroredMCPServers: Array(Set(sections.compactMap { CodexTOML.mcpServerName($0.header) })).sorted(),
                mirroredMCPRoot: CodexTOML.ownsMCPServerRoot(sections))
        }
        let guarded = Self.applyDaemonGuard(next ?? "", homePath: home.path)
        if guarded != (runtime ?? "") {
            try FileOps.writeAtomically(Data(guarded.utf8), to: runtimePath, mode: 0o600)
        }
        // Record only after the home config is written, so a failed pass retries next launch.
        if let newRecord {
            try FileOps.writeAtomically(try JSONEncoder.sortedKeys.encode(newRecord), to: recordPath, mode: 0o600)
        }
        return outcome
    }

    // MARK: Merge

    private static func isHomeScopedHookTrust(_ key: String, systemHome: String) -> Bool {
        // Hook sources inside ~/.codex itself belong to that home and must not be shared.
        let base = systemHome.hasSuffix("/") ? String(systemHome.dropLast()) : systemHome
        return key.hasPrefix(base + "/hooks.json") || key.hasPrefix(base + "/config.toml")
    }

    /// The system config for a home that has none yet: everything except home-scoped hook trust.
    static func fresh(system: String, systemHome: String) -> String {
        let (preamble, sections) = CodexTOML.split(system)
        return CodexTOML.join([preamble] + sections.filter { section in
            guard let key = CodexTOML.hookTrustKey(section.header) else { return true }
            return !isHomeScopedHookTrust(key, systemHome: systemHome)
        }.map(\.block))
    }

    static func merge(
        runtime: String, system: String, systemHome: String, mirroredServers: Set<String>, mirroredRoot: Bool
    ) -> String {
        let runtimeSections = dedupeProjects(CodexTOML.split(runtime).sections)
        let runtimeProjects = Set(runtimeSections.compactMap { CodexTOML.projectKey($0.header) })
        let runtimeHookKeys = Set(runtimeSections.compactMap { CodexTOML.hookTrustKey($0.header) })
        let (systemPreamble, rawSystemSections) = CodexTOML.split(system)
        let systemSections = dedupeProjects(rawSystemSections)
        var systemUntrusted = Set<String>()
        var systemTrusted = Set<String>()
        for section in systemSections {
            guard let key = CodexTOML.projectKey(section.header) else { continue }
            switch CodexTOML.trustLevel(section.block) {
            case "untrusted": systemUntrusted.insert(key.lowercased())
            case "trusted": systemTrusted.insert(key)
            default: break
            }
        }
        let systemServers = Set(systemSections.compactMap { CodexTOML.mcpServerName($0.header) })
        let systemOwnsRoot = CodexTOML.ownsMCPServerRoot(systemSections)

        var claimedHooks = runtimeHookKeys
        let fromSystem = systemSections.filter { section in
            if let key = CodexTOML.hookTrustKey(section.header) {
                guard !isHomeScopedHookTrust(key, systemHome: systemHome), !claimedHooks.contains(key) else { return false }
                claimedHooks.insert(key)
                return true
            }
            if let key = CodexTOML.projectKey(section.header) {
                // The home's own trust wins unless the system revokes it.
                return !runtimeProjects.contains(key) || CodexTOML.trustLevel(section.block) == "untrusted"
            }
            return true
        }
        let fromRuntime = runtimeSections.filter { section in
            if CodexTOML.hookTrustKey(section.header) != nil { return true }
            if let key = CodexTOML.projectKey(section.header) {
                return !systemUntrusted.contains(key.lowercased()) || systemTrusted.contains(key)
            }
            if let name = CodexTOML.mcpServerName(section.header) {
                return !systemOwnsRoot && !mirroredRoot && !systemServers.contains(name) && !mirroredServers.contains(name)
            }
            return false
        }
        return CodexTOML.join([systemPreamble] + fromSystem.map(\.block) + fromRuntime.map(\.block))
    }

    /// One section per project; a revocation wins regardless of order.
    private static func dedupeProjects(_ sections: [CodexTOML.Section]) -> [CodexTOML.Section] {
        var result: [CodexTOML.Section] = []
        var indexes: [String: Int] = [:]
        for section in sections {
            guard let key = CodexTOML.projectKey(section.header) else {
                result.append(section)
                continue
            }
            if let existing = indexes[key] {
                if CodexTOML.trustLevel(result[existing].block) != "untrusted",
                   CodexTOML.trustLevel(section.block) == "untrusted" {
                    result[existing] = section
                }
                continue
            }
            indexes[key] = result.count
            result.append(section)
        }
        return result
    }

    /// A managed home signs in with ChatGPT OAuth; a mirrored `forced_login_method = "api"` (or the older
    /// `preferred_auth_method = "apikey"`), at top level or in a profile, would make Codex demand an API key instead.
    /// Workspace pins and the credential store stay: they constrain the login rather than replace it.
    static func withoutAPIKeyLogin(_ config: String) -> String {
        CodexTOML.removeStringSettings(config) { keyPath, value in
            guard let key = keyPath.last, keyPath.count == 1 || (keyPath.count == 3 && keyPath[0] == "profiles") else {
                return false
            }
            let mode = value.lowercased()
            return (key == "forced_login_method" && mode == "api")
                || (key == "preferred_auth_method" && (mode == "apikey" || mode == "api"))
        }
    }

    static func rewriteRelativePaths(_ config: String, sourceDir: String) -> String {
        CodexTOML.rewriteStringSettings(config) { keyPath, value in
            guard pathKeys.contains(keyPath.joined(separator: ".")), !value.isEmpty,
                  !value.hasPrefix("/"), !value.hasPrefix("~")
            else { return nil }
            return FileOps.resolve(FileOps.join(sourceDir, value))
        }
    }

    // MARK: Daemon socket guard

    /// Codex starts a daemon on `<CODEX_HOME>/app-server-control/app-server-control.sock`; a long home overflows
    /// `sun_path`, so the guard turns daemon auto-start off for exactly those homes and removes itself otherwise.
    static func socketPathExceedsLimit(homePath: String) -> Bool {
        let canonical = (try? FileOps.realpath(homePath)) ?? nil
        var base = canonical ?? homePath
        while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
        return (base + "/app-server-control/app-server-control.sock").utf8.count > socketPathByteLimit
    }

    static func applyDaemonGuard(_ config: String, homePath: String) -> String {
        let stripped = stripDaemonGuard(config)
        guard socketPathExceedsLimit(homePath: homePath) else { return stripped }
        let line = "daemon_auto_start = false \(daemonMarker)"
        var (preamble, sections) = CodexTOML.split(stripped)
        if let index = sections.firstIndex(where: { CodexTOML.table($0.header) == .init(segments: ["features"], isArray: false) }) {
            var lines = sections[index].block.components(separatedBy: "\n")
            if lines.contains(where: { CodexTOML.keyPath(String($0.split(separator: "=").first ?? "")) == ["daemon_auto_start"] }) {
                // The user decides daemon auto-start themselves.
                return stripped
            }
            while lines.count > 1, lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            lines.append(line)
            sections[index].block = lines.joined(separator: "\n")
        } else if preamble.range(of: #"(?m)^\s*features\s*[=.]"#, options: .regularExpression) != nil {
            // Inline or dotted features tables cannot take another table entry safely.
            return stripped
        } else {
            sections.append(.init(header: "[features]", block: "[features]\n\(line)"))
        }
        return CodexTOML.join([preamble] + sections.map(\.block))
    }

    /// Removes the guard line, and a `[features]` table it leaves empty, so the override never spreads.
    static func stripDaemonGuard(_ config: String) -> String {
        guard config.contains(daemonMarker) else { return config }
        let (preamble, sections) = CodexTOML.split(config)
        var kept: [String] = []
        for section in sections {
            let lines = section.block.components(separatedBy: "\n").filter { !$0.hasSuffix(daemonMarker) }
            let isFeatures = CodexTOML.table(section.header) == .init(segments: ["features"], isArray: false)
            if isFeatures && lines.dropFirst().allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            kept.append(lines.joined(separator: "\n"))
        }
        return CodexTOML.join([preamble] + kept)
    }
}
