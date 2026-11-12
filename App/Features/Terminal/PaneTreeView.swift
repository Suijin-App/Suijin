import MercuryCore
import MercuryUI
import SwiftUI

/// A split tab: its pane tree in nested native split views, or the zoomed pane alone.
struct PaneTreeView: View {
    @Environment(AppModel.self) private var model
    let layout: PaneLayout
    let context: SessionContext

    var body: some View {
        if let zoomed = layout.zoomed {
            PaneCell(session: zoomed, layout: layout, context: context)
        } else {
            PaneNodeView(node: layout.root, path: [], layout: layout, context: context)
        }
    }
}

/// One node of the tree: a pane, or a split of its children.
private struct PaneNodeView: View {
    @Environment(AppModel.self) private var model
    let node: PaneNode
    let path: [Int]
    let layout: PaneLayout
    let context: SessionContext

    var body: some View {
        switch node {
        case .pane(let id):
            PaneCell(session: id, layout: layout, context: context)
        case .split(let axis, let children, let fractions):
            let model = model, layoutID = layout.id, path = path
            PaneSplitView(
                axis: axis,
                fractions: fractions,
                children: children.enumerated().map { index, child in
                    PaneSplitView.Child(
                        key: child.panes[0],
                        minimumLength: child.minimumLength(along: axis),
                        pane: child.singlePane,
                        // Each child is hosted on its own, so the environment is passed on explicitly.
                        content: AnyView(PaneNodeView(node: child, path: path + [index], layout: layout, context: context)
                            .environment(model))
                    )
                },
                onResize: { model.setPaneFractions($0, at: path, in: layoutID) }
            )
        }
    }
}

/// A pane of a split tab: a header strip above the session's terminal (or its ended or reconnecting view), and a
/// thin accent ring while it has the focus. The header is a strip of its own, so selecting text in the terminal never
/// starts anything else.
struct PaneCell: View {
    @Environment(AppModel.self) private var model
    let session: UUID
    let layout: PaneLayout
    let context: SessionContext

    /// The smallest pane: room for a short prompt line and the header.
    nonisolated static let minimumSize = CGSize(width: 160, height: 90)

    var body: some View {
        let isFocused = layout.focused == session && model.currentTab(in: context) == .panes(layout.id)
        VStack(spacing: 0) {
            if let record = model.sessions.first(where: { $0.id == session }) {
                PaneHeader(session: record, layout: layout, isFocused: isFocused)
            }
            SessionPaneContent(session: session, context: context, isFocused: isFocused, closeTitle: "Close Pane")
        }
        .modifier(PaneDropTarget(session: session))
        .overlay {
            Rectangle()
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.85 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .frame(minWidth: Self.minimumSize.width, maxWidth: .infinity, minHeight: Self.minimumSize.height, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Pane"))
    }
}

extension PaneNode {
    /// The session when the node is a single pane.
    var singlePane: UUID? {
        if case .pane(let id) = self { id } else { nil }
    }

    /// The smallest length the node's panes need along `axis`, dividers included.
    func minimumLength(along axis: PaneAxis) -> CGFloat {
        let pane = axis == .sideBySide ? PaneCell.minimumSize.width : PaneCell.minimumSize.height
        switch self {
        case .pane:
            return pane
        case .split(let splitAxis, let children, _):
            let lengths = children.map { $0.minimumLength(along: axis) }
            return splitAxis == axis ? lengths.reduce(0, +) + CGFloat(children.count - 1) : lengths.max() ?? pane
        }
    }
}
