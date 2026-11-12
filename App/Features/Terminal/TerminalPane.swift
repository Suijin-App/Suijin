import AppKit
import SevindaTerminal
import SwiftUI

/// Hosts a live session's terminal view. The view belongs to the session, so switching tabs keeps its screen.
/// Multi-line pastes are held back by the view's paste guard and confirmed here.
struct TerminalPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppModel.self) private var model
    let runtime: SessionRuntime
    let context: SessionContext
    let isFocused: Bool
    @State private var review: PendingPaste?

    var body: some View {
        let model = model, id = runtime.id
        TerminalViewHost(view: runtime.terminal.view, background: theme.background.nsColor, isFocused: isFocused && review == nil,
                         onFocus: { model.focusPane(id) })
            .onAppear { installHandlers() }
            .onChange(of: colorScheme, initial: true) { applyTheme() }
            .onChange(of: model.terminalStyleRevision) { applyTheme() }
            .confirmationDialog(
                Text("Paste \(review?.review.commandLineCount ?? 0) lines?"),
                isPresented: Binding(get: { review != nil }, set: { if !$0 { review?.decide(nil); review = nil } }),
                presenting: review
            ) { pending in
                Button("Paste and Run") { pending.decide(.run); review = nil }
                if pending.review.canPasteWithoutRunning {
                    Button("Paste Without Running") { pending.decide(.pasteOnly); review = nil }
                }
                Button("Cancel", role: .cancel) { pending.decide(nil); review = nil }
            } message: { pending in
                Text(verbatim: String(pending.review.text.prefix(600)))
            }
    }

    private func installHandlers() {
        let view = runtime.terminal.view
        // Through the state's binding, not `self`: the pane holds the runtime, and the view (owned by the runtime) holding
        // the pane kept every closed session's terminal, scrollback and renderer alive.
        let pending = $review
        view.onPasteReview = { review, decide in
            pending.wrappedValue = PendingPaste(review: review, decide: decide)
        }
        let model = model, context = context, id = runtime.id
        // The route names this pane: ⌘W typed here closes this pane, whatever the model last marked as focused.
        view.onKeyRoute = { route in model.handle(route, in: context, from: id) }
        let directory = model.sessions.first { $0.id == id }.map { URL(fileURLWithPath: $0.cwd, isDirectory: true) }
        view.onOpenLink = { link in model.openTerminalLink(link, in: context, relativeTo: directory) }
    }

    private var theme: TerminalTheme {
        _ = model.terminalStyleRevision
        return TerminalThemes.resolve(id: model.setting(.terminalTheme), isDark: colorScheme == .dark)
    }

    private func applyTheme() {
        let theme = theme
        runtime.terminal.view.setGPURendering(model.setting(.terminalGPURendering) != "false")
        runtime.terminal.view.apply(theme)
        let size = model.setting(.terminalFontSize).flatMap(Double.init) ?? Double(TerminalTheme.defaultFontSize)
        runtime.terminal.view.apply(fontSize: size, family: model.setting(.terminalFontFamily))
    }

    struct PendingPaste {
        let review: PasteReview
        let decide: @MainActor (TerminalInsertAction?) -> Void
    }
}

/// Puts an existing AppKit terminal view in SwiftUI with a small margin, so text does not touch the pane's edges, and
/// gives it keyboard focus when its pane is focused. The margin takes the terminal's background color, so the pane
/// reads as one surface. `onFocus` runs whenever the terminal really becomes the window's first responder (a click,
/// the app or AppKit moving the keyboard), so the model's focused pane follows the keyboard.
private struct TerminalViewHost: NSViewRepresentable {
    let view: MercuryTerminalView
    let background: NSColor
    let isFocused: Bool
    let onFocus: @MainActor () -> Void

    func makeNSView(context: Context) -> NSView {
        let container = FocusingContainer()
        container.wantsLayer = true
        // While the pane's size animates, the terminal keeps its size for a moment (its resizes are coalesced); a
        // terminal briefly wider than the pane must not draw over the inspector next to it.
        container.clipsToBounds = true
        container.terminal = view
        container.embedTerminal()
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? FocusingContainer else { return }
        container.terminal = view
        // Never from a container on its way out: when a pane moves to a new place in the layout (a split opens or
        // closes) SwiftUI updates the old container after the new one took the terminal, and taking it back left the
        // terminal in a container no window shows (a blank pane without keyboard). The new container claims it when
        // it joins the window.
        if view.superview !== container, view.window == nil { container.embedTerminal() }
        container.layer?.backgroundColor = background.cgColor
        container.wantsFocus = isFocused
        container.onFocus = onFocus
        if isFocused, container.window != nil, container.window?.firstResponder !== view {
            DispatchQueue.main.async { container.window?.makeFirstResponder(view) }
        }
    }
}

/// The terminal's container. A pane that should have the keyboard takes it when it joins the window too: the first
/// SwiftUI update of a new or switched-to pane runs before the view is in a window, and nothing updates it again, so
/// the keyboard stayed in the sidebar list (where the arrow keys switch sessions).
///
/// It also watches the window's first responder (key-value observed): the terminal becoming first responder by any
/// path reports `onFocus`, and the keyboard falling to the window itself (the focused pane next to this one closed,
/// so its view left the window) is taken back when this pane should have it.
private final class FocusingContainer: NSView {
    weak var terminal: MercuryTerminalView?
    var wantsFocus = false
    var onFocus: (@MainActor () -> Void)?
    private var observation: NSKeyValueObservation?

    static let horizontalInset: CGFloat = 10
    static let verticalInset: CGFloat = 6

    /// Moves the terminal into this container, inset by the pane's margin.
    func embedTerminal() {
        guard let terminal, terminal.superview !== self else { return }
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            terminal.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalInset),
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation = window?.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.firstResponderChanged(in: window) }
        }
        guard let window else { return }
        // The container that joins the window last is the one on screen: it holds the terminal, even if a container
        // about to be removed took it meanwhile.
        embedTerminal()
        takeFocusIfWanted(in: window)
    }

    /// A click in the margin around the terminal focuses it too, so anywhere in a pane's body selects that pane.
    override func mouseDown(with event: NSEvent) {
        guard let terminal, terminal.superview === self else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(terminal)
    }

    private func firstResponderChanged(in window: NSWindow) {
        guard let terminal, terminal.superview === self else { return }
        if window.firstResponder === terminal {
            onFocus?()
        } else if wantsFocus, window.firstResponder === window {
            takeFocusIfWanted(in: window)
        }
    }

    private func takeFocusIfWanted(in window: NSWindow) {
        guard wantsFocus else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantsFocus, self.window === window, let terminal = self.terminal, terminal.superview === self,
                  window.firstResponder !== terminal else { return }
            // Not from a field or sheet the user is typing in; only from the window itself or the sidebar list.
            guard window.firstResponder === window || window.firstResponder is NSTableView else { return }
            window.makeFirstResponder(terminal)
        }
    }
}
