import AppKit
import SwiftUI

/// The inspector of a context: its files (default) or facts about it (path, branch, source control, sessions).
struct InspectorView: View {
    let context: SessionContext
    @AppStorage("inspector.tab") private var tab: Tab = .files

    enum Tab: String { case files, info }

    var body: some View {
        VStack(spacing: 0) {
            // Like Xcode's inspector tabs: icon segments sharing the whole column width.
            FillingSegmentedControl(
                selection: Binding(get: { tab == .files ? 0 : 1 }, set: { tab = $0 == 0 ? .files : .info }),
                segments: [
                    .init(symbol: "doc", label: String(localized: "Files")),
                    .init(symbol: "info.circle", label: String(localized: "Info")),
                ]
            )
            .frame(height: 28)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            switch tab {
            case .files: FileTreeView(context: context)
            case .info: WorktreeInspector(context: context)
            }
        }
        .inspectorColumnWidth(min: 220, ideal: 280, max: 440)
    }
}

/// The system segmented control with its segments sharing the full width (`fillEqually`), as Xcode's inspector tabs
/// do. Custom on purpose: SwiftUI's segmented `Picker` always sizes to its content and cannot fill the column.
private struct FillingSegmentedControl: NSViewRepresentable {
    struct Segment {
        let symbol: String
        let label: String
    }

    @Binding var selection: Int
    let segments: [Segment]

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = segments.count
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.controlSize = .large
        if #available(macOS 26.0, *) { control.borderShape = .capsule }
        for (index, segment) in segments.enumerated() {
            control.setImage(NSImage(systemSymbolName: segment.symbol, accessibilityDescription: segment.label), forSegment: index)
            control.setToolTip(segment.label, forSegment: index)
        }
        control.setAccessibilityLabel(String(localized: "Inspector"))
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        if control.selectedSegment != selection { control.selectedSegment = selection }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject {
        var parent: FillingSegmentedControl
        init(parent: FillingSegmentedControl) { self.parent = parent }
        @objc func changed(_ sender: NSSegmentedControl) { parent.selection = sender.selectedSegment }
    }
}
