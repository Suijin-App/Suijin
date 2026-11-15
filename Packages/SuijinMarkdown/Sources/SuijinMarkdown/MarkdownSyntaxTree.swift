import Foundation
import SwiftTreeSitter
import TreeSitterMarkdown
import TreeSitterMarkdownInline

// Markdown is parsed the way the tree-sitter-markdown grammar is designed: the block grammar builds the document
// structure and leaves the text of paragraphs and headings in `inline` nodes, and the inline grammar (shipped in the
// same package as `TreeSitterMarkdownInline`) parses each of those for emphasis, code spans and links. The block
// tree is kept and reparsed incrementally on every edit; inline nodes are small and are parsed when they are styled.

/// The Markdown source of one document with its block syntax tree, updated incrementally as the text is edited.
/// All offsets are UTF-16 units, as in `NSString`. Not thread-safe: use it from one thread (the editor's main actor).
public final class MarkdownSyntaxTree {
    private let parser = Parser()
    private let inlineParser = Parser()
    private let source: NSMutableString
    private var tree: MutableTree?
    /// The edits not parsed yet: the text they inserted, and the front matter as it was before the first of them.
    private var unparsed: (edited: NSRange, frontMatterBefore: NSRange?)?

    public init(text: String) {
        source = NSMutableString(string: text)
        // The grammars are compiled into the package; setting them cannot fail unless the ABI is incompatible, in
        // which case every parse returns nil and the document shows unstyled.
        try? parser.setLanguage(Language(tree_sitter_markdown()))
        try? inlineParser.setLanguage(Language(tree_sitter_markdown_inline()))
        tree = parse(reusing: nil)
    }

    /// The current source.
    public var text: String { source as String }

    /// The length of the source in UTF-16 units.
    public var length: Int { source.length }

    var string: NSString { source }

    var rootNode: Node? { tree?.rootNode }

    /// Replaces the whole source and parses it from scratch.
    public func replaceAll(with text: String) {
        source.setString(text)
        unparsed = nil
        tree = parse(reusing: nil)
    }

    /// Replaces `oldLength` units at `location` with `replacement`, reparses incrementally, and returns the range of
    /// the new source whose styling may have changed: whole lines, covering the edit and every syntax change the
    /// parser reports.
    @discardableResult
    public func replace(location: Int, oldLength: Int, with replacement: String) -> NSRange {
        edit(location: location, oldLength: oldLength, with: replacement)
        return reparse()
    }

    /// Whether the source was edited since the tree was last parsed. The tree must be reparsed before it is styled.
    public var needsReparse: Bool { unparsed != nil }

    /// Replaces `oldLength` units at `location` with `replacement` without parsing. Several edits can be made before
    /// one `reparse()`: on a very long document a reparse takes longer than a keystroke should.
    public func edit(location: Int, oldLength: Int, with replacement: String) {
        let oldRange = NSRange(location: location, length: oldLength)
        precondition(location >= 0 && NSMaxRange(oldRange) <= source.length, "edit outside the source")
        let frontMatterBefore = unparsed?.frontMatterBefore ?? MarkdownFrontMatter.range(in: source)
        source.replaceCharacters(in: oldRange, with: replacement)
        let newLength = (replacement as NSString).length
        // Rows and columns are not supplied: nothing here reads node positions as points, and tree-sitter only needs
        // the byte offsets to reuse the unchanged parts of the tree.
        tree?.edit(InputEdit(startByte: location * 2, oldEndByte: NSMaxRange(oldRange) * 2,
                             newEndByte: (location + newLength) * 2,
                             startPoint: .zero, oldEndPoint: .zero, newEndPoint: .zero))

        // The edited text of all unparsed edits, in the coordinates of the current source.
        var edited = NSRange(location: location, length: newLength)
        if var earlier = unparsed?.edited {
            let delta = newLength - oldLength
            if NSMaxRange(oldRange) <= earlier.location {
                earlier.location += delta
            } else if location < NSMaxRange(earlier) {
                earlier.length = max(0, earlier.length + delta)
            }
            edited = NSUnionRange(earlier, edited)
        }
        unparsed = (edited, frontMatterBefore)
    }

