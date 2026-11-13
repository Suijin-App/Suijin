import Foundation
import Observation
import SevindaAccounts
import SevindaAgents
import SevindaCore
import SevindaUI
import SwiftUI

/// One place in an agent's fallback order: a managed account or the user's own login.
enum FallbackAccount: Hashable, Identifiable {
    case managed(UUID)
    case ownLogin

    /// The managed account's id; nil for the user's own login.
    var accountID: UUID? {
        if case .managed(let id) = self { return id }
        return nil
    }

    var id: String { storageValue }

    init(accountID: UUID?) {
        self = accountID.map(FallbackAccount.managed) ?? .ownLogin
    }

    /// How the order is stored: the account's id, or "own".
    var storageValue: String {
        switch self {
        case .managed(let id): id.uuidString
        case .ownLogin: "own"
        }
    }

    init?(storageValue: String) {
        if storageValue == "own" {
            self = .ownLogin
        } else if let id = UUID(uuidString: storageValue) {
            self = .managed(id)
        } else {
            return nil
        }
    }
}

extension AppModel {
    // MARK: Automatic switching settings

    /// Whether running sessions of `provider`'s agent move to a newly chosen default account. Off unless turned on.
    func movesOnDefaultChange(_ provider: AccountProvider) -> Bool {
        setting(provider == .claude ? .claudeMoveOnDefaultChange : .codexMoveOnDefaultChange) == "true"
    }

    func setMovesOnDefaultChange(_ provider: AccountProvider, _ on: Bool) {
        setSetting(provider == .claude ? .claudeMoveOnDefaultChange : .codexMoveOnDefaultChange, on ? "true" : nil)
        if !on { autoSwitcher.dropPendingMoves(of: provider) }
    }

    /// Whether a session of `provider`'s agent whose account used up a usage window moves to the next account with room.
    func switchesAtLimit(_ provider: AccountProvider) -> Bool {
        setting(provider == .claude ? .claudeSwitchAtLimit : .codexSwitchAtLimit) == "true"
    }

    /// Returns the usage refresh started by turning it on (it reads the own login's usage too from now on, then looks
    /// at the running sessions), so a caller can wait for it.
    @discardableResult
    func setSwitchesAtLimit(_ provider: AccountProvider, _ on: Bool) -> Task<Void, Never>? {
        setSetting(provider == .claude ? .claudeSwitchAtLimit : .codexSwitchAtLimit, on ? "true" : nil)
        guard on else { return nil }
        return Task { await accountsController.refreshUsage() }
    }

    /// Every account of `provider`'s agent in fallback order: the stored order of the accounts that still exist, then
    /// managed accounts it does not list yet (by name), then the user's own login if it is not listed.
    func fallbackOrder(for provider: AccountProvider) -> [FallbackAccount] {
        let managed = accounts.filter { $0.provider == provider }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let known = Set(managed.map(\.id))
        let key: SettingKey = provider == .claude ? .claudeFallbackOrder : .codexFallbackOrder
        var order: [FallbackAccount] = []
        for value in (setting(key) ?? "").split(separator: ",").map(String.init) {
            guard let entry = FallbackAccount(storageValue: value), !order.contains(entry) else { continue }
            if let id = entry.accountID, !known.contains(id) { continue }
            order.append(entry)
        }
        for account in managed where !order.contains(.managed(account.id)) { order.append(.managed(account.id)) }
        if !order.contains(.ownLogin) { order.append(.ownLogin) }
        return order
    }

    func setFallbackOrder(_ order: [FallbackAccount], for provider: AccountProvider) {
        let key: SettingKey = provider == .claude ? .claudeFallbackOrder : .codexFallbackOrder
        setSetting(key, order.map(\.storageValue).joined(separator: ","))
    }

    /// The name an account is shown with: a managed account's, or "someone@example.com · Your own login".
    func accountName(_ accountID: UUID?, provider: AccountProvider) -> String {
        if let accountID, let account = accounts.first(where: { $0.id == accountID }) { return account.displayName }
        let own = String(localized: "Your own login")
        return accountsController.defaultLoginEmail[provider].map { "\($0) · \(own)" } ?? own
    }

    /// The usage Sevinda last read for an account (`accountID` nil = the user's own login); nil when unknown.
    func knownUsage(of accountID: UUID?, provider: AccountProvider) -> UsageSnapshot? {
        if let accountID { return accountsController.usage[accountID] }
        return accountsController.defaultLoginUsage[provider]?.snapshot
    }

    /// Whether an account can take a session: its usage is known and every window still has room. An account whose
    /// usage is unknown (signed out, never read) is never picked, so a session never lands where it cannot work.
    func hasRoom(_ accountID: UUID?, provider: AccountProvider, now: Date = .now) -> Bool {
        guard let snapshot = knownUsage(of: accountID, provider: provider) else { return false }
        return !ProviderUsagePolicy.sections(snapshot, now: now).contains { $0.window.usedFraction >= 1 }
    }
}

/// A short note in a session's pane about an automatic move: where it went and why, or why it stayed.
struct AutoSwitchNote: Equatable {
    enum Kind: Equatable {
        case moved
        case skipped
    }

