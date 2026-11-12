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
        // Paths a program broke over rows with real line breaks: in each run of such rows, only the runs of path
        // characters that cross a break are scanned again, joined (the pieces were found above).
        for chain in heuristicChains(lines, rows: rows) {
            let joined = LogicalLine(characters: chain.flatMap(\.characters), codes: chain.flatMap(\.codes),
                                     cells: chain.flatMap(\.cells))
            var seams: [Int] = []
            var offset = 0
            for line in chain.dropLast() {
                offset += line.characters.count
                seams.append(offset)
            }
            var runStart = 0
            while runStart < joined.codes.count {
                guard !isDelimiter(code: joined.codes[runStart]) else {
                    runStart += 1
                    continue
                }
                var runEnd = runStart
                while runEnd < joined.codes.count, !isDelimiter(code: joined.codes[runEnd]) { runEnd += 1 }
                if seams.contains(where: { $0 > runStart && $0 < runEnd }) {
                    result += scan(joined.slice(runStart..<runEnd)).filter { $0.segments.count > 1 }
                }
                runStart = runEnd
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

    /// Rows the terminal soft-wrapped, joined: one character per entry, with its first Unicode scalar (what the scan
    /// compares, much cheaper than comparing characters) and the cell it came from.
    struct LogicalLine {
        var characters: [Character]
        var codes: [UInt32]
        var cells: [CellRef]

        init(characters: [Character], codes: [UInt32]? = nil, cells: [CellRef]) {
            self.characters = characters
            self.codes = codes ?? characters.map { $0.unicodeScalars.first?.value ?? 0 }
            self.cells = cells
        }

        func slice(_ range: Range<Int>) -> LogicalLine {
            LogicalLine(characters: Array(characters[range]), codes: Array(codes[range]), cells: Array(cells[range]))
        }
    }

    static func logicalLines(_ rows: [TerminalTextRow]) -> [LogicalLine] {
        var lines: [LogicalLine] = []
        for (index, row) in rows.enumerated() {
            let characters = row.cells.map(\.character)
            let codes = characters.map { $0.unicodeScalars.first?.value ?? 0 }
            let cells = row.cells.map { CellRef(row: index, column: $0.column, width: max(1, $0.width), isExplicitLink: $0.isExplicitLink) }
            if row.isWrapped, index > 0, !lines.isEmpty {
                lines[lines.count - 1].characters += characters
                lines[lines.count - 1].codes += codes
                lines[lines.count - 1].cells += cells
            } else {
                lines.append(LogicalLine(characters: characters, codes: codes, cells: cells))
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
        guard let last = upper.codes.last, let lastCell = upper.cells.last, let first = lower.codes.first,
              !isDelimiter(code: last), !isDelimiter(code: first) else { return false }
        let columns = rows[lastCell.row].columnCount
        // The edge threshold SwiftTerm uses for editor-rendered wraps: the last fifth of the row (at least 2 cells).
        return lastCell.column + lastCell.width >= columns - max(2, columns / 5)
    }

    private static func trimmed(_ line: LogicalLine) -> LogicalLine {
        guard let start = line.codes.firstIndex(where: { !isBlank(code: $0) }),
              let end = line.codes.lastIndex(where: { !isBlank(code: $0) }) else {
            return LogicalLine(characters: [], codes: [], cells: [])
        }
        return line.slice(start..<(end + 1))
    }

    // MARK: Character classes

    /// ASCII characters that end an unquoted path: controls, space, quotes, brackets and separators.
    private static let asciiDelimiters: [Bool] = (0..<128).map { (code: UInt32) in
        code <= 32 || code == 127 || "\"'`<>[]{}()|,".unicodeScalars.contains { $0.value == code }
    }

    /// Whitespace beyond ASCII: next line, no-break and typographic spaces, line and paragraph separators.
    private static func isUnicodeSpace(code: UInt32) -> Bool {
        switch code {
        case 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    static func isBlank(code: UInt32) -> Bool {
        code <= 32 || code == 127 || isUnicodeSpace(code: code)
    }

    /// Characters that end an unquoted path: whitespace, quotes, brackets, separators, and the symbols interfaces draw
    /// around text.
    static func isDelimiter(code: UInt32) -> Bool {
        if code < 128 { return asciiDelimiters[Int(code)] }
        return isUnicodeSpace(code: code) || isInterfaceSymbol(code: code)
    }

    static func isDelimiter(_ character: Character) -> Bool {
        isDelimiter(code: character.unicodeScalars.first?.value ?? 0)
    }

    /// Symbols agents and prompts draw next to text, never part of a path or link: bullets, arrows, technical symbols
    /// (`⎿`, `⏺`), box drawing and blocks, geometric shapes, dingbats (`✻`, `✓`), braille spinners and the private-use
    /// area (Nerd Font icons).
    static func isInterfaceSymbol(code: UInt32) -> Bool {
        switch code {
        case 0x2022, 0x2190...0x21FF, 0x2300...0x23FF, 0x2500...0x27BF, 0x2800...0x28FF, 0xE000...0xF8FF: return true
        default: return false
        }
    }

    private static func ascii(_ character: Character) -> UInt32 { UInt32(character.asciiValue!) }
    private static let colon = ascii(":"), dot = ascii("."), slash = ascii("/"), hash = ascii("#"), at = ascii("@")
    private static let openParenthesis = ascii("("), closeParenthesis = ascii(")"), comma = ascii(",")
    private static let letterL = ascii("L"), space = ascii(" ")

    private static func isDigit(_ code: UInt32) -> Bool { code >= 48 && code <= 57 }

    // MARK: Scanning

    static func scan(_ line: LogicalLine) -> [TerminalPathMatch] {
        let codes = line.codes
        guard !codes.isEmpty else { return [] }
        var matches: [TerminalPathMatch] = []
        var urlRanges: [Range<Int>] = []

        // Web links first: they contain `/` and would otherwise read as paths.
        var index = 0
        while index < codes.count {
            if codes[index] | 0x20 == 0x68, let range = urlRange(at: index, in: codes) { // `h` or `H`
                matches.append(match(kind: .url, text: String(line.characters[range]), display: range, line: line))
                urlRanges.append(range)
                index = range.upperBound
            } else {
                index += 1
            }
        }
        func insideURL(_ range: Range<Int>) -> Bool { urlRanges.contains { $0.overlaps(range) } }

        // Quoted paths, which may contain spaces.
        for quote in [ascii("`"), ascii("\""), ascii("'")] {
            var start = 0
            while let opening = codes[start...].firstIndex(of: quote) {
                guard let closing = codes[(opening + 1)...].firstIndex(of: quote) else { break }
                start = closing + 1
                let inner = (opening + 1)..<closing
                guard inner.count > 1, codes[inner].contains(space), !insideURL(inner) else { continue }
                // An apostrophe in prose ("don't") opens nothing: a quote must follow a delimiter or start the line.
                if opening > 0, !isDelimiter(code: codes[opening - 1]) { continue }
                if let found = pathMatch(in: inner, allowSpaces: true, line: line) { matches.append(found) }
            }
        }

        // Unquoted runs.
        index = 0
        while index < codes.count {
            guard !isDelimiter(code: codes[index]) else {
                index += 1
                continue
            }
            var end = index
            while end < codes.count, !isDelimiter(code: codes[end]) { end += 1 }
            let run = index..<end
            index = end
            guard !insideURL(run) else { continue }
            if let found = pathMatch(in: run, allowSpaces: false, line: line) { matches.append(found) }
        }
        return matches
    }

    private static let https = Array("https://".unicodeScalars.map(\.value))
    private static let http = Array("http://".unicodeScalars.map(\.value))
    /// Characters that end a link: whitespace and controls, quotes and angle brackets, and interface symbols.
    private static let asciiURLEnds: [Bool] = (0..<128).map { (code: UInt32) in
        code <= 32 || code == 127 || "\"'`<>|".unicodeScalars.contains { $0.value == code }
    }

    /// The range of an `http(s)://` link starting at `index`, trailing punctuation and unbalanced closing brackets
    /// removed.
    static func urlRange(at index: Int, in codes: [UInt32]) -> Range<Int>? {
        guard index == 0 || isDelimiter(code: codes[index - 1]) || codes[index - 1] == openParenthesis else { return nil }
        let prefixLength: Int
        if hasPrefix(https, at: index, in: codes) { prefixLength = https.count }
        else if hasPrefix(http, at: index, in: codes) { prefixLength = http.count }
        else { return nil }
        var end = index + prefixLength
        while end < codes.count, end - index <= maximumLength {
            let code = codes[end]
            if code < 128 ? asciiURLEnds[Int(code)] : (isUnicodeSpace(code: code) || isInterfaceSymbol(code: code)) { break }
            end += 1
        }
        let closers: [UInt32: UInt32] = [ascii(")"): ascii("("), ascii("]"): ascii("["), ascii("}"): ascii("{")]
        let trailing = Set(".,;:!?*".unicodeScalars.map(\.value))
        while end > index + prefixLength {
            let last = codes[end - 1]
            if trailing.contains(last) {
                end -= 1
            } else if let open = closers[last] {
                let slice = codes[index..<end]
                if slice.filter({ $0 == last }).count > slice.filter({ $0 == open }).count { end -= 1 } else { break }
            } else {
                break
            }
        }
        guard end > index + prefixLength, end - index <= maximumLength else { return nil }
        return index..<end
    }

    /// Whether `codes` holds `prefix` at `index`, ASCII letters in either case.
    private static func hasPrefix(_ prefix: [UInt32], at index: Int, in codes: [UInt32]) -> Bool {
        guard index + prefix.count <= codes.count else { return false }
        for offset in prefix.indices {
            let code = codes[index + offset]
            let lowered = code >= 65 && code <= 90 ? code + 32 : code
            if lowered != prefix[offset] { return false }
        }
        return true
    }

    /// A path in `range` of `line`, its line suffix split off; nil when the text does not look like a path.
    static func pathMatch(in range: Range<Int>, allowSpaces: Bool, line: LogicalLine) -> TerminalPathMatch? {
        let codes = line.codes
        var start = range.lowerBound
        var end = range.upperBound
        // Claude Code mentions files as `@path`.
        if start < end, codes[start] == at { start += 1 }
        // Trailing sentence punctuation; a final `.` stays when it is part of `..` or `/.`.
        let sentenceEnds = Set(",;:!?".unicodeScalars.map(\.value))
        while end > start {
            let last = codes[end - 1]
            if sentenceEnds.contains(last) {
                end -= 1
            } else if last == dot, end - 2 >= start, codes[end - 2] != dot, codes[end - 2] != slash {
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
        if let colonIndex = (start..<end).first(where: { codes[$0] == colon && $0 + 1 < end && isDigit(codes[$0 + 1]) }) {
            pathEnd = colonIndex
            var cursor = colonIndex + 1
            lineNumber = digits(from: &cursor, in: codes, limit: end)
            displayEnd = cursor
            if cursor + 1 < end, codes[cursor] == colon, isDigit(codes[cursor + 1]) {
                cursor += 1
                columnNumber = digits(from: &cursor, in: codes, limit: end)
                displayEnd = cursor
            }
        } else if let hashIndex = (start..<end).last(where: { codes[$0] == hash }), hashIndex + 2 < end,
                  codes[hashIndex + 1] == letterL, isDigit(codes[hashIndex + 2]) {
            // GitHub-style `#L12` (or `#L12-L20`, which opens at the first line).
            pathEnd = hashIndex
            var cursor = hashIndex + 2
            lineNumber = digits(from: &cursor, in: codes, limit: end)
            displayEnd = end
        } else if !allowSpaces, end == range.upperBound, end < codes.count, codes[end] == openParenthesis {
            // `path(12,4)` or `path(12)`, as compilers on some platforms print it.
            var cursor = end + 1
            if let number = digits(from: &cursor, in: codes, limit: codes.count) {
                var column: Int?
                if cursor < codes.count, codes[cursor] == comma {
                    cursor += 1
                    column = digits(from: &cursor, in: codes, limit: codes.count)
                }
                if cursor < codes.count, codes[cursor] == closeParenthesis {
                    lineNumber = number
                    columnNumber = column
                    displayEnd = cursor + 1
                }
            }
        }
        guard pathEnd > start, pathEnd - start <= maximumLength else { return nil }
        var text = String(line.characters[start..<pathEnd])
        if !allowSpaces, text.contains(where: \.isWhitespace) { return nil }
        if text.hasPrefix("file://") {
            text = URL(string: text)?.path ?? String(text.dropFirst("file://".count))
        } else if text.contains("://") || text.hasPrefix("mailto:") {
            return nil
        }
        guard let kind = classify(text) else { return nil }
        return match(kind: kind, text: text, display: start..<displayEnd, line: line, lineNumber: lineNumber, column: columnNumber)
    }

    private static func digits(from cursor: inout Int, in codes: [UInt32], limit: Int) -> Int? {
        let start = cursor
        var value = 0
        while cursor < limit, isDigit(codes[cursor]), cursor - start < 9 {
            value = value * 10 + Int(codes[cursor] - 48)
            cursor += 1
        }
        return cursor > start ? value : nil
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

