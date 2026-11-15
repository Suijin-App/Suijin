import AppKit

/// Fonts, colors and measures of the Markdown editor. The app passes its own values; the package knows no design
/// tokens. Colors are dynamic `NSColor`s, resolved for the appearance at drawing time.
public struct MarkdownTheme {
    public var baseFont = NSFont.systemFont(ofSize: 16)
    public var monoFont = NSFont.monospacedSystemFont(ofSize: 13.6, weight: .regular)
    public var textColor = NSColor.labelColor
    /// Quoted text and list bullets.
    public var secondaryTextColor = NSColor.secondaryLabelColor
    /// Markdown punctuation shown on the line being edited.
    public var markerColor = NSColor.tertiaryLabelColor
    public var linkColor = NSColor.linkColor
    /// Behind code blocks, tables and front matter.
    public var blockBackground = NSColor.quaternaryLabelColor.withAlphaComponent(0.08)
    public var inlineCodeBackground = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
    public var ruleColor = NSColor.separatorColor
    public var quoteBarColor = NSColor.separatorColor
    public var checkboxColor = NSColor.controlAccentColor
    public var background = NSColor.textBackgroundColor
    /// The text column is never wider than this; a wider view centers it.
    public var maximumContentWidth: CGFloat = 860
    /// Space between the text column and the view's edges.
    public var contentInset = NSSize(width: 24, height: 16)
    /// Heading sizes relative to the base font, level 1 first.
    public var headingScales: [CGFloat] = [2, 1.5, 1.25, 1, 0.875, 0.85]
    public var lineSpacing: CGFloat = 4

    public init() {}

    func headingFont(level: Int) -> NSFont {
        let scale = headingScales[max(0, min(level, headingScales.count) - 1)]
        return NSFont.systemFont(ofSize: (baseFont.pointSize * scale).rounded(), weight: .semibold)
    }

    /// How far each level of a block quote moves its text in.
    var quoteIndent: CGFloat { 16 }
    /// Padding of the text inside a code block, table or front matter.
    var blockPadding: CGFloat { 12 }
    /// Side of a drawn task box.
    var checkboxSide: CGFloat { max(12, baseFont.pointSize * 0.9).rounded() }
    /// The font the characters `[ ]` and `[x]` get under a drawn task box, sized so the three of them are as wide as
    /// the box whatever is between the brackets.
    var checkboxFont: NSFont { NSFont.monospacedSystemFont(ofSize: checkboxSide / 1.8, weight: .regular) }
    /// Extra width of each indentation space of a nested list item, so nesting reads clearly in a proportional font.
    var indentationKern: CGFloat { (baseFont.pointSize * 0.3).rounded() }
}

extension NSAttributedString.Key {
    /// The character's glyph is not laid out (a marker away from the line being edited).
    static let markdownHidden = NSAttributedString.Key("suijin.markdown.hidden")
    /// The character is drawn as a list dot.
    static let markdownBullet = NSAttributedString.Key("suijin.markdown.bullet")
    /// The characters are a task box drawn as a checkbox; the value is whether it is checked.
    static let markdownCheckbox = NSAttributedString.Key("suijin.markdown.checkbox")
    /// The characters are a thematic break drawn as a rule.
    static let markdownRule = NSAttributedString.Key("suijin.markdown.rule")
    /// The lines belong to a block drawn on a background; the value is its color.
    static let markdownBlock = NSAttributedString.Key("suijin.markdown.block")
    /// The lines belong to a block quote; the value is its depth.
    static let markdownQuoteDepth = NSAttributedString.Key("suijin.markdown.quote")
    /// The text is a link; the value is its destination.
    static let markdownLink = NSAttributedString.Key("suijin.markdown.link")

    /// Every attribute the editor sets. Restyling replaces these and leaves any other attribute (the input method's
    /// marked-text underline, spelling marks) alone.
    static let markdownOwned: [NSAttributedString.Key] = [
        .font, .foregroundColor, .paragraphStyle, .backgroundColor, .strikethroughStyle, .kern,
        .markdownHidden, .markdownBullet, .markdownCheckbox, .markdownRule, .markdownBlock, .markdownQuoteDepth, .markdownLink,
    ]
}
