import Charts
import MercuryCore
import MercuryUI
import MercuryUsage
import SwiftUI

/// Settings → Stats & Usage: Mercury's own counters, then the Claude Code and Codex token usage read from their local
/// logs (totals, a six-week heatmap, the token mix and one card per provider).
struct StatsUsageSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        StatsUsagePage(usage: model.usage)
    }
}

private struct StatsUsagePage: View {
    @Bindable var usage: UsageController

    var body: some View {
        Form {
            Section {
                MercuryStatsRow(stats: usage.stats)
            } header: {
                VStack(alignment: .leading, spacing: MercurySpacing.xs) {
                    Text("Stats & Usage")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Mercury activity plus Claude and Codex token usage read from their local logs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Mercury")
                        .padding(.top, MercurySpacing.m)
                }
            } footer: {
                mercuryFooter
            }
            Section {
                UsageControlsRow(usage: usage)
                usageContent
            } header: {
                Text("Usage Analytics")
            } footer: {
                Text("Read only from ~/.claude/projects, ~/.codex/sessions and the homes of your managed accounts. Costs are estimated at API list prices; not your subscription bill.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let snapshot = usage.snapshot, hasAnyData(snapshot) {
                Section {
                    providers(snapshot)
                } header: {
                    Text("Providers")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { usage.pageAppeared() }
        .onDisappear { usage.pageDisappeared() }
    }

    @ViewBuilder private var mercuryFooter: some View {
        if let error = usage.statsError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(MercuryColor.warningText)
        } else if let since = usage.stats?.trackingSince {
            Text("Tracking since \(since.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption).foregroundStyle(.secondary)
        } else if usage.stats != nil {
            Text("Counting starts with the next agent session.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var usageContent: some View {
        if let snapshot = usage.snapshot {
            if hasAnyData(snapshot), let summary = usage.summary() {
                UsageTilesRow(summary: summary)
                UsageChartsRow(
                    heatmap: snapshot.summary(provider: usage.scope.provider,
                                              since: UsageHeatmapModel.start()),
                    tokens: summary.tokens)
                UsageWarningRow(unreadableFiles: snapshot.unreadableFiles, skippedLines: summary.skippedLines)
            } else if usage.isRefreshing {
                ScanProgressRow(progress: usage.progress ?? 0)
            } else {
                ContentUnavailableView {
                    Label("No usage logs yet", systemImage: "chart.bar")
                } description: {
                    Text("Claude Code and Codex sessions appear here once they write logs.")
                }
                UsageWarningRow(unreadableFiles: snapshot.unreadableFiles, skippedLines: 0)
            }
        } else if usage.isRefreshing {
            ScanProgressRow(progress: usage.progress ?? 0)
        } else if let error = usage.refreshError {
            ContentUnavailableView {
                Label("Usage could not be read", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: error)
            } actions: {
                Button("Try Again") { usage.refresh() }
            }
        } else {
            ScanProgressRow(progress: 0)
        }
    }

    private func providers(_ snapshot: UsageSnapshot) -> some View {
        let since = usage.range.since(now: Date())
        let cards = ForEach(UsageProvider.allCases, id: \.self) { provider in
            ProviderUsageCard(
                provider: provider, summary: snapshot.summary(provider: provider, since: since),
                hasData: snapshot.hasData(provider: provider))
        }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: MercurySpacing.xl) {
                cards.frame(minWidth: 260)
            }
            VStack(alignment: .leading, spacing: MercurySpacing.l) { cards }
        }
        .padding(.vertical, MercurySpacing.xs)
    }

    private func hasAnyData(_ snapshot: UsageSnapshot) -> Bool {
        UsageProvider.allCases.contains { snapshot.hasData(provider: $0) }
    }
}

// MARK: Rows

/// Agents spawned, time agents worked and PRs created; placeholders while the counters load.
private struct MercuryStatsRow: View {
    let stats: MercuryStats?

    var body: some View {
        let shown = stats ?? MercuryStats()
        TileRow {
            StatTile(symbol: "sparkle", value: UsageFormat.count(Int(clamping: shown.agentsSpawned)),
                     caption: "Agents spawned")
            Divider()
            StatTile(symbol: "clock", value: UsageFormat.duration(seconds: shown.agentWorkSeconds),
                     caption: "Time agents worked")
            Divider()
            StatTile(symbol: "arrow.triangle.pull", value: UsageFormat.count(Int(clamping: shown.prsCreated)),
                     caption: "PRs created")
        }
        .redacted(reason: stats == nil ? .placeholder : [])
    }
}

/// Scope and range pickers, when usage was last read, and the refresh button.
private struct UsageControlsRow: View {
    @Bindable var usage: UsageController

    var body: some View {
        HStack(spacing: MercurySpacing.m) {
            Picker("Providers", selection: $usage.scope) {
                Text("Overview").tag(UsageScope.overview)
                Text("Claude").tag(UsageScope.claude)
                Text("Codex").tag(UsageScope.codex)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("Range", selection: $usage.range) {
                Text("7 days").tag(UsageRange.sevenDays)
                Text("30 days").tag(UsageRange.thirtyDays)
                Text("All time").tag(UsageRange.allTime)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: MercurySpacing.s)
            status
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if usage.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Reading logs"))
            } else {
                Button {
                    usage.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(Text("Read new log lines"))
            }
        }
    }

    @ViewBuilder private var status: some View {
        if usage.isRefreshing, usage.snapshot != nil {
            Text("Updating…")
        } else if let error = usage.refreshError, usage.snapshot != nil {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(MercuryColor.warningText)
                .help(Text(verbatim: error))
        } else if let updatedAt = usage.snapshot?.updatedAt {
            Text("Updated \(UsageFormat.updated(updatedAt))")
        }
    }
}

/// The first scan, with how much of the log bytes are read.
private struct ScanProgressRow: View {
    let progress: Double

    var body: some View {
        ProgressView(value: progress) {
            Text("Reading Claude and Codex logs…")
        } currentValueLabel: {
            Text(verbatim: UsageFormat.percent(progress)).monospacedDigit()
        }
        .padding(.vertical, MercurySpacing.xs)
    }
}

/// Total tokens, estimated cost, active days and cache share for the selected scope and range.
private struct UsageTilesRow: View {
    let summary: MercuryUsage.UsageSummary

    var body: some View {
        TileRow {
            StatTile(symbol: "number", value: UsageFormat.tokens(summary.tokens.total), caption: "Total tokens")
                .help(Text("\(UsageFormat.count(summary.tokens.total)) tokens"))
            Divider()
            StatTile(symbol: "dollarsign.circle", value: UsageFormat.cost(summary.costUSD), caption: "Est. cost",
                     badge: summary.hasUnpricedUsage ? "partial" : nil)
                .help(costHelp)
            Divider()
            StatTile(symbol: "calendar", value: UsageFormat.count(summary.activeDays), caption: "Active days")
            Divider()
            StatTile(symbol: "square.stack.3d.up", value: UsageFormat.percent(summary.cacheShare),
                     caption: "Cache share")
                .help(Text("Share of prompt tokens read from or written to the cache."))
        }
    }

    private var costHelp: Text {
        let base = Text("Estimated at API list prices; not your subscription bill.")
        guard summary.hasUnpricedUsage else { return base }
        return Text("\(base) Some models have no known price and are left out.")
    }
}

/// The six-week heatmap beside the token mix, stacked when the row is too narrow.
private struct UsageChartsRow: View {
    let heatmap: MercuryUsage.UsageSummary
    let tokens: UsageTokens

    var body: some View {
        let grid = UsageHeatmap(model: UsageHeatmapModel(daily: heatmap.daily), bestDay: heatmap.bestDay)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: MercurySpacing.xl) {
                grid.fixedSize()
                Divider()
                TokenMixView(tokens: tokens).frame(minWidth: 280)
            }
            VStack(alignment: .leading, spacing: MercurySpacing.l) {
                grid
                Divider()
                TokenMixView(tokens: tokens)
            }
        }
        .padding(.vertical, MercurySpacing.xs)
    }
}

/// A short note when some log files could not be read or some lines were not understood.
private struct UsageWarningRow: View {
    let unreadableFiles: Int
    let skippedLines: Int

    var body: some View {
        if unreadableFiles > 0 || skippedLines > 0 {
            Label {
                if unreadableFiles > 0, skippedLines > 0 {
                    Text("\(unreadableFiles) log files could not be read and \(skippedLines) lines were skipped.")
                } else if unreadableFiles > 0 {
                    Text("\(unreadableFiles) log files could not be read.")
                } else {
                    Text("\(skippedLines) log lines were skipped because their format is unknown.")
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.caption)
            .foregroundStyle(MercuryColor.warningText)
        }
    }
}

// MARK: Token mix

/// Input, output, cache read and cache write as one stacked bar with a legend of values and shares.
private struct TokenMixView: View {
    let tokens: UsageTokens

    private struct Segment: Identifiable {
        let id: Int
        let name: String
        let value: Int
        let color: Color
    }

    private var segments: [Segment] {
        [
            Segment(id: 0, name: String(localized: "Input"), value: tokens.input, color: .blue),
            Segment(id: 1, name: String(localized: "Output"), value: tokens.output, color: .purple),
            Segment(id: 2, name: String(localized: "Cache read"), value: tokens.cacheRead, color: .teal),
            Segment(id: 3, name: String(localized: "Cache write"), value: tokens.cacheWrite, color: .orange),
        ]
    }

    var body: some View {
        let segments = segments
        let total = max(1, tokens.total)
        VStack(alignment: .leading, spacing: MercurySpacing.s) {
            Text("Token mix").font(.headline)
            Text("New input, output and cache tokens in the selected range.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Chart(segments) { segment in
                BarMark(x: .value("Tokens", segment.value), y: .value("Mix", "tokens"), height: .ratio(1))
                    .foregroundStyle(segment.color)
            }
            .chartXScale(domain: 0...total)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 12)
            .clipShape(Capsule())
            .background(.quaternary, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Token mix"))
            .accessibilityValue(Text(verbatim: segments.map { "\($0.name) \(UsageFormat.tokens($0.value))" }
                .joined(separator: ", ")))
            Grid(alignment: .leading, horizontalSpacing: MercurySpacing.s, verticalSpacing: MercurySpacing.xs) {
                ForEach(segments) { segment in
                    GridRow {
                        Circle().fill(segment.color).frame(width: 8, height: 8)
                        Text(verbatim: segment.name).foregroundStyle(.secondary).lineLimit(1)
                        Text(verbatim: UsageFormat.tokens(segment.value))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(verbatim: UsageFormat.share(Double(segment.value) / Double(total)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                    .lineLimit(1)
                    .help(Text("\(UsageFormat.count(segment.value)) tokens"))
                }
            }
            .font(.callout)
        }
    }
}

// MARK: Tiles

/// Tiles of one row, equally wide, with the dividers between them.
private struct TileRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: MercurySpacing.m) { content }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, MercurySpacing.xs)
    }
}

/// An SF Symbol, a large number and a caption, read by VoiceOver as "caption, value".
private struct StatTile: View {
    let symbol: String
    let value: String
    let caption: LocalizedStringKey
    var badge: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: MercurySpacing.xs) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(height: 24, alignment: .leading)
                .accessibilityHidden(true)
            Text(verbatim: value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: MercurySpacing.xs) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let badge {
                    Text(badge)
                        .font(.caption2)
                        .foregroundStyle(MercuryColor.warningText)
                        .padding(.horizontal, 5)
                        .background(MercuryColor.warning.opacity(0.15), in: Capsule())
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(caption))
        .accessibilityValue(badge.map { Text("\(value), \(Text($0))") } ?? Text(verbatim: value))
    }
}
