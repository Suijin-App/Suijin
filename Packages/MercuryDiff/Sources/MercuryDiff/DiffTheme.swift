import AppKit
import MercuryUI
import SwiftUI

/// AppKit colors and fonts for the diff viewer, derived from MercuryUI tokens. Every color is dynamic
/// and resolves against the drawing appearance, so light/dark switches need no reload.
enum DiffTheme {
    /// AppKit counterpart of `MercuryFont.mono` (SwiftUI `.body` monospaced, 13 pt on macOS).
    @MainActor static let font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                                                  weight: .regular)
    /// Fixed row line height; a little taller than the font's natural height for readability.
    @MainActor static let lineHeight = ceil(naturalLineHeight * 1.3)
    /// Raises glyphs to the middle of the fixed line height (TextKit puts the extra space above them).
    @MainActor static let baselineOffset = (lineHeight - naturalLineHeight) / 2
    @MainActor private static let naturalLineHeight = ceil(font.ascender - font.descender + font.leading)
    @MainActor static let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize - 1, weight: .regular)

    static let background = NSColor(MercuryColor.codeBackground)
    static let text = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let gutterText = NSColor.tertiaryLabelColor
    static let separator = NSColor(MercuryColor.hairline)

    static let addedBackground = tinted(NSColor(MercuryColor.ok), light: 0.14, dark: 0.16)
    static let deletedBackground = tinted(NSColor(MercuryColor.error), light: 0.12, dark: 0.16)
    static let addedGutterBackground = tinted(NSColor(MercuryColor.ok), light: 0.24, dark: 0.26)
    static let deletedGutterBackground = tinted(NSColor(MercuryColor.error), light: 0.20, dark: 0.26)
    static let hunkBackground = tinted(NSColor(MercuryColor.brand), light: 0.08, dark: 0.12)
    /// Word-level marks inside a modified line, on top of the row background.
    static let addedWordBackground = tinted(NSColor(MercuryColor.ok), light: 0.30, dark: 0.34)
    static let deletedWordBackground = tinted(NSColor(MercuryColor.error), light: 0.26, dark: 0.34)
    /// Filler rows of a side-by-side column, opposite a line that only exists on the other side.
    static let paddingBackground = tinted(NSColor.secondaryLabelColor, light: 0.06, dark: 0.08)
    /// Lines chosen for a note while dragging in the gutter or writing the note.
    static let noteSelection = tinted(NSColor.controlAccentColor, light: 0.16, dark: 0.24)
    static let addedSign = NSColor(MercuryColor.okText)
    static let deletedSign = NSColor(MercuryColor.errorText)

    static func rowBackground(_ kind: DiffLayout.RowKind) -> NSColor? {
        switch kind {
        case .added: addedBackground
        case .deleted: deletedBackground
        case .hunkHeader: hunkBackground
        case .padding: paddingBackground
        case .context, .noNewlineMarker: nil
        }
    }

    static func gutterBackground(_ kind: DiffLayout.RowKind) -> NSColor? {
        switch kind {
        case .added: addedGutterBackground
        case .deleted: deletedGutterBackground
        case .hunkHeader: hunkBackground
        case .padding: paddingBackground
        case .context, .noNewlineMarker: nil
        }
    }

    /// Token colors use system colors, which already carry tuned light and dark variants.
    static func color(for token: TokenKind) -> NSColor {
        switch token {
        case .keyword: .systemPink
        case .string: .systemRed
        case .comment: .secondaryLabelColor
        case .number, .constant: .systemPurple
        case .type: .systemTeal
        case .function: .systemIndigo
        case .property: .systemBlue
        case .attribute: .systemOrange
        case .operator: .labelColor
        case .heading: .systemBlue
        case .link: .linkColor
        }
    }

    /// `base` at a per-appearance opacity, resolved at draw time (AppKit may resolve it on any thread).
    private static func tinted(_ base: NSColor, light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            var resolved = base
            appearance.performAsCurrentDrawingAppearance {
                resolved = base.usingColorSpace(.sRGB) ?? base
            }
            return resolved.withAlphaComponent(isDark ? dark : light)
        }
    }
}

public extension TokenKind {
    /// The color the diff view paints this token in, for other views that show highlighted code (the file viewer).
    var color: NSColor { DiffTheme.color(for: self) }
}
