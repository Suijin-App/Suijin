import Darwin
import Foundation
import SevindaAgents
import SevindaCore

/// Why a conversation could not be made available to another account.
public enum ConversationTransferError: Error, Equatable, Sendable {
    /// The conversation id is not one the CLI accepts.
    case invalidConversationID
    /// The source account's folder has no history file for the conversation.
    case historyNotFound
    /// The target account's folder does not exist (the account was never used or signed in).
    case targetMissing
    /// A different file already has the history file's name in the target; both are left as they are.
    case conflict(path: String)
    /// A destination would leave the target's history folder; nothing was written.
    case unsafeDestination(path: String)
    /// Reading or writing a file failed.
    case io(path: String, code: Int32)
}

/// Makes one Claude Code or Codex conversation resumable under another account by placing its history files in the
/// target account's folder, at the path the CLI looks for them:
///
/// - Claude Code: `<config dir>/projects/<encoded cwd>/<id>.jsonl`, plus the conversation's own folder
///   `<id>/` beside it (`subagents/`, `tool-results/`) when it has one.
/// - Codex: `<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<timestamp>-<id>.jsonl` (or `.jsonl.zst`), same dated path.
///
/// Files are hardlinked (one physical log, as Sevinda already shares Codex rollouts between homes), or copied when the
/// folders are on different volumes. Sources are only read; an existing destination is never replaced: the same
/// file (or identical content) counts as done, anything else is a conflict. Nothing outside the target's history
/// folder is written: no credentials, settings or state.
public struct ConversationTransfer: Sendable {
    public let provider: AccountProvider
    public let conversationID: String
    /// The session's working directory; Claude files conversations under it.
    public let cwd: String
    /// The source account's `CLAUDE_CONFIG_DIR` or `CODEX_HOME`.
    public let source: URL
    /// The target account's `CLAUDE_CONFIG_DIR` or `CODEX_HOME`.
    public let target: URL

    public init(provider: AccountProvider, conversationID: String, cwd: String, source: URL, target: URL) {
        self.provider = provider
        self.conversationID = conversationID
        self.cwd = cwd
        self.source = source
        self.target = target
    }

    /// One file to place: `source` read, `destination` created.
    public struct Step: Equatable, Sendable {
        public let source: String
        public let destination: String
    }

    /// What `run` did.
    public struct Report: Equatable, Sendable {
        public var linked = 0
        public var copied = 0
        /// Destinations that were already the same file or had the same content.
        public var present = 0
    }

    // MARK: Plan

    /// The files to place, after checking that the history exists, every destination stays inside the target's
    /// history folder, and no destination holds different content. Writes nothing.
    public func plan() throws -> [Step] {
        guard let id = AgentResume.validSessionID(conversationID) else { throw ConversationTransferError.invalidConversationID }
        guard (try? FileOps.statKind(target.path)) == .directory else { throw ConversationTransferError.targetMissing }
        let steps: [Step]
        let allowedRoot: String
        switch provider {
        case .claude:
            let found = try claudeSource(id: id)
            let folder = FileOps.join(target.path, "projects", Self.claudeProjectFolder(forCwd: canonicalCwd))
            allowedRoot = folder
            var list = [Step(source: found.transcript, destination: FileOps.join(folder, "\(id).jsonl"))]
            if let sidecar = found.sidecar {
                list += try Self.files(below: sidecar).map {
                    Step(source: FileOps.join(sidecar, $0), destination: FileOps.join(folder, id, $0))
                }
            }
            steps = list
        case .codex:
            let (dated, name) = try codexSource(id: id)
            allowedRoot = FileOps.join(target.path, "sessions")
            steps = [Step(source: FileOps.join(source.path, "sessions", dated, name),
                          destination: FileOps.join(target.path, "sessions", dated, name))]
        }
        for step in steps {
            guard Self.isAllowed(step.destination, root: allowedRoot) else {
                throw ConversationTransferError.unsafeDestination(path: step.destination)
            }
            if try Self.existingState(step) == .different {
                throw ConversationTransferError.conflict(path: step.destination)
            }
        }
        return steps
    }

