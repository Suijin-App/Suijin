import Foundation
import SuijinCore
import SuijinPTYProtocol
import os

private let logger = Logger(subsystem: "com.tekmium.suijin", category: "comments")

// Agents answer Markdown comments with `suijin comment resolve`. The app's database is the truth about comments; the
// broker in the helper keeps only what it needs to accept that command from the right session and to hold results
// while the app is closed. This file is the app's side: it tells the broker which comments wait on which session,
// and applies the results the broker hands back.

extension OrchestrationController {
    /// Whether an agent's `suijin comment resolve` can reach this app: connected to a helper that knows the command.
    var canResolveComments: Bool {
        #if DEBUG
        if assumesCommentSupportForPreview { return true }
        #endif
        return isConnected && (hostProtocolVersion ?? 0) >= PTYHostConstants.commentsProtocolVersion
    }

    /// Tells the broker about comments just pasted into `session`.
    func register(_ comments: [PendingComment]) {
        guard canResolveComments, !comments.isEmpty, let data = try? OrchestrationCoding.encoder.encode(comments) else { return }
        broker?.registerComments(data)
    }

    /// Takes comments back from their agent: deleted, reopened or edited in the app.
    func withdraw(_ ids: [UUID]) {
        guard canResolveComments, !ids.isEmpty,
              let data = try? OrchestrationCoding.encoder.encode(ids.map { $0.uuidString.lowercased() }) else { return }
        broker?.withdrawComments(data)
    }

    /// Sends the broker every comment that still waits for an answer, after each connect. The broker replaces its
    /// own list with it (the two can drift when the app was stopped abruptly) and then delivers the results it
    /// queued while the app was away.
    func syncComments() async {
        guard canResolveComments, let model = appModel else { return }
        do {
            let waiting = try await model.io { store in
                try store.markdownCommentsWaitingForAgents()
            }
            let pending = model.pendingComments(for: waiting)
            let data = try OrchestrationCoding.encoder.encode(pending)
            broker?.syncComments(data)
        } catch {
            logger.error("could not list the comments waiting for agents: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Applies agents' answers. A result for a comment the user deleted, reopened, edited or sent elsewhere
    /// meanwhile is dropped. Every result is acknowledged, so the broker stops sending it; applying one twice
    /// changes nothing.
    func applyCommentResults(_ results: [CommentResult]) async {
        guard let model = appModel, !results.isEmpty else { return }
        var handled: [String] = []
        for result in results {
            handled.append(result.id)
            guard let id = UUID(uuidString: result.id), let session = UUID(uuidString: result.sessionID),
                  let outcome = MarkdownCommentOutcome(rawValue: result.outcome) else { continue }
            let reply = Self.displayable(result.reply)
            do {
                // Only a comment still waiting on this very session takes the answer; the store checks and writes in
                // one transaction, and writes the answer's columns only.
                let resolvedAt = result.resolvedAt
                let applied: MarkdownComment? = try await model.io { store in
                    try store.resolveMarkdownComment(id: id, session: session, outcome: outcome, reply: reply, at: resolvedAt)
                }
                if let applied {
                    for book in model.markdownBooks.values { book.showAnswer(of: applied) }
                } else {
                    logger.info("ignored an agent's answer to a comment that no longer waits for it")
                }
            } catch {
                logger.error("could not apply an agent's answer: \(error.localizedDescription, privacy: .public)")
                handled.removeLast()
            }
        }
        if !handled.isEmpty, let data = try? OrchestrationCoding.encoder.encode(handled) {
            broker?.commentResultsApplied(data)
        }
    }

    /// The agent's reply as it may be shown: plain text without control characters, at most 500 characters. The
    /// broker already limits it; the app does not rely on that.
    static func displayable(_ reply: String?) -> String? {
        guard let reply else { return nil }
        let cleaned = String(String.UnicodeScalarView(reply.unicodeScalars.map { scalar in
            scalar.properties.generalCategory == .control ? " " : scalar
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return cleaned.count > 500 ? String(cleaned.prefix(499)) + "…" : cleaned
    }
}

extension AppModel {
    /// Whether agents can mark comments by themselves right now; when not, comments are still sent, without the
    /// instructions for `suijin comment resolve`, and the Comments column says why.
    var canAgentsResolveComments: Bool { runtimes.orchestration.canResolveComments }

    /// Comments were pasted into `session`: the broker will accept that session's answers for them.
    func registerSentComments(_ comments: [MarkdownComment], displayPath: String, session: UUID) {
        guard canAgentsResolveComments else { return }
        Task {
            // Short ids are unique among everything the session still has to answer, as in the pasted text.
            let waiting = (try? await io { try $0.markdownComments(sentToSession: session) })?
                .filter { $0.status == .sent }.map(\.id) ?? []
            let ids = Array(Set(waiting + comments.map(\.id)))
            runtimes.orchestration.register(comments.map { comment in
                PendingComment(id: comment.id.uuidString.lowercased(), sessionID: session.uuidString, filePath: displayPath,
                               text: MarkdownCommentFormatter.entry(comment, id: MarkdownCommentFormatter.shortID(of: comment.id, among: ids)),
                               createdAt: comment.sentAt ?? Date())
            })
        }
    }

    /// A session started or was resumed under its old id: the broker forgot what that session still had to answer
    /// when its process ended, so the list is sent again.
    func sessionDidStart() {
        Task { await runtimes.orchestration.syncComments() }
    }

    func withdrawComments(_ ids: [UUID]) {
        runtimes.orchestration.withdraw(ids)
    }

    /// The broker's view of `waiting` (comments sent to a session and not answered): each with the text and the
    /// file path its agent was given.
    func pendingComments(for waiting: [MarkdownComment]) -> [PendingComment] {
        let bySession = Dictionary(grouping: waiting.filter { $0.sentToSession != nil }, by: { $0.sentToSession! })
        return bySession.flatMap { session, comments -> [PendingComment] in
            let ids = comments.map(\.id)
            let root = sessions.first { $0.id == session }.flatMap { directory(of: context(of: $0))?.standardizedFileURL.path }
            return comments.map { comment in
                let path = root.flatMap { comment.filePath.hasPrefix($0 + "/") ? String(comment.filePath.dropFirst($0.count + 1)) : nil } ?? comment.filePath
                return PendingComment(id: comment.id.uuidString.lowercased(), sessionID: session.uuidString, filePath: path,
                                      text: MarkdownCommentFormatter.entry(comment, id: MarkdownCommentFormatter.shortID(of: comment.id, among: ids)),
                                      createdAt: comment.sentAt ?? comment.createdAt)
            }
        }
    }
}
