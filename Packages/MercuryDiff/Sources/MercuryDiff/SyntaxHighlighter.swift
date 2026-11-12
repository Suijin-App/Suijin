import Foundation
import os
import Synchronization
import SwiftTreeSitter
import TreeSitterGo
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterMarkdown
import TreeSitterPython
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript

/// The coarse syntax categories the diff viewer colors. Tree-sitter capture names
/// (`keyword.function`, `string.special.key`, ...) are folded into these.
public enum TokenKind: String, Sendable, Hashable, CaseIterable {
    case keyword, string, comment, number, constant, type, function, property, attribute, `operator`, heading, link

    /// Maps a tree-sitter highlight capture name to a token kind; nil means "leave uncolored".
    init?(captureName: String) {
        let parts = captureName.split(separator: ".", omittingEmptySubsequences: true)
        guard let head = parts.first else { return nil }
        let second = parts.count > 1 ? parts[1] : nil
        switch head {
        case "comment": self = .comment
        case "string", "character", "escape":
            self = captureName == "string.special.key" ? .property : .string
        case "number", "float": self = .number
        case "boolean", "constant": self = .constant
        case "keyword", "conditional", "repeat", "include", "exception", "storageclass": self = .keyword
        case "type", "constructor": self = .type
        case "function", "method": self = .function
        case "property", "field": self = .property
        case "variable":
            switch second {
            case "builtin": self = .keyword
            case "member": self = .property
            default: return nil
            }
        case "attribute", "label", "tag", "decorator": self = .attribute
        case "operator": self = .operator
        case "text", "markup":
            switch second {
            case "title", "heading": self = .heading
            case "literal", "raw": self = .string
            case "uri", "link", "reference": self = .link
            default: return nil
            }
        default: return nil
        }
    }
}

/// A colored range in UTF-16 units of the highlighted text.
public struct HighlightSpan: Sendable, Hashable {
    public var range: NSRange
    public var token: TokenKind

    public init(range: NSRange, token: TokenKind) {
        self.range = range
        self.token = token
    }
}

public enum SyntaxHighlighter {
    /// Language identifiers this highlighter supports.
    public static let supportedLanguages: Set<String> = Set(grammars.keys)

    /// Texts longer than this (UTF-16 units, about 4 MB of ASCII) are not highlighted: parsing and painting
    /// stay fast, but nobody reads a diff side that large and it would only cost memory.
    static let maximumLength = 4_000_000

    private static let extensions: [String: String] = [
        "swift": "swift",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "mts": "typescript", "cts": "typescript",
        "tsx": "tsx",
        "py": "python", "pyi": "python", "pyw": "python",
        "json": "json", "jsonc": "json",
        "go": "go",
        "rs": "rust",
        "md": "markdown", "markdown": "markdown",
    ]

    /// The language identifier for a file path, from its extension (case-insensitive); nil when unsupported.
    public static func language(forPath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return extensions[ext]
    }

