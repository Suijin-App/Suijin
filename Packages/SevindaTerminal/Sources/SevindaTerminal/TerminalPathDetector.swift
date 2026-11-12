import Foundation

/// One row of terminal text handed to `TerminalPathDetector`: the characters of the row by column, and whether the
/// terminal soft-wrapped the row above into it.
public struct TerminalTextRow: Sendable, Equatable {
    /// One character on screen. A wide character (CJK, emoji) covers two columns; the spacer cell after it is not
    /// listed.
    public struct Cell: Sendable, Equatable {
        public var character: Character
        public var column: Int
        public var width: Int
        /// The cell carries an explicit hyperlink (OSC 8); clicks on it stay with the terminal's own link handling.
        public var isExplicitLink: Bool

        public init(character: Character, column: Int, width: Int = 1, isExplicitLink: Bool = false) {
            self.character = character
            self.column = column
            self.width = width
            self.isExplicitLink = isExplicitLink
        }
    }

    public var cells: [Cell]
    /// The width of the terminal in columns, used to tell a row that reaches the right edge.
    public var columnCount: Int
    /// The terminal wrapped the previous row into this one (the program wrote past the right edge).
    public var isWrapped: Bool

    public init(cells: [Cell], columnCount: Int, isWrapped: Bool = false) {
        self.cells = cells
        self.columnCount = columnCount
        self.isWrapped = isWrapped
    }

    /// A row of single-width characters, for tests and previews.
    public init(_ text: String, columnCount: Int? = nil, isWrapped: Bool = false) {
        let characters = Array(text)
        self.cells = characters.enumerated().map { Cell(character: $1, column: $0) }
        self.columnCount = columnCount ?? characters.count
        self.isWrapped = isWrapped
    }
}

/// A path, an elided path or a web link found in terminal text.
public struct TerminalPathMatch: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// A complete path: absolute, `~/…`, or relative to the working directory.
        case path
        /// A path the program shortened with an ellipsis (`…/feature/x.swift`, `Sources/.../A.swift`); it names no file
        /// on its own, so it is never opened directly.
        case elided
        /// An `http` or `https` link.
        case url
    }

    /// The cells of one row that the match covers.
    public struct Segment: Sendable, Hashable {
        /// Index into the rows given to the detector.
        public var row: Int
        public var columns: Range<Int>

        public init(row: Int, columns: Range<Int>) {
            self.row = row
            self.columns = columns
        }
    }

    public var kind: Kind
    /// The path or link without quotes and without its line suffix.
    public var text: String
    /// The text as shown, line suffix included (`src/a.ts:12:4`).
    public var displayText: String
    public var line: Int?
    public var column: Int?
    /// One segment per row, top to bottom; a wrapped path has several.
    public var segments: [Segment]
    /// Some cell of the match carries an explicit (OSC 8) hyperlink.
    public var touchesExplicitLink: Bool

    public init(kind: Kind, text: String, displayText: String, line: Int? = nil, column: Int? = nil,
                segments: [Segment], touchesExplicitLink: Bool = false) {
        self.kind = kind
        self.text = text
        self.displayText = displayText
        self.line = line
        self.column = column
        self.segments = segments
        self.touchesExplicitLink = touchesExplicitLink
    }

    /// Whether the match covers the cell at `column` of `row`.
    public func contains(row: Int, column: Int) -> Bool {
        segments.contains { $0.row == row && $0.columns.contains(column) }
    }

    /// The number of cells covered, which ranks overlapping candidates.
    var cellCount: Int { segments.reduce(0) { $0 + $1.columns.count } }

    func overlaps(_ other: TerminalPathMatch) -> Bool {
        segments.contains { mine in other.segments.contains { $0.row == mine.row && $0.columns.overlaps(mine.columns) } }
    }
}

