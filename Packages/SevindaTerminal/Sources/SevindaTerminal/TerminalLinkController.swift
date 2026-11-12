import AppKit
import os
import SwiftTerm

/// A file a printed path names, as the host confirmed it on disk.
public struct TerminalFileTarget: Sendable, Hashable {
    /// Absolute, standardized.
    public var path: String
    public var isDirectory: Bool
    public var line: Int?
    public var column: Int?

    public init(path: String, isDirectory: Bool, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.isDirectory = isDirectory
        self.line = line
        self.column = column
    }
}

/// A path or web link on the terminal's screen that can be opened.
public struct TerminalLink: Sendable, Hashable {
    public enum Target: Sendable, Hashable {
        case file(TerminalFileTarget)
        case web(URL)
    }

    /// The match, its segments in buffer rows (counted from the top of the scrollback).
    public var match: TerminalPathMatch
    public var target: Target

    public init(match: TerminalPathMatch, target: Target) {
        self.match = match
        self.target = target
    }
}

/// What opens a link with the mouse.
public enum TerminalLinkTrigger: String, Sendable, CaseIterable {
    /// ⌘-click opens; a plain click keeps the terminal's behavior (selection, clicks sent to the program).
    case commandClick
    /// A plain single click opens too, unless the program reads the mouse or the click selects text.
    case click
}

/// When to look for links after output: once the screen has been quiet for `quietPeriod`, and, while output only
/// trickles in (an agent's spinner or status line), at most `maximumDelay` after the first change. A flood (more than
/// `trickleLimit` bytes since the last scan) is never interrupted by a scan.
struct TerminalLinkScanTiming: Sendable, Equatable {
    var quietPeriod: TimeInterval = 0.12
    var maximumDelay: TimeInterval = 0.75
    var trickleLimit = 16 * 1024

    private(set) var firstChange: TimeInterval?
    private(set) var lastChange: TimeInterval = 0
    private(set) var bytes = 0

    mutating func noteChange(at time: TimeInterval, bytes count: Int = 0) {
        if firstChange == nil { firstChange = time }
        lastChange = max(lastChange, time)
        bytes += count
    }

    /// When the next scan is due, or nil when nothing changed since the last one.
    var dueTime: TimeInterval? {
        guard let firstChange else { return nil }
        let quiet = lastChange + quietPeriod
        return bytes <= trickleLimit ? min(quiet, firstChange + maximumDelay) : quiet
    }

    mutating func scanned() {
        firstChange = nil
        lastChange = 0
        bytes = 0
    }
}

/// Finds paths and links on a terminal's screen and keeps the overlay that underlines them in step with the text.
///
/// - Scans read only the rows on screen (plus the rows a wrapped line continues into), on the main thread, after the
///   output pauses (`TerminalLinkScanTiming`); never while scrollback is replayed or while the view is off screen.
/// - Paths are confirmed by `resolve` (the host checks the disk off the main thread); web links need no check; links
///   the program marked itself (OSC 8) stay with SwiftTerm.
/// - A shown link is dropped as soon as the text under it changes, so an underline never sits under other text.
@MainActor
final class TerminalLinkController {
    private unowned let view: SevindaTerminalView
    let overlay: TerminalLinkOverlay

    /// Confirms paths, in order; nil entries do not exist. Nil turns detection off: nothing is scanned or drawn.
    var resolve: (@MainActor ([TerminalPathMatch]) async -> [TerminalFileTarget?])? {
        didSet {
            if resolve == nil {
                cancelScan()
                links = []
            } else {
                noteChange()
            }
        }
    }
    var trigger: TerminalLinkTrigger = .commandClick {
        didSet { updateHover() }
    }

    private(set) var links: [TerminalLink] = [] {
        didSet { if links != oldValue { layoutOverlay() } }
    }
    private(set) var hovered: TerminalLink?

    var timing = TerminalLinkScanTiming()
    private var scanTimer: DispatchWorkItem?
    private var scanTimerDue: TimeInterval?
    private var scanGeneration = 0
    /// The scrollback row at the top of the screen when the overlay was laid out.
    private var laidOutTop = 0
    private var validationQueued = false

