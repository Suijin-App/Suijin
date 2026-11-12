import Foundation

/// A declaration in a source file, for the viewer's symbol menu.
struct CodeSymbol: Hashable {
    enum Kind: Hashable { case type, function, property }
    let name: String
    let kind: Kind
    /// 1-based line number.
    let line: Int
    /// Leading spaces, so nested declarations indent in the menu.
    let depth: Int
}

/// Finds declarations line by line with each language's declaration syntax (`func`, `class`, `def`, `fn`, `const x =
/// () =>`, …). A light index for jumping around a file, not a parser: declarations split across lines are missed.
enum CodeSymbols {
    static func symbols(in text: String, language: String) -> [CodeSymbol] {
        guard let rules = rules[family(language)] else { return [] }
        var result: [CodeSymbol] = []
        var lineNumber = 0
        text.enumerateLines { line, _ in
            lineNumber += 1
            guard line.count < 400 else { return }
            for rule in rules {
                guard let match = rule.regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let range = Range(match.range(at: 1), in: line) else { continue }
                let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                let name = String(line[range]).trimmingCharacters(in: .whitespaces)
                result.append(CodeSymbol(name: name, kind: rule.kind, line: lineNumber, depth: indent / 2))
                break
            }
        }
        return result
    }

    private struct Rule {
        let regex: NSRegularExpression
        let kind: CodeSymbol.Kind
        init(_ pattern: String, _ kind: CodeSymbol.Kind) {
            // Patterns are fixed literals; a typo is a programming error caught by the tests.
            regex = try! NSRegularExpression(pattern: pattern)
            self.kind = kind
        }
    }

    private static func family(_ language: String) -> String {
        switch language {
        case "typescript", "tsx", "javascript": "js"
        default: language
        }
    }

    private static let modifiers = #"(?:(?:@\w+(?:\([^)]*\))?|public|private|internal|fileprivate|open|static|final|override|mutating|nonmutating|nonisolated|convenience|required|async|indirect|lazy|weak|unowned|dynamic)\s+)*"#

    private static let rules: [String: [Rule]] = [
        "swift": [
            Rule(#"^\s*"# + modifiers + #"(?:class|struct|enum|protocol|actor|extension)\s+([A-Za-z_][\w.]*)"#, .type),
            Rule(#"^\s*"# + modifiers + #"func\s+([^\s(<]+)"#, .function),
            Rule(#"^\s*"# + modifiers + #"(init[?!]?)\s*[(<]"#, .function),
        ],
        "js": [
            Rule(#"^\s*(?:export\s+)?(?:default\s+)?(?:abstract\s+)?(?:class|interface|enum)\s+([A-Za-z_$][\w$]*)"#, .type),
            Rule(#"^\s*(?:export\s+)?type\s+([A-Za-z_$][\w$]*)\s*(?:<[^=]*>)?\s*="#, .type),
            Rule(#"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)"#, .function),
            Rule(#"^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s+)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*(?::[^=]+)?=>"#, .function),
            // Class methods; control-flow keywords share the `name (…) {` shape and are excluded.
            Rule(#"^\s+(?:public\s+|private\s+|protected\s+|static\s+|async\s+|readonly\s+)*(?!(?:if|for|while|switch|catch|with|return|function)\b)([A-Za-z_$][\w$]*)\s*\([^)]*\)\s*(?::[^{]+)?\{\s*$"#, .function),
        ],
        "python": [
            Rule(#"^\s*class\s+([A-Za-z_]\w*)"#, .type),
            Rule(#"^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)"#, .function),
        ],
        "go": [
            Rule(#"^type\s+([A-Za-z_]\w*)"#, .type),
            Rule(#"^func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)"#, .function),
        ],
        "rust": [
            Rule(#"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:struct|enum|trait|union|type)\s+([A-Za-z_]\w*)"#, .type),
            Rule(#"^\s*impl(?:<[^>]*>)?\s+([A-Za-z_][\w:<>, ]*)"#, .type),
            Rule(#"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:const\s+)?(?:async\s+)?(?:unsafe\s+)?fn\s+([A-Za-z_]\w*)"#, .function),
        ],
    ]
}