/// Finds paths and web links in rows of terminal text. Pure and synchronous: the caller hands it the rows on screen
/// (with a few rows of context when the first row continues one above) and decides which matches exist on disk.
///
/// Recognized: absolute paths, `~/…`, `./…`, `../…`, relative paths with a `/` or a familiar file extension, `file://`
/// URLs, with an optional `:line`, `:line:column`, `(line,column)` or `#Lline` suffix; paths in backticks, quotes or a
/// Markdown link target (quoted paths may contain spaces); `http(s)` links. Rows the terminal soft-wrapped join into
/// one line. A path a program wrapped itself (an agent's interface, which breaks lines with real line breaks) is also
/// tried across the break when the upper row reaches the right edge; both the joined path and the pieces are offered,
/// and `preferred(_:)` keeps whichever exists.
public enum TerminalPathDetector {
    /// Longer candidates are ignored: no real path is this long, and a run this long is generated output.
    public static let maximumLength = 1024

    /// Every candidate in `rows`. Candidates may overlap (a joined path and its pieces); see `preferred(_:)`.
    public static func matches(in rows: [TerminalTextRow]) -> [TerminalPathMatch] {
        let lines = logicalLines(rows)
        var result: [TerminalPathMatch] = []
        for line in lines { result += scan(line) }
        // Paths a program broke over rows with real line breaks: join each run of such rows and keep only what
        // crosses a break (the pieces were found above).
        for chain in heuristicChains(lines, rows: rows) {
            let joined = LogicalLine(characters: chain.flatMap(\.characters), cells: chain.flatMap(\.cells))
            let seams = zip(chain, chain.dropFirst()).compactMap { upper, lower -> (Int, Int)? in
                guard let above = upper.cells.last?.row, let below = lower.cells.first?.row else { return nil }
                return (above, below)
            }
            result += scan(joined).filter { match in
                let covered = Set(match.segments.map(\.row))
                return seams.contains { covered.contains($0.0) && covered.contains($0.1) }
            }
        }
        return result
    }

    /// From overlapping candidates that the caller verified, the ones to show: the longest first, then any that do
    /// not overlap one already kept.
    public static func preferred(_ matches: [TerminalPathMatch]) -> [TerminalPathMatch] {
        var kept: [TerminalPathMatch] = []
        for match in matches.sorted(by: { $0.cellCount > $1.cellCount }) where !kept.contains(where: { $0.overlaps(match) }) {
            kept.append(match)
        }
        return kept.sorted { ($0.segments.first?.row ?? 0, $0.segments.first?.columns.lowerBound ?? 0)
            < ($1.segments.first?.row ?? 0, $1.segments.first?.columns.lowerBound ?? 0) }
    }

    // MARK: Lines

    struct CellRef: Equatable {
        var row: Int
        var column: Int
        var width: Int
        var isExplicitLink: Bool
    }

    /// Rows the terminal soft-wrapped, joined: one character per entry, with the cell it came from.
    struct LogicalLine {
        var characters: [Character]
        var cells: [CellRef]
    }

    static func logicalLines(_ rows: [TerminalTextRow]) -> [LogicalLine] {
        var lines: [LogicalLine] = []
        for (index, row) in rows.enumerated() {
            let characters = row.cells.map(\.character)
            let cells = row.cells.map { CellRef(row: index, column: $0.column, width: max(1, $0.width), isExplicitLink: $0.isExplicitLink) }
            if row.isWrapped, index > 0, !lines.isEmpty {
                lines[lines.count - 1].characters += characters
                lines[lines.count - 1].cells += cells
            } else {
                lines.append(LogicalLine(characters: characters, cells: cells))
            }
        }
        return lines
    }

    /// Runs of logical lines a program may have broken a path across: each upper line ends at (near) the right edge
    /// on a path character, and the lower one starts, after its indentation, with a path character. Lines come back
    /// without leading and trailing blanks.
    static func heuristicChains(_ lines: [LogicalLine], rows: [TerminalTextRow]) -> [[LogicalLine]] {
        let trimmed = lines.map(trimmed)
        var chains: [[LogicalLine]] = []
        var current: [LogicalLine] = []
        for index in trimmed.indices {
            if current.isEmpty { current = [trimmed[index]] }
            let upper = trimmed[index]
            if index + 1 < trimmed.count, canJoin(upper, trimmed[index + 1], rows: rows) {
                current.append(trimmed[index + 1])
            } else {
                if current.count > 1 { chains.append(current) }
                current = []
            }
        }
        return chains
    }

