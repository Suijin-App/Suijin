import AppKit
import SwiftTerm
import SwiftUI

/// An sRGB color of a terminal theme.
public struct TerminalRGB: Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(_ hex: UInt32) {
        red = UInt8((hex >> 16) & 0xFF)
        green = UInt8((hex >> 8) & 0xFF)
        blue = UInt8(hex & 0xFF)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    public var color: SwiftUI.Color { SwiftUI.Color(nsColor: nsColor) }

    /// SwiftTerm's palette entries use 16-bit channels.
    public var terminalColor: SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(red) * 257, green: UInt16(green) * 257, blue: UInt16(blue) * 257)
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio between two colors (1…21).
    public static func contrast(_ first: TerminalRGB, _ second: TerminalRGB) -> Double {
        let (lighter, darker) = first.luminance >= second.luminance ? (first.luminance, second.luminance) : (second.luminance, first.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// A terminal color theme: default colors, cursor, selection and the 16 ANSI colors (normal then bright).
///
/// SwiftTerm has no separate bold color: bold text uses the bold font, and bold ANSI colors use the
/// bright half of the palette, so themes carry no bold entry.
public struct TerminalTheme: Identifiable, Hashable, Sendable {
    public enum Appearance: Sendable { case light, dark }

    public let id: String
    /// Proper names of the palettes; shown as they are in every language.
    public let name: String
    public let appearance: Appearance
    public let background: TerminalRGB
    public let foreground: TerminalRGB
    public let cursor: TerminalRGB
    public let selection: TerminalRGB
    public let ansi: [TerminalRGB]

    public init(id: String, name: String, appearance: Appearance, background: UInt32, foreground: UInt32, cursor: UInt32,
         selection: UInt32, ansi: [UInt32]) {
        precondition(ansi.count == 16, "a terminal theme has 16 ANSI colors")
        self.id = id
        self.name = name
        self.appearance = appearance
        self.background = TerminalRGB(background)
        self.foreground = TerminalRGB(foreground)
        self.cursor = TerminalRGB(cursor)
        self.selection = TerminalRGB(selection)
        self.ansi = ansi.map(TerminalRGB.init)
    }

    public var isDark: Bool { appearance == .dark }

    // MARK: Font

    public static let defaultFontSize: CGFloat = 13
    public static let minimumFontSize: CGFloat = 9
    public static let maximumFontSize: CGFloat = 32

    /// SF Mono, the system monospaced font.
    public static func font(size: Double) -> NSFont {
        font(family: nil, size: size)
    }

    /// The terminal font: `family` when it is installed, else the preferred default family, else the system monospaced
    /// font.
    public static func font(family: String?, size: Double) -> NSFont {
        let clamped = min(max(CGFloat(size), minimumFontSize), maximumFontSize)
        let points = clamped.isFinite ? clamped : defaultFontSize
        if let name = family ?? defaultFamily, let font = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: points) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: points, weight: .regular)
    }

    /// Monospaced families installed on this Mac, for the font picker.
    public static func monospacedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12)?.isFixedPitch == true
        }
    }

    /// A "Nerd Font Mono" family when one is installed: shell prompts that draw Nerd Font icons (powerlevel10k,
    /// starship) then render the way they do in the user's other terminals. `nil` means the system monospaced font.
    public static let defaultFamily: String? = NSFontManager.shared.availableFontFamilies
        .filter { $0.hasSuffix("Nerd Font Mono") }
        .sorted()
        .first

    // MARK: Applying

    /// Installs the colors on an existing terminal view; the screen and scrollback are kept and redrawn.
    @MainActor
    public func apply(to view: TerminalView) {
        // The scroller and the find bar follow the theme, not the window, so they read on its background.
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        view.nativeBackgroundColor = background.nsColor
        view.nativeForegroundColor = foreground.nsColor
        view.caretColor = cursor.nsColor
        view.caretTextColor = background.nsColor
        view.selectedTextBackgroundColor = selection.nsColor
        // SwiftTerm paints its layer only when it lays out; keep it in step with the new background.
        view.layer?.backgroundColor = background.nsColor.cgColor
        // Last: resets SwiftTerm's color caches and redraws the whole screen with the new defaults.
        view.installColors(ansi.map(\.terminalColor))
    }
}

