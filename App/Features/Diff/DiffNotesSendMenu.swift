import AppKit
import SevindaCore
import SevindaDiff
import SevindaUI
import SwiftUI

/// Preferences of diff notes, kept in user defaults.
enum DiffNotePreferences {
    /// Press Return after pasting notes into a session, so the agent starts on them right away.
    static let sendAutomaticallyKey = "diff.notes.sendAutomatically"
    /// The diff layout picked in the Changes toolbar (`DiffDisplayMode` raw value).
    static let layoutKey = "diff.layout"
}

/// The toolbar menu that hands the context's unsent notes to an agent: pasted into a running session of this
/// worktree (one bracketed paste, so nothing runs until Return is pressed) or copied. Sent notes are marked as such;
/// editing one makes it unsent again.
struct DiffNotesSendMenu: View {
    @Environment(AppModel.self) private var model
    let context: SessionContext
    let book: DiffNotesBook
    @Binding var showsUnsentOnly: Bool
    @AppStorage(DiffNotePreferences.sendAutomaticallyKey) private var sendAutomatically = false

    var body: some View {
        let unsent = book.unsentInOrder
        let sessions = liveSessions
        Menu {
            Section {
                if sessions.isEmpty {
                    Text("No running session in this worktree")
                }
                ForEach(sessions) { session in
                    Button("Send to \(session.title)", systemImage: session.agent == .shell ? "terminal" : "paperplane") {
                        send(unsent, to: session)
                    }
                    .disabled(unsent.isEmpty)
                }
            } header: {
                Text("Send \(unsent.count) Unsent Notes")
            }
            Button("Copy Unsent Notes", systemImage: "doc.on.doc") { copy(unsent) }
                .disabled(unsent.isEmpty)
            Divider()
            Toggle("Show Only Unsent Notes", isOn: $showsUnsentOnly)
            Toggle("Send Notes Automatically", isOn: $sendAutomatically)
        } label: {
            Label {
                Text("Notes")
            } icon: {
                Image(systemName: unsent.isEmpty ? "text.bubble" : "text.bubble.fill")
            }
            .badge(unsent.count)
        }
        .help(Text("Send your diff notes to an agent, or copy them"))
        .accessibilityLabel(Text("Notes, \(unsent.count) unsent"))
    }

    /// Running sessions of this context, agents first.
    private var liveSessions: [AgentSessionRecord] {
        model.sessions(in: context)
            .filter { session in
                guard model.runtimes.runtime(for: session.id) != nil else { return false }
                let activity = model.runtimes.activity(of: session)
                return activity != .exited && activity != .failed
            }
            .sorted { ($0.agent == .shell ? 1 : 0, $0.createdAt) < ($1.agent == .shell ? 1 : 0, $1.createdAt) }
    }

    private func send(_ notes: [DiffNote], to session: AgentSessionRecord) {
        guard !notes.isEmpty, let runtime = model.runtimes.runtime(for: session.id) else { return }
        do {
            try runtime.paste(DiffNoteFormatter.format(notes), pressReturn: sendAutomatically)
            book.markSent(notes.map(\.id))
            // Show the session so the user can review the prompt and press Return.
            model.selectedTab[context] = .session(session.id)
        } catch {
            model.presentedError = PresentedError(title: String(localized: "Could not send the notes"),
                                                  message: error.localizedDescription)
        }
    }

    private func copy(_ notes: [DiffNote]) {
        guard !notes.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DiffNoteFormatter.format(notes), forType: .string)
        book.markSent(notes.map(\.id))
    }
}

/// The diff notes preference for the Settings window (the controller places it in a settings form).
struct DiffNotesSettingsSection: View {
    @AppStorage(DiffNotePreferences.sendAutomaticallyKey) private var sendAutomatically = false

    var body: some View {
        Section {
            Toggle("Send notes automatically", isOn: $sendAutomatically)
        } header: {
            Text("Diff Notes")
        } footer: {
            Text("Notes sent to an agent are pasted into its prompt. With this on, Sevinda also presses Return so the agent starts right away.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