    private static func canJoin(_ upper: LogicalLine, _ lower: LogicalLine, rows: [TerminalTextRow]) -> Bool {
        guard let last = upper.characters.last, let lastCell = upper.cells.last, let first = lower.characters.first,
              isPathCharacter(last), isPathCharacter(first) else { return false }
        let columns = rows[lastCell.row].columnCount
        // The edge threshold SwiftTerm uses for editor-rendered wraps: the last fifth of the row (at least 2 cells).
        return lastCell.column + lastCell.width >= columns - max(2, columns / 5)
    }

    private static func trimmed(_ line: LogicalLine) -> LogicalLine {
        let isBlank: (Character) -> Bool = { $0.isWhitespace || $0 == "\u{0}" }
        guard let start = line.characters.firstIndex(where: { !isBlank($0) }),
              let end = line.characters.lastIndex(where: { !isBlank($0) }) else {
            return LogicalLine(characters: [], cells: [])
        }
        return LogicalLine(characters: Array(line.characters[start...end]), cells: Array(line.cells[start...end]))
    }

    // MARK: Scanning

    /// Characters that end an unquoted path: whitespace, quotes, brackets, separators, and box-drawing lines that
    /// interfaces draw around text.
    static func isDelimiter(_ character: Character) -> Bool {
        if character.isWhitespace || character == "\u{0}" { return true }
        if "\"'`<>[]{}()|,".contains(character) { return true }
        guard let scalar = character.unicodeScalars.first else { return true }
        // Box drawing, block elements and the private-use area (Nerd Font icons in prompts).
        return (0x2500...0x259F).contains(scalar.value) || (0xE000...0xF8FF).contains(scalar.value)
    }

    static func isPathCharacter(_ character: Character) -> Bool { !isDelimiter(character) }

    static func scan(_ line: LogicalLine) -> [TerminalPathMatch] {
        let characters = line.characters
        guard !characters.isEmpty else { return [] }
        var matches: [TerminalPathMatch] = []
        var urlRanges: [Range<Int>] = []

        // Web links first: they contain `/` and would otherwise read as paths.
        var index = 0
        while index < characters.count {
            if let range = urlRange(at: index, in: characters) {
                let text = String(characters[range])
                matches.append(match(kind: .url, text: text, display: range, line: line))
                urlRanges.append(range)
                index = range.upperBound
            } else {
                index += 1
            }
        }
        func insideURL(_ range: Range<Int>) -> Bool { urlRanges.contains { $0.overlaps(range) } }

        // Quoted paths, which may contain spaces.
        for (open, close) in [("`", "`"), ("\"", "\""), ("'", "'")] as [(Character, Character)] {
            var start = 0
            while let opening = characters[start...].firstIndex(of: open) {
                guard let closing = characters[(opening + 1)...].firstIndex(of: close) else { break }
                start = closing + 1
                let inner = (opening + 1)..<closing
                guard inner.count > 1, characters[inner].contains(" "), !insideURL(inner) else { continue }
                // An apostrophe in prose ("don't") opens nothing: a quote must follow a delimiter or start the line.
                if opening > 0, !isDelimiter(characters[opening - 1]) { continue }
                if let found = pathMatch(in: inner, of: characters, allowSpaces: true, line: line) { matches.append(found) }
            }
        }

        // Unquoted runs.
        index = 0
        while index < characters.count {
            guard isPathCharacter(characters[index]) else {
                index += 1
                continue
            }
            var end = index
            while end < characters.count, isPathCharacter(characters[end]) { end += 1 }
            let run = index..<end
            index = end
            guard !insideURL(run) else { continue }
            if let found = pathMatch(in: run, of: characters, allowSpaces: false, line: line) { matches.append(found) }
        }
        return matches
    }

