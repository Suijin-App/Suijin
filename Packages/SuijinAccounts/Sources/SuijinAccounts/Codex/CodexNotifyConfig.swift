import Foundation

/// Codex's `notify` program for Suijin sessions: Codex runs it after every turn with one JSON argument
/// (`{"type":"agent-turn-complete","thread-id":…,"turn-id":…,"cwd":…,"client":…,"input-messages":[…],
/// "last-assistant-message":…}`, verified with codex-cli 0.166.0), and Suijin's `suijin hook codex-notify` tells the
/// orchestration broker that the session's turn ended.
///
/// It is set per launch with `codex -c notify=[…]`, so no `config.toml` is written: not the user's `~/.codex`, and not a
/// managed home, whose config the mirror rewrites from `~/.codex`. A `notify` the user configured keeps working: it is
/// chained after Suijin's hook with the same payload.
public enum CodexNotifyConfig {
    /// `["-c", "notify=[\"<cli>\",\"hook\",\"codex-notify\",\"--\",<user's program…>]"]`.
    /// `config` is the effective `config.toml` text (see `effectiveConfig`), nil when there is none.
    public static func launchArguments(cli: String, config: String?) -> [String] {
        var command = [cli, "hook", "codex-notify"]
        if let existing = config.flatMap(notifyCommand(in:)), !existing.isEmpty, !isSuijinHook(existing) {
            command += ["--"] + existing
        }
        return ["-c", "notify=\(tomlArray(command))"]
    }

    /// The `config.toml` Codex will read: the account home's, else `$CODEX_HOME`'s, else `~/.codex`'s. Read only.
    public static func effectiveConfig(home: URL?, environment: [String: String], realHome: URL) -> String? {
        let directory = home
            ?? environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? realHome.appendingPathComponent(".codex", isDirectory: true)
        guard let data = try? FileOps.readData(directory.appendingPathComponent("config.toml").path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A previous Suijin hook (a config that already chains through Suijin) is never chained again.
    static func isSuijinHook(_ command: [String]) -> Bool {
        command.count >= 3 && command[1] == "hook" && command[2] == "codex-notify"
    }

    /// The top-level `notify = [ "program", "arg", … ]` (single- or multi-line), nil when absent or not a string array.
    static func notifyCommand(in config: String) -> [String]? {
        let preamble = CodexTOML.split(config).preamble
        let lines = preamble.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            guard let equals = line.firstIndex(of: "="), CodexTOML.keyPath(String(line[..<equals])) == ["notify"] else { continue }
            var value = String(line[line.index(after: equals)...])
            var next = index + 1
            while !closesArray(value), next < lines.count {
                value += "\n" + lines[next]
                next += 1
            }
            return parseStringArray(value)
        }
        return nil
    }

    /// Whether `text` (from just after `=`) holds a complete `[ … ]`, ignoring brackets inside strings.
    private static func closesArray(_ text: String) -> Bool {
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in text {
            if let open = quote {
                if escaped { escaped = false; continue }
                if character == "\\" && open == "\"" { escaped = true; continue }
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { return true }
            case "#": return false // a comment before the array closed: keep reading lines
            default: break
            }
        }
        return false
    }

    static func parseStringArray(_ text: String) -> [String]? {
        var items: [String] = []
        var characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard characters.first == "[" else { return nil }
        characters.removeFirst()
        var index = 0
        func skipSeparators() {
            while index < characters.count {
                let character = characters[index]
                if character == "#" {
                    while index < characters.count, characters[index] != "\n" { index += 1 }
                } else if character.isWhitespace || character == "," {
                    index += 1
                } else {
                    return
                }
            }
        }
        while true {
            skipSeparators()
            guard index < characters.count else { return nil }
            let character = characters[index]
            if character == "]" { return items }
            guard character == "\"" || character == "'" else { return nil }
            index += 1
            var value = ""
            var closed = false
            while index < characters.count {
                let current = characters[index]
                index += 1
                if current == character { closed = true; break }
                if character == "\"", current == "\\", index < characters.count {
                    let escaped = characters[index]
                    index += 1
                    switch escaped {
                    case "n": value.append("\n")
                    case "t": value.append("\t")
                    case "\\", "\"": value.append(escaped)
                    default: value.append(escaped)
                    }
                    continue
                }
                value.append(current)
            }
            guard closed else { return nil }
            items.append(value)
        }
    }

    /// A TOML array of basic strings.
    static func tomlArray(_ items: [String]) -> String {
        "[" + items.map(tomlString).joined(separator: ",") + "]"
    }

    /// A TOML basic string (for keys and values in `-c` overrides).
    public static func tomlQuoted(_ value: String) -> String {
        tomlString(value)
    }

    static func tomlString(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            case "\r": escaped += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"\(escaped)\""
    }
}
