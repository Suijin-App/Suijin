import Foundation

/// How a list item starts.
public enum MarkdownListMarker: Sendable, Hashable {
    /// `-`, `*` or `+`.
    case bullet
    /// `1.` or `1)`.
    case ordered
    /// `- [ ]` or `- [x]`.
    case task(checked: Bool)
}

/// A range of the Markdown source that is shown in one style. Ranges are UTF-16 units, as in `NSString`. Runs of
/// different kinds nest and overlap (strong text inside a list item inside a quote).
public struct MarkdownStyleRun: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// A heading line (ATX or setext), level 1 to 6.
        case heading(level: Int)
        case strong
        case emphasis
        case strikethrough
        case inlineCode
        /// The text of a link; `destination` is nil for reference links, whose target is defined elsewhere.
        case link(destination: String?)
        /// The marker of a list item, with the task box when there is one.
        case listMarker(MarkdownListMarker)
        /// A whole list item; its text starts at `contentLocation` on the first line (after the marker).
        case listItem(contentLocation: Int)
        /// A block quote, `depth` 1 for the outermost.
        case blockquote(depth: Int)
        case thematicBreak
        /// A fenced or indented code block; `content` is the code itself, without the fences.
        case codeBlock(language: String?, content: NSRange?)
        case table
        case frontMatter
    }

    public var range: NSRange
    public var kind: Kind

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}

/// Markdown punctuation that the editor shows in a rendered form away from the line being edited: most markers
/// are hidden, a bullet becomes a dot, a task box and a thematic break are drawn.
public struct MarkdownMarker: Sendable, Hashable {
    public enum Role: Sendable, Hashable {
        /// `#` with its space, or a setext underline.
        case heading
        case emphasis
        case strong
        case strikethrough
        /// The backticks of a code span.
        case code
        /// The `[` of a link, or the `<` of an autolink.
        case linkOpen
        /// From `]` through the destination, or the `>` of an autolink.
        case linkClose
        /// `>` with its space.
        case blockquote
        /// The backslash of an escaped character.
        case escape
        /// `-`, `*` or `+` of a list item: drawn as a dot.
        case bullet
        /// The `- ` before a task box: hidden, the box stands in for the bullet.
        case taskBullet
        /// `[ ]` or `[x]`: drawn as a box.
        case checkbox(checked: Bool)
        /// `---`: drawn as a rule.
        case thematicBreak
    }

    public var range: NSRange
    public var role: Role

    public init(range: NSRange, role: Role) {
        self.range = range
        self.role = role
    }
}

/// The styling of a range of a document: its runs in document order (outer before inner), and its markers sorted by
/// location and never overlapping.
public struct MarkdownStyling: Sendable, Hashable {
    public var runs: [MarkdownStyleRun]
    public var markers: [MarkdownMarker]

    public init(runs: [MarkdownStyleRun] = [], markers: [MarkdownMarker] = []) {
        self.runs = runs
        self.markers = markers
    }
}
