import Foundation

/// Parses `git diff` unified output (default `a/` and `b/` prefixes) into `FileDiff` values.
public enum DiffParser {
    public static func parse(_ unifiedDiff: String) -> [FileDiff] {
        // Split on LF scalars only, so a CRLF file keeps its `\r` in the text instead of merging graphemes.
        var lines = unifiedDiff.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        if lines.last == "" { lines.removeLast() }

        var files: [FileDiff] = []
        var file: FileState?
        var hunk: HunkState?

        func finishHunk() {
            if let done = hunk { file?.diff.hunks.append(done.hunk) }
            hunk = nil
        }
        func finishFile() {
            finishHunk()
            if let done = file { files.append(done.finished()) }
            file = nil
        }

        for line in lines {
            if var current = hunk {
                let consumed: Bool
                if line.hasPrefix("\\") {
                    // `\ No newline at end of file`, after the line it applies to.
                    current.appendMarker(line)
                    consumed = true
                } else {
                    consumed = current.isOpen && current.consume(line)
                }
                if consumed {
                    hunk = current
                    continue
                }
                finishHunk()
            }

            if line.hasPrefix("diff --git ") {
                finishFile()
                file = FileState(headerPaths: parseGitHeader(String(line.dropFirst("diff --git ".count))))
            } else if line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                // Combined diffs (unmerged files) are not rendered line by line; keep the entry only.
                finishFile()
                let path = unquote(String(line.drop(while: { $0 != " " }).dropFirst().drop(while: { $0 != " " }).dropFirst()))
                file = FileState(headerPaths: (path, path))
                file?.isCombined = true
            } else if line.hasPrefix("@@ "), file != nil, file?.isCombined == false, let parsed = HunkState(header: line) {
                hunk = parsed
            } else if file != nil {
                file?.applyExtendedHeader(line)
            }
        }
        finishFile()
        return files
    }

    // MARK: Paths

    /// Splits the `a/<old> b/<new>` part of a `diff --git` line. Paths with spaces are ambiguous here, so
    /// `---`/`+++` and `rename from/to` lines override these when present.
    static func parseGitHeader(_ rest: String) -> (old: String?, new: String?) {
        if rest.hasPrefix("\"") {
            guard let (old, remainder) = takeQuoted(Substring(rest)) else { return (nil, nil) }
            let new = remainder.drop(while: { $0 == " " })
            return (stripPrefix(old, "a/"), stripPrefix(unquote(String(new)), "b/"))
        }
        // Same path on both sides (the usual case): "a/P b/P".
        let chars = Array(rest)
        if chars.count % 2 == 1 {
            let half = chars.count / 2
            let old = String(chars[..<half])
            let new = String(chars[(half + 1)...])
            if chars[half] == " ", old.hasPrefix("a/"), new.hasPrefix("b/"), old.dropFirst(2) == new.dropFirst(2) {
                return (String(old.dropFirst(2)), String(new.dropFirst(2)))
            }
        }
        if let range = rest.range(of: " b/") ?? rest.range(of: " \"b/") {
            let old = String(rest[..<range.lowerBound])
            let new = unquote(String(rest[rest.index(after: range.lowerBound)...]))
            return (stripPrefix(old, "a/"), stripPrefix(new, "b/"))
        }
        return (nil, nil)
    }

    /// Path from a `---`/`+++` line; nil for `/dev/null`.
    static func parseMarkerPath(_ raw: String, prefix: String) -> String? {
        var value = raw
        // git appends a tab after names that contain spaces.
        if value.hasSuffix("\t") { value.removeLast() }
        let path = unquote(value)
        if path == "/dev/null" { return nil }
        return stripPrefix(path, prefix)
    }

    static func stripPrefix(_ path: String, _ prefix: String) -> String {
        path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// Decodes a C-quoted git path (`"dir/caf\303\251 x.txt"`); returns other strings unchanged.
    static func unquote(_ value: String) -> String {
        guard value.hasPrefix("\""), let (decoded, rest) = takeQuoted(Substring(value)), rest.isEmpty else { return value }
        return decoded
    }

    /// Reads one quoted token from the start of `input`; returns it decoded and the remaining text.
    private static func takeQuoted(_ input: Substring) -> (String, Substring)? {
        let scalars = Array(input.unicodeScalars)
        guard scalars.first == "\"" else { return nil }
        var bytes: [UInt8] = []
        var index = 1
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\"" {
                let rest = String(String.UnicodeScalarView(scalars[(index + 1)...]))
                return (String(decoding: bytes, as: UTF8.self), Substring(rest))
            }
            if scalar == "\\", index + 1 < scalars.count {
                index += 1
                let escaped = scalars[index]
                switch escaped {
                case "n": bytes.append(0x0A)
                case "t": bytes.append(0x09)
                case "r": bytes.append(0x0D)
                case "a": bytes.append(0x07)
                case "b": bytes.append(0x08)
                case "f": bytes.append(0x0C)
                case "v": bytes.append(0x0B)
                case "0"..."7":
                    var octal = 0
                    var digits = 0
                    while digits < 3, index < scalars.count, ("0"..."7").contains(scalars[index]) {
                        octal = octal * 8 + Int(scalars[index].value - 48)
                        index += 1
                        digits += 1
                    }
                    bytes.append(UInt8(truncatingIfNeeded: octal))
                    continue
                default: bytes.append(contentsOf: Array(String(escaped).utf8))
                }
                index += 1
                continue
            }
            bytes.append(contentsOf: Array(String(scalar).utf8))
            index += 1
        }
        return nil
    }
}

