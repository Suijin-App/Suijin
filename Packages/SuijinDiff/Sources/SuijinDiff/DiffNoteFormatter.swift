import Foundation

/// What a note needs to be handed to an agent. SuijinCore's `DiffNote` conforms in the app.
public protocol DiffNoteFormattable {
    var filePath: String { get }
    /// Inclusive start of a line range; nil (or equal to `lineNumber`) for a single line.
    var startLine: Int? { get }
    /// The (last) noted line; 0 means the whole file.
    var lineNumber: Int { get }
    var body: String { get }
}

/// The text pasted into an agent's prompt for review notes. Fixed and quote-safe, so every agent reads the same
/// shape (ported from Orca's `diff-comments-format.ts`):
///
/// ```
/// File: <path>
/// Line: <n>            (or "Lines: <a>-<b>", or "Scope: file")
/// User comment: "<body with \ " CR LF escaped>"
/// ```
///
/// Several notes are separated by one empty line.
public enum DiffNoteFormatter {
    public static func format(_ note: some DiffNoteFormattable) -> String {
        // Backslashes first, so the escapes added afterwards are not escaped again. Foundation replaces UTF-16
        // units, so a CRLF pair becomes `\r\n` exactly as in the original.
        let escaped = note.body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        let location: String
        if note.lineNumber == 0 {
            location = "Scope: file"
        } else if let start = note.startLine, start != note.lineNumber {
            location = "Lines: \(start)-\(note.lineNumber)"
        } else {
            location = "Line: \(note.lineNumber)"
        }
        return ["File: \(note.filePath)", location, "User comment: \"\(escaped)\""].joined(separator: "\n")
    }

    public static func format(_ notes: [some DiffNoteFormattable]) -> String {
        notes.map { format($0) }.joined(separator: "\n\n")
    }
}