    /// Scans done and the time the last one took on the main thread (tests and diagnostics).
    private(set) var scanCount = 0
    private(set) var lastScanDuration: Duration?
    /// How long finding the candidates of the last scan took, off the main thread.
    private(set) var lastDetectionDuration: Duration?
    private static let signposter = OSSignposter(subsystem: "com.tekmium.sevinda", category: "TerminalLinks")

    init(view: SevindaTerminalView) {
        self.view = view
        overlay = TerminalLinkOverlay(frame: view.bounds)
        overlay.onPointerCrossing = { [weak self] in self?.updateHover() }
        Self.register(self)
    }

    var isEnabled: Bool { resolve != nil }

    // MARK: Changes

    /// Output was fed, the view scrolled or resized, or it came back on screen: shown links are checked against the
    /// text at once (coalesced to one pass per turn of the run loop) and a scan is scheduled.
    func noteChange(bytes: Int = 0) {
        guard isEnabled else { return }
        timing.noteChange(at: ProcessInfo.processInfo.systemUptime, bytes: bytes)
        armScanTimer()
        guard !links.isEmpty, !validationQueued else { return }
        validationQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.validationQueued = false
                self.validateLinks()
            }
        }
    }

    /// The grid was reflowed (a resize or a font change): every shown position is stale.
    func gridChanged() {
        guard isEnabled else { return }
        links = []
        noteChange()
    }

    private func armScanTimer() {
        guard let due = timing.dueTime else { return }
        if let scanTimerDue, scanTimerDue <= due, scanTimer != nil { return }
        scanTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.scanTimerFired() }
        }
        scanTimer = item
        scanTimerDue = due
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due - ProcessInfo.processInfo.systemUptime), execute: item)
    }

    private func scanTimerFired() {
        scanTimer = nil
        scanTimerDue = nil
        guard let due = timing.dueTime else { return }
        if ProcessInfo.processInfo.systemUptime + 0.001 < due {
            armScanTimer()
            return
        }
        timing.scanned()
        scanNow()
    }

    private func cancelScan() {
        scanTimer?.cancel()
        scanTimer = nil
        scanTimerDue = nil
        timing.scanned()
        scanGeneration += 1
    }

    // MARK: Scanning

    /// Whether the screen can be scanned now: on screen, shown, not replaying scrollback.
    var canScan: Bool {
        isEnabled && view.window != nil && !view.isHiddenOrHasHiddenAncestor && !view.isReplayingScrollback
    }

    /// Reads the screen on the main thread (the only part that must run there), finds candidates off it and has the
    /// paths confirmed; the overlay updates when the answer comes, keeping only links whose text is still on screen.
    func scanNow() {
        guard canScan, let resolve else { return }
        let state = Self.signposter.beginInterval("scan")
        let started = ContinuousClock.now
        let snapshot = view.screenRows()
        lastScanDuration = ContinuousClock.now - started
        scanCount += 1
        Self.signposter.endInterval("scan", state)

        scanGeneration += 1
        let generation = scanGeneration
        Task { @MainActor [weak self] in
            let (candidates, detection) = await Task.detached(priority: .userInitiated) {
                let started = ContinuousClock.now
                let found = TerminalPathDetector.matches(in: snapshot.rows)
                    .filter { !$0.touchesExplicitLink && $0.kind != .elided }
                    .map { snapshot.absolute($0) }
                return (found, ContinuousClock.now - started)
            }.value
            guard let self, generation == self.scanGeneration, self.isEnabled else { return }
            self.lastDetectionDuration = detection
            let paths = candidates.filter { $0.kind == .path }
            var found: [TerminalLink] = candidates.compactMap { match in
                guard match.kind == .url, let url = URL(string: match.text), url.host != nil else { return nil }
                return TerminalLink(match: match, target: .web(url))
            }
            let targets = paths.isEmpty ? [] : await resolve(paths)
            guard generation == self.scanGeneration, self.isEnabled else { return }
            for (match, target) in zip(paths, targets) {
                if let target { found.append(TerminalLink(match: match, target: .file(target))) }
            }
            let kept = Set(TerminalPathDetector.preferred(found.map(\.match)))
            self.links = found.filter { kept.contains($0.match) && self.view.textMatches($0.match) }
                .sorted { ($0.match.segments.first?.row ?? 0, $0.match.segments.first?.columns.lowerBound ?? 0)
                    < ($1.match.segments.first?.row ?? 0, $1.match.segments.first?.columns.lowerBound ?? 0) }
        }
    }

    /// Drops links whose text changed and moves the overlay when the screen scrolled.
    func validateLinks() {
        let valid = links.filter { view.textMatches($0.match) }
        if valid != links {
            links = valid
        } else if view.getTerminal().buffer.yDisp != laidOutTop {
            layoutOverlay()
        }
    }

    // MARK: Overlay

    func layoutOverlay() {
        guard let geometry = view.cellGeometry() else {
            overlay.marks = []
            return
        }
        let terminal = view.getTerminal()
        let top = terminal.buffer.yDisp
        laidOutTop = top
        overlay.marks = links.map { link in
            var rects: [CGRect] = [], underlines: [CGRect] = [], strong: [CGRect] = []
            for segment in link.match.segments where (top..<(top + terminal.rows)).contains(segment.row) {
                let row = segment.row - top
                rects.append(geometry.rect(row: row, columns: segment.columns))
                underlines.append(geometry.underline(row: row, columns: segment.columns, thickness: 1))
                strong.append(geometry.underline(row: row, columns: segment.columns, thickness: 2))
            }
            return TerminalLinkOverlay.Mark(rects: rects, underlines: underlines, emphasizedUnderlines: strong,
                                            toolTip: Self.toolTip(for: link))
        }
        updateHover()
    }

    static func toolTip(for link: TerminalLink) -> String {
        switch link.target {
        case .web(let url):
            return url.absoluteString
        case .file(let file):
            guard let line = file.line else { return file.path }
            return file.column.map { "\(file.path):\(line):\($0)" } ?? "\(file.path):\(line)"
        }
    }

    // MARK: Pointer

    /// The link at a point of the view (view coordinates).
    func link(at point: CGPoint) -> TerminalLink? {
        guard let cell = view.bufferCell(at: point) else { return nil }
        return links.first { $0.match.contains(row: cell.row, column: cell.column) }
    }

    /// Whether a click opens a link now: ⌘ is held, or plain clicks open and the program does not read the mouse.
    var clickOpensLinks: Bool {
        if NSEvent.modifierFlags.contains(.command) { return true }
        return trigger == .click && !view.isReportingMouse
    }

    /// Finds the link under the pointer and emphasizes it when a click would open it.
    func updateHover() {
        guard isEnabled, let window = view.window else {
            hovered = nil
            overlay.emphasized = nil
            return
        }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let link = view.bounds.contains(point) ? link(at: point) : nil
        hovered = link
        let index = link.flatMap { links.firstIndex(of: $0) }
        let emphasized = clickOpensLinks ? index : nil
        let wasEmphasized = overlay.emphasized != nil
        overlay.emphasized = emphasized
        if emphasized != nil {
            NSCursor.pointingHand.set()
        } else if wasEmphasized {
            NSCursor.iBeam.set()
        }
    }

    // MARK: Modifier keys

    /// Controllers to tell when ⌘ goes down or up: the emphasis follows the key while the pointer rests on a link.
    private static let controllers = NSHashTable<TerminalLinkController>.weakObjects()
    private static var flagsMonitor: Any?

    private static func register(_ controller: TerminalLinkController) {
        controllers.add(controller)
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated {
                for controller in controllers.allObjects where controller.view.window === event.window && !controller.links.isEmpty {
                    controller.updateHover()
                }
            }
            return event
        }
    }
}