/// One file being parsed.
private struct FileState {
    var diff = FileDiff(oldPath: nil, newPath: nil)
    var headerOld: String?
    var headerNew: String?
    var isNew = false
    var isDeleted = false
    var isCombined = false
    var sawOldMarker = false
    var sawNewMarker = false

    init(headerPaths: (old: String?, new: String?)) {
        headerOld = headerPaths.old
        headerNew = headerPaths.new
    }

    mutating func applyExtendedHeader(_ line: String) {
        if line.hasPrefix("new file mode") {
            isNew = true
        } else if line.hasPrefix("deleted file mode") {
            isDeleted = true
        } else if let value = line.value(after: "rename from ") ?? line.value(after: "copy from ") {
            headerOld = DiffParser.unquote(value)
        } else if let value = line.value(after: "rename to ") ?? line.value(after: "copy to ") {
            headerNew = DiffParser.unquote(value)
        } else if let value = line.value(after: "similarity index ") {
            diff.similarity = Int(value.trimmingCharacters(in: CharacterSet(charactersIn: "%")))
        } else if let value = line.value(after: "--- ") {
            sawOldMarker = true
            diff.oldPath = DiffParser.parseMarkerPath(value, prefix: "a/")
        } else if let value = line.value(after: "+++ ") {
            sawNewMarker = true
            diff.newPath = DiffParser.parseMarkerPath(value, prefix: "b/")
        } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
            diff.isBinary = true
        }
    }

    func finished() -> FileDiff {
        var result = diff
        if !sawOldMarker { result.oldPath = headerOld }
        if !sawNewMarker { result.newPath = headerNew }
        if isNew { result.oldPath = nil }
        if isDeleted { result.newPath = nil }
        return result
    }
}

/// One hunk being parsed; counts down the lines its header announced.
private struct HunkState {
    var hunk: DiffHunk
    var oldNext: Int
    var newNext: Int
    var oldRemaining: Int
    var newRemaining: Int

    var isOpen: Bool { oldRemaining > 0 || newRemaining > 0 }

    init?(header: String) {
        // @@ -oldStart[,oldCount] +newStart[,newCount] @@[ section]
        let parts = header.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
              let old = Self.range(parts[1].dropFirst()), let new = Self.range(parts[2].dropFirst()) else { return nil }
        hunk = DiffHunk(header: header, oldStart: old.start, oldCount: old.count, newStart: new.start, newCount: new.count)
        oldNext = old.start
        newNext = new.start
        oldRemaining = old.count
        newRemaining = new.count
    }

    private static func range(_ text: Substring) -> (start: Int, count: Int)? {
        let pieces = text.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Int(pieces[0]) else { return nil }
        if pieces.count == 1 { return (start, 1) }
        guard pieces.count == 2, let count = Int(pieces[1]) else { return nil }
        return (start, count)
    }

    /// Consumes one ` `/`-`/`+` body line; false when the line does not belong to the hunk.
    mutating func consume(_ line: String) -> Bool {
        let marker = line.unicodeScalars.first
        let text = String(String.UnicodeScalarView(line.unicodeScalars.dropFirst()))
        switch marker {
        case " ", nil:
            // An empty line is a context line whose trailing space was stripped (e.g. by an editor).
            guard oldRemaining > 0, newRemaining > 0 else { return false }
            hunk.lines.append(DiffLine(kind: .context, text: text, oldLine: oldNext, newLine: newNext))
            oldNext += 1; newNext += 1; oldRemaining -= 1; newRemaining -= 1
        case "-":
            guard oldRemaining > 0 else { return false }
            hunk.lines.append(DiffLine(kind: .deleted, text: text, oldLine: oldNext, newLine: nil))
            oldNext += 1; oldRemaining -= 1
        case "+":
            guard newRemaining > 0 else { return false }
            hunk.lines.append(DiffLine(kind: .added, text: text, oldLine: nil, newLine: newNext))
            newNext += 1; newRemaining -= 1
        default:
            return false
        }
        return true
    }

    mutating func appendMarker(_ line: String) {
        let text = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        hunk.lines.append(DiffLine(kind: .noNewlineMarker, text: text, oldLine: nil, newLine: nil))
    }
}

private extension String {
    func value(after prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
