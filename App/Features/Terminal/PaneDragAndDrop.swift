import AppKit
import SuijinCore
import SuijinUI
import SwiftUI
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: "com.tekmium.suijin", category: "panes")

/// Rearranging the panes of a split tab by dragging a pane's header.
///
/// The drag is a system drag session (cursor, Esc to cancel, the image sliding back on a cancel), started from the
/// header's title by `PaneDragSource`, with a payload of its own type so tab drags (plain text) and pane drags never
/// land on each other. While it runs, the dragged pane dims; over another pane of the same tab five zones (`PanePlacement`
/// in SuijinCore) show where it would land with a Liquid Glass preview and a label; a drop moves it there
/// (`AppModel.movePane`) with the panes sliding into their new places (`PaneRearrangeAnimation`). Dropping it on the
/// title-bar tab group moves it into a tab of its own.
///
/// The other way round, a session tab dragged from the title bar onto a pane (or onto a plain tab's terminal) moves
/// the whole tab into the tab on screen (`AppModel.mergeTab`). A tab has nothing to swap with, so the pane is divided
/// into four zones and the nearest edge takes the drop. Session tabs carry a type of their own for this beside the
/// plain text that reorders tabs; Changes and file tabs carry the text only, so a pane never takes one.
extension UTType {
    /// A pane being dragged; the payload is its session id.
    static let suijinPane = UTType(exportedAs: "com.tekmium.suijin.pane")
    /// A session tab (plain or split) being dragged; the payload is `DetailTab.dragPayload`.
    static let suijinTab = UTType(exportedAs: "com.tekmium.suijin.tab")
}

extension NSPasteboard.PasteboardType {
    static let suijinPane = NSPasteboard.PasteboardType(UTType.suijinPane.identifier)
}

/// The pane or tab drag in progress, if any: what is dragged and where it would land.
@Observable
@MainActor
final class PaneDragState {
    struct Target: Equatable {
        let pane: UUID
        let placement: PanePlacement
    }

    /// The session of the pane being dragged.
    private(set) var source: UUID?
    /// The session tab being dragged from the title bar. A SwiftUI drag reports its start only, so this can outlive a
    /// drag that ended without a drop; drop targets also require the tab's type on the drag itself, and the next
    /// drag of either kind replaces it.
    private(set) var tab: DetailTab?
    /// The pane under the pointer and the zone it is in; nil while the pointer is over no pane that takes the drop.
    private(set) var target: Target?

    func begin(_ pane: UUID) {
        source = pane
        tab = nil
        target = nil
    }

    func beginTab(_ tab: DetailTab) {
        self.tab = tab
        source = nil
        target = nil
    }

    /// The drag ended: dropped, cancelled (Esc) or released where nothing takes it.
    func end() {
        source = nil
        tab = nil
        target = nil
    }

    func hover(_ pane: UUID, placement: PanePlacement?) {
        let new = placement.map { Target(pane: pane, placement: $0) }
        if new != target, new != nil || target?.pane == pane { target = new }
    }

    func leave(_ pane: UUID) {
        if target?.pane == pane { target = nil }
    }
}

extension AppModel {
    /// Whether the pane being dragged can land on `target`: another pane of the same split tab, all of it on screen.
    func canDropDraggedPane(onto target: UUID) -> Bool {
        guard let source = paneDrag.source, source != target, let layout = layout(containing: source) else { return false }
        return layout.contains(target) && layout.zoomed == nil
    }

    /// Drops the dragged pane on `target`: beside it on an edge, or the two swap places. The moved pane keeps the
    /// keyboard. Returns whether anything moved.
    @discardableResult
    func dropDraggedPane(onto target: UUID, placement: PanePlacement) -> Bool {
        guard canDropDraggedPane(onto: target), let source = paneDrag.source else { return false }
        paneDrag.end()
        do {
            try rearrangePanes { try movePane(source, to: target, placement: placement) }
        } catch {
            logger.error("Could not move a pane: \(String(describing: error), privacy: .public)")
            return false
        }
        focusPane(source)
        return true
    }

    /// Whether the tab being dragged can become panes of the tab that shows `target` (`canMergeTab`). A zoomed pane
    /// takes it too: the tab then shows every pane again.
    func canDropDraggedTab(onto target: UUID) -> Bool {
        guard let tab = paneDrag.tab else { return false }
        return canMergeTab(tab, beside: target)
    }

    /// Drops the dragged tab on `target`: its sessions become panes beside it on `edge`, and the pane that had the
    /// focus in the dragged tab takes the keyboard. Returns whether anything moved.
    @discardableResult
    func dropDraggedTab(onto target: UUID, edge: PaneEdge) -> Bool {
        guard canDropDraggedTab(onto: target), let tab = paneDrag.tab else { return false }
        paneDrag.end()
        do {
            try rearrangePanes { try mergeTab(tab, beside: target, edge: edge) }
        } catch {
            logger.error("Could not move a tab into a split: \(String(describing: error), privacy: .public)")
            return false
        }
        return true
    }

