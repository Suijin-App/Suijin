import Foundation
import SuijinPTYProtocol

/// What the broker remembers about one Markdown review comment. The app's database is the source of truth; this
/// record exists so the broker can authorize `suijin comment resolve`, answer `suijin comment list` while the app is
/// closed, and keep an answer until the app has applied it.
struct CommentRecord: Codable, Hashable, Sendable {
    var comment: PendingComment
    /// The agent's answer, once it gave one.
    var result: CommentResult?
    /// The app applied (or deliberately ignored) `result`: it is not delivered again.
    var acknowledged = false
    /// The receiving session ended. The record goes as soon as nothing is left to deliver.
    var sessionEnded = false

    init(comment: PendingComment) {
        self.comment = comment
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        comment = try container.decode(PendingComment.self, forKey: .comment)
        result = try container.decodeIfPresent(CommentResult.self, forKey: .result)
        acknowledged = try container.decodeIfPresent(Bool.self, forKey: .acknowledged) ?? false
        sessionEnded = try container.decodeIfPresent(Bool.self, forKey: .sessionEnded) ?? false
    }

    /// A result the app still has to apply.
    var awaitsDelivery: Bool { result != nil && !acknowledged }
}

/// The pure parts of the comment commands: id matching, reply sanitation and the `comment list` text.
enum CommentLedger {
    static let outcomes: Set<String> = ["fixed", "declined"]
    /// The longest reply kept, in characters, including the trailing ellipsis of a cut reply.
    static let replyLimit = 500

    /// The same failure for every id the caller may not answer: unknown, ambiguous, malformed, another session's,
    /// or a caller that is not a Suijin session. It never reveals whether a comment exists elsewhere.
    static let noSuchComment = BrokerFailure(
        code: "no-such-comment", message: "No such comment for this session.",
        hint: "Run `suijin comment list` for the comments waiting for this session.")

    /// Two spellings of one app session id (the app may pass UUIDs in either case).
    static func sameSession(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    /// The hexadecimal digits of a typed id (`c-7f3a2b`, `7F3A2B`, a full UUID): the optional `c-` prefix and dashes
    /// removed, lowercased. nil when anything else remains or it cannot be part of a UUID.
    static func query(_ typed: String) -> String? {
        var value = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("c-") { value.removeFirst(2) }
        value = value.replacingOccurrences(of: "-", with: "")
        guard !value.isEmpty, value.unicodeScalars.count <= 32,
              value.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
        else { return nil }
        return value
    }

    /// A comment UUID without dashes, lowercased: what `query` is matched against as a prefix.
    static func compact(_ id: String) -> String {
        id.lowercased().replacingOccurrences(of: "-", with: "")
    }

    /// The typed id as confirmations show it: lowercased, with the `c-` prefix.
    static func displayID(_ typed: String) -> String {
        var value = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("c-") { value.removeFirst(2) }
        return "c-" + value
    }

    /// The reply as stored and shown: control characters removed (line breaks and tabs become one space), trimmed,
    /// at most `replyLimit` characters with a trailing `…` when cut; nil when nothing is left.
    static func sanitizeReply(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if breaks.contains(scalar) {
                if scalars.last != " " { scalars.append(" ") }
            } else if scalar.properties.generalCategory == .control || directionControls.contains(scalar) {
                continue
            } else {
                scalars.append(scalar)
            }
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > replyLimit else { return trimmed }
        return String(trimmed.prefix(replyLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Line and column breaks, each run of which becomes a single space.
    private static let breaks: Set<Unicode.Scalar> = ["\n", "\r", "\t", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"]

    /// Format characters that reorder how text displays (they could disguise a reply).
    private static let directionControls: Set<Unicode.Scalar> = [
        "\u{061C}", "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
    ]

    /// `suijin comment list`: how to answer, then the waiting comments grouped by file, each as it was pasted.
    static func listText(_ comments: [PendingComment]) -> String {
        guard !comments.isEmpty else { return "No review comments are waiting for an answer from this session." }
        var files: [String] = []
        var byFile: [String: [String]] = [:]
        for comment in comments {
            if byFile[comment.filePath] == nil { files.append(comment.filePath) }
            byFile[comment.filePath, default: []].append(comment.text.trimmingCharacters(in: .newlines))
        }
        let header = "For each comment, edit the file, then report it: suijin comment resolve <id> --fixed --reply "
            + "\"what you changed\" (or --declined --reply \"why not\")."
        let sections = files.map { file in
            (["Review comments on \(file):"] + (byFile[file] ?? [])).joined(separator: "\n\n")
        }
        return ([header] + sections).joined(separator: "\n\n")
    }
}
