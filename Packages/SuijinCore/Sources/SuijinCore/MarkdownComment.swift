import Foundation

/// Where a Markdown comment stands: not handed to an agent yet, handed to one, or answered by it.
public enum MarkdownCommentStatus: String, Codable, Sendable, CaseIterable {
    /// Written but not handed to an agent (or edited/reopened since).
    case open
    /// Handed to an agent, no answer yet.
    case sent
    /// The agent reported the comment as addressed.
    case fixed
    /// The agent reported it would not or could not address the comment.
    case declined

    /// True once an agent has answered the comment.
    public var isResolved: Bool { self == .fixed || self == .declined }
}

/// How an agent answered a comment.
public enum MarkdownCommentOutcome: String, Codable, Sendable, CaseIterable {
    case fixed, declined

    /// The status a comment takes with this outcome.
    public var status: MarkdownCommentStatus {
        switch self {
        case .fixed: .fixed
        case .declined: .declined
        }
    }
}

/// Where a comment sits in its file: the quoted text, its surrounding context and its last known position.
///
/// Offsets are UTF-16 code units (`NSString`/`NSRange` compatible) into the text the anchor was last resolved
/// against; lines are 1-based and only for display. `MarkdownCommentAnchoring` builds, follows and re-finds anchors.
public struct MarkdownCommentAnchor: Codable, Hashable, Sendable {
    /// Maximum length, in UTF-16 code units, of `prefix` and `suffix`.
    public static let contextLength = 64

    /// The commented text, verbatim. Kept as it was when the anchor detaches, so the user can still read it.
    public var quote: String
    /// Up to `contextLength` UTF-16 units of text right before the quote.
    public var prefix: String
    /// Up to `contextLength` UTF-16 units of text right after the quote.
    public var suffix: String
    /// Inclusive start, in UTF-16 code units.
    public var startOffset: Int
    /// Exclusive end, in UTF-16 code units.
    public var endOffset: Int
    /// 1-based line of the first quoted character.
    public var startLine: Int
    /// 1-based line of the last quoted character.
    public var endLine: Int
    /// True when the quote could not be found in the file any more; offsets and lines are then stale.
    public var isDetached: Bool

    public init(
        quote: String, prefix: String, suffix: String, startOffset: Int, endOffset: Int, startLine: Int, endLine: Int,
        isDetached: Bool = false
    ) {
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.startLine = startLine
        self.endLine = endLine
        self.isDetached = isDetached
    }

    /// The quoted range in UTF-16 code units.
    public var range: NSRange { NSRange(location: startOffset, length: endOffset - startOffset) }

    /// True when the fields are internally consistent; the store rejects anything else.
    public var isValid: Bool {
        !quote.isEmpty && startOffset >= 0 && endOffset > startOffset && startLine >= 1 && endLine >= startLine
    }
}

/// A comment on a span of a Markdown file, kept in Suijin's database (the file itself is never touched) and handed
/// to an agent on request. The agent answers it as fixed or declined.
///
/// A comment belongs to a worktree, or to the main checkout of a workspace (`worktreeID == nil`).
public struct MarkdownComment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var workspaceID: UUID
    /// Nil for the main checkout of the workspace.
    public var worktreeID: UUID?
    /// Absolute, standardized path of the Markdown file.
    public var filePath: String
    /// The user's note; may be empty when the quote speaks for itself.
    public var body: String
    public var anchor: MarkdownCommentAnchor
    public var status: MarkdownCommentStatus
    public var createdAt: Date
    public var updatedAt: Date?
    /// When the comment was last handed to an agent (pasted into a session or copied).
    public var sentAt: Date?
    /// The Suijin agent session the comment was pasted into; nil when it was only copied or never sent.
    public var sentToSession: UUID?
    /// When the agent answered.
    public var resolvedAt: Date?
    /// The agent's short answer, plain text.
    public var agentReply: String?

    /// `filePath` is standardized (`.` and `..` removed); it must be absolute to be saved.
    public init(
        id: UUID = UUID(), workspaceID: UUID, worktreeID: UUID? = nil, filePath: String, body: String,
        anchor: MarkdownCommentAnchor, status: MarkdownCommentStatus = .open, createdAt: Date = Date(),
        updatedAt: Date? = nil, sentAt: Date? = nil, sentToSession: UUID? = nil, resolvedAt: Date? = nil,
        agentReply: String? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.worktreeID = worktreeID
        self.filePath = Self.standardizedPath(filePath)
        self.body = body
        self.anchor = anchor
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sentAt = sentAt
        self.sentToSession = sentToSession
        self.resolvedAt = resolvedAt
        self.agentReply = agentReply
    }

    /// Replaces the note. A comment that was already handed to an agent (sent, fixed or declined) goes back to
    /// `open` without its delivery and answer, so the edited text is handed over again.
    public mutating func edit(body: String, at date: Date = Date()) {
        self.body = body
        updatedAt = date
        if status != .open { clearDelivery() }
    }

    /// Records that the comment was handed to an agent: pasted into `session`, or copied when `session` is nil.
    /// Any earlier answer is cleared, since the comment now waits for a new one.
    public mutating func markSent(to session: UUID?, at date: Date = Date()) {
        status = .sent
        sentAt = date
        sentToSession = session
        resolvedAt = nil
        agentReply = nil
    }

    /// Records the agent's answer.
    public mutating func resolve(_ outcome: MarkdownCommentOutcome, reply: String?, at date: Date = Date()) {
        status = outcome.status
        agentReply = reply
        resolvedAt = date
    }

    /// Moves a fixed or declined comment back to `open` and drops the agent's answer; other statuses are unchanged.
    public mutating func reopen() {
        guard status.isResolved else { return }
        clearDelivery()
    }

    private mutating func clearDelivery() {
        status = .open
        sentAt = nil
        sentToSession = nil
        resolvedAt = nil
        agentReply = nil
    }

    /// `path` with `.` and `..` components removed when it is absolute; relative paths are returned unchanged.
    static func standardizedPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        return URL(fileURLWithPath: path).standardized.path
    }
}
