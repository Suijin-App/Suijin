import Foundation
import SwiftTreeSitter

/// Turns the syntax tree into style runs and markers. Pure: the same tree and range always give the same result.
public enum MarkdownStyler {
    /// The runs and markers of every block that touches `range`. Blocks are never cut: a paragraph that only partly
    /// lies in `range` is returned whole, so callers that restyle a range clip to it.
    public static func styling(of tree: MarkdownSyntaxTree, in range: NSRange) -> MarkdownStyling {
        var builder = Builder(tree: tree, range: range)
        builder.run()
        return builder.result()
    }

    /// The styling of the whole document.
    public static func styling(of tree: MarkdownSyntaxTree) -> MarkdownStyling {
        styling(of: tree, in: NSRange(location: 0, length: tree.length))
    }

    /// The markers shown in their rendered form: every marker except those on a line being edited. `active` holds
    /// the ranges of the lines with the insertion point or the selection; a marker that touches one of them stays as
    /// typed. (Code blocks, tables and front matter have no markers at all, so nothing in them is ever hidden.)
    public static func hiddenMarkers(in markers: [MarkdownMarker], activeLines active: [NSRange]) -> [MarkdownMarker] {
        markers.filter { marker in
            !active.contains { line in
                line.length == 0
                    ? line.location >= marker.range.location && line.location <= NSMaxRange(marker.range)
                    : NSIntersectionRange(line, marker.range).length > 0
            }
        }
    }

    private struct Builder {
        let tree: MarkdownSyntaxTree
        let source: NSString
        let range: NSRange
        let frontMatter: NSRange?
        var runs: [MarkdownStyleRun] = []
        var markers: [MarkdownMarker] = []

        init(tree: MarkdownSyntaxTree, range: NSRange) {
            self.tree = tree
            source = tree.string
            self.range = range
            frontMatter = MarkdownFrontMatter.range(in: tree.string)
        }

        func result() -> MarkdownStyling {
            var sorted = markers.sorted { $0.range.location < $1.range.location }
            // Adjacent delimiters of one construct (`**`) are single-character nodes: join them.
            var merged: [MarkdownMarker] = []
            for marker in sorted where marker.range.length > 0 {
                if let last = merged.last, NSMaxRange(last.range) > marker.range.location { continue }
                if let last = merged.last, last.role == marker.role, NSMaxRange(last.range) == marker.range.location,
                   Self.joins(marker.role) {
                    merged[merged.count - 1].range.length += marker.range.length
                } else {
                    merged.append(marker)
                }
            }
            sorted = merged
            return MarkdownStyling(runs: runs.filter { touches($0.range) }, markers: sorted.filter { touches($0.range) })
        }

        private static func joins(_ role: MarkdownMarker.Role) -> Bool {
            switch role {
            case .emphasis, .strong, .strikethrough, .code: true
            default: false
            }
        }

        private func touches(_ other: NSRange) -> Bool {
            other.location < NSMaxRange(range) && NSMaxRange(other) > range.location
                || (range.length == 0 && other.location <= range.location && NSMaxRange(other) >= range.location)
        }

        mutating func run() {
            if let frontMatter {
                runs.append(MarkdownStyleRun(range: trimmed(frontMatter), kind: .frontMatter))
            }
            guard let root = tree.rootNode else { return }
            visit(root.treeCursor, quoteDepth: 0)
        }

        /// Visits the children of the cursor's node that touch the range.
        private mutating func visitChildren(_ cursor: TreeCursor, quoteDepth: Int) {
            guard cursor.goToFirstChild() else { return }
            repeat {
                guard let child = cursor.currentNode else { continue }
                if child.range.location > NSMaxRange(range) { break }
                if NSMaxRange(child.range) >= range.location { visit(cursor, quoteDepth: quoteDepth) }
            } while cursor.gotoNextSibling()
            _ = cursor.gotoParent()
        }

