import Foundation

/// What the user chose for text held back by the paste guard.
public enum TerminalInsertAction: Equatable, Sendable {
    /// Send it and press Enter.
    case run
    /// Put it on the command line without running it.
    case pasteOnly
}

/// When pasted text needs the user's confirmation.
public enum PasteGuardPolicy: Equatable, Sendable {
    /// Every paste of more than one command line.
    case always
    /// Multi-line pastes only while the program did not enable bracketed paste (with it, pasted line breaks run
    /// nothing; shells and agent TUIs such as Claude Code and Codex enable it).
    case unlessBracketedPaste
    /// Never; pastes go straight through.
    case never
}

/// Pasted text held back until the user decides.
public struct PasteReview: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let text: String
    /// Non-blank, non-comment lines, a `\`-continued line counting once.
    public let commandLineCount: Int
    /// `false` when the program cannot take several lines without running them (no bracketed paste), so the only
    /// choices are Run and Cancel.
    public let canPasteWithoutRunning: Bool
}

/// Decides whether pasted text may go straight to the program and turns the user's decision into the bytes to send.
public enum PasteGuard {
    public static let bracketedPasteStart: [UInt8] = Array("\u{1B}[200~".utf8)
    public static let bracketedPasteEnd: [UInt8] = Array("\u{1B}[201~".utf8)

    /// `nil` when the paste can be sent as is.
    public static func review(_ text: String, bracketedPaste: Bool, policy: PasteGuardPolicy = .always) -> PasteReview? {
        switch policy {
        case .never: return nil
        case .unlessBracketedPaste where bracketedPaste: return nil
        case .always, .unlessBracketedPaste: break
        }
        let count = commandLines(text).count
        guard count > 1 else { return nil }
        return PasteReview(text: text, commandLineCount: count,
                           canPasteWithoutRunning: bracketedPaste || !body(of: text).contains("\r"))
    }

    /// Bytes of a paste that needed no review, as a terminal pastes: wrapped in bracketed-paste markers when the
    /// program asked for them, line breaks sent as carriage returns.
    public static func plainPasteBytes(_ text: String, bracketedPaste: Bool) -> [UInt8] {
        let content = Array(normalizeLineBreaks(text).utf8)
        return bracketedPaste ? bracketedPasteStart + content + bracketedPasteEnd : content
    }

    /// Bytes for a decision; `nil` when the text cannot be pasted without running (several lines and no bracketed
    /// paste).
    public static func bytes(for text: String, action: TerminalInsertAction, bracketedPaste: Bool) -> [UInt8]? {
        let content = Array(body(of: text).utf8)
        switch action {
        case .run:
            let enter = Array("\r".utf8)
            return bracketedPaste ? bracketedPasteStart + content + bracketedPasteEnd + enter : content + enter
        case .pasteOnly:
            if bracketedPaste { return bracketedPasteStart + content + bracketedPasteEnd }
            return content.contains(UInt8(ascii: "\r")) ? nil : content
        }
    }

    /// Text without trailing line breaks, every line break as `\r` (what the Return key sends).
    public static func body(of text: String) -> String {
        var normalized = normalizeLineBreaks(text)
        while normalized.last == "\r" { normalized.removeLast() }
        return normalized
    }

    /// Non-blank, non-comment lines, with `\` continuations joined to the line they continue.
    static func commandLines(_ text: String) -> [String] {
        var result: [String] = []
        var continuing = false
        for raw in normalizeLineBreaks(text).split(separator: "\r", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            defer { continuing = trimmed.hasSuffix("\\") }
            if continuing || trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func normalizeLineBreaks(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
    }
}
