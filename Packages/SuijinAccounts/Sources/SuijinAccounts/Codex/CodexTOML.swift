import Foundation

/// Line-level TOML structure for config.toml: enough to split tables and edit single settings while preserving the
/// surrounding bytes. Multiline strings and arrays are tracked so text inside them is never read as structure.
enum CodexTOML {
    struct Section {
        var header: String
        var block: String
    }

    struct Table: Equatable {
        var segments: [String]
        var isArray: Bool
    }

    private struct ScanState {
        var basic = false
        var literal = false
        var arrayDepth = 0
        var isStructural: Bool { !basic && !literal && arrayDepth == 0 }
    }

    private static func update(_ state: ScanState, _ line: String) -> ScanState {
        let chars = Array(line)
        var state = state
        var index = 0
        func starts(_ token: String, at position: Int) -> Bool {
            let tokenChars = Array(token)
            guard position + tokenChars.count <= chars.count else { return false }
            return Array(chars[position..<(position + tokenChars.count)]) == tokenChars
        }
        while index < chars.count {
            if state.basic {
                if chars[index] == "\\" { index += 2; continue }
                if starts("\"\"\"", at: index) { state.basic = false; index += 3; continue }
                index += 1
                continue
            }
            if state.literal {
                if starts("'''", at: index) { state.literal = false; index += 3; continue }
                index += 1
                continue
            }
            let char = chars[index]
            if char == "#" { break }
            if starts("\"\"\"", at: index) { state.basic = true; index += 3; continue }
            if starts("'''", at: index) { state.literal = true; index += 3; continue }
            if char == "\"" { index = skipBasic(chars, from: index + 1); continue }
            if char == "'" { index = skipLiteral(chars, from: index + 1); continue }
            // Header brackets balance on one line; remaining depth belongs to a multiline array.
            if char == "[" { state.arrayDepth += 1 } else if char == "]" { state.arrayDepth = max(0, state.arrayDepth - 1) }
            index += 1
        }
        return state
    }

    private static func skipBasic(_ chars: [Character], from start: Int) -> Int {
        var index = start
        while index < chars.count {
            if chars[index] == "\\" { index += 2; continue }
            if chars[index] == "\"" { return index + 1 }
            index += 1
        }
        return index
    }

    private static func skipLiteral(_ chars: [Character], from start: Int) -> Int {
        var index = start
        while index < chars.count {
            if chars[index] == "'" { return index + 1 }
            index += 1
        }
        return index
    }

    /// The `[table]` or `[[array]]` header of a line, comment removed; nil for other lines.
    static func header(of line: String) -> String? {
        let chars = Array(line)
        var index = 0
        while index < chars.count && chars[index] != "#" {
            if chars[index] == "\"" { index = skipBasic(chars, from: index + 1) }
            else if chars[index] == "'" { index = skipLiteral(chars, from: index + 1) }
            else { index += 1 }
        }
        var header = String(chars[0..<min(index, chars.count)])
        while header.last?.isWhitespace == true { header.removeLast() }
        let trimmed = header.drop { $0 == " " || $0 == "\t" }
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 3 else { return nil }
        return header
    }

    /// Decoded dotted key path of a header, e.g. `[projects."/a/b"]` -> ["projects", "/a/b"].
    static func table(_ header: String) -> Table? {
        var text = header.trimmingCharacters(in: .whitespaces)
        let isArray = text.hasPrefix("[[") && text.hasSuffix("]]")
        text = String(text.dropFirst(isArray ? 2 : 1).dropLast(isArray ? 2 : 1))
        guard let segments = keyPath(text) else { return nil }
        return Table(segments: segments, isArray: isArray)
    }

    /// Splits a dotted key (`a."b.c".d`) into decoded segments.
    static func keyPath(_ text: String) -> [String]? {
        let chars = Array(text)
        var segments: [String] = []
        var index = 0
        func skipSpace() { while index < chars.count && (chars[index] == " " || chars[index] == "\t") { index += 1 } }
        while true {
            skipSpace()
            guard index < chars.count else { return nil }
            var segment = ""
            if chars[index] == "\"" {
                index += 1
                while index < chars.count && chars[index] != "\"" {
                    if chars[index] == "\\", index + 1 < chars.count {
                        let next = chars[index + 1]
                        switch next {
                        case "n": segment.append("\n")
                        case "t": segment.append("\t")
                        default: segment.append(next)
                        }
                        index += 2
                        continue
                    }
                    segment.append(chars[index])
                    index += 1
                }
                guard index < chars.count else { return nil }
                index += 1
            } else if chars[index] == "'" {
                index += 1
                while index < chars.count && chars[index] != "'" { segment.append(chars[index]); index += 1 }
                guard index < chars.count else { return nil }
                index += 1
            } else {
                while index < chars.count, chars[index].isLetter || chars[index].isNumber
                    || chars[index] == "_" || chars[index] == "-" {
                    segment.append(chars[index])
                    index += 1
                }
                guard !segment.isEmpty else { return nil }
            }
            segments.append(segment)
            skipSpace()
            if index == chars.count { return segments }
            guard chars[index] == "." else { return nil }
            index += 1
        }
    }