extension SevindaTerminalView {
    /// Rows of the screen for the detector, with up to a few rows above and below when a wrapped line continues past
    /// the screen's edge.
    struct ScreenRows: Sendable {
        var rows: [TerminalTextRow]
        /// The scrollback row of `rows[0]`.
        var firstRow: Int

        /// The match with its segments in scrollback rows.
        nonisolated func absolute(_ match: TerminalPathMatch) -> TerminalPathMatch {
            var match = match
            match.segments = match.segments.map { .init(row: $0.row + firstRow, columns: $0.columns) }
            return match
        }
    }

    /// The most rows read above and below the screen to complete a wrapped line.
    static let wrapContextRows = 4

    func screenRows() -> ScreenRows {
        let terminal = getTerminal()
        let top = terminal.buffer.yDisp
        var first = top
        while first > max(0, top - Self.wrapContextRows), terminal.bufferLine(atRow: first)?.isWrapped == true { first -= 1 }
        var end = top + terminal.rows
        while end < top + terminal.rows + Self.wrapContextRows, terminal.bufferLine(atRow: end)?.isWrapped == true { end += 1 }
        var rows: [TerminalTextRow] = []
        rows.reserveCapacity(end - first)
        for row in first..<end {
            guard let line = terminal.bufferLine(atRow: row) else { break }
            rows.append(textRow(line, terminal: terminal))
        }
        return ScreenRows(rows: rows, firstRow: first)
    }

