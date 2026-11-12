import Darwin
import Foundation

/// What provisioning did with one shared entry.
public enum ProvisionOutcome: String, Sendable, Hashable {
    case linked, synced, merged, unchanged, userOwned, absent, failed
}

/// A non-fatal provisioning problem; `detail` is for logs and never contains file contents.
public struct ProvisionWarning: Sendable, Hashable {
    public var surface: String
    public var detail: String
}

public struct ProvisionReport: Sendable {
    public var surfaces: [String: ProvisionOutcome] = [:]
    public var warnings: [ProvisionWarning] = []
}

enum ProvisionError: Error, LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail): detail
        }
    }
}

/// Shares the user's Claude setup with a profile without sharing the login:
/// folders of the default home are symlinked (so new skills or agents show up everywhere), files are copied
/// (rename-replace saves would break links), `CLAUDE.md` becomes an import of `~/.claude/CLAUDE.md`,
/// `settings.json` syncs per key, `.claude.json` copies without account-bound keys, and runtime state stays private.
///
/// Nothing here writes to the default home; it is only read.
struct ClaudeProfileProvisioner: Sendable {
    let store: ClaudeProfileStore

    static let memoryImport = "@~/.claude/CLAUDE.md\n"

    /// Runtime entries Claude keeps per config dir (matches Claude's own host-config snapshot exclusions).
    static let runtimeStateEntries: [String] = [
        ".claude.json", ".claude.json.backup", ".credentials.json", ".session_ingress_token", "active-time.json",
        "antproto.json", "api-dumps", "backups", "bridge-spawn", "cache", "ccr", "ccr-home-seed.json", "chrome",
        "computer-use.lock", "daemon", "debug", "downloads", "dump-prompts", "feedback", "feedback-bundles",
        "file-history", "file-transfers", "gh-pr-status-cache.json", "hfi-auth.json", "history.jsonl", "ide",
        "image-cache", "jobs", "local", "local-settings", "logs", "loop.md", "mcp-discovery-cache",
        "mcp-needs-auth-cache.json", "mcp-skill-archives", "paste-cache", "plans", "policy-limits.json",
        "project-settings", "projects", "remote", "remote-control", "remote-settings.json", "scratch", "seed-admin",
        "server-sessions.json", "server.lock", "session-env", "sessions", "shares", "shell-snapshots",
        "startup-perf", "state", "stats-cache.json", "statsig", "storage-v2", "systemd", "tasks", "teams",
        "telemetry", "todos", "traces", "uploads", "usage-data",
    ]

    /// Conversation history folders; Orca shares them by moving them into the default home, which Sevinda never
    /// writes, so they stay private to each profile.
    static let historyEntries: [String] = [
        "projects", "session-env", "file-history", "shell-snapshots", "todos", "paste-cache", "tasks", "plans",
        "transcripts",
    ]

    static let unsharedEntries: Set<String> = Set(runtimeStateEntries + historyEntries + ["settings.json"])

    /// User resource folders shared by symlink. Only these are linked: an unknown folder may be runtime state (such as
    /// `session-states`), and a link would make every account write it into the user's own `~/.claude`. `plugins` is
    /// shared on purpose, so plugin installs made from a profile land in `~/.claude/plugins`.
    static let sharedDirectories: Set<String> = [
        "agents", "commands", "skills", "hooks", "output-styles", "rules", "plugins", "scripts",
    ]

    static func isSharedEntry(_ name: String) -> Bool {
        // Hidden state, daemon files and per-folder agent memory stay with each profile.
        !unsharedEntries.contains(name) && !name.hasPrefix(".") && !name.hasPrefix("daemon")
            && !name.hasPrefix("agent-memory")
    }

