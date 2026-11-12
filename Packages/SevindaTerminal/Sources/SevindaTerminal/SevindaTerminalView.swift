import AppKit
import MetalKit
import SwiftTerm

/// SwiftTerm's macOS view, used for display and input only: it runs no process. `TerminalSession` connects it to a
/// `TerminalEngine`.
///
/// - Input (keys, input-method text, approved pastes) leaves through `onInput`. Key handling and `NSTextInputClient`
///   are SwiftTerm's own, untouched, so input methods (Vietnamese Telex/VNI, Japanese, …) compose as usual.
/// - `paste(_:)` runs the paste guard first: text that needs confirmation goes to `onPasteReview`, and nothing is sent
///   until the app answers.
/// - A local key monitor applies `TerminalKeyRouter` to ⌘ shortcuts while this view is the key window's first
///   responder; tab and split routes go to `onKeyRoute`.
/// - The visible screen is exposed to accessibility (and UI tests) as the view's value; the app sets the label.
@MainActor
open class SevindaTerminalView: TerminalView {
    /// Bytes for the program: typed keys, composed text, approved pastes and terminal replies (cursor reports, …).
    public var onInput: ((ArraySlice<UInt8>) -> Void)?
    /// The grid changed size (the view was resized, or the font changed).
    public var onSizeChange: ((TerminalSize) -> Void)?
    public var onTitleChange: ((String) -> Void)?
    /// The working directory the shell reported (OSC 7), when it reports one.
    public var onCurrentDirectoryChange: ((String?) -> Void)?
    public var onBell: (() -> Void)?
    /// Tab and split shortcuts; return `false` to let the event go on to the app's menus.
    public var onKeyRoute: ((TerminalKeyRoute) -> Bool)?
    /// A paste that needs the user's decision. Call `decide` exactly once, with `nil` to cancel. Without a handler,
    /// pastes go through unchecked.
    /// A link the user ⌘-clicked: an OSC 8 hyperlink, or text SwiftTerm detected as a URL or a file path (`docs/a.md`,
    /// `/tmp/x.swift:12`). Return `true` when handled; otherwise web and mail links open in their default app.
    public var onOpenLink: ((String) -> Bool)?
    public var onPasteReview: ((PasteReview, _ decide: @escaping @MainActor (TerminalInsertAction?) -> Void) -> Void)?
    public var pasteGuardPolicy: PasteGuardPolicy = .always

    /// Smaller than any terminal anyone uses. A view in a container that is not laid out yet, or one collapsing during
    /// a tab switch, is briefly this small; resizing the emulator to it reflows every line into a few columns, which
    /// overflows the scrollback and throws the oldest output away for good.
    public static let minimumSize = NSSize(width: 80, height: 40)

    private var bridge: DelegateBridge?
    /// Finds paths and links on screen and underlines them; see `linkResolver`.
    private(set) var linkController: TerminalLinkController!

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    public override init(frame: CGRect, font: NSFont?) {
        super.init(frame: frame, font: font)
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        let bridge = DelegateBridge(view: self)
        self.bridge = bridge
        terminalDelegate = bridge
        hideScroller()
        let linkController = TerminalLinkController(view: self)
        self.linkController = linkController
        linkController.overlay.frame = bounds
        addSubview(linkController.overlay, positioned: .below, relativeTo: nil)
        // Like Terminal.app: Option composes characters (accents on a US layout) instead of acting as Meta.
        optionAsMetaKey = false
        setAccessibilityIdentifier("terminal.view")
        Self.installKeyMonitor()
    }

    /// Size changes closer together than this are coalesced; see `setFrameSize(_:)`.
    public var resizeThrottle: TimeInterval = 0.12
    /// When the size last changed in a window (system uptime), and the size waiting for the throttle to pass.
    private var lastResize: TimeInterval?
    private var pendingSize: NSSize?