    private func textRow(_ line: BufferLine, terminal: Terminal) -> TerminalTextRow {
        let columns = min(line.count, terminal.cols)
        var cells: [TerminalTextRow.Cell] = []
        cells.reserveCapacity(columns)
        var column = 0
        var lastText = -1
        while column < columns {
            let data = line[column]
            let width = Int(data.width)
            if width > 0 {
                let character = Self.character(data, terminal: terminal)
                if character != " " { lastText = cells.count }
                cells.append(.init(character: character, column: column, width: width, isExplicitLink: data.hasPayload))
            }
            column += max(1, width)
        }
        // Trailing blank cells hold nothing to find.
        cells.removeSubrange((lastText + 1)...)
        return TerminalTextRow(cells: cells, columnCount: terminal.cols, isWrapped: line.isWrapped)
    }

    /// The character of a cell; never-written cells read as a space.
    private static func character(_ data: CharData, terminal: Terminal) -> Character {
        let character = terminal.getCharacter(for: data)
        return character == "\u{0}" ? " " : character
    }

    /// Whether the cells of `match` (scrollback rows) still show its text.
    func textMatches(_ match: TerminalPathMatch) -> Bool {
        let terminal = getTerminal()
        var text = ""
        for segment in match.segments {
            guard let line = terminal.bufferLine(atRow: segment.row), segment.columns.upperBound <= line.count else { return false }
            var column = segment.columns.lowerBound
            while column < segment.columns.upperBound {
                let data = line[column]
                if data.width > 0 { text.append(Self.character(data, terminal: terminal)) }
                column += max(1, Int(data.width))
            }
        }
        return text == match.displayText
    }

    /// The scrollback row and column at a point of the view.
    func bufferCell(at point: CGPoint) -> (row: Int, column: Int)? {
        let terminal = getTerminal()
        guard let geometry = cellGeometry(),
              let cell = geometry.cell(at: point, rows: terminal.rows, columns: terminal.cols) else { return nil }
        return (cell.row + terminal.buffer.yDisp, cell.column)
    }

    /// The size and text metrics of a cell as SwiftTerm lays out the grid; nil before the view is in a window.
    public func cellGeometry() -> TerminalCellGeometry? {
        guard let window else { return nil }
        let scale = window.backingScaleFactor
        guard let pixels = cellSizeInPixels(source: getTerminal()), pixels.width > 0, pixels.height > 0 else { return nil }
        let font = self.font as CTFont
        return TerminalCellGeometry(cellSize: CGSize(width: CGFloat(pixels.width) / scale, height: CGFloat(pixels.height) / scale),
                                    viewHeight: bounds.height,
                                    baselineOffset: ceil(CTFontGetDescent(font) + CTFontGetLeading(font)),
                                    underlinePosition: CTFontGetUnderlinePosition(font), scale: scale)
    }

    /// The program asked for mouse events, so plain clicks go to it.
    var isReportingMouse: Bool { allowMouseReporting && getTerminal().mouseMode != .off }
}
