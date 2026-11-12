import Foundation
import GRDB

/// Which comparison a diff note was written against. Both compare with the working tree, so new-side line numbers
/// mean the same file lines in either scope.
public enum DiffNoteScope: String, Codable, Sendable, CaseIterable {
    /// HEAD against the working tree.
    case uncommitted
    /// The merge base with the base branch against the working tree.
    case branch
}

/// A review note on the new side of a file's diff, kept until the user deletes it and handed to an agent on request.
///
/// A note belongs to a worktree, or to the main checkout of a git workspace (`worktreeID == nil`).
public struct DiffNote: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var workspaceID: UUID
    /// Nil for the main checkout of the workspace.
    public var worktreeID: UUID?
    /// Path relative to the repository toplevel.
    public var filePath: String
    /// The path before a rename, when the file was renamed.
    public var oldPath: String?
    /// Inclusive start of a line range; nil for a single line or a file note. Never greater than `lineNumber`.
    public var startLine: Int?
    /// The (last) new-side line the note is about; 0 means the whole file.
    public var lineNumber: Int
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date?
    /// When the note was last handed to an agent; editing the note clears it.
    public var sentAt: Date?
    public var scope: DiffNoteScope
    /// Fingerprint of the noted lines when the note was written; when the lines at those numbers no longer match,
    /// the note may have drifted from what it describes.
    public var diffIdentity: String?

    public init(
        id: UUID = UUID(), workspaceID: UUID, worktreeID: UUID? = nil, filePath: String, oldPath: String? = nil,
        startLine: Int? = nil, lineNumber: Int, body: String, createdAt: Date = Date(), updatedAt: Date? = nil,
        sentAt: Date? = nil, scope: DiffNoteScope, diffIdentity: String? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.worktreeID = worktreeID
        self.filePath = filePath
        self.oldPath = oldPath
        self.startLine = startLine
        self.lineNumber = lineNumber
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sentAt = sentAt
        self.scope = scope
        self.diffIdentity = diffIdentity
    }

    /// True for a note on the whole file rather than on lines.
    public var isFileNote: Bool { lineNumber == 0 }

    /// The note with a new body: marks it updated and unsent, so the edited text is handed to the agent again.
    public func edited(body: String, at date: Date = Date()) -> DiffNote {
        var copy = self
        copy.body = body
        copy.updatedAt = date
        copy.sentAt = nil
        return copy
    }
}

extension DiffNote: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "diff_note" }
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSinceReferenceDate }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSinceReferenceDate }
}

public enum DiffNoteError: Error, LocalizedError, Equatable {
    case invalidLineRange
    case emptyBody

    public var errorDescription: String? {
        switch self {
        case .invalidLineRange: "A note's start line must be between 1 and its end line."
        case .emptyBody: "A note cannot be empty."
        }
    }
}

extension SevindaStore {
    /// Notes of a worktree, oldest first.
    public func diffNotes(worktreeID: UUID) throws -> [DiffNote] {
        try dbQueue.read { db in
            try DiffNote.filter(Column("worktreeID") == worktreeID).order(Column("createdAt")).fetchAll(db)
        }
    }

    /// Notes of a workspace's main checkout (not of its worktrees), oldest first.
    public func diffNotes(mainCheckoutOf workspaceID: UUID) throws -> [DiffNote] {
        try dbQueue.read { db in
            try DiffNote.filter(Column("workspaceID") == workspaceID && Column("worktreeID") == nil)
                .order(Column("createdAt")).fetchAll(db)
        }
    }

    /// Inserts or updates a note. Rejects an empty body and a range that is not `1...lineNumber`.
    public func save(_ note: DiffNote) throws {
        guard !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DiffNoteError.emptyBody }
        guard note.lineNumber >= 0 else { throw DiffNoteError.invalidLineRange }
        if let start = note.startLine {
            guard note.lineNumber > 0, start >= 1, start <= note.lineNumber else { throw DiffNoteError.invalidLineRange }
        }
        try dbQueue.write { db in try note.save(db) }
    }

    public func deleteDiffNote(id: UUID) throws {
        _ = try dbQueue.write { db in try DiffNote.deleteOne(db, key: id) }
    }
}