    let kind: Kind
    let text: String
}

/// Moves running Claude and Codex sessions to another account without being asked, as Settings → Accounts allows:
/// when the agent's default account changes, and when a session's account used up a usage window (to the first account
/// in the fallback order that has room). It uses the same move as Continue With Another Account, and only once the
/// agent reported its turn finished and sits at its normal input prompt (`AgentStatusTracker.finishedTurn`). A session
/// in the middle of a turn, or waiting at a permission request or a question, waits until the user answered and the
/// next turn finished: moving it then would end the agent and drop the request unseen.
///
/// Never moved: shells and agents started in a shell (the record is a shell); a running Codex, which tells Sevinda
/// neither its conversation nor when it is safely at its prompt (an approval prompt is as silent as an idle one); and
/// so Codex orchestration workers too. Claude workers keep their place in the orchestration across a move (same
/// session, same broker identity), so they follow the settings like any other session.
@Observable
@MainActor
final class AutoAccountSwitcher {
    @ObservationIgnored private unowned let model: AppModel
    /// What each session's pane says about its last automatic move or why it stayed.
    private(set) var notes: [UUID: AutoSwitchNote] = [:]
    /// Sessions waiting for their turn to end before they move to the new default account (nil = the own login).
    @ObservationIgnored private(set) var pendingDefault: [UUID: UUID?] = [:]
    /// When each session last moved on its own; a session does not move for a limit again within `limitCooldown`.
    @ObservationIgnored private var lastMove: [UUID: Date] = [:]
    @ObservationIgnored private var inFlight: Set<UUID> = []
    @ObservationIgnored private var noteExpiry: [UUID: Task<Void, Never>] = [:]
    /// The clock; tests move it forward.
    @ObservationIgnored var now: () -> Date = Date.init
    /// How long a moved note stays before it hides; a note about a session that stayed stays until closed.
    @ObservationIgnored var movedNoteDuration: Duration = .seconds(60)

    /// A session moved for a limit (or any automatic move) does not move for a limit again this soon, so two accounts
    /// near their limits never bounce it back and forth.
    static let limitCooldown: TimeInterval = 10 * 60

    init(model: AppModel) {
        self.model = model
    }

    // MARK: Events

    /// The user made `target` (nil = the own login) `provider`'s default. With the setting on, every running session of
    /// that agent on another account moves to it once its turn ends; a running Codex, or a session whose conversation is
    /// unknown, gets a note instead.
    func defaultChanged(_ provider: AccountProvider, to target: UUID?) {
        for session in model.sessions where session.agent.accountProvider == provider {
            pendingDefault[session.id] = nil
        }
        guard model.movesOnDefaultChange(provider) else { return }
        let name = model.accountName(target, provider: provider)
        for session in model.sessions where session.agent.accountProvider == provider && session.accountID != target {
            // `accountProvider` already leaves shells out; a running Codex stays with a note.
            guard isLive(session) else { continue }
            guard session.agent != .codex, model.runtimes.continuableConversation(of: session) != nil else {
                show(AutoSwitchNote(kind: .skipped, text: unknownConversationNote(session, target: name)), for: session.id)
                continue
            }
            pendingDefault[session.id] = target
            Task { await self.moveIfReady(session.id) }
        }
    }

    /// The agent reported its turn finished: the session may move now.
    func turnFinished(_ id: UUID) {
        Task { await self.moveIfReady(id) }
    }

    /// New usage was read: sessions whose account is at its limit move now if they are between turns, or once their
    /// turn ends.
    func usageChanged() async {
        for session in model.sessions where session.agent.accountProvider != nil {
            await moveIfReady(session.id)
        }
    }

    /// Turning "move on default change" off forgets the moves still waiting for a turn to end.
    func dropPendingMoves(of provider: AccountProvider) {
        for session in model.sessions where session.agent.accountProvider == provider { pendingDefault[session.id] = nil }
    }

    /// The session closed: nothing about it is kept.
    func forget(_ id: UUID) {
        pendingDefault[id] = nil
        lastMove[id] = nil
        dismissNote(id)
    }

    func dismissNote(_ id: UUID) {
        notes[id] = nil
        noteExpiry.removeValue(forKey: id)?.cancel()
    }

    // MARK: Moving

