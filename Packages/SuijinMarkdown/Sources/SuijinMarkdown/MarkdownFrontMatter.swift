import Foundation

/// A Markdown file split into its YAML front matter (`---` … `---` at the top, as plans and docs use) and its body.
/// The front matter is shown as fields; Markdown would otherwise read it as a setext heading.
public struct MarkdownDocument {
    public let frontMatter: [(key: String, value: String)]
    public let body: String

    public init(_ text: String) {
        let source = text as NSString
        guard let range = MarkdownFrontMatter.range(in: source) else {
            frontMatter = []
            body = text
            return
        }
        let lines = source.substring(with: range).components(separatedBy: .newlines)
        frontMatter = lines.dropFirst().compactMap { line in
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { return nil }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return key.isEmpty ? nil : (key, value)
        }
        body = source.substring(from: NSMaxRange(range))
    }
}

/// Where the front matter of a Markdown source is: the reader and the editor share this one rule.
public enum MarkdownFrontMatter {
    /// The range of the front matter block, from the opening `---` line through the closing `---` line and its line
    /// ending; nil when the source does not start with one or it is never closed.
    public static func range(in source: NSString) -> NSRange? {
        guard source.length >= 3 else { return nil }
        let first = source.lineRange(for: NSRange(location: 0, length: 0))
        guard isDelimiter(source, first) else { return nil }
        var location = NSMaxRange(first)
        while location < source.length {
            let line = source.lineRange(for: NSRange(location: location, length: 0))
            if isDelimiter(source, line) { return NSRange(location: 0, length: NSMaxRange(line)) }
            location = NSMaxRange(line)
        }
        return nil
    }

    private static func isDelimiter(_ source: NSString, _ line: NSRange) -> Bool {
        // A delimiter line is short; longer lines are not copied out just to be compared.
        guard line.length >= 3, line.length <= 64 else { return false }
        return source.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines) == "---"
    }
}
