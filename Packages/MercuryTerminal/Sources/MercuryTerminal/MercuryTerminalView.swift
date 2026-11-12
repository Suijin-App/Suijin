import AppKit
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
open class MercuryTerminalView: TerminalView {
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
        super.setFrameSize(size)
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
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyRenderer()
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
                      let view = event.window?.firstResponder as? MercuryTerminalView else { return false }
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

/// Receives SwiftTerm's view events and forwards them to the view's closures. SwiftTerm's delegate protocol predates
/// Swift concurrency; it calls on the main thread, which the `@preconcurrency` conformance checks at run time.
@MainActor
private final class DelegateBridge: @preconcurrency TerminalViewDelegate {
    weak var view: MercuryTerminalView?

    init(view: MercuryTerminalView) {
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

    func scrolled(source: TerminalView, position: Double) {}

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
