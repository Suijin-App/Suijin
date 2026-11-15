import SuijinGit
import SuijinUI
import SwiftUI

/// The inspector's pull request section: the branch's pull request with its review state and checks, or why pull
/// requests are not available here (no `gh`, not signed in, not a GitHub remote).
struct PullRequestStatusSection: View {
    let state: SourceControlState

    var body: some View {
        Section {
            switch state.pullRequest {
            case .unknown, .checking:
                HStack(spacing: SuijinSpacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Checking for a pull request…").foregroundStyle(.secondary)
                }
            case .ready(let pr?):
                PullRequestSummary(pr: pr)
                ChecksList(checks: state.checks, error: state.checksError)
            case .ready(nil):
                Text("This branch has no pull request yet.").foregroundStyle(.secondary)
                Button("Create Pull Request…") { state.createPullRequestSurface = .inspector }
                    .disabled(!(state.status?.hasCommits ?? false))
            default:
                PullRequestUnavailableNote(state: state)
            }
        } header: {
            HStack {
                Text("Pull Request")
                Spacer()
                if let checkedAt = state.pullRequestCheckedAt {
                    Text(checkedAt, style: .relative).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
                Button { Task { await state.refreshPullRequest() } } label: {
                    Label("Refresh Pull Request", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(Text("Refresh the pull request and its checks"))
            }
        }
    }
}

/// Number, title, state and review decision of a pull request, with a button to open it.
struct PullRequestSummary: View {
    let pr: PullRequest

    var body: some View {
        let glyph = PullRequestGlyph(pr: pr)
        VStack(alignment: .leading, spacing: SuijinSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: SuijinSpacing.xs) {
                Image(systemName: glyph.systemImage).foregroundStyle(glyph.color)
                Text(verbatim: "#\(pr.number)").monospacedDigit().foregroundStyle(.secondary)
                Text(verbatim: pr.title).lineLimit(2).truncationMode(.tail)
            }
            // The tags and the button share a row while the inspector is wide enough; in a narrow one the button
            // goes under the tags instead of squeezing them.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SuijinSpacing.xs) {
                    tags(glyph)
                    Spacer(minLength: SuijinSpacing.xs)
                    openButton
                }
                VStack(alignment: .leading, spacing: SuijinSpacing.xs) {
                    HStack(spacing: SuijinSpacing.xs) { tags(glyph) }
                    openButton
                }
            }
        }
    }

    @ViewBuilder
    private func tags(_ glyph: PullRequestGlyph) -> some View {
        Tag(glyph.label, tone: glyph.tone)
        if let review = Self.reviewTag(for: pr) { Tag(review.0, tone: review.1) }
    }

    private var openButton: some View {
        Button("Open") { NSWorkspace.shared.open(pr.url) }
            .help(Text(verbatim: pr.url.absoluteString))
    }

    /// The review tag of a pull request: only while it is open. Once it is merged or closed the review is over, and
    /// "Review required" beside "Merged" (a pull request merged without one) says nothing the user can act on.
    static func reviewTag(for pr: PullRequest) -> (Text, StatusTone)? {
        pr.state == .open ? review(pr.reviewDecision) : nil
    }

    static func review(_ decision: String?) -> (Text, StatusTone)? {
        switch decision {
        case "APPROVED": (Text("Approved"), .ok)
        case "CHANGES_REQUESTED": (Text("Changes requested"), .error)
        case "REVIEW_REQUIRED": (Text("Review required"), .warning)
        default: nil
        }
    }
}

/// Symbol, color and name of a pull request's state.
struct PullRequestGlyph {
    let systemImage: String
    let color: Color
    let tone: StatusTone
    let label: Text

    init(pr: PullRequest) {
        switch pr.state {
        case .merged: (systemImage, color, tone, label) = ("arrow.triangle.merge", SuijinColor.agent, .agent, Text("Merged"))
        case .closed: (systemImage, color, tone, label) = ("xmark.circle", SuijinColor.error, .error, Text("Closed"))
        case .open where pr.isDraft: (systemImage, color, tone, label) = ("arrow.triangle.pull", SuijinColor.idle, .idle, Text("Draft"))
        case .open: (systemImage, color, tone, label) = ("arrow.triangle.pull", SuijinColor.ok, .ok, Text("Open"))
        }
    }
}

/// Why pull requests are not available for this context, with the action that fixes it.
struct PullRequestUnavailableNote: View {
    let state: SourceControlState

    var body: some View {
        switch state.pullRequest {
        case .ghMissing:
            note(Text("GitHub CLI is not installed"), "Suijin creates and reads pull requests with your own gh. Install it, then check again.")
            HStack {
                Link("Get GitHub CLI", destination: URL(string: "https://cli.github.com")!)
                Spacer()
                Button("Check Again") { Task { await state.recheckGitHubCLI() } }
            }
        case .notLoggedIn(let host):
            note(Text("gh is not signed in to \(host)"), "Sign in once in a terminal; Suijin never stores a GitHub token.")
            HStack {
                Button("Sign In in Terminal") { Task { await state.openGitHubLogin(host: host) } }
                Spacer()
                Button("Check Again") { Task { await state.recheckGitHubCLI() } }
            }
        case .notGitHub(let url):
            note(Text("Pull requests need a GitHub remote"),
                 url == nil ? "This repository has no remote to push to." : "The push remote is not on GitHub.")
            if let url {
                Text(verbatim: url).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
            }
        case .noBranch:
            note(Text("No branch is checked out"), "HEAD is detached. Check out a branch to open a pull request for it.")
        case .failed(let message):
            note(Text("Could not read the pull request"), nil)
            Text(verbatim: message).font(.callout).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
            Button("Try Again") { Task { await state.refreshPullRequest() } }
        default:
            EmptyView()
        }
    }

    private func note(_ title: Text, _ detail: LocalizedStringKey?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label { title } icon: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
            if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// The sidebar badge: the pull request's state symbol and number, red when a check failed.
struct PullRequestBadgeContent: View {
    let state: SourceControlState

    var body: some View {
        if let pr = state.currentPullRequest {
            let glyph = PullRequestGlyph(pr: pr)
            let failing = pr.state == .open && state.checks.contains { $0.bucket == .fail }
            HStack(spacing: 2) {
                Image(systemName: glyph.systemImage)
                    .foregroundStyle(failing ? SuijinColor.error : glyph.color)
                Text(verbatim: "#\(pr.number)").monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            .imageScale(.small)
            .lineLimit(1)
            .fixedSize()
            .help(failing ? Text("Pull request #\(pr.number): checks failing") : Text("Pull request #\(pr.number)"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(failing ? Text("Pull request \(pr.number), checks failing") : Text("Pull request \(pr.number)"))
        }
    }
}
