import SwiftUI

/// A keyboard shortcut drawn as a key cap, in the welcome tour and the Shortcuts settings. Custom because SwiftUI has
/// no view for showing a shortcut outside a menu.
struct KeyCap: View {
    let shortcut: String

    var body: some View {
        Text(verbatim: shortcut)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .frame(minWidth: 26)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
            }
            .accessibilityLabel(Text(verbatim: ShortcutSpeech.label(for: shortcut)))
    }
}

/// Spoken names of the symbols in a shortcut, so VoiceOver reads "Shift Command O" instead of the glyphs.
enum ShortcutSpeech {
    static func label(for shortcut: String) -> String {
        let names: [Character: String] = [
            "⌘": String(localized: "Command"), "⇧": String(localized: "Shift"), "⌥": String(localized: "Option"),
            "⌃": String(localized: "Control"), "↩": String(localized: "Return"), "←": String(localized: "Left Arrow"),
            "→": String(localized: "Right Arrow"), "↑": String(localized: "Up Arrow"), "↓": String(localized: "Down Arrow"),
            ",": String(localized: "Comma"), "=": String(localized: "Equals"), "-": String(localized: "Minus"),
            "[": String(localized: "Left Bracket"), "]": String(localized: "Right Bracket"),
            "/": String(localized: "Slash"),
        ]
        // Keys written as a word ("Esc", "Space") end the shortcut and are read as one name.
        let words = ["Esc": String(localized: "Escape"), "Space": String(localized: "Space")]
        if let word = words.first(where: { shortcut.hasSuffix($0.key) }) {
            let modifiers = label(for: String(shortcut.dropLast(word.key.count)))
            return modifiers.isEmpty ? word.value : modifiers + " " + word.value
        }
        return shortcut.map { names[$0] ?? String($0) }.joined(separator: " ")
    }
}
