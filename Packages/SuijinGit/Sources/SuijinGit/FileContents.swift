import Foundation

/// One side of a diff: the version before the change, or the one after it.
public enum DiffSide: Hashable, Sendable {
    case old, new
}

/// Why the bytes of a file version could not be returned.
public enum FileContentsError: Error, LocalizedError, Equatable, Sendable {
    /// The version is larger than the caller accepts; nothing was read.
    case tooLarge(path: String, size: Int, limit: Int)
    /// The path is not a plain path inside the checkout.
    case invalidPath(String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let path, let size, let limit):
            let format = ByteCountFormatter()
            return "\(path) is \(format.string(fromByteCount: Int64(size))), more than the \(format.string(fromByteCount: Int64(limit))) that can be shown."
        case .invalidPath(let path):
            return "\(path) is not a path inside the checkout."
        }
    }
}

extension DiffService {
    /// The bytes of the file at `path` (relative to the toplevel) as stored in `revision` (a commit or tree). Nil when
    /// `revision` has no file there (missing, a directory or a submodule). Throws `FileContentsError.tooLarge` without
    /// reading the blob when it exceeds `maximumSize` bytes.
    public func blob(at path: String, revision: String, maximumSize: Int = .max) async throws -> Data? {
        try Self.validate(path)
        // `ls-tree` matches paths literally (no globs) and reports type and size, so a missing path, a directory or a
        // submodule are told apart without a failing command, and a huge blob is never read.
        let listing = try await runner.run(["ls-tree", "-l", "-z", "--end-of-options", revision, "--", path], in: worktree)
        guard let entry = Self.parseTreeEntry(listing, path: path) else { return nil }
        guard entry.size <= maximumSize else { throw FileContentsError.tooLarge(path: path, size: entry.size, limit: maximumSize) }
        return try await runner.run(["cat-file", "blob", entry.object], in: worktree)
    }

    /// The bytes of a file on `side` of `scope`. The old side is the scope's base revision (HEAD for `.uncommitted`, the
    /// merge base for `.committed` and `.againstBase`, the parent for `.commit`); the new side is the scope's tip commit,
    /// or the working tree for scopes that include it. Pass the old path of a renamed or copied file for the old side.
    /// Nil when the file does not exist on that side.
    public func contents(of path: String, side: DiffSide, scope: DiffScope, maximumSize: Int = .max) async throws -> Data? {
        switch side {
        case .old:
            return try await blob(at: path, revision: baseRevision(scope), maximumSize: maximumSize)
        case .new:
            if let tip = Self.tip(of: scope) { return try await blob(at: path, revision: tip, maximumSize: maximumSize) }
            return try workingTreeFile(at: path, maximumSize: maximumSize)
        }
    }

    /// A regular file in the checkout; nil when it is missing or not a regular file (a directory, a symbolic link).
    private func workingTreeFile(at path: String, maximumSize: Int) throws -> Data? {
        try Self.validate(path)
        let url = worktree.appendingPathComponent(path, isDirectory: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maximumSize else { throw FileContentsError.tooLarge(path: path, size: size, limit: maximumSize) }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Rejects absolute paths and `..` components, which would leave the checkout.
    private static func validate(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !components.contains(".."), !path.contains("\0") else {
            throw FileContentsError.invalidPath(path)
        }
    }

    /// The blob entry for exactly `path` in `git ls-tree -l -z` output (`mode SP type SP object SP size TAB path NUL`).
    static func parseTreeEntry(_ data: Data, path: String) -> (object: String, size: Int)? {
        for record in data.split(separator: 0) {
            let text = String(decoding: record, as: UTF8.self)
            guard let tab = text.firstIndex(of: "\t"), text[text.index(after: tab)...] == path else { continue }
            let fields = text[..<tab].split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 4, fields[1] == "blob", let size = Int(fields[3]) else { return nil }
            return (String(fields[2]), size)
        }
        return nil
    }
}
