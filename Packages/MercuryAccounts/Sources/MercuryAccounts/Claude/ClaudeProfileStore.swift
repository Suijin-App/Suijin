import Darwin
import Foundation

/// Locations and ownership of Claude profile folders: `<dataRoot>/claude-profiles/<uuid>/home` is the account's
/// `CLAUDE_CONFIG_DIR`; `profile.json` beside it marks a completed setup.
public struct ClaudeProfileStore: Sendable {
    public let root: URL
    public let realHome: URL
    /// The user's own `CLAUDE_CONFIG_DIR`, when set; `~/.claude` otherwise.
    public let userConfigDir: URL?

    public init(dataRoot: URL, realHome: URL, userConfigDir: URL? = nil) {
        root = URL(fileURLWithPath: FileOps.resolve(dataRoot.path), isDirectory: true)
            .appendingPathComponent("claude-profiles", isDirectory: true)
        self.realHome = realHome
        self.userConfigDir = userConfigDir
    }

    /// The default Claude home profiles share from.
    public var defaultHome: URL {
        userConfigDir ?? realHome.appendingPathComponent(".claude", isDirectory: true)
    }

    public var pointerFile: URL { root.appendingPathComponent("selected-host") }

    /// Lowercase UUIDs keep one stable spelling: Claude names the Keychain item after the exact path string.
    public func home(for accountID: UUID) -> URL {
        root.appendingPathComponent(accountID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("home", isDirectory: true)
    }

    func markerFile(forHome home: URL) -> URL {
        home.deletingLastPathComponent().appendingPathComponent("profile.json")
    }

    func settingsRecord(forHome home: URL) -> URL {
        // Beside the setup marker, outside the folder Claude reads.
        home.deletingLastPathComponent().appendingPathComponent("settings-sync.json")
    }

    /// The account a home path belongs to, if it has the exact `<root>/<uuid>/home` shape.
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

    public func isSetUp(home: URL) -> Bool {
        (try? FileOps.lstatKind(home.path)) == .directory
            && (try? FileOps.lstatKind(markerFile(forHome: home).path)) == .file
    }

    // MARK: Safety checks

    /// Rejects homes that escape the profile root, run through a symlink below it, or overlap a default Claude home.
    public func validate(home: URL) throws {
        guard let id = accountID(forHome: home) else {
            throw AccountsError.unsafePath("Claude profile does not match its account namespace")
        }
        try assertDescendantWithoutLinks(FileOps.resolve(self.home(for: id).path))
        try assertOutsideDefaultHomes(home.path)
    }

    private func assertDescendantWithoutLinks(_ destination: String) throws {
        let rootPath = FileOps.resolve(root.path)
        guard destination != rootPath, FileOps.isInsideOrEqual(destination, root: rootPath) else {
            throw AccountsError.unsafePath("Claude profile destination escapes its root")
        }
        // The caller owns the root; links below it must not redirect profile writes.
        var cursor = rootPath
        for part in destination.dropFirst(rootPath.count).split(separator: "/") {
            cursor = FileOps.join(cursor, String(part))
            if try FileOps.lstatKind(cursor) == .symlink {
                throw AccountsError.unsafePath("Claude profile path contains a link")
            }
        }
    }

    /// Profiles and default homes must not overlap in either direction.
    func assertOutsideDefaultHomes(_ profileHome: String) throws {
        var defaults = [
            realHome.appendingPathComponent(".claude").path,
            realHome.appendingPathComponent(".config/claude").path,
        ]
        if let userConfigDir { defaults.append(userConfigDir.path) }
        let profile = try FileOps.canonicalPath(profileHome)
        for defaultHome in defaults {
            let other = try FileOps.canonicalPath(defaultHome)
            if FileOps.isInsideOrEqual(profile, root: other) || FileOps.isInsideOrEqual(other, root: profile) {
                throw AccountsError.unsafePath("Claude profile and default home must be separate directories")
            }
        }
    }

    // MARK: Lifecycle

    private struct Marker: Codable, Equatable {
        var version: Int
        var accountId: String
        var runtime: String
    }

    /// Validates ownership, creates the home (700), and returns the marker writer that must run last in setup.
    func prepareDirectory(accountID: UUID) throws -> (home: URL, markSetUp: @Sendable () throws -> Void) {
        let home = home(for: accountID)
        try validate(home: home)
        let markerPath = markerFile(forHome: home).path
        let expected = Marker(version: 1, accountId: accountID.uuidString.lowercased(), runtime: "host")
        let existing = try readMarker(markerPath)
        if let existing, existing != expected {
            throw AccountsError.notOwned("Claude profile belongs to another account")
        }
        let homeKind = try FileOps.lstatKind(home.path)
        if let homeKind, homeKind != .directory {
            throw AccountsError.unsafePath("Claude profile home is not a directory")
        }
        // A marker without its home is stale: setup must run again before the profile counts as ready.
        if homeKind == nil, existing != nil { unlink(markerPath) }
        try FileOps.ensureDirectory(home.path, mode: 0o700)
        _ = chmod(home.path, 0o700)
        _ = chmod(home.deletingLastPathComponent().path, 0o700)
        let needsMarker = existing == nil || homeKind == nil
        let data = try JSONEncoder.sortedKeys.encode(expected) + Data("\n".utf8)
        return (home, {
            if needsMarker { try FileOps.writeAtomically(data, to: markerPath, mode: 0o600) }
        })
    }

    private func readMarker(_ path: String) throws -> Marker? {
        guard let kind = try FileOps.lstatKind(path) else { return nil }
        guard kind == .file else { throw AccountsError.notOwned("Claude profile marker is not a file") }
        guard let data = try FileOps.readData(path), let marker = try? JSONDecoder().decode(Marker.self, from: data)
        else { throw AccountsError.unreadable("the Claude profile marker") }
        return marker
    }

    /// Deletes `<root>/<uuid>` after validating the home; symlinked shared folders are unlinked, never followed.
    func removeProfile(home: URL) throws {
        try validate(home: home)
        try FileOps.removeTree(home.deletingLastPathComponent().path)
    }
}

extension JSONEncoder {
    static var sortedKeys: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
