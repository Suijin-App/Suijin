import Foundation

public enum FileChangeKind: Hashable, Sendable {
    case added, deleted, modified
    case renamed(from: String)
    case copied(from: String)
    case typeChanged, unmerged
}

/// A path changed in a diff scope, relative to the repository toplevel.
public struct ChangedFile: Hashable, Sendable {
    public var path: String
    public var kind: FileChangeKind

    public init(path: String, kind: FileChangeKind) {
        self.path = path
        self.kind = kind
    }
}

public enum DiffLineKind: Hashable, Sendable {
    case context, added, deleted
    /// `\ No newline at end of file`, applying to the line before it.
    case noNewlineMarker
}

public struct DiffLine: Hashable, Sendable {
    public var kind: DiffLineKind
    /// The line without its leading ` `, `+`, `-` or `\` marker and without the newline.
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?

    public init(kind: DiffLineKind, text: String, oldLine: Int?, newLine: Int?) {
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
    }
}

public struct DiffHunk: Hashable, Sendable {
    /// The whole `@@ -a,b +c,d @@ section` line.
    public var header: String
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [DiffLine]

    public init(header: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [DiffLine] = []) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

public struct FileDiff: Hashable, Sendable {
    /// Nil for an added file.
    public var oldPath: String?
    /// Nil for a deleted file.
    public var newPath: String?
    public var isBinary: Bool
    public var hunks: [DiffHunk]
    /// Rename or copy similarity in percent, when git reported one.
    public var similarity: Int?

    public init(oldPath: String?, newPath: String?, isBinary: Bool = false, hunks: [DiffHunk] = [], similarity: Int? = nil) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.isBinary = isBinary
        self.hunks = hunks
        self.similarity = similarity
    }

    /// The path to show: the new path, or the old one for a deleted file.
    public var displayPath: String { newPath ?? oldPath ?? "" }
}

public enum DiffScope: Hashable, Sendable {
    /// Everything since the merge base with the given branch: `base...HEAD` plus working-tree changes.
    case againstBase(String)
    /// HEAD against the working tree, including untracked files.
    case uncommitted
    /// Only what is committed: the merge base with the given branch against HEAD. No working-tree changes.
    case committed(String)
    /// What one commit changed: its first parent (the empty tree for a root commit) against the commit.
    case commit(String)
}

/// One commit in a list of a branch's commits.
public struct CommitSummary: Hashable, Sendable, Identifiable {
    public var sha: String
    public var shortSHA: String
    public var subject: String
    public var author: String
    public var date: Date
    public var id: String { sha }

    public init(sha: String, shortSHA: String, subject: String, author: String, date: Date) {
        self.sha = sha
        self.shortSHA = shortSHA
        self.subject = subject
        self.author = author
        self.date = date
    }
}
