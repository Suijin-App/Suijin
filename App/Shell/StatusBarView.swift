import SevindaCore
import SevindaUI
import SwiftUI

/// Status bar at the bottom of the window: usage of the selected accounts, running sessions, app memory.
struct StatusBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: SevindaSpacing.l) {
            UsageStatusItem(provider: .claude)
            UsageStatusItem(provider: .codex)
            UsageRefreshButton()
            Spacer(minLength: SevindaSpacing.s)
            ResourceStatusItem()
                .layoutPriority(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, SevindaSpacing.l)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("statusBar")
    }
}

/// The running sessions and Sevinda's memory; clicking them opens the Resource Manager.
private struct ResourceStatusItem: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingResources = false

    var body: some View {
        Button {
            isShowingResources.toggle()
        } label: {
            HStack(spacing: SevindaSpacing.l) {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                    Text("\(model.runtimes.liveCount) running")
                }
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    Text(verbatim: ProcessMemory.formattedFootprint())
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("Show the Resource Manager: memory and CPU of running sessions and Sevinda"))
        .accessibilityLabel(Text("Resource Manager"))
        .accessibilityIdentifier("resourceManagerButton")
        .popover(isPresented: $isShowingResources, arrowEdge: .top) {
            ResourceManagerPopover { isShowingResources = false }
                .environment(model)
        }
    }
}

/// Refreshes usage of the providers shown on the left; a small spinner replaces it while a refresh runs. Hidden
/// when no provider is signed in.
private struct UsageRefreshButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let controller = model.accountsController
        if AccountProvider.allCases.contains(where: { controller.statusUsage(for: $0) != nil }) {
            if controller.isRefreshingUsage {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel(Text("Refreshing usage"))
            } else {
                Button {
                    Task { await controller.refreshUsageNow() }
                } label: {
                    Image(systemName: "arrow.clockwise").imageScale(.small)
                }
                .buttonStyle(.borderless)
                .help(Text("Refresh usage"))
                .accessibilityLabel(Text("Refresh usage"))
            }
        }
    }
}

/// The app's physical memory footprint, as Activity Monitor shows it.
enum ProcessMemory {
    static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    static func formattedFootprint() -> String {
        guard let bytes = footprint() else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
