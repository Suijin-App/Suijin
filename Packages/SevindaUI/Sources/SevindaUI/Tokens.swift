import AppKit
import SwiftUI

/// Sevinda design tokens, copied from CapstioUI with a Sevinda brand color;
/// each color has a light/dark pair and follows the system appearance automatically.
public enum SevindaColor {
    /// Sevinda brand: a quicksilver teal, darker in light mode for contrast on white.
    public static let brand = dynamic(light: 0x0B7A84, dark: 0x3CC4CC)
    public static let accent = Color.accentColor

    public static let ok = dynamic(light: 0x30D158, dark: 0x30D158)
    public static let warning = dynamic(light: 0xFF9F0A, dark: 0xFF9F0A)
    public static let error = dynamic(light: 0xFF453A, dark: 0xFF453A)
    public static let idle = dynamic(light: 0xAEAEB2, dark: 0x8E8E93)
    public static let agent = dynamic(light: 0xBF5AF2, dark: 0xBF5AF2)

    public static let card = dynamic(light: 0xF6F6F8, dark: 0x2C2C30)
    public static let codeBackground = dynamic(light: 0xFAFAFB, dark: 0x1C1C1F)
    public static let hairline = dynamic(light: 0xDCDCE0, dark: 0x3A3A3E)
    public static let terminalBackground = dynamic(light: 0x1E1F24, dark: 0x141518)
    public static let terminalText = dynamic(light: 0xD8DEE9, dark: 0xD8DEE9)

    /// Bolder text color on the light background of tags/risk, to reach contrast in light mode.
    public static let okText = dynamic(light: 0x1F7A3A, dark: 0x5BE584)
    public static let warningText = dynamic(light: 0x9A5B00, dark: 0xFFB340)
    public static let errorText = dynamic(light: 0xB3001B, dark: 0xFF6961)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

public enum SevindaSpacing {
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
}

public enum SevindaRadius {
    public static let control: CGFloat = 7
    public static let card: CGFloat = 10
    public static let sheet: CGFloat = 12
}

public enum SevindaFont {
    public static let mono = Font.system(.body, design: .monospaced)
    public static let monoSmall = Font.system(.caption, design: .monospaced)
    public static let statValue = Font.system(size: 24, weight: .semibold).monospacedDigit()
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
