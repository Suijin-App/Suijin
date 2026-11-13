import SuijinCore
import SwiftUI

/// The mark of the program a session runs: the Claude and Codex logos (trimmed to the same visual size), or a
/// terminal symbol for a shell.
struct AgentLogo: View {
    let agent: AgentKind
    var size: CGFloat = 14

    var body: some View {
        Group {
            switch agent {
            case .claude: Image("ClaudeLogo").resizable().interpolation(.high)
            case .codex: Image("CodexLogo").resizable().interpolation(.high)
            case .shell: Image(systemName: "terminal").resizable().foregroundStyle(.secondary)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .accessibilityLabel(agent == .claude ? Text("Claude Code") : agent == .codex ? Text("Codex") : Text("Shell"))
    }
}

/// A session's status next to its logo. A running session shows nothing extra, so the logo alone means "working";
/// the other states get a small symbol, the waiting one pulsing.
struct SessionStatusGlyph: View {
    let activity: SessionActivityDisplay

    var body: some View {
        if activity != .running {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(activity.color)
                .symbolEffect(.pulse, isActive: activity == .waitingForInput)
                .accessibilityLabel(activity.label)
        }
    }

    private var symbol: String {
        switch activity {
        case .starting: "circle.dotted"
        case .running: "circle.fill"
        case .waitingForInput: "exclamationmark.bubble.fill"
        case .idle: "checkmark.circle"
        case .exited: "stop.circle"
        case .failed: "xmark.octagon.fill"
        }
    }
}

extension SessionRuntimeRegistry {
    /// What a tab or sidebar row calls a session: the terminal title the program set (Claude Code names the task
    /// there), unless it is only the program's own name; otherwise the session's title.
    func displayTitle(of session: AgentSessionRecord) -> String {
        if let shown = Self.shownTitle(titles[session.id]) { return shown }
        // A shell running an agent is named after that agent until the agent names its task.
        if session.agent == .shell, let agent = shellAgents[session.id] { return SessionNotice.name(of: agent) }
        // An own-login session names the login signed in now, which can change while it runs.
        return model.sessionAccount(of: session)?.title(stored: session.title, agentName: session.agent.sessionTitle)
            ?? session.title
    }

    /// The part of a terminal title a tab shows: without the spinner or symbols around it, `nil` when only the
    /// program's own name (or nothing) is left.
    nonisolated static func shownTitle(_ raw: String?) -> String? {
        let title = (raw ?? "").trimmingCharacters(in: titleTrim)
        return genericTitles.contains(title.lowercased()) ? nil : title
    }

    private nonisolated static let genericTitles: Set<String> = ["claude code", "claude", "codex", ""]
    /// Built once: composing character sets is slow, and every tab and sidebar row asks on each render.
    private nonisolated static let titleTrim = CharacterSet.alphanumerics.inverted.subtracting(.punctuationCharacters)
        .union(.whitespaces)
}