/// The built-in themes. Sevinda Light and Sevinda Dark are the defaults for each appearance. The other palettes are
/// well-known schemes whose licenses allow redistributing the colors; each entry names its source and license.
public enum TerminalThemes {
    public static let sevindaLight = TerminalTheme(
        id: "sevinda-light", name: "Sevinda Light", appearance: .light,
        // System-like hues darkened to read on a near-white background.
        background: 0xFAFAFB, foreground: 0x1D1D1F, cursor: 0x007AFF, selection: 0xB3D7FF,
        ansi: [0x1D1D1F, 0xC4262E, 0x1F7A3A, 0x9A5B00, 0x0B5CD5, 0x9B2393, 0x0E7C86, 0x6E6E73,
               0x6E6E73, 0xB3001B, 0x248A3D, 0xB25000, 0x0040DD, 0xAD3BA8, 0x0071A4, 0x8E8E93])

    public static let sevindaDark = TerminalTheme(
        id: "sevinda-dark", name: "Sevinda Dark", appearance: .dark,
        background: 0x1C1C1F, foreground: 0xD8DEE9, cursor: 0x0A84FF, selection: 0x3F638B,
        ansi: [0x3B4252, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xD8DEE9,
               0x5C6370, 0xFF7A85, 0xB5E08F, 0xFFD88A, 0x82C4FF, 0xDD95F0, 0x7FD6E0, 0xFFFFFF])

