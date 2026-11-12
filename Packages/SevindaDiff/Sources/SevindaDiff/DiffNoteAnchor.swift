import Foundation
import SevindaGit

/// Where a note points: a new-side line, an inclusive range ending at `lineNumber`, or the whole file (0).
public struct DiffNoteAnchor: Hashable, Sendable {
    public var startLine: Int?
    public var lineNumber: Int

    public init(startLine: Int? = nil, lineNumber: Int) {
        self.startLine = startLine == lineNumber ? nil : startLine
        self.lineNumber = lineNumber
    }

    /// The anchor of a range dragged from `anchor` to `focus`, in either direction.
    public init(from anchor: Int, to focus: Int) {
        self.init(startLine: min(anchor, focus), lineNumber: max(anchor, focus))
    }

    public static let file = DiffNoteAnchor(lineNumber: 0)

    public var isFile: Bool { lineNumber == 0 }
    public var lines: ClosedRange<Int> { (startLine ?? lineNumber)...lineNumber }

    /// "line 4", "lines 3–7" or "file", for note headers.
    public var label: String {
        if isFile { return String(localized: "file", bundle: .module, comment: "Location of a note on a whole file") }
        if let startLine {
            return String(localized: "lines \(startLine)–\(lineNumber)", bundle: .module,
                          comment: "Location of a note on a range of lines")
        }
        return String(localized: "line \(lineNumber)", bundle: .module, comment: "Location of a note on one line")
    }
}

/// A saved note as the diff view shows it.
public struct DiffNoteItem: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var anchor: DiffNoteAnchor
    public var body: String
    public var isSent: Bool
    /// The noted lines changed since the note was written.
    public var isStale: Bool

    public init(id: UUID, anchor: DiffNoteAnchor, body: String, isSent: Bool, isStale: Bool) {
        self.id = id
        self.anchor = anchor
        self.body = body
        self.isSent = isSent
        self.isStale = isStale
    }
}

/// What the diff view calls when the user creates, edits or deletes a note. The owner persists the change and
/// passes the updated notes back.
public struct DiffNoteActions {
    public var create: @MainActor (DiffNoteAnchor, String) -> Void
    public var update: @MainActor (UUID, String) -> Void
    public var delete: @MainActor (UUID) -> Void

    public init(create: @escaping @MainActor (DiffNoteAnchor, String) -> Void,
                update: @escaping @MainActor (UUID, String) -> Void,
                delete: @escaping @MainActor (UUID) -> Void) {
        self.create = create
        self.update = update
        self.delete = delete
    }
}

/// Notes and their handlers for one file's diff.
public struct DiffNotesConfiguration {
    public var notes: [DiffNoteItem]
    public var actions: DiffNoteActions

    public init(notes: [DiffNoteItem], actions: DiffNoteActions) {
        self.notes = notes
        self.actions = actions
    }
}

/// Which lines of a diff notes can point to, and whether a saved note still matches them.
public enum DiffNoteAnchoring {
    /// The new-side lines the diff shows (context and added), by line number.
    public static func newSideLines(of diff: FileDiff) -> [Int: String] {
        var lines: [Int: String] = [:]
        for hunk in diff.hunks {
            for line in hunk.lines where line.kind == .context || line.kind == .added {
                if let number = line.newLine { lines[number] = line.text }
            }
        }
        return lines
    }

    /// New-side lines a note can be shown under in `mode`; notes on other lines (or on the file) belong next to the
    /// diff instead. That is every shown new-side line except an empty last row, which has no character to carry the
    /// space a note needs.
    public static func placeableLines(of diff: FileDiff, mode: DiffDisplayMode) -> Set<Int> {
        switch mode {
        case .unified:
            guard !diff.isBinary else { return [] }
            var lines: [DiffLayout.Line] = []
            for hunk in diff.hunks {
                lines.append(DiffLayout.Line(kind: .hunkHeader, text: hunk.header))
                for line in hunk.lines {
                    lines.append(DiffLayout.Line(kind: .context, text: line.text, newLine: line.newLine))
                }
            }
            return placeableLines(in: lines)
        case .sideBySide:
            return placeableLines(in: SideBySideLayout.alignedRows(of: diff).map(\.right))
        }
    }

    static func placeableLines(in lines: [DiffLayout.Line]) -> Set<Int> {
        var result = Set<Int>()
        for (index, line) in lines.enumerated() {
            guard let number = line.newLine else { continue }
            if index == lines.count - 1, line.text.isEmpty { continue }
            result.insert(number)
        }
        return result
    }

    /// A fingerprint of the noted lines' text (64-bit FNV-1a, hex); nil for a file note or when a line is not shown.
    public static func identity(of anchor: DiffNoteAnchor, in lines: [Int: String]) -> String? {
        guard !anchor.isFile else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for number in anchor.lines {
            guard let text = lines[number] else { return nil }
            for byte in text.utf8 + [0x0A] {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
        }
        return String(hash, radix: 16)
    }

    /// True when a note written with `identity` no longer matches the lines it points to. A file note, or a note
    /// without a recorded identity, is never stale.
    public static func isStale(_ anchor: DiffNoteAnchor, identity: String?, in lines: [Int: String]) -> Bool {
        guard let identity, !anchor.isFile else { return false }
        return self.identity(of: anchor, in: lines) != identity
    }

    /// The furthest line from `anchor` towards `focus` reachable without crossing a line that cannot be noted, so a
    /// drag stops at the edge of a hunk instead of jumping over the gap (Orca's `clampFocusLineToCommentable`).
    public static func clampFocus(anchor: Int, focus: Int, commentable: Set<Int>) -> Int {
        guard focus != anchor else { return focus }
        let step = focus > anchor ? 1 : -1
        var reachable = anchor
        var line = anchor + step
        while step > 0 ? line <= focus : line >= focus {
            guard commentable.contains(line) else { break }
            reachable = line
            line += step
        }
        return reachable
    }
}