    /// Moves the session if it waits for the new default account, or if its account is at its limit and switching at
    /// the limit is on, and its turn is over. Otherwise nothing happens (it is looked at again when its turn ends or
    /// new usage arrives). With no account that has room, it stays and its limit banner offers the choice.
    func moveIfReady(_ id: UUID) async {
        guard !inFlight.contains(id), let session = model.sessions.first(where: { $0.id == id }),
              let provider = session.agent.accountProvider, isLive(session), !isExcluded(session),
              isAtItsPrompt(session) else { return }
        let target: UUID?
        let reason: String
        if let pending = pendingDefault[id] {
            pendingDefault[id] = nil
            guard pending != session.accountID else { return }
            target = pending
            reason = String(localized: "Moved to \(model.accountName(pending, provider: provider)), the new default account.")
        } else if model.switchesAtLimit(provider), let section = model.reachedLimit(of: session, now: now()),
                  lastMove[id].map({ now().timeIntervalSince($0) >= Self.limitCooldown }) ?? true,
                  let next = limitTarget(for: session, provider: provider) {
            target = next
            let from = model.sessionAccount(of: session).map { $0.name ?? $0.line } ?? model.accountName(session.accountID, provider: provider)
            reason = String(localized: "Moved to \(model.accountName(next, provider: provider)) because \(from) hit its \(Self.limitPhrase(section)).")
        } else {
            return
        }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        let name = model.accountName(target, provider: provider)
        switch await model.runtimes.moveConversation(session, onAccount: target, named: name) {
        case .moved:
            lastMove[id] = now()
            show(AutoSwitchNote(kind: .moved, text: reason), for: id)
            notifyIfInBackground(session, text: reason)
        case .failed(let message):
            show(AutoSwitchNote(kind: .skipped, text: String(localized: "Could not move to \(name). \(message)")), for: id)
        case .notStarted:
            break
        }
    }

    /// The first account in the fallback order, other than the session's own, that has room; nil when none has.
    func limitTarget(for session: AgentSessionRecord, provider: AccountProvider) -> UUID?? {
        let date = now()
        for entry in model.fallbackOrder(for: provider) where entry.accountID != session.accountID {
            if model.hasRoom(entry.accountID, provider: provider, now: date) { return .some(entry.accountID) }
        }
        return nil
    }

    // MARK: Rules

    /// Whether the agent reported its last turn finished and nothing came since: no new prompt, no permission request,
    /// no question. Only then does ending it cut nothing short.
    private func isAtItsPrompt(_ session: AgentSessionRecord) -> Bool {
        model.runtimes.runtime(for: session.id)?.tracker.finishedTurn == true
    }

    private func isLive(_ session: AgentSessionRecord) -> Bool {
        model.runtimes.runtime(for: session.id) != nil && !model.runtimes.activity(of: session).isEnded
    }

    /// Shells (and any agent started in one) have no account; a running Codex never reports that it is safely at its
    /// prompt.
    private func isExcluded(_ session: AgentSessionRecord) -> Bool {
        session.agent == .shell || session.agent == .codex
    }

    /// "5-hour limit", "weekly limit", "weekly Fable limit", as the middle of a sentence.
    static func limitPhrase(_ section: UsageSection) -> String {
        switch section.kind {
        case .session: String(localized: "5-hour limit")
        case .weekly: String(localized: "weekly limit")
        case .model: String(localized: "weekly \(section.model ?? "") limit")
        }
    }

    private func unknownConversationNote(_ session: AgentSessionRecord, target: String) -> String {
        session.agent == .codex
            ? String(localized: "Quit Codex to move it to \(target).")
            : String(localized: "Send Claude a message, then this session can move to \(target).")
    }

    // MARK: Telling the user

    private func show(_ note: AutoSwitchNote, for id: UUID) {
        dismissNote(id)
        notes[id] = note
        guard note.kind == .moved else { return }
        let duration = movedNoteDuration
        noteExpiry[id] = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, self?.notes[id] == note else { return }
            self?.notes[id] = nil
        }
    }

    #if DEBUG
    /// Screenshot tests show a note without moving anything.
    func showForPreview(_ note: AutoSwitchNote, for id: UUID) {
        show(note, for: id)
    }
    #endif

    /// A notification only while Sevinda is in the background, and only when the user allows session notifications.
    private func notifyIfInBackground(_ session: AgentSessionRecord, text: String) {
        guard model.setting(.notifyWhenWaiting) != "false", model.notifiesUser else { return }
        let name = SessionNotice.name(of: session.agent)
        UserNotifier.shared.post(identifier: session.id.uuidString,
                                 title: String(localized: "\(name) switched accounts"),
                                 body: "\(model.runtimes.displayTitle(of: session)): \(text)", session: session.id)
    }
}

/// The note in a session's pane after an automatic account move, or about why the session stayed. Small, at the top
/// and closable; it never takes the keyboard.
struct AutoSwitchNoteView: View {
    @Environment(AppModel.self) private var model
    let session: UUID

    var body: some View {
        if let note = model.autoSwitcher.notes[session] {
            HStack(spacing: SevindaSpacing.s) {
                Image(systemName: note.kind == .moved ? "arrow.triangle.swap" : "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(verbatim: note.text)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: SevindaSpacing.s)
                Button {
                    model.autoSwitcher.dismissNote(session)
                } label: {
                    Image(systemName: "xmark").imageScale(.small)
                }
                .buttonStyle(.borderless)
                .help(Text("Hide"))
                .accessibilityLabel(Text("Hide"))
            }
            .padding(.horizontal, SevindaSpacing.m)
            .padding(.vertical, SevindaSpacing.s)
            .frame(maxWidth: 560)
            .floatingGlass(in: Capsule())
            .padding(SevindaSpacing.s)
            .accessibilityElement(children: .contain)
        }
    }
}