    /// Parses the edits made since the last parse, reusing the unchanged parts of the tree, and returns the range of
    /// the source whose styling may have changed (whole lines; empty when nothing was edited).
    @discardableResult
    public func reparse() -> NSRange {
        guard let unparsed else { return NSRange(location: 0, length: 0) }
        self.unparsed = nil
        var changed = unparsed.edited
        if let old = tree, let new = parse(reusing: old) {
            for range in new.changedRanges(from: old) {
                let start = Int(range.bytes.lowerBound) / 2, end = Int(range.bytes.upperBound) / 2
                changed = NSUnionRange(changed, NSRange(location: start, length: max(0, end - start)))
            }
            tree = new
        } else {
            tree = parse(reusing: nil)
            changed = NSRange(location: 0, length: source.length)
        }
        // Front matter is recognized apart from the grammar (see MarkdownFrontMatter): when its extent changes,
        // everything it covered or released is styled again.
        let frontMatterAfter = MarkdownFrontMatter.range(in: source)
        if unparsed.frontMatterBefore != frontMatterAfter {
            let end = max(unparsed.frontMatterBefore.map(NSMaxRange) ?? 0, frontMatterAfter.map(NSMaxRange) ?? 0) + unparsed.edited.length
            changed = NSUnionRange(changed, NSRange(location: 0, length: end))
        }
        let clamped = NSIntersectionRange(changed, NSRange(location: 0, length: source.length))
        let anchored = clamped.length == 0 ? NSRange(location: min(changed.location, source.length), length: 0) : clamped
        return expandedToBlocks(source.lineRange(for: anchored))
    }

    /// Grows a range of whole lines to the leaf blocks (paragraphs, headings, code blocks, tables) it touches, so
    /// that a multi-line block is always styled as a whole.
    private func expandedToBlocks(_ range: NSRange) -> NSRange {
        guard let root = rootNode, range.length > 0 else { return range }
        var result = range
        func visit(_ cursor: TreeCursor) {
            guard let node = cursor.currentNode else { return }
            if Self.containers.contains(node.nodeType ?? "") {
                guard cursor.goToFirstChild() else { return }
                repeat {
                    guard let child = cursor.currentNode else { continue }
                    if child.range.location >= NSMaxRange(range) { break }
                    if NSMaxRange(child.range) > range.location { visit(cursor) }
                } while cursor.gotoNextSibling()
                _ = cursor.gotoParent()
            } else if node.isNamed {
                result = NSUnionRange(result, node.range)
            }
        }
        visit(root.treeCursor)
        result = NSIntersectionRange(result, NSRange(location: 0, length: source.length))
        return source.lineRange(for: result)
    }

    /// Block nodes that only hold other blocks.
    static let containers: Set<String> = ["document", "section", "list", "list_item", "block_quote"]

    /// Parses the text of one `inline` node. `blanked` are ranges inside it that belong to the block structure
    /// (quote markers and indentation of continuation lines); they are replaced by spaces of the same length so the
    /// offsets of the result still match the source. Returns the tree with the offset to add to its node ranges.
    func parseInline(_ range: NSRange, blanking blanked: [NSRange]) -> (tree: MutableTree, offset: Int)? {
        guard range.length > 0, NSMaxRange(range) <= source.length else { return nil }
        var units = [unichar](repeating: 0, count: range.length)
        source.getCharacters(&units, range: range)
        for blank in blanked {
            let local = NSIntersectionRange(blank, range)
            guard local.length > 0 else { continue }
            for index in (local.location - range.location)..<(NSMaxRange(local) - range.location)
            where units[index] != 0x0A && units[index] != 0x0D {
                units[index] = 0x20
            }
        }
        let tree = units.withUnsafeBufferPointer { buffer -> MutableTree? in
            inlineParser.parse(tree: nil as MutableTree?) { byteOffset, _ in
                Self.chunk(of: buffer, at: byteOffset)
            }
        }
        return tree.map { ($0, range.location) }
    }

    // MARK: - Parsing

    private func parse(reusing old: MutableTree?) -> MutableTree? {
        let source = source
        return parser.parse(tree: old) { byteOffset, _ in
            let location = byteOffset / 2
            guard location < source.length else { return nil }
            let count = min(Self.chunkSize, source.length - location)
            var data = Data(count: count * 2)
            data.withUnsafeMutableBytes { bytes in
                guard let base = bytes.bindMemory(to: unichar.self).baseAddress else { return }
                source.getCharacters(base, range: NSRange(location: location, length: count))
            }
            return data
        }
    }

    private static let chunkSize = 8192

    private static func chunk(of buffer: UnsafeBufferPointer<unichar>, at byteOffset: Int) -> Data? {
        let location = byteOffset / 2
        guard location < buffer.count else { return nil }
        let count = min(chunkSize, buffer.count - location)
        return Data(buffer: UnsafeBufferPointer(rebasing: buffer[location..<(location + count)]))
    }
}
