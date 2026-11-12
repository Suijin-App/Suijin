import Darwin
import Foundation

/// Locations and ownership of Codex account homes: `<dataRoot>/codex-homes/<uuid>/home` is the account's
/// `CODEX_HOME`, marked by `home/.sevinda-managed-home` (the account id) once created.
public struct CodexHomeStore: Sendable {
    public static let markerName = ".sevinda-managed-home"

    public let root: URL
    public let realHome: URL

    public init(dataRoot: URL, realHome: URL) {
        root = URL(fileURLWithPath: FileOps.resolve(dataRoot.path), isDirectory: true)
            .appendingPathComponent("codex-homes", isDirectory: true)
        self.realHome = realHome
    }

    /// The user's own Codex home, only ever read.
    public var systemHome: URL { realHome.appendingPathComponent(".codex", isDirectory: true) }
    public var pointerFile: URL { root.appendingPathComponent("selected-host") }

    public func home(for accountID: UUID) -> URL {
        root.appendingPathComponent(accountID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("home", isDirectory: true)
    }

    func mirrorRecord(forHome home: URL) -> URL {
        // Outside the home, so Codex never sees it.
        home.deletingLastPathComponent().appendingPathComponent("config-mirror.json")
    }

    public func accountID(forHome home: URL) -> UUID? {
        let path = FileOps.resolve(home.path)
        let folder = (path as NSString).deletingLastPathComponent
        guard (path as NSString).lastPathComponent == "home",
              FileOps.resolve((folder as NSString).deletingLastPathComponent) == FileOps.resolve(root.path),
              let id = UUID(uuidString: (folder as NSString).lastPathComponent),
              FileOps.resolve(self.home(for: id).path) == path
        else { return nil }
        return id
    }

    /// Creates the home (700) and its ownership marker (600). Refuses a path that runs through a symlink below the
    /// root, lands inside `~/.codex`, or already carries another account's marker.
    func create(accountID: UUID) throws -> URL {
        let home = home(for: accountID)
        let rootPath = FileOps.resolve(root.path)
        var cursor = rootPath
        for part in FileOps.resolve(home.path).dropFirst(rootPath.count).split(separator: "/") {
            cursor = FileOps.join(cursor, String(part))
            if try FileOps.lstatKind(cursor) == .symlink {
                throw AccountsError.unsafePath("Codex home path contains a link")
            }
        }
        try assertOutsideSystemHome(home.path)
        let markerPath = home.appendingPathComponent(Self.markerName).path
        if let kind = try FileOps.lstatKind(markerPath) {
            guard kind == .file, try readMarker(markerPath) == accountID.uuidString.lowercased() else {
                throw AccountsError.notOwned("Codex home ownership marker does not match its account")
            }
        }
        try FileOps.ensureDirectory(home.path, mode: 0o700)
        _ = chmod(home.path, 0o700)
        _ = chmod(home.deletingLastPathComponent().path, 0o700)
        try FileOps.writeAtomically(Data("\(accountID.uuidString.lowercased())\n".utf8), to: markerPath, mode: 0o600)
        return try verify(home: home)
    }

    /// Ownership check before any use: the canonical home must be `<root>/<id>/home` for the id its path names,
    /// outside `~/.codex`, and carry a regular-file marker with that id. Returns the home as given (its spelling is
    /// what gets injected as `CODEX_HOME`).
    @discardableResult
    func verify(home: URL) throws -> URL {
        guard let id = accountID(forHome: home) else {
            throw AccountsError.unsafePath("Codex home is outside Sevinda account storage")
        }
        guard let canonicalHome = try FileOps.realpath(home.path) else {
            throw AccountsError.notOwned("Codex home directory does not exist")
        }
        guard let canonicalRoot = try FileOps.realpath(root.path) else {
            throw AccountsError.notOwned("Codex account storage does not exist")
        }
        let expected = try FileOps.canonicalPath(FileOps.join(canonicalRoot, id.uuidString.lowercased(), "home"))
        guard canonicalHome == expected else {
            throw AccountsError.unsafePath("Codex home does not match its account id")
        }
        try assertOutsideSystemHome(canonicalHome)
        guard canonicalHome != canonicalRoot, FileOps.isInsideOrEqual(canonicalHome, root: canonicalRoot) else {
            throw AccountsError.unsafePath("Codex home is outside Sevinda account storage")
        }
        let markerPath = FileOps.join(canonicalHome, Self.markerName)
        guard try FileOps.lstatKind(markerPath) == .file else {
            throw AccountsError.notOwned("Codex home is missing its ownership marker")
        }
        guard try readMarker(markerPath) == id.uuidString.lowercased() else {
            throw AccountsError.notOwned("Codex home ownership marker does not match its account")
        }
        return home
    }

    private func assertOutsideSystemHome(_ path: String) throws {
        let candidate = try FileOps.canonicalPath(path)
        let system = try FileOps.canonicalPath(systemHome.path)
        // A redirected storage root must never allow managed writes into, or around, the user's Codex home.
        if FileOps.isInsideOrEqual(candidate, root: system) || FileOps.isInsideOrEqual(system, root: candidate) {
            throw AccountsError.unsafePath("Codex home overlaps the system Codex home")
        }
    }

    private func readMarker(_ path: String) throws -> String {
        guard let data = try FileOps.readData(path) else { return "" }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Owned account homes, for session sharing between accounts.
    func ownedHomes() -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.sorted().compactMap { name in
            guard let id = UUID(uuidString: name) else { return nil }
            return try? verify(home: home(for: id))
        }
    }

    func remove(home: URL) throws {
        try verify(home: home)
        try FileOps.removeTree(home.deletingLastPathComponent().path)
    }
}
