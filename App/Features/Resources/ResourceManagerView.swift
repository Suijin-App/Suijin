import Charts
import SevindaUI
import SwiftUI

/// The Resource Manager popover of the status bar. Samples only while it is shown: the `.task` loop ends when the
/// popover closes, and a new monitor (with an empty history) starts each time it opens.
struct ResourceManagerPopover: View {
    @Environment(AppModel.self) private var model
    @State private var monitor = ResourceMonitor()
    /// Called after a session row was selected, so the owner can close the popover.
    var onSelectSession: () -> Void

    var body: some View {
        ResourceManagerView(
            report: monitor.report,
            history: monitor.history,
            problem: monitor.problem,
            onRefresh: { Task { await monitor.refresh(model: model) } },
            onSelect: select
        )
        .task {
            await monitor.refresh(model: model)
            // The first CPU figures need a second sample; take it soon instead of after the full interval.
            var interval = Duration.seconds(1)
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                await monitor.refresh(model: model)
                interval = .seconds(2)
            }
        }
    }

    private func select(_ row: ResourceReport.Row) {
        guard case .session(let id) = row.id, let context = row.context else { return }
        model.selection = context
        model.selectedTab[context] = .session(id)
        onSelectSession()
    }
}

/// The popover's content, independent of sampling so it can be rendered with fixed figures.
struct ResourceManagerView: View {
    static let width: CGFloat = 400
    static let maxListHeight: CGFloat = 380
    static let cpuColumn: CGFloat = 52
    static let memoryColumn: CGFloat = 68
    static let sparklineWidth: CGFloat = 44

    let report: ResourceReport?
    let history: [ResourceReport.GroupID: [UInt64]]
    let problem: String?
    let onRefresh: () -> Void
    let onSelect: (ResourceReport.Row) -> Void

    @State private var collapsed: Set<ResourceReport.GroupID> = []
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let report {
                columnHeader
                list(report)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .accessibilityLabel(Text("Measuring resources"))
            }
            if let problem {
                Divider()
                Label {
                    Text(verbatim: problem).lineLimit(2)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SevindaColor.warning)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, SevindaSpacing.m)
                .padding(.vertical, SevindaSpacing.s)
            }
        }
        .frame(width: Self.width)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: SevindaSpacing.m) {
            Label("Resource Manager", systemImage: "memorychip")
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: SevindaSpacing.s)
            if let report {
                HStack(spacing: SevindaSpacing.m) {
                    summary(Text("CPU"), value: Self.cpuText(report.cpu))
                    summary(Text("Memory"), value: Self.memoryText(report.memory))
                }
                .accessibilityElement(children: .combine)
            }
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(Text("Refresh"))
            .accessibilityLabel(Text("Refresh"))
        }
        .padding(.horizontal, SevindaSpacing.m)
        .padding(.vertical, SevindaSpacing.s + 2)
    }

    private func summary(_ title: Text, value: Text) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            title.font(.caption2).foregroundStyle(.secondary)
            value.font(.callout.weight(.semibold)).monospacedDigit()
        }
    }

    private var columnHeader: some View {
        HStack(spacing: SevindaSpacing.s) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU").frame(width: Self.cpuColumn, alignment: .trailing)
            Text("Memory").frame(width: Self.memoryColumn, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, SevindaSpacing.m + SevindaSpacing.xs)
        .padding(.top, SevindaSpacing.s)
        .padding(.bottom, 2)
        .accessibilityHidden(true)
    }

    private func list(_ report: ResourceReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SevindaSpacing.xs) {
                if report.sessionGroups.isEmpty {
                    ContentUnavailableView {
                        Label("No Running Sessions", systemImage: "terminal")
                    } description: {
                        Text("Only Sevinda is using resources right now.")
                    }
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SevindaSpacing.s)
                }
                ForEach(report.sessionGroups) { group in groupView(group) }
                groupView(report.sevinda)
            }
            .padding(.horizontal, SevindaSpacing.m)
            .padding(.bottom, SevindaSpacing.m)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
        }
        .frame(height: min(max(listHeight, 1), Self.maxListHeight))
    }

    private func groupView(_ group: ResourceReport.Group) -> some View {
        DisclosureGroup(isExpanded: expansion(of: group.id)) {
            VStack(spacing: 0) {
                ForEach(group.rows) { row in
                    if row.context != nil {
                        Button { onSelect(row) } label: { ResourceRowView(row: row) }
                            .buttonStyle(ResourceRowButtonStyle())
                            .help(Text("Show this session"))
                    } else {
                        ResourceRowView(row: row)
                    }
                }
            }
        } label: {
            HStack(spacing: SevindaSpacing.s) {
                Text(verbatim: group.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MemorySparkline(samples: history[group.id] ?? [])
                    .frame(width: Self.sparklineWidth, height: 14)
                Self.cpuText(group.cpu)
                    .frame(width: Self.cpuColumn, alignment: .trailing)
                Self.memoryText(group.memory)
                    .frame(width: Self.memoryColumn, alignment: .trailing)
            }
            .font(.subheadline)
            .monospacedDigit()
            .padding(.vertical, 3)
            .accessibilityElement(children: .combine)
        }
    }

    private func expansion(of id: ResourceReport.GroupID) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { expanded in if expanded { collapsed.remove(id) } else { collapsed.insert(id) } }
        )
    }

    static func memoryText(_ bytes: UInt64?) -> Text {
        guard let bytes else { return Text(verbatim: "—") }
        return Text(Int64(clamping: bytes), format: .byteCount(style: .memory))
    }

    static func cpuText(_ cpu: Double?) -> Text {
        guard let cpu else { return Text(verbatim: "—") }
        return Text(cpu / 100, format: .percent.precision(.fractionLength(1)))
    }
}

