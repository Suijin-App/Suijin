import SevindaCore
import SevindaUI
import SevindaUsage
import SwiftUI

/// Settings → Stats & Usage → Providers: one provider's logo and data status, its most used model and project, then
/// tokens, sessions and turns, and the estimated cost in the selected range.
struct ProviderUsageCard: View {
    let provider: UsageProvider
    let summary: SevindaUsage.UsageSummary
    /// Whether the provider has any usage at all, in any range.
    let hasData: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SevindaSpacing.s) {
            HStack(spacing: SevindaSpacing.s) {
                AgentLogo(agent: agent, size: 20)
                Text(verbatim: name).font(.headline).lineLimit(1)
                Spacer(minLength: SevindaSpacing.s)
                Group {
                    if hasData {
                        Label("Has data", systemImage: "checkmark.circle.fill")
                    } else {
                        Label("No data yet", systemImage: "circle.dashed")
                    }
                }
                .font(.caption)
                .foregroundStyle(hasData ? AnyShapeStyle(SevindaColor.okText) : AnyShapeStyle(.secondary))
                .lineLimit(1)
            }
            Text(verbatim: detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(Text(verbatim: detail))
            Grid(alignment: .leading, horizontalSpacing: SevindaSpacing.m, verticalSpacing: SevindaSpacing.xs) {
                row("Tokens", UsageFormat.tokens(summary.tokens.total))
                row("Sessions · turns",
                    "\(UsageFormat.count(summary.sessions)) · \(UsageFormat.count(summary.turns))")
                row("Est. cost", UsageFormat.cost(summary.costUSD))
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).lineLimit(1)
            Text(verbatim: value)
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var agent: AgentKind {
        switch provider {
        case .claude: .claude
        case .codex: .codex
        }
    }

    private var name: String {
        switch provider {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// "top model · top project", or a note that no model was used in range.
    private var detail: String {
        let model = summary.topModel?.name ?? String(localized: "No model yet")
        guard let project = summary.topProject?.name else { return model }
        return "\(model) · \(project)"
    }
}