    /// Whether the pane being dragged can leave its split tab for a tab of its own in `context`.
    func canDropDraggedPaneOnTabBar(in context: SessionContext) -> Bool {
        guard let source = paneDrag.source, layout(containing: source) != nil,
              let record = sessions.first(where: { $0.id == source }) else { return false }
        return self.context(of: record) == context
    }

    /// Drops the dragged pane on the title-bar tab group: it becomes a tab of its own, selected.
    @discardableResult
    func dropDraggedPaneOnTabBar(in context: SessionContext) -> Bool {
        guard canDropDraggedPaneOnTabBar(in: context), let source = paneDrag.source else { return false }
        paneDrag.end()
        movePaneToNewTab(source)
        return true
    }

    /// Swaps the selected tab's focused pane with its neighbor on `edge` (the Move Pane commands and ⌃⌥⌘ arrows).
    /// Nothing while a pane is zoomed or at the tab's edge. Returns whether it moved.
    @discardableResult
    func moveFocusedPane(in context: SessionContext, toward edge: PaneEdge) -> Bool {
        guard case .panes(let id)? = currentTab(in: context), let layout = paneLayouts[id], layout.zoomed == nil else { return false }
        return rearrangePanes { movePane(layout.focused, toward: edge) }
    }
}

// MARK: Drag source

/// Makes its content (the header's logo, status and title) the handle a pane is dragged by. A click without a drag
/// runs `onClick`. Built on an AppKit view because a SwiftUI drag reports neither its start nor its end, and the
/// dragged pane must dim exactly while the drag lasts, then come back however the drag ends (dropped, Esc, released
/// elsewhere).
struct PaneDragSource: NSViewRepresentable {
    let session: UUID
    let agent: AgentKind
    let title: String
    let onBegin: @MainActor () -> Void
    let onEnd: @MainActor () -> Void
    let onClick: @MainActor () -> Void

    func makeNSView(context: Context) -> PaneDragSourceView {
        let view = PaneDragSourceView()
        view.setAccessibilityElement(false)
        update(view)
        return view
    }

    func updateNSView(_ view: PaneDragSourceView, context: Context) {
        update(view)
    }

    private func update(_ view: PaneDragSourceView) {
        view.session = session
        view.onBegin = onBegin
        view.onEnd = onEnd
        view.onClick = onClick
        let agent = agent, title = title
        view.makeImage = { appearance, scale in PaneDragChip.image(agent: agent, title: title, appearance: appearance, scale: scale) }
    }
}

final class PaneDragSourceView: NSView, NSDraggingSource {
    var session: UUID?
    var onBegin: (@MainActor () -> Void)?
    var onEnd: (@MainActor () -> Void)?
    var onClick: (@MainActor () -> Void)?
    var makeImage: (@MainActor (NSAppearance, CGFloat) -> NSImage?)?

    private var mouseDown: NSEvent?
    private var isDragging = false

    /// How far the pointer moves with the button down before a click becomes a drag.
    static let dragThreshold: CGFloat = 4

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    /// Only plain left clicks and drags stop here: a right click or Control-click goes on to the header's context
    /// menu, and everything else (hover, scrolling) to SwiftUI below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, !event.modifierFlags.contains(.control) else { return nil }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp: return super.hitTest(point)
        default: return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDown = event
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let start = mouseDown, let session else { return }
        let dx = event.locationInWindow.x - start.locationInWindow.x
        let dy = event.locationInWindow.y - start.locationInWindow.y
        guard dx * dx + dy * dy >= Self.dragThreshold * Self.dragThreshold else { return }
        beginDrag(session: session, from: start)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDown = nil }
        guard !isDragging, mouseDown != nil else { return }
        window?.invalidateCursorRects(for: self)
        onClick?()
    }

    /// Starts the system drag session with a picture of the pane's logo and title under the pointer.
    func beginDrag(session: UUID, from event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(session.uuidString, forType: .suijinPane)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let scale = window?.backingScaleFactor ?? 2
        let start = convert(event.locationInWindow, from: nil)
        if let image = makeImage?(effectiveAppearance, scale) {
            // The pointer holds the picture a little in from its leading edge, as it held the header.
            dragging.setDraggingFrame(NSRect(x: start.x - 16, y: start.y - image.size.height / 2, width: image.size.width,
                                             height: image.size.height), contents: image)
        } else {
            dragging.setDraggingFrame(NSRect(x: start.x - 8, y: start.y - 8, width: 16, height: 16), contents: nil)
        }
        isDragging = true
        let drag = beginDraggingSession(with: [dragging], event: event, source: self)
        drag.animatesToStartingPositionsOnCancelOrFail = true
        drag.draggingFormation = .none
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Panes only move within the app; other apps and the Finder never take one.
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onBegin?()
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        mouseDown = nil
        window?.invalidateCursorRects(for: self)
        onEnd?()
    }
}