        private mutating func visit(_ cursor: TreeCursor, quoteDepth: Int) {
            guard let node = cursor.currentNode, let type = node.nodeType else { return }
            let nodeRange = node.range
            // Whatever the grammar made of the lines of the front matter, they are shown as front matter.
            if let frontMatter, nodeRange.location < NSMaxRange(frontMatter), !MarkdownSyntaxTree.containers.contains(type) {
                return
            }
            switch type {
            case "document", "section", "list":
                visitChildren(cursor, quoteDepth: quoteDepth)
            case "minus_metadata", "plus_metadata":
                if frontMatter == nil { runs.append(MarkdownStyleRun(range: trimmed(nodeRange), kind: .frontMatter)) }
            case "atx_heading":
                heading(node, quoteDepth: quoteDepth)
            case "setext_heading":
                setextHeading(node, quoteDepth: quoteDepth)
            case "paragraph":
                paragraph(node, quoteDepth: quoteDepth)
            case "list_item":
                listItem(node)
                visitChildren(cursor, quoteDepth: quoteDepth)
            case "block_quote":
                runs.append(MarkdownStyleRun(range: trimmed(nodeRange), kind: .blockquote(depth: quoteDepth + 1)))
                visitChildren(cursor, quoteDepth: quoteDepth + 1)
            case "block_quote_marker", "block_continuation":
                if quoteDepth > 0 { quoteMarkers(in: nodeRange) }
            case "thematic_break":
                let text = trimmed(nodeRange)
                runs.append(MarkdownStyleRun(range: text, kind: .thematicBreak))
                markers.append(MarkdownMarker(range: text, role: .thematicBreak))
            case "fenced_code_block":
                var language: String?
                var content: NSRange?
                node.enumerateChildren { child in
                    switch child.nodeType {
                    case "info_string":
                        let info = source.substring(with: child.range).trimmingCharacters(in: .whitespaces)
                        language = info.split(separator: " ").first.map(String.init)
                    case "code_fence_content":
                        content = child.range
                    default: break
                    }
                }
                runs.append(MarkdownStyleRun(range: trimmed(nodeRange), kind: .codeBlock(language: language, content: content)))
            case "indented_code_block":
                let text = trimmed(nodeRange)
                runs.append(MarkdownStyleRun(range: text, kind: .codeBlock(language: nil, content: text)))
            case "pipe_table":
                runs.append(MarkdownStyleRun(range: trimmed(nodeRange), kind: .table))
            default:
                // HTML blocks and link reference definitions stay as typed.
                break
            }
        }

        // MARK: Blocks

        private mutating func heading(_ node: Node, quoteDepth: Int) {
            var level = 1
            var marker: NSRange?
            var content: Node?
            node.enumerateChildren { child in
                guard let type = child.nodeType else { return }
                if type.hasPrefix("atx_h"), type.hasSuffix("_marker"), marker == nil {
                    level = Int(type.dropFirst(5).prefix(1)) ?? 1
                    marker = child.range
                } else if type == "inline" {
                    content = child
                }
            }
            let line = trimmed(node.range)
            runs.append(MarkdownStyleRun(range: line, kind: .heading(level: level)))
            if let marker {
                // The marker is hidden with the space after it.
                let end = content?.range.location ?? min(NSMaxRange(marker) + 1, NSMaxRange(line))
                markers.append(MarkdownMarker(range: NSRange(location: marker.location, length: max(marker.length, end - marker.location)), role: .heading))
            }
            if let content { inline(content, quoteDepth: quoteDepth) }
        }

        private mutating func setextHeading(_ node: Node, quoteDepth: Int) {
            var level = 1
            var content: Node?
            node.enumerateChildren { child in
                switch child.nodeType {
                case "paragraph": content = child
                case "setext_h1_underline":
                    markers.append(MarkdownMarker(range: trimmed(child.range), role: .heading))
                case "setext_h2_underline":
                    level = 2
                    markers.append(MarkdownMarker(range: trimmed(child.range), role: .heading))
                case "block_continuation":
                    if quoteDepth > 0 { quoteMarkers(in: child.range) }
                default: break
                }
            }
            guard let content else { return }
            runs.append(MarkdownStyleRun(range: trimmed(content.range), kind: .heading(level: level)))
            paragraph(content, quoteDepth: quoteDepth)
        }

