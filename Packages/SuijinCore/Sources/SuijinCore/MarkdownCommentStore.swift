import Foundation
import GRDB

public enum MarkdownCommentError: Error, LocalizedError, Equatable {
    case invalidFilePath
    case invalidAnchor

    public var errorDescription: String? {
        switch self {
        case .invalidFilePath: "A comment's file path must be absolute and standardized."
        case .invalidAnchor: "A comment must quote a non-empty span of its file."
        }
    }
}

// The anchor is stored flat, one column per field, rather than as a JSON blob.
extension MarkdownComment: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "markdown_comment" }

    public init(row: Row) throws {
        let rawStatus: String = row["status"]
        guard let status = MarkdownCommentStatus(rawValue: rawStatus) else {
            throw DatabaseError(message: "Unknown markdown comment status \(rawStatus)")
        }
        id = row["id"]
        workspaceID = row["workspaceID"]
        worktreeID = row["worktreeID"]
        filePath = row["filePath"]
        body = row["body"]
        anchor = MarkdownCommentAnchor(
            quote: row["quote"], prefix: row["prefix"], suffix: row["suffix"],
            startOffset: row["startOffset"], endOffset: row["endOffset"],
            startLine: row["startLine"], endLine: row["endLine"], isDetached: row["isDetached"]
        )
        self.status = status
        createdAt = Date(timeIntervalSinceReferenceDate: row["createdAt"])
        updatedAt = Self.date(row["updatedAt"])
        sentAt = Self.date(row["sentAt"])
        sentToSession = row["sentToSession"]
        resolvedAt = Self.date(row["resolvedAt"])
        agentReply = row["agentReply"]
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["workspaceID"] = workspaceID
        container["worktreeID"] = worktreeID
        container["filePath"] = filePath
        container["body"] = body
        container["quote"] = anchor.quote
        container["prefix"] = anchor.prefix
        container["suffix"] = anchor.suffix
        container["startOffset"] = anchor.startOffset
        container["endOffset"] = anchor.endOffset
        container["startLine"] = anchor.startLine
        container["endLine"] = anchor.endLine
        container["isDetached"] = anchor.isDetached
        container["status"] = status.rawValue
        container["createdAt"] = createdAt.timeIntervalSinceReferenceDate
        container["updatedAt"] = updatedAt?.timeIntervalSinceReferenceDate
        container["sentAt"] = sentAt?.timeIntervalSinceReferenceDate
        container["sentToSession"] = sentToSession
        container["resolvedAt"] = resolvedAt?.timeIntervalSinceReferenceDate
        container["agentReply"] = agentReply
    }

    private static func date(_ interval: Double?) -> Date? {
        interval.map(Date.init(timeIntervalSinceReferenceDate:))
    }
}

extension SuijinStore {
    /// Comments on one file of a context (`worktreeID == nil` is the workspace's main checkout), oldest first.
    public func markdownComments(filePath: String, workspaceID: UUID, worktreeID: UUID?) throws -> [MarkdownComment] {
        let path = MarkdownComment.standardizedPath(filePath)
        return try dbQueue.read { db in
            try MarkdownComment
                .filter(Column("workspaceID") == workspaceID && Column("worktreeID") == worktreeID
                        && Column("filePath") == path)
                .order(Column("createdAt")).fetchAll(db)
        }
    }

    /// Comments on every file of a context (`worktreeID == nil` is the workspace's main checkout, not its
    /// worktrees), oldest first.
    public func markdownComments(workspaceID: UUID, worktreeID: UUID?) throws -> [MarkdownComment] {
        try dbQueue.read { db in
            try MarkdownComment.filter(Column("workspaceID") == workspaceID && Column("worktreeID") == worktreeID)
                .order(Column("createdAt")).fetchAll(db)
        }
    }

    /// Comments last pasted into an agent session, oldest first.
    public func markdownComments(sentToSession session: UUID) throws -> [MarkdownComment] {
        try dbQueue.read { db in
            try MarkdownComment.filter(Column("sentToSession") == session).order(Column("createdAt")).fetchAll(db)
        }
    }

    /// Every comment pasted into a session and not answered yet, in all workspaces, oldest first.
    public func markdownCommentsWaitingForAgents() throws -> [MarkdownComment] {
        try dbQueue.read { db in
            try MarkdownComment
                .filter(Column("status") == MarkdownCommentStatus.sent.rawValue && Column("sentToSession") != nil)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }

    public func markdownComment(id: UUID) throws -> MarkdownComment? {
        try dbQueue.read { db in try MarkdownComment.fetchOne(db, key: id) }
    }

    /// Inserts or updates a comment. Rejects a relative or unstandardized file path and an inconsistent anchor.
    public func save(_ comment: MarkdownComment) throws {
        guard comment.filePath.hasPrefix("/"), comment.filePath == MarkdownComment.standardizedPath(comment.filePath)
        else { throw MarkdownCommentError.invalidFilePath }
        guard comment.anchor.isValid else { throw MarkdownCommentError.invalidAnchor }
        try dbQueue.write { db in try comment.save(db) }
    }

    /// Moves a comment: writes its anchor and nothing else. A comment that was deleted meanwhile stays deleted, and
    /// its status, note and answer are never touched, so a position written late cannot undo a newer change.
    public func updateMarkdownCommentAnchor(id: UUID, anchor: MarkdownCommentAnchor) throws {
        guard anchor.isValid else { throw MarkdownCommentError.invalidAnchor }
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE markdown_comment
                    SET quote = ?, prefix = ?, suffix = ?, startOffset = ?, endOffset = ?, startLine = ?, endLine = ?,
                        isDetached = ?
                    WHERE id = ?
                    """,
                arguments: [anchor.quote, anchor.prefix, anchor.suffix, anchor.startOffset, anchor.endOffset,
                            anchor.startLine, anchor.endLine, anchor.isDetached, id])
        }
    }

    /// Records an agent's answer, in one transaction, only when the comment still waits on `session` and the answer
    /// is not older than the moment it was sent (an answer to an earlier version of the comment is dropped).
    /// Returns the answered comment, or nil when nothing was changed.
    public func resolveMarkdownComment(id: UUID, session: UUID, outcome: MarkdownCommentOutcome, reply: String?,
                                       at date: Date) throws -> MarkdownComment? {
        try dbQueue.write { db in
            guard var comment = try MarkdownComment.fetchOne(db, key: id), comment.status == .sent,
                  comment.sentToSession == session else { return nil }
            // The answer's time crossed a process boundary with whole seconds; allow for that.
            if let sentAt = comment.sentAt, date < sentAt.addingTimeInterval(-1) { return nil }
            comment.resolve(outcome, reply: reply, at: date)
            try db.execute(
                sql: "UPDATE markdown_comment SET status = ?, resolvedAt = ?, agentReply = ? WHERE id = ?",
                arguments: [comment.status.rawValue, date.timeIntervalSinceReferenceDate, reply, id])
            return comment
        }
    }

    public func deleteMarkdownComment(id: UUID) throws {
        _ = try dbQueue.write { db in try MarkdownComment.deleteOne(db, key: id) }
    }
}