    /// The text before the first table and every table block, in order.
    static func split(_ config: String) -> (preamble: String, sections: [Section]) {
        let lines = config.components(separatedBy: "\n")
        var state = ScanState()
        var preamble: [String] = []
        var sections: [Section] = []
        var current: (header: String, lines: [String])?
        for line in lines {
            if state.isStructural, let header = header(of: line) {
                if let open = current { sections.append(Section(header: open.header, block: open.lines.joined(separator: "\n"))) }
                current = (header, [line])
            } else if current != nil {
                current!.lines.append(line)
            } else {
                preamble.append(line)
            }
            state = update(state, line)
        }
        if let open = current { sections.append(Section(header: open.header, block: open.lines.joined(separator: "\n"))) }
        return (preamble.joined(separator: "\n"), sections)
    }

    /// Non-empty trimmed blocks joined by a blank line, ending in a newline.
    static func join(_ blocks: [String]) -> String {
        let kept = blocks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return kept.isEmpty ? "" : kept.joined(separator: "\n\n") + "\n"
    }

    // MARK: Section kinds

    static func projectKey(_ header: String) -> String? {
        guard let table = table(header), !table.isArray, table.segments.count == 2, table.segments[0] == "projects"
        else { return nil }
        var path = table.segments[1]
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func hookTrustKey(_ header: String) -> String? {
        guard let table = table(header), !table.isArray, table.segments.count >= 2,
              table.segments[0] == "hooks", table.segments[1] == "state"
        else { return nil }
        return table.segments.dropFirst(2).joined(separator: ".")
    }

    static func mcpServerName(_ header: String) -> String? {
        guard let table = table(header), !table.isArray, table.segments.first == "mcp_servers", table.segments.count >= 2
        else { return nil }
        return table.segments[1]
    }

    static func ownsMCPServerRoot(_ sections: [Section]) -> Bool {
        sections.contains { table($0.header) == Table(segments: ["mcp_servers"], isArray: false) }
    }

    static func trustLevel(_ block: String) -> String? {
        for line in block.components(separatedBy: "\n").dropFirst() {
            guard let (key, value) = stringSetting(line), key == ["trust_level"] else { continue }
            return value
        }
        return nil
    }

    /// `key = "value"` / `key = 'value'` on one line; nil for anything else.
    static func stringSetting(_ line: String) -> ([String], String)? {
        guard let equals = line.firstIndex(of: "="), header(of: line) == nil else { return nil }
        guard let key = keyPath(String(line[..<equals])) else { return nil }
        var rest = line[line.index(after: equals)...].drop { $0 == " " || $0 == "\t" }
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        if rest.hasPrefix("\"\"\"") || rest.hasPrefix("'''") { return nil }
        rest = rest.dropFirst()
        var value = ""
        var closed = false
        var iterator = rest.makeIterator()
        while let char = iterator.next() {
            if char == quote { closed = true; break }
            if quote == "\"" && char == "\\" {
                guard let next = iterator.next() else { return nil }
                value.append(next == "n" ? "\n" : next == "t" ? "\t" : next)
                continue
            }
            value.append(char)
        }
        return closed ? (key, value) : nil
    }

    /// Top-level `model_provider`, if the config pins one.
    static func topLevelModelProvider(_ config: String) -> String? {
        let (preamble, _) = split(config)
        for line in preamble.components(separatedBy: "\n") {
            if let (key, value) = stringSetting(line), key == ["model_provider"] { return value }
        }
        return nil
    }

    // MARK: Edits

    /// Drops one-line string settings for which `matches(keyPath, value)` is true (key path includes the table).
    static func removeStringSettings(_ config: String, where matches: ([String], String) -> Bool) -> String {
        var state = ScanState()
        var table: [String] = []
        var kept: [String] = []
        for line in config.components(separatedBy: "\n") {
            defer { state = update(state, line) }
            if state.isStructural {
                if let header = header(of: line) {
                    table = self.table(header)?.segments ?? []
                } else if let (key, value) = stringSetting(line), matches(table + key, value) {
                    continue
                }
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// Rewrites one-line string settings: `transform(keyPath, value)` returns a replacement value or nil.
    static func rewriteStringSettings(_ config: String, _ transform: ([String], String) -> String?) -> String {
        var state = ScanState()
        var table: [String] = []
        var lines = config.components(separatedBy: "\n")
        for index in lines.indices {
            let line = lines[index]
            defer { state = update(state, line) }
            guard state.isStructural else { continue }
            if let header = header(of: line) {
                table = self.table(header)?.segments ?? []
                continue
            }
            guard let (key, value) = stringSetting(line), let replacement = transform(table + key, value),
                  let equals = line.firstIndex(of: "=")
            else { continue }
            let comment = line.range(of: "#", options: .backwards).map { line[$0.lowerBound...] }
            let valueText = "\"" + replacement.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
            var rewritten = String(line[...equals]) + " " + valueText
            if let comment, !String(comment).contains("\"") && !String(comment).contains("'") { rewritten += " " + comment }
            lines[index] = rewritten
        }
        return lines.joined(separator: "\n")
    }
}
