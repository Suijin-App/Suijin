import SevindaCore
import SwiftUI

/// The strip above a pane of a split tab: the agent's logo, status and title (the drag handle, `PaneDragHandle`),
/// then, while zoomed, which pane of how many is shown, and the zoom and close buttons. Full strength while the pane
/// has the focus or the pointer, quieter otherwise. Clicking it focuses the pane.
struct PaneHeader: View {
    @Environment(AppModel.self) private var model
    let session: AgentSessionRecord
    let layout: PaneLayout
    let isFocused: Bool
    @State private var isHovered = false

    static let height: CGFloat = 26

    var body: some View {
        let activity = model.runtimes.activity(of: session)
        let isZoomed = layout.zoomed == session.id
        let title = model.runtimes.displayTitle(of: session)
        HStack(spacing: 6) {
            PaneDragHandle(session: session.id, agent: model.runtimes.displayAgent(of: session), title: title) {
                HStack(spacing: 6) {
                    AgentLogo(agent: model.runtimes.displayAgent(of: session), size: 13)
                        .opacity(activity.isEnded ? 0.5 : 1)
                    SessionStatusGlyph(activity: activity)
                    Text(verbatim: title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isFocused ? .primary : .secondary)
                    PermissionsSkippedBadge(session: session)
                    Spacer(minLength: 0)
                }
            }
            if isZoomed, let index = layout.panes.firstIndex(of: session.id) {
                Text("\(index + 1) of \(layout.paneCount)")
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .help(Text("Pane \(index + 1) of \(layout.paneCount) is zoomed (⇧⌘↩ shows them all)"))
            }
            Group {
                Button { model.toggleZoom(session.id) } label: {
                    Image(systemName: isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help(isZoomed ? Text("Show all panes (⇧⌘↩)") : Text("Zoom pane (⇧⌘↩)"))
                .accessibilityLabel(isZoomed ? Text("Show all panes") : Text("Zoom pane"))
                Button { model.requestClose(session.id) } label: {
                    Image(systemName: "xmark")
                }
                .help(Text("Close pane and end the session (⌘W)"))
                .accessibilityLabel(Text("Close pane"))
            }
            .buttonStyle(.borderless)
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .opacity(isFocused || isHovered || isZoomed ? 1 : 0)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(isFocused ? Color.accentColor.opacity(0.14) : Color.primary.opacity(isHovered ? 0.07 : 0.04))
        .overlay(alignment: .bottom) { Divider() }
        .opacity(isFocused || isHovered ? 1 : 0.75)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu { PaneMenuItems(session: session.id, layout: layout) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: title))
    }
}

/// The part of a pane header the pane is dragged by (logo, status and title): dragging it rearranges the panes
/// (`PaneDragAndDrop.swift`), clicking it focuses the pane. The terminal below is never involved, so selecting text
/// in it starts no drag. VoiceOver moves the pane with actions instead.
struct PaneDragHandle<Content: View>: View {
    @Environment(AppModel.self) private var model
    let session: UUID
    let agent: AgentKind
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        let model = model, session = session
        content
            .contentShape(Rectangle())
            .overlay {
                PaneDragSource(session: session, agent: agent, title: title,
                               onBegin: { model.paneDrag.begin(session) },
                               onEnd: { model.paneDrag.end() },
                               onClick: {
                                   model.focusPane(session)
                                   // The keyboard too, even when the model already marked this pane (the keyboard was
                                   // in the sidebar).
                                   if let view = model.runtimes.runtime(for: session)?.terminal.view {
                                       view.window?.makeFirstResponder(view)
                                   }
                               })
            }
            .help(Text("Drag to move the pane"))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Focuses the pane. Use the actions to move it."))
            .accessibilityAction { model.focusPane(session) }
            .accessibilityAction(named: Text("Move Pane Left")) { move(.left) }
            .accessibilityAction(named: Text("Move Pane Right")) { move(.right) }
            .accessibilityAction(named: Text("Move Pane Up")) { move(.top) }
            .accessibilityAction(named: Text("Move Pane Down")) { move(.bottom) }
            .accessibilityAction(named: Text("Move Pane to New Tab")) { model.movePaneToNewTab(session) }
    }

    private func move(_ edge: PaneEdge) {
        model.focusPane(session)
        model.rearrangePanes { model.movePane(session, toward: edge) }
    }
}