    /// Parses `text` with the grammar for `language` and returns non-overlapping spans sorted by location.
    /// Runs on the concurrent executor, never on the caller's actor. Unknown languages yield no spans.
    @concurrent
    public static func highlight(_ text: String, language: String) async -> [HighlightSpan] {
        guard let grammar = grammars[language], let query = query(for: grammar) else { return [] }
        let length = text.utf16.count
        guard length > 0, length <= maximumLength, !Task.isCancelled else { return [] }

        let parser = Parser()
        do {
            try parser.setLanguage(grammar.language)
        } catch {
            logger.error("Cannot set tree-sitter language \(language, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
        guard let tree = parser.parse(text) else { return [] }
        guard !Task.isCancelled else { return [] }

        var captures: [Capture] = []
        let matches = query.execute(in: tree).resolve(with: Predicate.Context(string: text))
        for match in matches {
            for capture in match.captures {
                guard let name = capture.name else { continue }
                let range = capture.range
                guard range.length > 0, range.location >= 0, NSMaxRange(range) <= length else { continue }
                let paint: UInt8
                if name == "none" {
                    paint = 0
                } else if let token = TokenKind(captureName: name) {
                    paint = token.paintValue
                } else {
                    paint = Capture.noStyle
                }
                captures.append(Capture(range: range, pattern: capture.patternIndex, paint: paint))
            }
        }
        guard !Task.isCancelled else { return [] }
        return flatten(captures, length: length, firstPatternWins: grammar.firstPatternWins)
    }

    // MARK: - Painting

    struct Capture {
        /// Marks a capture that wins its range but applies no color (for example `@variable`).
        static let noStyle: UInt8 = .max
        var range: NSRange
        var pattern: Int
        var paint: UInt8
    }

    /// Resolves nested and duplicate captures into flat, non-overlapping spans: inner captures override outer
    /// ones, and for identical ranges the grammar's precedence convention decides the winner.
    static func flatten(_ captures: [Capture], length: Int, firstPatternWins: Bool) -> [HighlightSpan] {
        let ordered = captures.sorted { a, b in
            if a.range.location != b.range.location { return a.range.location < b.range.location }
            if a.range.length != b.range.length { return a.range.length > b.range.length }
            return firstPatternWins ? a.pattern < b.pattern : a.pattern > b.pattern
        }
        var paints = [UInt8](repeating: 0, count: length)
        var previous: NSRange?
        for capture in ordered {
            // Sorted so the winner of an identical range comes first; the rest of that range is ignored.
            if let previous, previous == capture.range { continue }
            previous = capture.range
            guard capture.paint != Capture.noStyle else { continue }
            let end = NSMaxRange(capture.range)
            for index in capture.range.location..<end { paints[index] = capture.paint }
        }

        var spans: [HighlightSpan] = []
        var runStart = 0
        var current: UInt8 = 0
        for index in 0...length {
            let value: UInt8 = index < length ? paints[index] : 0
            guard value != current else { continue }
            if current != 0, let token = TokenKind(paintValue: current) {
                spans.append(HighlightSpan(range: NSRange(location: runStart, length: index - runStart), token: token))
            }
            current = value
            runStart = index
        }
        return spans
    }

    // MARK: - Grammars

    struct Grammar: Sendable {
        let language: Language
        let queryResource: String
        /// Official tree-sitter grammars follow the CLI convention where the earliest pattern wins for an
        /// identical node; grammars written for nvim-treesitter (Swift, Markdown) let the latest pattern win.
        let firstPatternWins: Bool
    }

    static let grammars: [String: Grammar] = [
        "swift": Grammar(language: Language(tree_sitter_swift()), queryResource: "highlights-swift", firstPatternWins: false),
        "javascript": Grammar(language: Language(tree_sitter_javascript()), queryResource: "highlights-javascript", firstPatternWins: true),
        "typescript": Grammar(language: Language(tree_sitter_typescript()), queryResource: "highlights-typescript", firstPatternWins: true),
        "tsx": Grammar(language: Language(tree_sitter_tsx()), queryResource: "highlights-tsx", firstPatternWins: true),
        "python": Grammar(language: Language(tree_sitter_python()), queryResource: "highlights-python", firstPatternWins: true),
        "json": Grammar(language: Language(tree_sitter_json()), queryResource: "highlights-json", firstPatternWins: true),
        "go": Grammar(language: Language(tree_sitter_go()), queryResource: "highlights-go", firstPatternWins: true),
        "rust": Grammar(language: Language(tree_sitter_rust()), queryResource: "highlights-rust", firstPatternWins: true),
        "markdown": Grammar(language: Language(tree_sitter_markdown()), queryResource: "highlights-markdown", firstPatternWins: false),
    ]

    private static let logger = Logger(subsystem: "app.mercury.MercuryDiff", category: "SyntaxHighlighter")

    /// Compiled queries per resource; `nil` records a query that failed so it is not recompiled per call.
    private static let queryCache = Mutex<[String: Query?]>([:])

    static func query(for grammar: Grammar) -> Query? {
        if let cached = queryCache.withLock({ $0[grammar.queryResource] }) { return cached }
        let compiled: Query?
        do {
            guard let url = Bundle.module.url(forResource: grammar.queryResource, withExtension: "scm") else {
                throw CocoaError(.fileNoSuchFile)
            }
            compiled = try Query(language: grammar.language, data: Data(contentsOf: url))
        } catch {
            logger.error("Cannot load highlight query \(grammar.queryResource, privacy: .public): \(String(describing: error), privacy: .public)")
            compiled = nil
        }
        // Two threads may compile the same query concurrently; either result is equivalent.
        queryCache.withLock { $0[grammar.queryResource] = compiled }
        return compiled
    }
}

extension TokenKind {
    /// Compact non-zero paint value used while flattening; 0 means "no color".
    var paintValue: UInt8 { UInt8(Self.allCases.firstIndex(of: self)! + 1) }

    init?(paintValue: UInt8) {
        let index = Int(paintValue) - 1
        guard Self.allCases.indices.contains(index) else { return nil }
        self = Self.allCases[index]
    }
}