        private mutating func paragraph(_ node: Node, quoteDepth: Int) {
            node.enumerateChildren { child in
                switch child.nodeType {
                case "inline": inline(child, quoteDepth: quoteDepth)
                case "block_continuation": if quoteDepth > 0 { quoteMarkers(in: child.range) }
                default: break
                }
            }
        }

        private mutating func listItem(_ node: Node) {
            var markerRange: NSRange?
            var kind = MarkdownListMarker.bullet
            var contentLocation: Int?
            node.enumerateChildren { child in
                guard let type = child.nodeType else { return }
                if type.hasPrefix("list_marker_") {
                    // The node covers the indentation before the marker and the space after it.
                    let text = visible(child.range)
                    markerRange = text
                    switch type {
                    case "list_marker_minus", "list_marker_star", "list_marker_plus":
                        kind = .bullet
                        markers.append(MarkdownMarker(range: text, role: .bullet))
                    default:
                        kind = .ordered
                    }
                    contentLocation = NSMaxRange(child.range)
                } else if type == "task_list_marker_checked" || type == "task_list_marker_unchecked" {
                    let checked = type == "task_list_marker_checked"
                    kind = .task(checked: checked)
                    let box = visible(child.range)
                    if let last = markers.indices.last, markers[last].role == .bullet, NSMaxRange(markers[last].range) <= box.location {
                        markers[last] = MarkdownMarker(range: NSRange(location: markers[last].range.location, length: box.location - markers[last].range.location), role: .taskBullet)
                    }
                    markers.append(MarkdownMarker(range: box, role: .checkbox(checked: checked)))
                    if let marker = markerRange { markerRange = NSUnionRange(marker, box) }
                    contentLocation = skippingSpaces(from: NSMaxRange(box))
                }
            }
            guard let markerRange else { return }
            runs.append(MarkdownStyleRun(range: markerRange, kind: .listMarker(kind)))
            runs.append(MarkdownStyleRun(range: trimmed(node.range), kind: .listItem(contentLocation: contentLocation ?? NSMaxRange(markerRange))))
        }

        /// One marker for each `>` in `range`, with the space after it.
        private mutating func quoteMarkers(in range: NSRange) {
            var index = range.location
            let end = min(NSMaxRange(range), source.length)
            while index < end {
                if source.character(at: index) == 0x3E {
                    let hasSpace = index + 1 < source.length && source.character(at: index + 1) == 0x20
                    markers.append(MarkdownMarker(range: NSRange(location: index, length: hasSpace ? 2 : 1), role: .blockquote))
                    index += hasSpace ? 2 : 1
                } else {
                    index += 1
                }
            }
        }

        // MARK: Inline

        private mutating func inline(_ node: Node, quoteDepth: Int) {
            var blanked: [NSRange] = []
            node.enumerateChildren { child in
                guard child.nodeType == "block_continuation" else { return }
                blanked.append(child.range)
                if quoteDepth > 0 { quoteMarkers(in: child.range) }
            }
            guard let parsed = tree.parseInline(node.range, blanking: blanked), let root = parsed.tree.rootNode else { return }
            inlineNode(root, offset: parsed.offset, parentType: nil)
        }