    /// The range of an `http(s)://` link starting at `index`, trailing punctuation and unbalanced closing brackets
    /// removed.
    static func urlRange(at index: Int, in characters: [Character]) -> Range<Int>? {
        guard index == 0 || isDelimiter(characters[index - 1]) || characters[index - 1] == "(" else { return nil }
        let prefixLength: Int
        if hasPrefix("https://", at: index, in: characters) { prefixLength = 8 }
        else if hasPrefix("http://", at: index, in: characters) { prefixLength = 7 }
        else { return nil }
        var end = index + prefixLength
        while end < characters.count {
            let character = characters[end]
            if character.isWhitespace || character == "\u{0}" || "\"'`<>|".contains(character) { break }
            if let scalar = character.unicodeScalars.first, (0x2500...0x259F).contains(scalar.value) { break }
            end += 1
        }
        while end > index + prefixLength {
            let last = characters[end - 1]
            if ".,;:!?*".contains(last) {
                end -= 1
            } else if let open = ([")": "(", "]": "[", "}": "{"] as [Character: Character])[last] {
                let slice = characters[index..<end]
                if slice.filter({ $0 == last }).count > slice.filter({ $0 == open }).count { end -= 1 } else { break }
            } else {
                break
            }
        }
        guard end > index + prefixLength, end - index <= maximumLength else { return nil }
        return index..<end
    }

    private static func hasPrefix(_ prefix: String, at index: Int, in characters: [Character]) -> Bool {
        let prefix = Array(prefix)
        guard index + prefix.count <= characters.count else { return false }
        for (offset, character) in prefix.enumerated() where characters[index + offset].lowercased() != String(character) {
            return false
        }
        return true
    }

    /// A path in `range`, its line suffix split off; nil when the text does not look like a path.
    static func pathMatch(in range: Range<Int>, of characters: [Character], allowSpaces: Bool,
                          line: LogicalLine) -> TerminalPathMatch? {
        var start = range.lowerBound
        var end = range.upperBound
        // Claude Code mentions files as `@path`.
        if start < end, characters[start] == "@" { start += 1 }
        // Trailing sentence punctuation; a final `.` stays when it is part of `..` or `/.`.
        while end > start {
            let last = characters[end - 1]
            if ",;:!?".contains(last) {
                end -= 1
            } else if last == ".", end - 2 >= start, characters[end - 2] != ".", characters[end - 2] != "/" {
                end -= 1
            } else {
                break
            }
        }
        guard end > start else { return nil }

        // `path:line:column`: the path ends at the first `:` followed by a digit.
        var pathEnd = end
        var lineNumber: Int?
        var columnNumber: Int?
        var displayEnd = end
        if let colon = (start..<end).first(where: { characters[$0] == ":" && $0 + 1 < end && characters[$0 + 1].isASCIIDigit }) {
            pathEnd = colon
            var cursor = colon + 1
            lineNumber = digits(from: &cursor, in: characters, limit: end)
            displayEnd = cursor
            if cursor + 1 < end, characters[cursor] == ":", characters[cursor + 1].isASCIIDigit {
                cursor += 1
                columnNumber = digits(from: &cursor, in: characters, limit: end)
                displayEnd = cursor
            }
        } else if let hash = (start..<end).last(where: { characters[$0] == "#" }), hash + 2 < end, characters[hash + 1] == "L",
                  characters[hash + 2].isASCIIDigit {
            // GitHub-style `#L12` (or `#L12-L20`, which opens at the first line).
            pathEnd = hash
            var cursor = hash + 2
            lineNumber = digits(from: &cursor, in: characters, limit: end)
            displayEnd = end
        } else if !allowSpaces, end == range.upperBound, end < characters.count, characters[end] == "(" {
            // `path(12,4)` or `path(12)`, as compilers on some platforms print it.
            var cursor = end + 1
            if let number = digits(from: &cursor, in: characters, limit: characters.count) {
                var column: Int?
                if cursor < characters.count, characters[cursor] == "," {
                    cursor += 1
                    column = digits(from: &cursor, in: characters, limit: characters.count)
                }
                if cursor < characters.count, characters[cursor] == ")" {
                    lineNumber = number
                    columnNumber = column
                    displayEnd = cursor + 1
                }
            }
        }
        guard pathEnd > start, pathEnd - start <= maximumLength else { return nil }
        var text = String(characters[start..<pathEnd])
        if !allowSpaces, text.contains(where: \.isWhitespace) { return nil }
        if text.hasPrefix("file://") {
            text = URL(string: text)?.path ?? String(text.dropFirst("file://".count))
        } else if text.contains("://") || text.hasPrefix("mailto:") {
            return nil
        }
        guard let kind = classify(text) else { return nil }
        return match(kind: kind, text: text, display: start..<displayEnd, line: line, lineNumber: lineNumber, column: columnNumber)
    }