    /// A size that animates (the inspector or sidebar sliding in, a live window resize) changes every frame, and each
    /// grid change reflows the whole scrollback and sends the program SIGWINCH, which makes an agent's interface
    /// repaint. So in a window the first change applies at once and later ones at most every `resizeThrottle`, ending
    /// on the last size asked for. Meanwhile the view keeps its size; its container clips it or shows the terminal
    /// background around it.
    open override func setFrameSize(_ newSize: NSSize) {
        guard newSize.width >= Self.minimumSize.width, newSize.height >= Self.minimumSize.height else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard window != nil, let lastResize, now - lastResize < resizeThrottle else {
            pendingSize = nil
            applySize(newSize, at: now)
            return
        }
        guard newSize != frame.size || pendingSize != nil else { return }
        let isScheduled = pendingSize != nil
        pendingSize = newSize
        guard !isScheduled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (lastResize + resizeThrottle - now)) { [weak self] in
            MainActor.assumeIsolated { self?.applyPendingSize() }
        }
    }

    private func applySize(_ size: NSSize, at time: TimeInterval) {
        if size != frame.size, window != nil { lastResize = time }
        let changed = size != frame.size
        super.setFrameSize(size)
        if changed { linkController?.gridChanged() }
    }

    private func applyPendingSize() {
        guard let size = pendingSize else { return }
        pendingSize = nil
        applySize(size, at: ProcessInfo.processInfo.systemUptime)
    }

    /// Hides SwiftTerm's scroller for good: it drew a track along the right edge whenever there was scrollback and,
    /// while shown, took a column's width from the screen (so the terminal resized as scrollback appeared). The
    /// trackpad and the mouse wheel still scroll.
    private func hideScroller() {
        subviews.compactMap { $0 as? NSScroller }.first?.isHidden = true
    }

    /// True while a restored session's scrollback is being fed: the screen stays invisible meanwhile, so reopening
    /// the app shows the session once, at its end, instead of every line of its history scrolling past.
    public var isReplayingScrollback = false {
        didSet {
            alphaValue = isReplayingScrollback ? 0 : 1
            if isReplayingScrollback != oldValue { onReplayChange?(isReplayingScrollback) }
            if !isReplayingScrollback, oldValue { linkController?.noteChange() }
        }
    }
    /// Called when a scrollback replay starts or finishes, so the host can show progress meanwhile.
    public var onReplayChange: ((Bool) -> Void)?

    /// Drops every handler the app installed, so nothing a closure captured outlives the session. Called when the
    /// session ends.
    public func removeHandlers() {
        onPasteReview = nil
        onKeyRoute = nil
        onOpenLink = nil
        onReplayChange = nil
        onInput = nil
        onSizeChange = nil
        onOpenFileLink = nil
        linkMenuProvider = nil
        linkResolver = nil
        pendingLinkOpen?.cancel()
        pendingLinkOpen = nil
    }

    // MARK: Paths and links

    /// Confirms which printed paths exist (the host checks the disk); entries line up with the matches, nil for a path
    /// that names nothing. Setting it turns on underlining paths and web links on screen; nil (the default) turns it off,
    /// and nothing is scanned or drawn.
    public var linkResolver: (@MainActor ([TerminalPathMatch]) async -> [TerminalFileTarget?])? {
        get { linkController.resolve }
        set { linkController.resolve = newValue }
    }

    /// What opens an underlined path or link with the mouse.
    public var linkTrigger: TerminalLinkTrigger {
        get { linkController.trigger }
        set { linkController.trigger = newValue }
    }

    /// The links underlined now, top to bottom (rows count from the top of the scrollback).
    public var shownLinks: [TerminalLink] { linkController.links }

    /// An underlined path was clicked (see `TerminalLinkClick`). Web links open in the default browser after
    /// `onOpenLink` declines them.
    public var onOpenFileLink: ((TerminalFileTarget) -> Void)?

    /// Scans the screen at once instead of waiting for the output to pause (tests).
    public func scanLinksNow() { linkController.scanNow() }

    /// How many scans ran, and how long the last one took on the main thread (tests and measurements).
    public var linkScanCount: Int { linkController.scanCount }
    public var lastLinkScanDuration: Duration? { linkController.lastScanDuration }

    /// The directory the shell last reported with OSC 7 (`file://host/path`), as a path.
    public var reportedDirectory: String? {
        Self.directory(fromOSC7: getTerminal().hostCurrentDirectory)
    }

    /// The path of an OSC 7 report: `file://host/path` (percent-encoded, though shells often leave spaces as they
    /// are) or a bare absolute path.
    nonisolated static func directory(fromOSC7 reported: String?) -> String? {
        guard var text = reported, !text.isEmpty else { return nil }
        if text.lowercased().hasPrefix("file://") {
            text.removeFirst("file://".count)
            guard let slash = text.firstIndex(of: "/") else { return nil }
            text = String(text[slash...])
        }
        guard text.hasPrefix("/") else { return nil }
        return text.removingPercentEncoding ?? text
    }

    /// Output reached the screen (called by `TerminalSession` as it feeds).
    func noteOutputFed(byteCount: Int) {
        linkController.noteChange(bytes: byteCount)
    }

    /// The overlay stays right above the Metal surface, which SwiftTerm inserts (and replaces when the window changes)
    /// below the caret; without Metal it is the lowest subview, above the text the view draws itself.
    /// Re-placing a subview from inside `didAddSubview` puts it on top of everything, so it waits one turn.
    open override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard subview is MTKView else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.placeLinkOverlay() }
        }
    }

    func placeLinkOverlay() {
        guard let overlay = linkController?.overlay else { return }
        let surface = subviews.last { $0 is MTKView }
        let wanted = surface.flatMap { subviews.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        guard subviews.firstIndex(of: overlay) != wanted else { return }
        overlay.removeFromSuperview()
        if let surface {
            addSubview(overlay, positioned: .above, relativeTo: surface)
        } else {
            addSubview(overlay, positioned: .below, relativeTo: nil)
        }
    }

    open override func viewDidUnhide() {
        super.viewDidUnhide()
        linkController?.noteChange()
    }

    // MARK: Appearance

    /// Draws with SwiftTerm's Metal renderer (a glyph atlas on the GPU) or with CoreGraphics. Metal redraws a full
    /// screen of scrollback in well under a millisecond where CoreGraphics takes several, which is what makes
    /// scrolling a long agent session smooth. Without a usable Metal device the view stays on CoreGraphics.
    ///
    /// The Metal path keeps a few window-sized drawables and a glyph atlas per terminal (about 30 MB at Retina sizes),
    /// so a terminal off screen (a background tab) gives them up and takes them again when it is shown.
    public func setGPURendering(_ enabled: Bool) {
        prefersGPURendering = enabled
        applyRenderer()
    }

    private var prefersGPURendering = false

    private func applyRenderer() {
        let wanted = prefersGPURendering && window != nil
        guard wanted != isUsingMetalRenderer else { return }
        do {
            try setUseMetal(wanted)
        } catch {
            try? setUseMetal(false)
        }
        placeLinkOverlay()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let reference = WeakViewReference(self)
        firstResponderObservation = window?.observe(\.firstResponder, options: [.new]) { window, _ in
            MainActor.assumeIsolated {
                guard let view = reference.view, window.firstResponder === view else { return }
                view.focusedAt = ProcessInfo.processInfo.systemUptime
            }
        }
        applyRenderer()
        // Back on screen: positions depend on the window's scale, and output may have arrived meanwhile.
        if window != nil { linkController?.gridChanged() }
    }

    // MARK: Opening links with the mouse

    /// What the press of the current click found, for its release.
    private struct LinkPress {
        var point: CGPoint
        var link: TerminalLink?
        var selectionWasActive: Bool
        var paneWasFocused: Bool
        var dragged = false
    }

    private var linkPress: LinkPress?
    private var pendingLinkOpen: DispatchWorkItem?
    /// When the view last became the window's first responder (system uptime).
    private var focusedAt: TimeInterval = 0
    private var firstResponderObservation: NSKeyValueObservation?

    /// Every press still reaches SwiftTerm (selection starts, the program gets its click); only the release may open a
    /// link, see `TerminalLinkClick`.
    open override func mouseDown(with event: NSEvent) {
        pendingLinkOpen?.cancel()
        pendingLinkOpen = nil
        if linkController.isEnabled {
            let point = convert(event.locationInWindow, from: nil)
            // The window makes the clicked view first responder just before this press arrives: focus gained after the
            // event was posted came with this click.
            linkPress = LinkPress(point: point, link: linkController.link(at: point), selectionWasActive: selectionActive,
                                  paneWasFocused: focusedAt < event.timestamp)
        } else {
            linkPress = nil
        }
        super.mouseDown(with: event)
    }

    open override func mouseDragged(with event: NSEvent) {
        if let press = linkPress, !press.dragged {
            let point = convert(event.locationInWindow, from: nil)
            if hypot(point.x - press.point.x, point.y - press.point.y) > TerminalLinkClick.dragThreshold { linkPress?.dragged = true }
        }
        super.mouseDragged(with: event)
    }

    open override func mouseUp(with event: NSEvent) {
        guard let press = linkPress, linkController.isEnabled else {
            linkPress = nil
            return super.mouseUp(with: event)
        }
        linkPress = nil
        let point = convert(event.locationInWindow, from: nil)
        let click = TerminalLinkClick(trigger: linkTrigger, clickCount: event.clickCount, modifiers: event.modifierFlags,
                                      dragged: press.dragged || hypot(point.x - press.point.x, point.y - press.point.y) > TerminalLinkClick.dragThreshold,
                                      selectionWasActive: press.selectionWasActive, selectionIsActive: selectionActive,
                                      reportsMouse: isReportingMouse, paneWasFocused: press.paneWasFocused,
                                      pressLink: press.link, releaseLink: linkController.link(at: point))
        switch click.decision {
        case .none:
            super.mouseUp(with: event)
        case .openNow(let link):
            // As SwiftTerm does for the links it opens itself: the release ends here.
            open(link)
        case .openAfterDoubleClickInterval(let link):
            super.mouseUp(with: event)
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pendingLinkOpen = nil
                    // Nothing selected meanwhile, and the text under the link unchanged.
                    guard !self.selectionActive, self.textMatches(link.match) else { return }
                    self.open(link)
                }
            }
            pendingLinkOpen = item
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: item)
        }
    }

    /// Builds the menu for a right-click on a path or link; nil keeps the terminal's own behavior there. Asked only while
    /// link detection is on and the pointer is on a candidate.
    public var linkMenuProvider: ((TerminalLinkMenuRequest) -> NSMenu?)?

    /// A right-click (or a program reading the mouse, which never gets right-clicks from SwiftTerm) on a path or link
    /// shows the host's menu for it; anywhere else the terminal keeps its current behavior.
    open override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let linkMenuProvider, let request = linkMenuRequest(at: point), let menu = linkMenuProvider(request) { return menu }
        return super.menu(for: event)
    }

    /// The link and candidates at `point` (view coordinates); nil when there is nothing there or detection is off.
    public func linkMenuRequest(at point: CGPoint) -> TerminalLinkMenuRequest? {
        guard linkController.isEnabled, let cell = bufferCell(at: point) else { return nil }
        let link = linkController.link(at: point)
        let snapshot = screenRows()
        let candidates = TerminalPathDetector.matches(in: snapshot.rows)
            .map { snapshot.absolute($0) }
            .filter { $0.contains(row: cell.row, column: cell.column) && !$0.touchesExplicitLink }
            .sorted { $0.cellCount > $1.cellCount }
        guard link != nil || !candidates.isEmpty else { return nil }
        return TerminalLinkMenuRequest(link: link, candidates: candidates, point: point)
    }

    /// Opens a link: a path through `onOpenFileLink`, a web link through `onOpenLink` or else the default browser.
    func open(_ link: TerminalLink) {
        switch link.target {
        case .file(let file):
            onOpenFileLink?(file)
        case .web(let url):
            if onOpenLink?(url.absoluteString) == true { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// With the Metal renderer on, the terminal's surface is a Metal subview that does not take the keyboard, and a
    /// click lands on it: the window then left the keyboard where it was, so clicking the body of another pane did
    /// not focus that pane. Clicks on the surface go to the terminal itself, which takes the keyboard as any click
    /// target does.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is MTKView ? self : hit
    }

    /// Installs a theme; the screen and scrollback are kept and redrawn.
    public func apply(_ theme: TerminalTheme) {
        theme.apply(to: self)
    }

    /// Changes the font size (clamped to the theme's limits); the grid is recomputed and `onSizeChange` reports it.
    public func apply(fontSize: Double, family: String? = nil) {
        let font = TerminalTheme.font(family: family, size: fontSize)
        guard self.font != font else { return }
        self.font = font
        linkController.gridChanged()
    }

    // MARK: Paste guard

    open override func paste(_ sender: Any) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let bracketed = isBracketedPasteMode
        guard let onPasteReview, let review = PasteGuard.review(text, bracketedPaste: bracketed, policy: pasteGuardPolicy) else {
            super.paste(sender)
            return
        }
        onPasteReview(review) { [weak self] action in
            guard let self, let action else { return }
            self.insert(review.text, action: action)
        }
    }

    /// Sends text the user approved (or a command the app inserts) as `action` asks. Returns `false` when it cannot
    /// be pasted without running (several lines and no bracketed paste).
    @discardableResult
    public func insert(_ text: String, action: TerminalInsertAction) -> Bool {
        guard let bytes = PasteGuard.bytes(for: text, action: action, bracketedPaste: isBracketedPasteMode) else { return false }
        send(data: bytes[...])
        return true
    }

    // MARK: Shortcuts

    /// Performs a routed shortcut; `false` lets the event continue to the app's menus.
    open func perform(_ route: TerminalKeyRoute) -> Bool {
        switch route {
        case .newTab, .closeTab, .previousTab, .nextTab, .splitRight, .splitDown, .focusPane, .movePane, .zoomPane, .equalizePanes:
            return onKeyRoute?(route) ?? false
        case .copy:
            if selectionActive { copy(self) }
            return true
        case .paste:
            paste(self)
            return true
        case .selectAll:
            selectAll(nil)
            return true
        case .find:
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            performTextFinderAction(item)
            return true
        case .app, .terminal:
            return false
        }
    }

    private static var keyMonitor: Any?

    /// One monitor for the whole app; it acts only when a terminal view is the key window's first responder, and only
    /// on ⌘ shortcuts (everything else, marked text included, takes SwiftTerm's normal path).
    private static func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard event.window?.isKeyWindow == true,
                      let view = event.window?.firstResponder as? SevindaTerminalView else { return false }
                return view.perform(TerminalKeyRouter.route(event))
            }
            return handled ? nil : event
        }
    }

    // MARK: State and text

    /// The size of the emulator's grid.
    public var gridSize: TerminalSize {
        let terminal = getTerminal()
        return TerminalSize(cols: terminal.cols, rows: terminal.rows)
    }

    /// A full-screen program (vim, less, an agent TUI) switched to the alternate screen.
    public var isShowingAlternateScreen: Bool { getTerminal().isCurrentBufferAlternate }

    /// The program asked for bracketed paste (`ESC [ ? 2004 h`), so pasted line breaks run nothing.
    public var isBracketedPasteMode: Bool { getTerminal().bracketedPasteMode }

    /// The rows on screen, trailing spaces trimmed.
    public func visibleText() -> String {
        let terminal = getTerminal()
        return (0..<terminal.rows).map { terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
            .joined(separator: "\n")
    }

    open override func isAccessibilityElement() -> Bool { true }
    open override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    open override func accessibilityValue() -> Any? { visibleText() }

    // MARK: Delegate events

    fileprivate func handleClipboardCopy(_ content: Data) {
        // OSC 52 from the program (an agent's "copy" command, tmux, vim). Reading the clipboard stays refused.
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A weak reference to a terminal view for a key-value observation handler, which must be `Sendable`. Unchecked
/// because the handler reads it only on the main actor (`MainActor.assumeIsolated`), where the view lives.
private final class WeakViewReference: @unchecked Sendable {
    weak var view: SevindaTerminalView?

    init(_ view: SevindaTerminalView) {
        self.view = view
    }
}

/// Receives SwiftTerm's view events and forwards them to the view's closures. SwiftTerm's delegate protocol predates
/// Swift concurrency; it calls on the main thread, which the `@preconcurrency` conformance checks at run time.
@MainActor
private final class DelegateBridge: @preconcurrency TerminalViewDelegate {
    weak var view: SevindaTerminalView?

    init(view: SevindaTerminalView) {
        self.view = view
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        view?.onSizeChange?(TerminalSize(cols: newCols, rows: newRows))
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        view?.onTitleChange?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        view?.onCurrentDirectoryChange?(directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        view?.onInput?(data)
    }

    func scrolled(source: TerminalView, position: Double) {
        view?.linkController?.noteChange()
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func bell(source: TerminalView) {
        if let onBell = view?.onBell { onBell() } else { NSSound.beep() }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        view?.handleClipboardCopy(content)
    }

    func clipboardRead(source: TerminalView) -> Data? { nil }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if view?.onOpenLink?(link) == true { return }
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file", "mailto"].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}
