import AppKit
import SuijinCore
import SuijinUI
import SwiftUI

/// The menu at the top of the Comments column that hands the file's comments to an agent: pasted into a running
/// session of this context (one bracketed paste, so nothing runs until Return is pressed) or copied.
///
/// The number of comments is said once, in a heading; under it each running session is one item, named as its tab
/// is. Comments that were sent and have no answer yet can be sent again, to the same session or another one.
struct MarkdownCommentsSendMenu: View {
    @Environment(AppModel.self) private var model
    let book: MarkdownCommentsBook
    /// The same preference as for diff notes: also press Return after pasting.
    @AppStorage(DiffNotePreferences.sendAutomaticallyKey) private var sendAutomatically = false

    var body: some View {
        let unsent = book.unsent
        let waiting = book.waiting
        let targets = model.sendTargets(in: book.context)
        Menu {
            if unsent.isEmpty && waiting.isEmpty {
                Text("No comments to send")
            } else if targets.isEmpty {
                Text("No running session in this worktree")
            }
            if !unsent.isEmpty, !targets.isEmpty {
                Section {
                    ForEach(targets) { target in
                        Button(target.title, systemImage: target.systemImage) {
                            book.send(unsent, to: target.session, pressReturn: sendAutomatically)
                        }
                    }
                } header: {
                    Text("Send ^[\(unsent.count) Comment](inflect: true) to")
                }
            }
            if !waiting.isEmpty, !targets.isEmpty {
                Section {
                    ForEach(targets) { target in
                        Button(target.title, systemImage: target.systemImage) {
                            book.send(waiting, to: target.session, pressReturn: sendAutomatically)
                        }
                    }
                } header: {
                    Text("Send ^[\(waiting.count) Sent Comment](inflect: true) Again to")
                }
            }
            Divider()
            Button("Copy Comments", systemImage: "doc.on.doc") { book.copy(unsent) }
                .disabled(unsent.isEmpty)
            Toggle("Send Automatically", isOn: $sendAutomatically)
        } label: {
            Label {
                Text(unsent.isEmpty ? "Send" : "Send \(unsent.count)")
            } icon: {
                Image(systemName: unsent.isEmpty ? "paperplane" : "paperplane.fill")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(Text("Send comments to an agent session you choose, or copy them"))
        .accessibilityLabel(Text("Send comments, \(unsent.count) not sent"))
    }
}

/// A running session comments or notes can be sent to, with the name its menu item shows.
struct SendTarget: Identifiable {
    let session: AgentSessionRecord
    let title: String

    var id: UUID { session.id }
    var systemImage: String { session.agent == .shell ? "terminal" : "paperplane" }

    /// Names for sessions shown together: each is called what its tab is called; sessions that would read the same
    /// also say which tab they are in and, when that is still not enough, when they started.
    static func titles(for sessions: [(id: UUID, title: String, tab: Int?, started: Date)]) -> [UUID: String] {
        var result: [UUID: String] = [:]
        let byTitle = Dictionary(grouping: sessions, by: \.title)
        let time = Date.FormatStyle(date: .omitted, time: .standard)
        for (title, group) in byTitle {
            guard group.count > 1 else {
                result[group[0].id] = title
                continue
            }
            let byTab = Dictionary(grouping: group, by: \.tab)
            for session in group {
                let tab = session.tab.map { String(localized: "Tab \($0)") }
                let alone = (byTab[session.tab]?.count ?? 0) == 1
                let started = String(localized: "started \(session.started.formatted(time))")
                let detail = [tab, alone && tab != nil ? nil : started].compactMap { $0 }.joined(separator: ", ")
                result[session.id] = "\(title) (\(detail))"
            }
        }
        return result
    }
}

extension AppModel {
    /// Running sessions of `context`, agents first: where diff notes and Markdown comments can be pasted.
    func liveSessions(in context: SessionContext) -> [AgentSessionRecord] {
        sessions(in: context)
            .filter { session in
                guard runtimes.runtime(for: session.id) != nil else { return false }
                let activity = runtimes.activity(of: session)
                return activity != .exited && activity != .failed
            }
            .sorted { ($0.agent == .shell ? 1 : 0, $0.createdAt) < ($1.agent == .shell ? 1 : 0, $1.createdAt) }
    }

    /// The running sessions of `context` as the Send menus list them: named as their tabs are, and told apart when
    /// several have the same name.
    func sendTargets(in context: SessionContext) -> [SendTarget] {
        let live = liveSessions(in: context)
        let tabs = tabList(in: context)
        let titles = SendTarget.titles(for: live.map { session in
            (id: session.id, title: runtimes.displayTitle(of: session),
             tab: tabs.firstIndex(of: tab(of: session.id)).map { $0 + 1 }, started: session.createdAt)
        })
        return live.map { SendTarget(session: $0, title: titles[$0.id] ?? runtimes.displayTitle(of: $0)) }
    }
}

extension MarkdownCommentsBook {
    /// The file as the agent should name it: relative to the context's folder when it lies inside it.
    var displayPath: String {
        if let root = appModel?.directory(of: context)?.standardizedFileURL.path, path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return path
    }

    /// Saves the file when it has unsaved edits (the agent must see the text the line numbers refer to) and brings
    /// every comment's lines up to that text. False when the save failed or met a newer version on disk.
    private func prepareToSend() -> Bool {
        if let session, session.isDirty, !session.save() { return false }
        saveMovedAnchors()
        return true
    }

    /// The text handed over for `ids`, with short ids that are unique among everything `session` still has to
    /// answer.
    private func text(for ids: [UUID], pending: [UUID]) -> String {
        let chosen = placed.filter { ids.contains($0.id) }
        return MarkdownCommentFormatter.format(chosen, filePath: displayPath, pendingIDs: pending,
                                               includesInstructions: appModel?.canAgentsResolveComments == true)
    }

    /// Pastes `comments` into `session` and marks them sent to it; the session's tab is shown so the user can read
    /// the prompt and press Return.
    func send(_ comments: [MarkdownComment], to session: AgentSessionRecord, pressReturn: Bool) {
        guard !comments.isEmpty, let model = appModel, let runtime = model.runtimes.runtime(for: session.id),
              prepareToSend() else { return }
        let ids = comments.map(\.id)
        Task {
            do {
                let waiting = try await model.io { try $0.markdownComments(sentToSession: session.id) }
                    .filter { $0.status == .sent }.map(\.id)
                let text = text(for: ids, pending: waiting)
                guard !text.isEmpty else { return }
                try runtime.paste(text, pressReturn: pressReturn)
                markSent(ids, to: session.id)
                model.registerSentComments(placed.filter { ids.contains($0.id) }, displayPath: displayPath, session: session.id)
                model.selectedTab[context] = model.tab(of: session.id)
            } catch {
                model.presentedError = PresentedError(title: String(localized: "Could not send the comments"),
                                                         message: error.localizedDescription)
            }
        }
    }

    /// Copies `comments` as the same text. Copied comments count as sent, to no session in particular, so no agent
    /// can mark them.
    func copy(_ comments: [MarkdownComment], to pasteboard: NSPasteboard = .general) {
        guard !comments.isEmpty, prepareToSend() else { return }
        let ids = comments.map(\.id)
        let chosen = placed.filter { ids.contains($0.id) }
        let text = MarkdownCommentFormatter.format(chosen, filePath: displayPath, includesInstructions: false)
        guard !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        markSent(ids, to: nil)
    }

    /// Hands a sent comment that has no answer yet to its session once more; when that session is gone the comment
    /// goes back to open, for the Send menu to hand it to another one.
    func sendAgain(_ id: UUID) {
        guard let comment = comments.first(where: { $0.id == id }), comment.status == .sent else { return }
        if let sessionID = comment.sentToSession,
           let session = appModel?.liveSessions(in: context).first(where: { $0.id == sessionID }) {
            send([comment], to: session, pressReturn: UserDefaults.standard.bool(forKey: DiffNotePreferences.sendAutomaticallyKey))
        } else {
            unsend(id)
        }
    }
}