    private static func digits(from cursor: inout Int, in characters: [Character], limit: Int) -> Int? {
        let start = cursor
        while cursor < limit, characters[cursor].isASCIIDigit, cursor - start < 9 { cursor += 1 }
        return cursor > start ? Int(String(characters[start..<cursor])) : nil
    }

    /// File extensions that make a bare name (no `/`) read as a file: `README.md`, `Package.swift`.
    static let knownExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cxx", "rs", "go", "py", "rb", "js", "jsx", "mjs", "cjs", "ts",
        "tsx", "java", "kt", "kts", "scala", "cs", "php", "lua", "dart", "ex", "exs", "erl", "hs", "zig", "sh", "bash",
        "zsh", "fish", "ps1", "md", "markdown", "mdx", "txt", "rst", "adoc", "json", "jsonl", "yml", "yaml", "toml", "ini",
        "cfg", "conf", "xml", "plist", "xcstrings", "strings", "entitlements", "pbxproj", "xcconfig", "html", "htm", "css",
        "scss", "sass", "less", "vue", "svelte", "sql", "graphql", "proto", "csv", "tsv", "log", "lock", "diff", "patch",
        "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "pdf", "mp4", "mov", "m4v", "mp3", "m4a", "wav", "gradle",
        "dockerfile", "env", "tf", "nix", "cmake", "mk", "storyboard", "xib",
    ]

    /// Extension-less names that are files in most repositories.
    static let knownNames: Set<String> = [
        "Makefile", "Dockerfile", "Gemfile", "Podfile", "Brewfile", "Rakefile", "Procfile", "Justfile", "LICENSE",
        "README", "CHANGELOG", "CONTRIBUTING", "AUTHORS", "NOTICE",
    ]

    /// `.path`, `.elided`, or nil when `text` does not look like a path.
    static func classify(_ text: String) -> TerminalPathMatch.Kind? {
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let components = text.split(separator: "/", omittingEmptySubsequences: false)
        let isEllipsis: (Substring) -> Bool = { component in
            component.hasPrefix("…") || component.hasSuffix("…") || (component.hasPrefix("...")) || component.hasSuffix("...")
        }
        if components.contains(where: isEllipsis) {
            // Elided only when something follows the last ellipsis: `…/b.swift` names a file to look for; `a/b…` does
            // not.
            guard let last = components.last, !last.isEmpty, !last.hasSuffix("…"), !last.hasSuffix("..."),
                  last.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return .elided
        }
        if text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("./") || text.hasPrefix("../") { return .path }
        if text.hasPrefix("//") { return nil }
        if components.count > 1 {
            // `a/b`: both sides need a letter or digit, so `/` used as "or" between symbols reads as nothing.
            guard components.filter({ !$0.isEmpty }).count >= 2 else { return nil }
            return .path
        }
        if knownNames.contains(text) { return .path }
        if text.hasPrefix(".") {
            // A dotfile (`.gitignore`, `.env`): letters, digits, `-` and `_` after the dot.
            let name = text.dropFirst()
            return !name.isEmpty && name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) ? .path : nil
        }
        guard let dot = text.lastIndex(of: ".") else { return nil }
        let ext = text[text.index(after: dot)...].lowercased()
        guard knownExtensions.contains(ext), text[..<dot].contains(where: \.isLetter) else { return nil }
        return .path
    }

    private static func match(kind: TerminalPathMatch.Kind, text: String, display: Range<Int>, line: LogicalLine,
                              lineNumber: Int? = nil, column: Int? = nil) -> TerminalPathMatch {
        var segments: [TerminalPathMatch.Segment] = []
        var explicit = false
        for index in display {
            let cell = line.cells[index]
            explicit = explicit || cell.isExplicitLink
            let columns = cell.column..<(cell.column + cell.width)
            if let last = segments.last, last.row == cell.row {
                segments[segments.count - 1].columns = min(last.columns.lowerBound, columns.lowerBound)..<max(last.columns.upperBound, columns.upperBound)
            } else {
                segments.append(.init(row: cell.row, columns: columns))
            }
        }
        return TerminalPathMatch(kind: kind, text: text, displayText: String(line.characters[display]), line: lineNumber,
                                 column: column, segments: segments, touchesExplicitLink: explicit)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