    /// Call after `store.validate(home:)`. Failures of single entries become warnings.
    func provision(profileHome: URL) -> ProvisionReport {
        var report = ProvisionReport()
        let defaultHome = store.defaultHome
        // Import ~/.claude memory (avoids loading it twice as parent memory); copy a custom home's file instead.
        let imported = FileOps.resolve(defaultHome.path)
            == FileOps.resolve(store.realHome.appendingPathComponent(".claude").path)
        var names: [String] = []
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: defaultHome.path)
                .filter(Self.isSharedEntry).sorted()
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            // No default home: nothing to share.
        } catch {
            report.warnings.append(ProvisionWarning(surface: "profile", detail: error.localizedDescription))
        }
        for name in names {
            let source = defaultHome.appendingPathComponent(name).path
            let target = profileHome.appendingPathComponent(name).path
            run(&report, name) {
                switch try FileOps.statKind(source) {
                case .directory:
                    guard Self.sharedDirectories.contains(name) else { return .absent }
                    return try Self.linkDirectory(source: source, target: target)
                case .file:
                    if name == "CLAUDE.md" && imported {
                        return try Self.copyFile(source: source, target: target) { _ in Data(Self.memoryImport.utf8) }
                    }
                    return try Self.copyFile(source: source, target: target)
                default:
                    return .absent
                }
            }
        }
        var withheld: [String] = []
        run(&report, "settings.json") {
            let result = try ClaudeSettingsSync.sync(
                source: defaultHome.appendingPathComponent("settings.json"),
                target: profileHome.appendingPathComponent("settings.json"),
                record: store.settingsRecord(forHome: profileHome))
            withheld = result.withheld
            return result.outcome
        }
        if !withheld.isEmpty {
            report.warnings.append(ProvisionWarning(
                surface: "settings.json",
                detail: "Not shared with the account (it would override its login): \(withheld.joined(separator: ", "))"))
        }
        run(&report, ".claude.json") {
            try ClaudeStateCopy.copy(
                source: ClaudeStateCopy.stateFile(configDir: store.userConfigDir, realHome: store.realHome),
                target: ClaudeStateCopy.stateFile(configDir: profileHome, realHome: store.realHome))
        }
        return report
    }

    private func run(_ report: inout ProvisionReport, _ surface: String, _ body: () throws -> ProvisionOutcome) {
        do {
            report.surfaces[surface] = try body()
        } catch {
            report.surfaces[surface] = .failed
            report.warnings.append(ProvisionWarning(surface: surface, detail: error.localizedDescription))
        }
    }

    /// Links `target` to `source` (the source path, so later changes of a user symlink are followed).
    static func linkDirectory(source: String, target: String) throws -> ProvisionOutcome {
        guard let canonical = try FileOps.realpath(source) else { return .absent }
        switch try FileOps.lstatKind(target) {
        case .symlink:
            if let resolved = try FileOps.realpath(target) {
                return resolved == canonical ? .unchanged : .userOwned
            }
            // A dangling link is ours to replace.
            unlink(target)
        case .directory:
            guard try FileManager.default.contentsOfDirectory(atPath: target).isEmpty else { return .userOwned }
            rmdir(target)
        case .file, .other:
            return .userOwned
        case nil:
            break
        }
        try FileOps.ensureDirectory((target as NSString).deletingLastPathComponent)
        guard symlink(source, target) == 0 else { throw FileOps.errnoError("symlink", target) }
        return .linked
    }

    /// Copies a file, keeping only the owner permission bits of the source (scripts stay executable, 600/700).
    static func copyFile(
        source: String, target: String, render: (Data) -> Data = { $0 }
    ) throws -> ProvisionOutcome {
        guard let raw = try FileOps.readData(source) else { return .absent }
        let desired = render(raw)
        let mode = (try FileOps.mode(source) & 0o700) | 0o600
        switch try FileOps.lstatKind(target) {
        case .symlink:
            return .userOwned
        case .file:
            if try FileOps.readData(target) == desired { return .unchanged }
        case .directory, .other:
            return .userOwned
        case nil:
            break
        }
        try FileOps.writeAtomically(desired, to: target, mode: mode)
        return .synced
    }
}
