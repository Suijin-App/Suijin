import AppKit
import MercuryTerminal
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
        TerminalViewHost(view: runtime.terminal.view, background: theme.background.nsColor, isFocused: isFocused && review == nil)
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
        view.onKeyRoute = { route in model.handle(route, in: context) }
        let directory = model.sessions.first { $0.id == id }.map { URL(fileURLWithPath: $0.cwd, isDirectory: true) }
        view.onOpenLink = { link in model.openTerminalLink(link, in: context, relativeTo: directory) }
        view.onFocus = {
            guard let tab = model.selectedSession(in: context) else { return }
            model.focusedPane[tab] = id == tab ? nil : id
        }
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
/// reads as one surface.
private struct TerminalViewHost: NSViewRepresentable {
    let view: MercuryTerminalView
    let background: NSColor
    let isFocused: Bool

    static let horizontalInset: CGFloat = 10
    static let verticalInset: CGFloat = 6

    func makeNSView(context: Context) -> NSView {
        let container = FocusingContainer()
        container.wantsLayer = true
        // While the pane's size animates, the terminal keeps its size for a moment (its resizes are coalesced); a
        // terminal briefly wider than the pane must not draw over the inspector next to it.
        container.clipsToBounds = true
        embed(in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container { embed(in: container) }
        container.layer?.backgroundColor = background.cgColor
        (container as? FocusingContainer)?.wantsFocus = isFocused
        if isFocused, container.window != nil, container.window?.firstResponder !== view {
            DispatchQueue.main.async { container.window?.makeFirstResponder(view) }
        }
    }

    private func embed(in container: NSView) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.horizontalInset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.horizontalInset),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.verticalInset),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.verticalInset),
        ])
        container.layer?.backgroundColor = background.cgColor
    }
}

/// The terminal's container. A pane that should have the keyboard takes it when it joins the window too: the first
/// SwiftUI update of a new or switched-to pane runs before the view is in a window, and nothing updates it again, so
/// the keyboard stayed in the sidebar list (where the arrow keys switch sessions).
private final class FocusingContainer: NSView {
    var wantsFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsFocus, let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantsFocus, self.window === window, let terminal = self.subviews.first,
                  window.firstResponder !== terminal else { return }
            // Not from a field or sheet the user is typing in; only from the window itself or the sidebar list.
            guard window.firstResponder === window || window.firstResponder is NSTableView else { return }
            window.makeFirstResponder(terminal)
        }
    }
}
