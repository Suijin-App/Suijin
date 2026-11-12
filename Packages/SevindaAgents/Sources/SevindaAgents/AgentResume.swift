import Foundation
import SevindaCore

/// Resuming an agent's conversation after its process ended: the arguments that reopen it, and the conversation id
/// read from what the CLI prints as it exits.
///
/// - Claude Code prints `Resume this session with:` and `claude --resume <uuid>`.
/// - Codex prints `To continue this session, run codex resume <uuid>`.
public enum AgentResume {
    /// `--resume <id>` for Claude Code, the `resume <id>` subcommand for Codex; nothing for a shell or a missing or
    /// malformed id. Codex's global options (`-c`) go before the subcommand, so callers insert theirs at the front.
    public static func arguments(kind: AgentKind, sessionID: String?) -> [String] {
        guard let id = sessionID.flatMap(validSessionID) else { return [] }
        switch kind {
        case .claude: return ["--resume", id]
        case .codex: return ["resume", id]
        case .shell: return []
        }
    }

    /// The conversation id in the last resume hint `kind`'s CLI printed in `text` (the end of its screen), if any. A
    /// hint of the other agent does not count.
    public static func sessionID(inExitText text: String, kind: AgentKind) -> String? {
        let command = switch kind {
        case .claude: #"claude\s+(?:--resume|-r)"#
        case .codex: #"codex\s+resume"#
        case .shell: ""
        }
        guard !command.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"\b"# + command + #"\s+("# + uuidPattern + #")\b"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let idRange = Range(match.range(at: 1), in: text) else { return nil }
        return validSessionID(String(text[idRange]))
    }

    /// `id` when it can be passed to the CLI as a conversation id: letters, digits, `-`, `_` and `.`, never starting
    /// with `-` (it would read as an option), at most 128 characters. Both CLIs use UUIDs.
    public static func validSessionID(_ id: String) -> String? {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...128).contains(id.count), let first = id.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first),
              id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return id
    }

    private static let uuidPattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
}