    /// Places every planned file. A failure part way leaves what was placed (each file is complete) and every source
    /// untouched.
    @discardableResult
    public func run() throws -> Report {
        var report = Report()
        for step in try plan() {
            switch try Self.place(step) {
            case .linked: report.linked += 1
            case .copied: report.copied += 1
            case .present: report.present += 1
            }
        }
        return report
    }

    // MARK: Claude

    /// The folder name Claude Code files a working directory's conversations under: every UTF-16 unit that is not an
    /// ASCII letter or digit becomes `-`; a name longer than 200 is cut to 200 and gets `-` and a base-36 hash of the
    /// path (Claude Code's `sanitizePath`, read from its 2.1 bundle).
    public static func claudeProjectFolder(forCwd path: String) -> String {
        let units = path.utf16.map { unit -> Character in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: Character(UnicodeScalar(UInt8(unit)))
            default: "-"
            }
        }
        let name = String(units)
        guard name.count > maxClaudeFolderLength else { return name }
        return String(name.prefix(maxClaudeFolderLength)) + "-" + String(abs(Int64(javaStyleHash(path))), radix: 36)
    }

    static let maxClaudeFolderLength = 200

    /// `h = h * 31 + unit` over UTF-16 units in 32-bit arithmetic, as Claude Code hashes long paths.
    static func javaStyleHash(_ text: String) -> Int32 {
        text.utf16.reduce(Int32(0)) { hash, unit in (hash << 5) &- hash &+ Int32(unit) }
    }

    /// Claude files a conversation under its process's working directory, which the system reports with symlinks
    /// resolved (`/private/tmp`, not `/tmp`).
    private var canonicalCwd: String {
        (try? FileOps.realpath(cwd)).flatMap(\.self) ?? FileOps.resolve(cwd)
    }

    private func claudeSource(id: String) throws -> (transcript: String, sidecar: String?) {
        let projects = FileOps.join(source.path, "projects")
        var folders = [Self.claudeProjectFolder(forCwd: canonicalCwd), Self.claudeProjectFolder(forCwd: FileOps.resolve(cwd))]
        // A session whose folder moved or was renamed still has its history under the name it started with.
        let others = ((try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? []).sorted()
        folders += others.filter { !folders.contains($0) }
        for folder in folders {
            let transcript = FileOps.join(projects, folder, "\(id).jsonl")
            guard (try? FileOps.lstatKind(transcript)) == .file else { continue }
            let sidecar = FileOps.join(projects, folder, id)
            return (transcript, (try? FileOps.lstatKind(sidecar)) == .directory ? sidecar : nil)
        }
        throw ConversationTransferError.historyNotFound
    }

    /// Regular files below `root`, as paths relative to it; links and anything else are skipped.
    private static func files(below root: String, relative: String = "") throws -> [String] {
        let dir = relative.isEmpty ? root : FileOps.join(root, relative)
        var result: [String] = []
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() {
            let child = relative.isEmpty ? name : FileOps.join(relative, name)
            switch try? FileOps.lstatKind(FileOps.join(root, child)) {
            case .file: result.append(child)
            case .directory: result += try files(below: root, relative: child)
            default: continue
            }
        }
        return result
    }

    // MARK: Codex

    /// The rollout's dated folder (`YYYY/MM/DD`) and file name in the source's `sessions`.
    private func codexSource(id: String) throws -> (dated: String, name: String) {
        let sessions = FileOps.join(source.path, "sessions")
        let suffixes = ["-\(id).jsonl", "-\(id).jsonl.zst"].map { $0.lowercased() }
        // Newest first: a conversation is usually continued soon after it ran.
        for year in Self.entries(sessions, digits: 4) {
            for month in Self.entries(FileOps.join(sessions, year), digits: 2) {
                for day in Self.entries(FileOps.join(sessions, year, month), digits: 2) {
                    let dir = FileOps.join(sessions, year, month, day)
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                    if let name = names.first(where: { name in
                        name.hasPrefix("rollout-") && suffixes.contains { name.lowercased().hasSuffix($0) }
                            && (try? FileOps.lstatKind(FileOps.join(dir, name))) == .file
                    }) {
                        return ("\(year)/\(month)/\(day)", name)
                    }
                }
            }
        }
        throw ConversationTransferError.historyNotFound
    }

    /// Folder names of exactly `digits` digits, newest first.
    private static func entries(_ dir: String, digits: Int) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.count == digits && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
            .sorted(by: >)
    }

    // MARK: Placing files

    /// Whether `path` lies strictly inside `root`, spelled without `.`, `..` or empty components.
    static func isAllowed(_ path: String, root: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        return path != FileOps.resolve(root) && FileOps.isInsideOrEqual(path, root: FileOps.resolve(root))
    }

    enum Existing { case absent, same, different }

    /// Whether the destination is free, already this file (or identical content), or something else.
    static func existingState(_ step: Step) throws -> Existing {
        guard let kind = try lstatOrThrow(step.destination) else { return .absent }
        guard kind == .file else { return .different }
        return try sameContent(step.source, step.destination) ? .same : .different
    }

    private static func lstatOrThrow(_ path: String) throws -> EntryKind? {
        do {
            return try FileOps.lstatKind(path)
        } catch {
            throw ConversationTransferError.io(path: path, code: Int32((error as NSError).code))
        }
    }

    enum Placed { case linked, copied, present }

    /// Hardlinks the source to the destination, or copies it beside the destination and moves it in without replacing
    /// anything; an existing destination with the same content counts as placed.
    static func place(_ step: Step) throws -> Placed {
        let directory = (step.destination as NSString).deletingLastPathComponent
        do {
            try FileOps.ensureDirectory(directory, mode: 0o700)
        } catch {
            throw ConversationTransferError.io(path: directory, code: Int32((error as NSError).code))
        }
        if link(step.source, step.destination) == 0 { return .linked }
        let code = errno
        if code == EEXIST { return try settledExisting(step) }
        guard [EXDEV, EPERM, ENOTSUP, EMLINK].contains(code) else {
            throw ConversationTransferError.io(path: step.destination, code: code)
        }
        let staged = FileOps.join(directory, ".sevinda-\(UUID().uuidString).tmp")
        defer { unlink(staged) }
        guard copyfile(step.source, staged, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_EXCL)) == 0 else {
            throw ConversationTransferError.io(path: step.source, code: errno)
        }
        _ = chmod(staged, 0o600)
        if renamex_np(staged, step.destination, UInt32(RENAME_EXCL)) == 0 { return .copied }
        let renameCode = errno
        if renameCode == EEXIST { return try settledExisting(step) }
        throw ConversationTransferError.io(path: step.destination, code: renameCode)
    }

    private static func settledExisting(_ step: Step) throws -> Placed {
        guard try existingState(step) == .same else { throw ConversationTransferError.conflict(path: step.destination) }
        return .present
    }

    /// The same file (device and inode), or the same bytes.
    static func sameContent(_ lhs: String, _ rhs: String) throws -> Bool {
        var left = stat(), right = stat()
        guard stat(lhs, &left) == 0 else { throw ConversationTransferError.io(path: lhs, code: errno) }
        guard stat(rhs, &right) == 0 else { throw ConversationTransferError.io(path: rhs, code: errno) }
        if left.st_dev == right.st_dev && left.st_ino == right.st_ino { return true }
        guard left.st_size == right.st_size else { return false }
        guard let a = FileHandle(forReadingAtPath: lhs) else { throw ConversationTransferError.io(path: lhs, code: EACCES) }
        guard let b = FileHandle(forReadingAtPath: rhs) else { throw ConversationTransferError.io(path: rhs, code: EACCES) }
        defer {
            try? a.close()
            try? b.close()
        }
        while true {
            let chunkA = try a.read(upToCount: 1 << 16) ?? Data()
            let chunkB = try b.read(upToCount: 1 << 16) ?? Data()
            if chunkA != chunkB { return false }
            if chunkA.isEmpty { return true }
        }
    }
}