    /// Solarized, Ethan Schoonover (MIT). Light uses base01 for text (Solarized's emphasized tone) so body
    /// text reaches 4.5:1; the standard terminal mapping puts the base tones on the bright colors.
    public static let solarizedLight = TerminalTheme(
        id: "solarized-light", name: "Solarized Light", appearance: .light,
        background: 0xFDF6E3, foreground: 0x586E75, cursor: 0x586E75, selection: 0xEEE8D5,
        ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
               0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3])

    public static let solarizedDark = TerminalTheme(
        id: "solarized-dark", name: "Solarized Dark", appearance: .dark,
        background: 0x002B36, foreground: 0x839496, cursor: 0x93A1A1, selection: 0x073642,
        ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
               0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3])

    /// GitHub Light and Dark default, from Primer primitives / github-vscode-theme (MIT).
    public static let githubLight = TerminalTheme(
        id: "github-light", name: "GitHub Light", appearance: .light,
        background: 0xFFFFFF, foreground: 0x1F2328, cursor: 0x0969DA, selection: 0xB6E3FF,
        ansi: [0x24292F, 0xCF222E, 0x116329, 0x4D2D00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
               0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F])

    public static let githubDark = TerminalTheme(
        id: "github-dark", name: "GitHub Dark", appearance: .dark,
        background: 0x0D1117, foreground: 0xE6EDF3, cursor: 0x2F81F7, selection: 0x264F78,
        ansi: [0x484F58, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
               0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xFFFFFF])

    /// One Light and One Dark, from Atom's one-light-syntax / one-dark-syntax palettes (MIT).
    public static let oneLight = TerminalTheme(
        id: "one-light", name: "One Light", appearance: .light,
        background: 0xFAFAFA, foreground: 0x383A42, cursor: 0x526FFF, selection: 0xE5E5E6,
        ansi: [0x383A42, 0xE45649, 0x50A14F, 0xC18401, 0x4078F2, 0xA626A4, 0x0184BC, 0xA0A1A7,
               0x696C77, 0xCA1243, 0x50A14F, 0x986801, 0x4078F2, 0xA626A4, 0x0184BC, 0xFAFAFA])

    public static let oneDark = TerminalTheme(
        id: "one-dark", name: "One Dark", appearance: .dark,
        background: 0x282C34, foreground: 0xABB2BF, cursor: 0x528BFF, selection: 0x3E4451,
        ansi: [0x3E4451, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
               0x5C6370, 0xBE5046, 0x98C379, 0xD19A66, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF])

    /// Tomorrow and Tomorrow Night, Chris Kempson's tomorrow-theme (MIT); Night's bright colors come from
    /// its Tomorrow Night Bright variant.
    public static let tomorrow = TerminalTheme(
        id: "tomorrow", name: "Tomorrow", appearance: .light,
        background: 0xFFFFFF, foreground: 0x4D4D4C, cursor: 0x4D4D4C, selection: 0xD6D6D6,
        ansi: [0x4D4D4C, 0xC82829, 0x718C00, 0xEAB700, 0x4271AE, 0x8959A8, 0x3E999F, 0xD6D6D6,
               0x8E908C, 0xC82829, 0x718C00, 0xF5871F, 0x4271AE, 0x8959A8, 0x3E999F, 0xEFEFEF])

    public static let tomorrowNight = TerminalTheme(
        id: "tomorrow-night", name: "Tomorrow Night", appearance: .dark,
        background: 0x1D1F21, foreground: 0xC5C8C6, cursor: 0xC5C8C6, selection: 0x373B41,
        ansi: [0x373B41, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
               0x969896, 0xD54E53, 0xB9CA4A, 0xE7C547, 0x7AA6DA, 0xC397D8, 0x70C0B1, 0xEAEAEA])

    /// Gruvbox, Pavel Pertsev (MIT): the standard terminal mapping of the light and dark palettes.
    public static let gruvboxLight = TerminalTheme(
        id: "gruvbox-light", name: "Gruvbox Light", appearance: .light,
        background: 0xFBF1C7, foreground: 0x3C3836, cursor: 0x3C3836, selection: 0xEBDBB2,
        ansi: [0xFBF1C7, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0x7C6F64,
               0x928374, 0x9D0006, 0x79740E, 0xB57614, 0x076678, 0x8F3F71, 0x427B58, 0x3C3836])

    public static let gruvboxDark = TerminalTheme(
        id: "gruvbox-dark", name: "Gruvbox Dark", appearance: .dark,
        background: 0x282828, foreground: 0xEBDBB2, cursor: 0xEBDBB2, selection: 0x504945,
        ansi: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
               0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2])

    /// Nord, Arctic Ice Studio (MIT), as in nord-iterm2.
    public static let nord = TerminalTheme(
        id: "nord", name: "Nord", appearance: .dark,
        background: 0x2E3440, foreground: 0xD8DEE9, cursor: 0xD8DEE9, selection: 0x434C5E,
        ansi: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
               0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4])

    /// Dracula, Zeno Rocha and contributors (MIT), from the Dracula terminal specification.
    public static let dracula = TerminalTheme(
        id: "dracula", name: "Dracula", appearance: .dark,
        background: 0x282A36, foreground: 0xF8F8F2, cursor: 0xF8F8F2, selection: 0x44475A,
        ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
               0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF])

    /// Tokyo Night ("night" style), enkia / folke's tokyonight.nvim (MIT).
    public static let tokyoNight = TerminalTheme(
        id: "tokyo-night", name: "Tokyo Night", appearance: .dark,
        background: 0x1A1B26, foreground: 0xC0CAF5, cursor: 0xC0CAF5, selection: 0x33467C,
        ansi: [0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
               0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5])

    public static let all: [TerminalTheme] = [
        sevindaLight, solarizedLight, githubLight, oneLight, tomorrow, gruvboxLight,
        sevindaDark, solarizedDark, githubDark, oneDark, tomorrowNight, gruvboxDark, nord, dracula, tokyoNight,
    ]

    public static var light: [TerminalTheme] { all.filter { $0.appearance == .light } }
    public static var dark: [TerminalTheme] { all.filter { $0.appearance == .dark } }

    public static func theme(id: String) -> TerminalTheme? { all.first { $0.id == id } }

    /// The theme with `id`; an unknown identifier falls back to Sevinda's default for the appearance.
    public static func resolve(id: String?, isDark: Bool) -> TerminalTheme {
        id.flatMap(theme(id:)) ?? (isDark ? sevindaDark : sevindaLight)
    }

    /// Whether the app currently shows the dark appearance, for terminals created outside a view update.
    @MainActor
    public static var appIsDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
