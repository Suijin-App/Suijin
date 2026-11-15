import Foundation
import SuijinTerminal

/// The text size of one terminal: ⌘+ and ⌘- make the text of the terminal with the keyboard one point larger or
/// smaller, ⌘0 puts it back, and every other terminal stays as it is.
///
/// Each session keeps an offset in points from the size set in Settings › Terminal, not a size of its own, so
/// changing that setting moves every terminal and a zoomed one stays that much larger than the rest. The offset
/// belongs to the session: it follows it between tabs and panes and is stored in user defaults until the session is
/// closed.
extension AppModel {
    private static let terminalFontOffsetsKey = "terminal.fontSizeOffsets"

    /// The saved offsets of every session, from user defaults.
    static func savedTerminalFontOffsets() -> [UUID: Int] {
        guard let saved = UserDefaults.standard.dictionary(forKey: terminalFontOffsetsKey) as? [String: Int] else { return [:] }
        var offsets: [UUID: Int] = [:]
        for (key, offset) in saved {
            if let id = UUID(uuidString: key), offset != 0 { offsets[id] = offset }
        }
        return offsets
    }

    /// The text size set in Settings › Terminal, in points.
    var terminalBaseFontSize: Double {
        setting(.terminalFontSize).flatMap(Double.init) ?? Double(TerminalTheme.defaultFontSize)
    }

    /// The text size of a session's terminal: the size in Settings plus the session's offset, within the limits every
    /// terminal font has.
    func terminalFontSize(of session: UUID) -> Double {
        Self.clampedFontSize(terminalBaseFontSize + Double(terminalFontOffsets[session] ?? 0))
    }

    /// Makes a session's terminal text `step` points larger (smaller when negative). At a limit nothing changes, and
    /// the offset never grows past it, so the next step the other way shows at once.
    func adjustTerminalFontSize(of session: UUID, by step: Int) {
        let size = Self.clampedFontSize(terminalFontSize(of: session) + Double(step))
        setTerminalFontOffset(Int((size - terminalBaseFontSize).rounded()), of: session)
    }

    /// Puts a session's terminal text back at the size set in Settings.
    func resetTerminalFontSize(of session: UUID) {
        setTerminalFontOffset(0, of: session)
    }

    /// Sessions that were closed keep no offset.
    func forgetTerminalFontOffsets(of closed: Set<UUID>) {
        let kept = terminalFontOffsets.filter { !closed.contains($0.key) }
        guard kept.count != terminalFontOffsets.count else { return }
        terminalFontOffsets = kept
        saveTerminalFontOffsets()
    }

    private func setTerminalFontOffset(_ offset: Int, of session: UUID) {
        guard (terminalFontOffsets[session] ?? 0) != offset else { return }
        terminalFontOffsets[session] = offset == 0 ? nil : offset
        saveTerminalFontOffsets()
    }

    private func saveTerminalFontOffsets() {
        var saved: [String: Int] = [:]
        for (session, offset) in terminalFontOffsets where offset != 0 { saved[session.uuidString] = offset }
        UserDefaults.standard.set(saved, forKey: Self.terminalFontOffsetsKey)
    }

    private static func clampedFontSize(_ size: Double) -> Double {
        min(max(size, Double(TerminalTheme.minimumFontSize)), Double(TerminalTheme.maximumFontSize))
    }
}
