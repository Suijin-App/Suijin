import Foundation

/// Turns Markdown comments into the text handed to an agent. Pure: nothing here reads a file or a database.
///
/// The text is prose for the agent, pasted into its prompt (one bracketed paste), never a command line: quotes and
/// notes go in verbatim and nothing in them is interpreted by a shell.
public enum MarkdownCommentFormatter {
    /// Quotes longer than this many lines are cut in the handed-over text; the line numbers still cover all of it.
    public static let maximumQuoteLines = 20

    /// The fewest hexadecimal digits a short comment id shows.
    public static let minimumIDLength = 6

    /// The short id agents use for a comment (`c-7f3a2b`): the start of its UUID, as long as needed to tell it
    /// apart from every other id in `ids`.
    public static func shortID(of id: UUID, among ids: [UUID]) -> String {
        let hex = Self.hex(id)
        let others = ids.filter { $0 != id }.map(Self.hex)
        var length = minimumIDLength
        while length < hex.count, others.contains(where: { $0.hasPrefix(hex.prefix(length)) }) { length += 1 }
        return "c-" + hex.prefix(length)
    }

    /// The comment a short or full id names among `ids`: nil when none or more than one matches.
    public static func resolve(_ text: String, among ids: [UUID]) -> UUID? {
        var wanted = text.trimmingCharacters(in: .whitespaces).lowercased()
        if wanted.hasPrefix("c-") { wanted.removeFirst(2) }
        wanted = wanted.replacingOccurrences(of: "-", with: "")
        guard !wanted.isEmpty, wanted.allSatisfy(\.isHexDigit) else { return nil }
        let matches = ids.filter { hex($0).hasPrefix(wanted) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The text for `comments` on the file shown as `filePath`. Detached comments have no place in the file and are
    /// left out. `ids` are all comments waiting on the same agent, so short ids stay unique among them. With
    /// `includesInstructions` the text tells the agent how to report each result with `suijin comment resolve`.
    public static func format(_ comments: [MarkdownComment], filePath: String, pendingIDs ids: [UUID] = [],
                              includesInstructions: Bool = true) -> String {
        let placed = comments.filter { !$0.anchor.isDetached }
        guard !placed.isEmpty else { return "" }
        let all = Array(Set(ids + placed.map(\.id)))
        var lines: [String] = []
        if includesInstructions {
            lines.append("Review comments on \(filePath). For each one, edit the file, then report the result:")
            lines.append("  suijin comment resolve <id> --fixed --reply \"what you changed\"")
            lines.append("  suijin comment resolve <id> --declined --reply \"why not\"")
        } else {
            lines.append("Review comments on \(filePath). For each one, edit the file.")
        }
        for comment in placed {
            lines.append("")
            lines.append(entry(comment, id: shortID(of: comment.id, among: all)))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One comment: its id and lines, the quoted text, and the note when there is one.
    public static func entry(_ comment: MarkdownComment, id: String) -> String {
        let anchor = comment.anchor
        let range = anchor.startLine == anchor.endLine ? "line \(anchor.startLine)" : "lines \(anchor.startLine)-\(anchor.endLine)"
        var lines = ["[\(id)] \(range)"]
        let quoted = anchor.quote.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for line in quoted.prefix(maximumQuoteLines) { lines.append("> " + line) }
        if quoted.count > maximumQuoteLines {
            lines.append("> … (\(quoted.count - maximumQuoteLines) more lines not shown)")
        }
        let note = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { lines.append("Note: " + note) }
        return lines.joined(separator: "\n")
    }

    private static func hex(_ id: UUID) -> String {
        id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
