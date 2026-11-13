import Darwin
import Foundation
import SQLite3

/// Shares the user's Codex resources and session history with account homes. Only the account home is written;
/// `~/.codex` is read (session rollouts are hardlinked from it, never moved or edited).
struct CodexSharedResources: Sendable {
    let store: CodexHomeStore

    /// Codex rejects these from any home but its own, so each account home links them from `~/.codex`.
    static let linkedEntries = [
        "skills", "hooks", "plugins", "plugin-state", "profile-v2", "themes", "prompts", ".tmp/bundled-marketplaces",
        "AGENTS.md",
    ]
    /// Global rules are copied with this prefix; it sorts before the home's own `default.rules`, whose approvals win.
    static let globalRulePrefix = "_suijin-global-"

    // MARK: Resource links

    /// Links each present resource whose target is free, and removes a link whose source disappeared.
    func linkResources(into home: URL) {
        for entry in Self.linkedEntries {
            let source = store.systemHome.appendingPathComponent(entry).path
            let target = home.appendingPathComponent(entry).path
            do {
                let targetKind = try FileOps.lstatKind(target)
                let pointsToSource = targetKind == .symlink
                    && (try? FileManager.default.destinationOfSymbolicLink(atPath: target)) == source
                guard try FileOps.statKind(source) != nil else {
                    if pointsToSource { unlink(target) }
                    continue
                }
                guard targetKind == nil else { continue }
                try FileOps.ensureDirectory((target as NSString).deletingLastPathComponent)
                if symlink(source, target) != 0 { throw FileOps.errnoError("symlink", target) }
            } catch {
                // One unreadable resource must not stop the launch.
                continue
            }
        }
    }

    /// Mirrors `~/.codex/rules/*.rules` as prefixed copies, removing copies whose source is gone.
    func syncRules(into home: URL) {
        let sourceDir = store.systemHome.appendingPathComponent("rules").path
        let targetDir = home.appendingPathComponent("rules").path
        // A linked or foreign rules entry already exposes its own rules; copies would leak into it.
        do {
            if let kind = try FileOps.lstatKind(targetDir), kind != .directory { return }
        } catch {
            return
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sourceDir)) ?? []
        var desired: [String: Data] = [:]
        for name in names where name.hasSuffix(".rules") {
            let path = FileOps.join(sourceDir, name)
            guard (try? FileOps.lstatKind(path)) == .file, let data = try? FileOps.readData(path) else { continue }
            desired[Self.globalRulePrefix + name] = data
        }
        let existing = ((try? FileManager.default.contentsOfDirectory(atPath: targetDir)) ?? [])
            .filter { $0.hasPrefix(Self.globalRulePrefix) }
        for name in existing where desired[name] == nil {
            unlink(FileOps.join(targetDir, name))
        }
        guard !desired.isEmpty else { return }
        try? FileOps.ensureDirectory(targetDir)
        for (name, data) in desired {
            let path = FileOps.join(targetDir, name)
            if (try? FileOps.readData(path)) == data { continue }
            try? FileOps.writeAtomically(data, to: path, mode: 0o600)
        }
    }

    // MARK: Session sharing

    struct LinkPass: Equatable {
        var scanned = 0
        var linked = 0
    }

    /// Hardlinks rollouts (`sessions/**/*.jsonl`, `*.jsonl.zst`) missing from `target` from each source in order, so
    /// `codex resume` in any account sees the same conversations as one physical log. Existing names are never
    /// replaced. Codex ignores symlinked rollouts, so a symlink is only the fallback across volumes.
    ///
    /// Runs only when the target's state database finished its backfill (or there is none yet but the home already
    /// has rollouts): linking into a home Codex has not indexed would make its first start backfill everything.
    func shareSessions(into target: URL, from sources: [URL]) -> LinkPass {
        var pass = LinkPass()
        guard Self.isReadyForBridgedHistory(target) else { return pass }
        let targetRoot = target.appendingPathComponent("sessions").path
        let targetResolved = FileOps.resolve(target.path)
        let sourceRoots = sources.map { FileOps.resolve($0.path) }
            .filter { $0 != targetResolved }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .map { FileOps.join($0, "sessions") }
        visit([], sourceRoots: sourceRoots, targetRoot: targetRoot, pass: &pass)
        return pass
    }

    private func visit(_ relative: [String], sourceRoots: [String], targetRoot: String, pass: inout LinkPass) {
        var rollouts: [(String, [String])] = []
        var directories: [String] = []
        for root in sourceRoots {
            let dir = relative.reduce(root) { FileOps.join($0, $1) }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() {
                let path = FileOps.join(dir, name)
                switch try? FileOps.lstatKind(path) {
                case .directory:
                    if !directories.contains(name) { directories.append(name) }
                case .file where Self.isRollout(name):
                    if let index = rollouts.firstIndex(where: { $0.0 == name }) {
                        rollouts[index].1.append(dir)
                    } else {
                        rollouts.append((name, [dir]))
                    }
                default:
                    break
                }
            }
        }
        let targetDir = relative.reduce(targetRoot) { FileOps.join($0, $1) }
        for (name, sourceDirs) in rollouts {
            pass.scanned += 1
            let destination = FileOps.join(targetDir, name)
            // Rollout names carry the session UUID, so an existing name is this conversation (or a dangling link).
            guard FileOps.isDefinitelyAbsent(destination) else { continue }
            guard (try? FileOps.ensureDirectory(targetDir)) != nil else { return }
            for dir in sourceDirs {
                let source = FileOps.join(dir, name)
                if link(source, destination) == 0 || (errno == EXDEV && symlink(source, destination) == 0) {
                    pass.linked += 1
                    break
                }
                if errno == EEXIST { break }
            }
        }
        for name in directories {
            visit(relative + [name], sourceRoots: sourceRoots, targetRoot: targetRoot, pass: &pass)
        }
    }

    static func isRollout(_ name: String) -> Bool {
        name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst")
    }

    static func isReadyForBridgedHistory(_ home: URL) -> Bool {
        guard let database = newestStateDatabase(in: home) else {
            return hasRollouts(home.appendingPathComponent("sessions").path)
        }
        return backfillComplete(database)
    }

    static func newestStateDatabase(in home: URL) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        var newest: (version: Int, name: String)?
        for name in names {
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst("state_".count).dropLast(".sqlite".count))
            else { continue }
            if newest.map({ version > $0.version }) ?? true { newest = (version, name) }
        }
        return newest.map { FileOps.join(home.path, $0.name) }
    }

    private static func hasRollouts(_ dir: String) -> Bool {
        guard let enumerator = FileManager.default.enumerator(atPath: dir) else { return false }
        while let name = enumerator.nextObject() as? String {
            if isRollout(name) { return true }
        }
        return false
    }

    /// Reads `backfill_state.status` read-only; anything but `complete` (or an unreadable DB) means not ready.
    static func backfillComplete(_ path: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT status FROM backfill_state WHERE id = 1", -1, &statement, nil) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return false }
        return String(cString: text) == "complete"
    }
}