        private mutating func inlineNode(_ node: Node, offset: Int, parentType: String?) {
            guard let type = node.nodeType else { return }
            let nodeRange = NSRange(location: node.range.location + offset, length: node.range.length)
            var descends = true
            switch type {
            case "emphasis":
                runs.append(MarkdownStyleRun(range: nodeRange, kind: .emphasis))
            case "strong_emphasis":
                runs.append(MarkdownStyleRun(range: nodeRange, kind: .strong))
            case "strikethrough":
                // `~~text~~` parses as a strikethrough inside a strikethrough: one run is enough.
                if parentType != "strikethrough" { runs.append(MarkdownStyleRun(range: nodeRange, kind: .strikethrough)) }
            case "emphasis_delimiter":
                let role: MarkdownMarker.Role = switch parentType {
                case "strong_emphasis": .strong
                case "strikethrough": .strikethrough
                default: .emphasis
                }
                markers.append(MarkdownMarker(range: nodeRange, role: role))
            case "code_span":
                runs.append(MarkdownStyleRun(range: nodeRange, kind: .inlineCode))
            case "code_span_delimiter":
                markers.append(MarkdownMarker(range: nodeRange, role: .code))
            case "inline_link", "full_reference_link", "collapsed_reference_link":
                link(node, range: nodeRange, offset: offset, hasDestination: type == "inline_link")
            case "uri_autolink", "email_autolink":
                guard nodeRange.length > 2 else { break }
                let inner = NSRange(location: nodeRange.location + 1, length: nodeRange.length - 2)
                let target = source.substring(with: inner)
                runs.append(MarkdownStyleRun(range: inner, kind: .link(destination: type == "email_autolink" ? "mailto:" + target : target)))
                markers.append(MarkdownMarker(range: NSRange(location: nodeRange.location, length: 1), role: .linkOpen))
                markers.append(MarkdownMarker(range: NSRange(location: NSMaxRange(nodeRange) - 1, length: 1), role: .linkClose))
                descends = false
            case "backslash_escape":
                markers.append(MarkdownMarker(range: NSRange(location: nodeRange.location, length: 1), role: .escape))
                descends = false
            case "image", "html_tag":
                // Shown as typed: images are not drawn in the editor, and HTML is not interpreted.
                descends = false
            default:
                break
            }
            guard descends else { return }
            node.enumerateChildren { child in
                inlineNode(child, offset: offset, parentType: type)
            }
        }

        private mutating func link(_ node: Node, range nodeRange: NSRange, offset: Int, hasDestination: Bool) {
            var text: NSRange?
            var destination: String?
            node.enumerateChildren { child in
                let childRange = NSRange(location: child.range.location + offset, length: child.range.length)
                switch child.nodeType {
                case "link_text": text = childRange
                case "link_destination": destination = source.substring(with: childRange)
                default: break
                }
            }
            guard let text, text.length > 0 else { return }
            if let target = destination, target.hasPrefix("<"), target.hasSuffix(">"), target.count >= 2 {
                destination = String(target.dropFirst().dropLast())
            }
            runs.append(MarkdownStyleRun(range: text, kind: .link(destination: hasDestination ? destination : nil)))
            markers.append(MarkdownMarker(range: NSRange(location: nodeRange.location, length: text.location - nodeRange.location), role: .linkOpen))
            markers.append(MarkdownMarker(range: NSRange(location: NSMaxRange(text), length: NSMaxRange(nodeRange) - NSMaxRange(text)), role: .linkClose))
        }

        // MARK: Ranges

        /// `range` without the line endings and blank lines the grammar leaves at the end of a block.
        private func trimmed(_ range: NSRange) -> NSRange {
            var end = min(NSMaxRange(range), source.length)
            while end > range.location, Self.isLineEnding(source.character(at: end - 1)) { end -= 1 }
            return NSRange(location: range.location, length: end - range.location)
        }

        /// `range` without the spaces and line endings around its text.
        private func visible(_ range: NSRange) -> NSRange {
            var start = range.location
            var end = min(NSMaxRange(range), source.length)
            while start < end, Self.isBlank(source.character(at: start)) { start += 1 }
            while end > start, Self.isBlank(source.character(at: end - 1)) { end -= 1 }
            return NSRange(location: start, length: end - start)
        }

        private func skippingSpaces(from location: Int) -> Int {
            var index = location
            while index < source.length, source.character(at: index) == 0x20 || source.character(at: index) == 0x09 { index += 1 }
            return index
        }

        private static func isLineEnding(_ unit: unichar) -> Bool { unit == 0x0A || unit == 0x0D }
        private static func isBlank(_ unit: unichar) -> Bool { unit == 0x20 || unit == 0x09 || isLineEnding(unit) }
    }
}