/// One measured target: logo, title (and branch), status dot, CPU and memory.
private struct ResourceRowView: View {
    let row: ResourceReport.Row

    var body: some View {
        HStack(spacing: SevindaSpacing.s) {
            icon.frame(width: 16)
            if let activity = row.activity {
                Circle()
                    .fill(activity.color)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(activity.label)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: row.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = row.subtitle {
                    Label {
                        Text(verbatim: subtitle).lineLimit(1).truncationMode(.middle)
                    } icon: {
                        Image(systemName: "arrow.triangle.branch").accessibilityHidden(true)
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ResourceManagerView.cpuText(row.figures?.cpu)
                .foregroundStyle(.secondary)
                .frame(width: ResourceManagerView.cpuColumn, alignment: .trailing)
            ResourceManagerView.memoryText(row.figures?.memory)
                .frame(width: ResourceManagerView.memoryColumn, alignment: .trailing)
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.vertical, 4)
        .padding(.horizontal, SevindaSpacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch row.icon {
        case .agent(let agent):
            AgentLogo(agent: agent, size: 14)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// A plain row that highlights under the pointer and while pressed, like a menu or list row.
private struct ResourceRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Highlighted(configuration: configuration)
    }

    private struct Highlighted: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : isHovered ? 0.06 : 0))
                )
                .onHover { isHovered = $0 }
        }
    }
}

/// Recent memory totals of a group as a small line; empty until two samples exist.
private struct MemorySparkline: View {
    let samples: [UInt64]

    /// The samples' range padded by a tenth of the peak, so small fluctuations stay small instead of filling the
    /// whole height.
    private var domain: ClosedRange<Double> {
        let low = Double(samples.min() ?? 0), high = Double(samples.max() ?? 0)
        let pad = max(high * 0.1, 1)
        return max(low - pad, 0)...(high + pad)
    }

    var body: some View {
        if samples.count >= 2 {
            // The newest sample sits at the right edge, so a short history grows in from the right.
            let start = ResourceMonitor.historyLength - samples.count
            Chart(Array(samples.enumerated()), id: \.offset) { item in
                LineMark(x: .value("Sample", start + item.offset), y: .value("Memory", Double(item.element)))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.25))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartXScale(domain: 0...(ResourceMonitor.historyLength - 1))
            .chartYScale(domain: domain)
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }
}