/// The picture under the pointer while a pane is dragged: its logo and title on a plain capsule (a picture cannot
/// show live glass).
private struct PaneDragChip: View {
    let agent: AgentKind
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            AgentLogo(agent: agent, size: 14)
            Text(verbatim: title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 260)
        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
        .padding(1)
    }

    @MainActor
    static func image(agent: AgentKind, title: String, appearance: NSAppearance, scale: CGFloat) -> NSImage? {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let renderer = ImageRenderer(content: PaneDragChip(agent: agent, title: title)
            .environment(\.colorScheme, isDark ? .dark : .light))
        renderer.scale = scale
        return renderer.nsImage
    }
}

// MARK: Drop targets

/// Makes a pane of a split tab take the dragged pane: dims it while it is the one dragged, and shows where the dragged
/// pane would land while the pointer is over it. It takes a dragged session tab as well, and so does a plain tab's
/// terminal, which is why this is used there too (a pane drag never lands on a plain tab: it has no other pane).
struct PaneDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    let session: UUID
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        let drag = model.paneDrag
        let isSource = drag.source == session
        content
            .opacity(isSource ? 0.5 : 1)
            .animation(.easeOut(duration: 0.15), value: isSource)
            .overlay { PaneDropPreview(placement: drag.target?.pane == session ? drag.target?.placement : nil) }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onDrop(of: [.suijinPane, .suijinTab], delegate: PaneDropDelegate(model: model, pane: session, size: size))
    }
}

private struct PaneDropDelegate: DropDelegate {
    let model: AppModel
    let pane: UUID
    let size: CGSize

    /// Whether the drag is a session tab from the title bar, not a pane.
    private func isTab(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.suijinTab])
    }

    private func canDrop(_ info: DropInfo) -> Bool {
        if isTab(info) { return model.canDropDraggedTab(onto: pane) }
        return info.hasItemsConforming(to: [.suijinPane]) && model.canDropDraggedPane(onto: pane)
    }

    /// Where the drag would land: one of five zones for a pane, the nearest edge for a tab (it has nothing to swap).
    private func placement(_ info: DropInfo) -> PanePlacement? {
        if isTab(info) { return PaneEdge(nearestTo: info.location, in: size).map { .edge($0) } }
        return PanePlacement(dropAt: info.location, in: size)
    }

    func validateDrop(info: DropInfo) -> Bool {
        canDrop(info)
    }

    func dropEntered(info: DropInfo) {
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: canDrop(info) ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) {
        model.paneDrag.leave(pane)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let placement = placement(info) else { return false }
        if isTab(info) {
            guard case .edge(let edge) = placement else { return false }
            return model.dropDraggedTab(onto: pane, edge: edge)
        }
        return model.dropDraggedPane(onto: pane, placement: placement)
    }

    private func update(_ info: DropInfo) {
        guard canDrop(info) else { return }
        model.paneDrag.hover(pane, placement: placement(info))
    }
}

/// Where the dragged pane would land on this pane: a tinted Liquid Glass panel over the half it would take (or the
/// whole pane for a swap) with a label. Custom on purpose: the system has no drop-zone preview for split views. Moving
/// between zones slides the panel with a short spring.
struct PaneDropPreview: View {
    let placement: PanePlacement?

    var body: some View {
        GeometryReader { proxy in
            if let placement {
                let rect = placement.previewRect(in: CGRect(origin: .zero, size: proxy.size)).insetBy(dx: 6, dy: 6)
                VStack(spacing: 6) {
                    Image(systemName: placement.symbol)
                        .font(.title2)
                    Text(placement.label)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .foregroundStyle(.primary)
                .padding(8)
                .frame(width: max(rect.width, 0), height: max(rect.height, 0))
                .floatingGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous), tint: Color.accentColor.opacity(0.35))
                .position(x: rect.midX, y: rect.midY)
                .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.12, bounce: 0), value: placement)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension PanePlacement {
    /// What a drop in this zone does, as the preview says it.
    var label: LocalizedStringKey {
        switch self {
        case .center: "Swap"
        case .edge(.left): "Place Left"
        case .edge(.right): "Place Right"
        case .edge(.top): "Place Above"
        case .edge(.bottom): "Place Below"
        }
    }

    var symbol: String {
        switch self {
        case .center: "arrow.left.arrow.right"
        case .edge(.left): "rectangle.lefthalf.inset.filled"
        case .edge(.right): "rectangle.righthalf.inset.filled"
        case .edge(.top): "rectangle.tophalf.inset.filled"
        case .edge(.bottom): "rectangle.bottomhalf.inset.filled"
        }
    }
}

/// Makes the title-bar tab group take a dragged pane: it lights up while the pane is over it, and a drop moves the
/// pane into a tab of its own.
struct PaneTabBarDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    let context: SessionContext
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    Label("Move to New Tab", systemImage: "plus.rectangle.on.rectangle")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .floatingGlass(in: Capsule(), tint: Color.accentColor.opacity(0.35))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isTargeted)
            .onDrop(of: [.suijinPane], delegate: TabBarDropDelegate(model: model, context: context, isTargeted: $isTargeted))
    }
}

private struct TabBarDropDelegate: DropDelegate {
    let model: AppModel
    let context: SessionContext
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.suijinPane]) && model.canDropDraggedPaneOnTabBar(in: context)
    }

    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        return model.dropDraggedPaneOnTabBar(in: context)
    }
}
