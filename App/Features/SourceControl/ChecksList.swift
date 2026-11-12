import MercuryGit
import MercuryUI
import SwiftUI

/// The CI checks of a pull request with a summary line; each check opens its page in the browser.
struct ChecksList: View {
    let checks: [PullRequestCheck]
    let error: String?

    var body: some View {
        if let error {
            Label { Text(verbatim: error).lineLimit(3).textSelection(.enabled) } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(MercuryColor.warningText)
            }
            .font(.callout)
        } else if checks.isEmpty {
            Text("No checks reported").foregroundStyle(.secondary).font(.callout)
        } else {
            Text(summary).font(.callout).foregroundStyle(.secondary)
            ForEach(Self.sorted(checks)) { check in
                CheckRow(check: check)
            }
        }
    }

    /// Failures first, then pending, then the rest, each group by name.
    static func sorted(_ checks: [PullRequestCheck]) -> [PullRequestCheck] {
        let order: [PullRequestCheck.Bucket: Int] = [.fail: 0, .pending: 1, .cancel: 2, .pass: 3, .skipping: 4]
        return checks.sorted { ((order[$0.bucket] ?? 9), $0.name) < ((order[$1.bucket] ?? 9), $1.name) }
    }

    private var summary: String {
        let passed = checks.count { $0.bucket == .pass }
        let failed = checks.count { $0.bucket == .fail }
        let pending = checks.count { $0.bucket == .pending }
        var parts: [String] = []
        if failed > 0 { parts.append(String(localized: "\(failed) failed")) }
        if pending > 0 { parts.append(String(localized: "\(pending) pending")) }
        if passed > 0 { parts.append(String(localized: "\(passed) passed")) }
        let other = checks.count - passed - failed - pending
        if other > 0 { parts.append(String(localized: "\(other) skipped or cancelled")) }
        return parts.joined(separator: " · ")
    }
}

private struct CheckRow: View {
    let check: PullRequestCheck

    var body: some View {
        let glyph = CheckGlyph(bucket: check.bucket)
        HStack(spacing: MercurySpacing.xs) {
            Image(systemName: glyph.systemImage)
                .foregroundStyle(glyph.color)
                .accessibilityLabel(glyph.label)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: check.name).lineLimit(1).truncationMode(.tail)
                if let workflow = check.workflow {
                    Text(verbatim: workflow).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: MercurySpacing.xs)
            if let link = check.link {
                Button { NSWorkspace.shared.open(link) } label: {
                    Label("Open Check", systemImage: "arrow.up.right.square")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(Text("Open \(check.name) in the browser"))
            }
        }
        .help(Text(verbatim: "\(check.name): \(check.state)"))
    }
}

/// Symbol, color and spoken name of a check result.
struct CheckGlyph {
    let systemImage: String
    let color: Color
    let label: Text

    init(bucket: PullRequestCheck.Bucket) {
        switch bucket {
        case .pass: (systemImage, color, label) = ("checkmark.circle.fill", MercuryColor.ok, Text("Passed"))
        case .fail: (systemImage, color, label) = ("xmark.circle.fill", MercuryColor.error, Text("Failed"))
        case .pending: (systemImage, color, label) = ("clock.fill", MercuryColor.warning, Text("Pending"))
        case .skipping: (systemImage, color, label) = ("minus.circle", MercuryColor.idle, Text("Skipped"))
        case .cancel: (systemImage, color, label) = ("slash.circle", MercuryColor.idle, Text("Cancelled"))
        }
    }
}
