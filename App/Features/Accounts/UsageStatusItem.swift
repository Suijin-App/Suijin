import SevindaAccounts
import SevindaCore
import SevindaUI
import SwiftUI

/// The status bar item of one provider, laid out like Orca's: logo, a capacity bar for the most used window, then
/// "87% used 5d 12h · 14% used Fable". Shown only while the provider is signed in, through a managed default
/// account or the user's own login. Clicking opens the details popover.
struct UsageStatusItem: View {
    @Environment(AppModel.self) private var model
    let provider: AccountProvider
    @State private var showsDetails = false

    var body: some View {
        if let state = model.accountsController.statusUsage(for: provider) {
            // Recompute the countdowns every minute; usage itself changes only on refresh.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let sections = ProviderUsagePolicy.sections(state.snapshot, now: context.date)
                Button { showsDetails.toggle() } label: {
                    UsageStatusLabel(provider: provider, state: state, sections: sections, now: context.date)
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: UsageDescription.tooltip(provider: provider, state: state, sections: sections, now: context.date)))
                .accessibilityLabel(Text(verbatim: UsageDescription.accessibility(provider: provider, state: state, sections: sections, now: context.date)))
                .accessibilityHint(Text("Shows usage details"))
                .popover(isPresented: $showsDetails, arrowEdge: .top) {
                    UsageDetailsPopover(provider: provider, state: state, sections: sections, now: context.date)
                }
            }
        }
    }
}

/// Logo, bar and inline usage text, or the failure label when there is no usage to show.
private struct UsageStatusLabel: View {
    let provider: AccountProvider
    let state: ProviderUsageState
    let sections: [UsageSection]
    let now: Date

    var body: some View {
        HStack(spacing: MercurySpacing.xs + 2) {
            AgentLogo(agent: provider.agentKind, size: 13)
            if let tightest = ProviderUsagePolicy.tightest(sections) {
                UsageCapacityBar(fraction: tightest.window.usedFraction, provider: provider)
                Text(verbatim: sections.map { ProviderUsagePolicy.inlineText($0, now: now) }.joined(separator: " · "))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Usage kept from before a failed refresh.
                if let failure = state.failure, !failure.isCalm { UsageWarningIcon() }
            } else if let failure = state.failure {
                if !failure.isCalm { UsageWarningIcon() }
                Text(verbatim: failure.label).lineLimit(1).truncationMode(.tail)
            } else {
                Text("Updating…").lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct UsageWarningIcon: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle").imageScale(.small).foregroundStyle(.secondary)
    }
}

/// Thin capsule bar of the tightest window in the provider's own color (the percentage beside it tells how close
/// the limit is), so the bar reads as Claude or Codex at a glance instead of a traffic light.
struct UsageCapacityBar: View {
    let fraction: Double
    let provider: AccountProvider
    var width: CGFloat = 60

    var body: some View {
        // Like every native control, the bar loses its tint while the window is inactive.
        Gauge(value: min(max(fraction, 0), 1)) { EmptyView() }
            .gaugeStyle(.accessoryLinearCapacity)
            .labelsHidden()
            .tint(provider.brandColor)
            .frame(width: width)
            .accessibilityHidden(true)
    }
}

/// Native popover with every window, its reset time, the account and the last update (Orca's provider details).
struct UsageDetailsPopover: View {
    @Environment(AppModel.self) private var model
    let provider: AccountProvider
    let state: ProviderUsageState
    let sections: [UsageSection]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: MercurySpacing.m) {
            HStack(spacing: MercurySpacing.s) {
                AgentLogo(agent: provider.agentKind, size: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: provider.displayName).font(.headline)
                    Text(verbatim: UsageDescription.accountLine(state))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            if sections.isEmpty, state.failure == nil {
                Text("No usage limits reported yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(verbatim: ProviderUsagePolicy.title(section)).font(.callout)
                        Spacer(minLength: MercurySpacing.s)
                        Text("\(section.percent)% used").font(.callout).monospacedDigit()
                    }
                    UsageCapacityBar(fraction: section.window.usedFraction, provider: provider, width: 248)
                    if let reset = section.window.resetsAt {
                        Text(verbatim: UsageDescription.resetLine(reset, now: now))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if let failure = state.failure {
                Label {
                    Text(verbatim: failure.message(provider: provider.displayName))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: failure.isCalm ? "info.circle" : "exclamationmark.triangle")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if let fetched = state.snapshot?.fetchedAt {
                Text("Updated \(fetched, format: .relative(presentation: .named))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Divider()
            HStack {
                Button("Account Settings…") { withAnimation(.easeOut(duration: 0.18)) { model.settingsPage = .accounts } }
                Spacer()
                Button {
                    Task { await model.accountsController.refreshUsageNow() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.accountsController.isRefreshingUsage)
            }
            .controlSize(.small)
        }
        .padding(MercurySpacing.l)
        .frame(width: 280)
    }
}

/// Text for the tooltip, the popover and VoiceOver; tokens never appear here, only names and percentages.
enum UsageDescription {
    static func accountLine(_ state: ProviderUsageState) -> String {
        let source = state.isManaged ? String(localized: "Mercury account") : String(localized: "Your own login")
        guard let name = state.accountName, !name.isEmpty else { return source }
        return "\(name) · \(source)"
    }

    static func resetLine(_ reset: Date, now: Date) -> String {
        guard reset > now else { return String(localized: "Resets now") }
        let duration = ProviderUsagePolicy.resetDuration(until: reset, now: now)
        let when = reset.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return String(localized: "Resets in \(duration) (\(when))")
    }

    static func tooltip(provider: AccountProvider, state: ProviderUsageState, sections: [UsageSection], now: Date) -> String {
        var lines = ["\(provider.displayName) — \(accountLine(state))"]
        for section in sections {
            var line = String(localized: "\(ProviderUsagePolicy.title(section)): \(section.percent)% used")
            if let reset = section.window.resetsAt { line += ", " + resetLine(reset, now: now) }
            lines.append(line)
        }
        if let failure = state.failure { lines.append(failure.message(provider: provider.displayName)) }
        if let fetched = state.snapshot?.fetchedAt {
            lines.append(String(localized: "Updated \(fetched.formatted(.relative(presentation: .named)))"))
        }
        return lines.joined(separator: "\n")
    }

    static func accessibility(provider: AccountProvider, state: ProviderUsageState, sections: [UsageSection], now: Date) -> String {
        var parts = [String(localized: "\(provider.displayName) usage")]
        parts += sections.map { section in
            var text = String(localized: "\(ProviderUsagePolicy.title(section)) \(section.percent) percent used")
            if let reset = section.window.resetsAt, reset > now {
                text += ", " + String(localized: "resets in \(ProviderUsagePolicy.resetDuration(until: reset, now: now))")
            }
            return text
        }
        if let failure = state.failure { parts.append(failure.label) }
        return parts.joined(separator: "; ")
    }
}

extension AccountProvider {
    var agentKind: AgentKind {
        switch self {
        case .claude: .claude
        case .codex: .codex
        }
    }

    /// Product names, not translated.
    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

extension AccountProvider {
    /// The color of the provider's logo: Claude's terracotta, Codex's purple.
    var brandColor: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.47, green: 0.42, blue: 0.96)
        }
    }
}
