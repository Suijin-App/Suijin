import SuijinAccounts
import SuijinAgents
import SuijinCore
import SuijinUI
import SwiftUI

/// An account a session's conversation can continue on: a managed account of the same agent, or the user's own login.
struct ContinueTarget: Identifiable, Equatable {
    /// Nil for the user's own login.
    let accountID: UUID?
    let name: String
    var id: String { accountID?.uuidString ?? "own-login" }
}

extension AppModel {
    /// The other accounts of `session`'s agent: every managed account but its own, then the user's own login unless
    /// it already runs on it. Empty for a shell.
    func continueTargets(for session: AgentSessionRecord) -> [ContinueTarget] {
        guard let provider = session.agent.accountProvider else { return [] }
        var targets = accounts.filter { $0.provider == provider && $0.id != session.accountID }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { ContinueTarget(accountID: $0.id, name: $0.displayName) }
        if session.accountID != nil {
            let own = String(localized: "Your own login")
            let name = accountsController.defaultLoginEmail[provider].map { "\($0) · \(own)" } ?? own
            targets.append(ContinueTarget(accountID: nil, name: name))
        }
        return targets
    }

    /// Why `session`'s conversation cannot continue on another account now; nil when it can.
    func continueUnavailableReason(for session: AgentSessionRecord) -> String? {
        guard session.agent != .shell else { return String(localized: "Only Claude and Codex sessions can move to another account.") }
        if runtimes.resuming.contains(session.id) || runtimes.movingConversation[session.id] != nil {
            return String(localized: "This session is starting.")
        }
        guard runtimes.continuableConversation(of: session) == nil else { return nil }
        let running = runtimes.runtime(for: session.id) != nil && !runtimes.activity(of: session).isEnded
        return switch (session.agent, running) {
        case (.codex, true): String(localized: "Codex tells Suijin which conversation this is when it quits. Quit Codex, then continue from here.")
        case (_, true): String(localized: "Claude has not reported this conversation yet. Send it a message first.")
        default: String(localized: "Suijin does not know which conversation this session had, so it cannot continue it.")
        }
    }

    /// Moves `session`'s conversation to `target` and resumes it there, in the same place.
    func continueConversation(_ session: AgentSessionRecord, on target: ContinueTarget) async {
        await runtimes.continueConversation(session, onAccount: target.accountID, named: target.name)
    }

    /// The focused session of the selected tab when it runs `provider`'s agent.
    func focusedSession(for provider: AccountProvider) -> AgentSessionRecord? {
        guard let context = selection, let id = activeSession(in: context),
              let session = sessions.first(where: { $0.id == id }), session.agent.accountProvider == provider
        else { return nil }
        return session
    }

    /// A usage window of the account a running session uses that is used up, from the usage Suijin polls. Nil when
    /// the session does not run, its account's usage is unknown, or (own login) the login changed since it started.
    func reachedLimit(of session: AgentSessionRecord, now: Date = .now) -> UsageSection? {
        guard runtimes.runtime(for: session.id) != nil, !runtimes.activity(of: session).isEnded,
              let account = sessionAccount(of: session) else { return nil }
        let snapshot: UsageSnapshot? = if let id = account.managedID {
            accountsController.usage[id]
        } else if account.signedInNow == nil {
            accountsController.defaultLoginUsage[account.provider]?.snapshot
        } else {
            nil
        }
        return ProviderUsagePolicy.sections(snapshot, now: now).first { $0.window.usedFraction >= 1 }
    }
}

/// Plain-language messages for a conversation that could not move.
enum ConversationMove {
    static func message(for error: Error, agent: AgentKind) -> String {
        guard let error = error as? ConversationTransferError else { return error.localizedDescription }
        let name = agent.sessionTitle
        return switch error {
        case .invalidConversationID:
            String(localized: "Suijin does not know which conversation this session had.")
        case .historyNotFound:
            String(localized: "\(name) has not saved this conversation in the current account's folder yet, so there is nothing to move. The session was not changed.")
        case .targetMissing:
            String(localized: "The other account has no \(name) folder yet. Sign in to it once, then try again.")
        case .conflict(let path):
            String(localized: "The other account already has a different copy of this conversation (\(path)). Suijin left both copies as they are.")
        case .unsafeDestination:
            String(localized: "The conversation's files would land outside the account's history folder, so nothing was moved.")
        case .io(let path, let code):
            String(localized: "\(path): \(String(cString: strerror(code))). The original conversation was not changed.")
        }
    }
}

/// "Continue With Another Account ▸": the other accounts of the session's agent, or why there is none to pick. Used in
/// the session's context menu, its ended view, the usage popover and the limit banner.
struct ContinueWithAccountMenu: View {
    let session: AgentSessionRecord
    var title: LocalizedStringKey = "Continue With Another Account"

    var body: some View {
        Menu(title) { ContinueWithAccountItems(session: session) }
            .accessibilityHint(Text("Continues this conversation on another account in the same place"))
    }
}

/// The items of `ContinueWithAccountMenu`, for menus that nest them themselves.
struct ContinueWithAccountItems: View {
    @Environment(AppModel.self) private var model
    let session: AgentSessionRecord

    var body: some View {
        let targets = model.continueTargets(for: session)
        if let reason = model.continueUnavailableReason(for: session) {
            Text(verbatim: reason)
        } else if targets.isEmpty {
            Text("No other \(session.agent.sessionTitle) account.")
        } else {
            ForEach(targets) { target in
                Button {
                    Task { await model.continueConversation(session, on: target) }
                } label: {
                    Label {
                        Text(verbatim: target.name)
                    } icon: {
                        Image(systemName: target.accountID == nil ? "person.crop.circle" : "person.crop.circle.badge.checkmark")
                    }
                }
            }
        }
        Divider()
        Button("Account Settings…") { withAnimation(.easeOut(duration: 0.18)) { model.settingsPage = .accounts } }
    }
}

/// A slim banner at the top of a running session whose account used up a usage window, offering the other accounts.
/// Closing it hides it until that window resets. Shown only from the usage Suijin polls, never from screen text.
struct UsageLimitBanner: View {
    @Environment(AppModel.self) private var model
    let session: AgentSessionRecord
    @State private var dismissedUntil: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let section = model.reachedLimit(of: session, now: context.date),
               dismissedUntil.map({ context.date >= $0 }) ?? true,
               !model.continueTargets(for: session).isEmpty,
               let account = model.sessionAccount(of: session) {
                content(section: section, account: account, now: context.date)
            }
        }
    }

    private func content(section: UsageSection, account: SessionAccount, now: Date) -> some View {
        HStack(spacing: SuijinSpacing.s) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(ProviderUsagePolicy.title(section)) reached on \(account.name ?? account.line).")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let reset = section.window.resetsAt {
                    Text(verbatim: UsageDescription.resetLine(reset, now: now))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: SuijinSpacing.s)
            ContinueWithAccountMenu(session: session, title: "Continue With…")
                .fixedSize()
            Button {
                dismissedUntil = section.window.resetsAt ?? now.addingTimeInterval(60 * 60)
            } label: {
                Image(systemName: "xmark").imageScale(.small)
            }
            .buttonStyle(.borderless)
            .help(Text("Hide until the limit resets"))
            .accessibilityLabel(Text("Hide"))
        }
        .padding(.horizontal, SuijinSpacing.m)
        .padding(.vertical, SuijinSpacing.s)
        .frame(maxWidth: 560)
        .floatingGlass(in: Capsule())
        .padding(SuijinSpacing.s)
        .accessibilityElement(children: .contain)
    }
}
