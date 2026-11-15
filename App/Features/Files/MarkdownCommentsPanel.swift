import SuijinCore
import SuijinUI
import SwiftUI

/// The Comments column of a Markdown tab: every comment of the file as a card, in reading order, with the menu that
/// hands them to an agent. Comments whose text is gone are listed last, under their own heading.
struct MarkdownCommentsPanel: View {
    @Environment(AppModel.self) private var model
    let book: MarkdownCommentsBook

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SuijinSpacing.s) {
                Text("Comments")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: SuijinSpacing.s)
                MarkdownCommentsSendMenu(book: book)
            }
            .padding(.horizontal, SuijinSpacing.m)
            .padding(.vertical, SuijinSpacing.s)
            Divider()
            if !model.canAgentsResolveComments {
                Text("Agents can mark comments as fixed once the running sessions have ended and Suijin’s helper has updated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SuijinSpacing.m)
                    .padding(.vertical, SuijinSpacing.s)
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        if !book.isLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if book.comments.isEmpty {
            ContentUnavailableView {
                Label("No Comments", systemImage: "text.bubble")
            } description: {
                Text("In Edit, select some text and choose Comment to leave a note for an agent.")
            }
        } else {
            List {
                Section {
                    ForEach(book.placed) { comment in card(comment) }
                }
                let detached = book.detached
                if !detached.isEmpty {
                    Section {
                        ForEach(detached) { comment in card(comment) }
                    } header: {
                        Text("Detached")
                    } footer: {
                        Text("The text these comments were on is no longer in the file.")
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func card(_ comment: MarkdownComment) -> some View {
        MarkdownCommentCard(comment: comment, isActive: book.activeID == comment.id, book: book)
            .listRowSeparator(.visible)
    }
}

/// One comment in the Comments column: its state, the quoted text on one line, the note, and the agent's reply once
/// there is one. Clicking it shows its text in the editor.
struct MarkdownCommentCard: View {
    let comment: MarkdownComment
    let isActive: Bool
    let book: MarkdownCommentsBook
    @State private var isEditing = false

    /// What the card says about where the comment stands.
    enum Badge {
        case open, sent, fixed, notFixed, detached

        init(_ comment: MarkdownComment) {
            if comment.anchor.isDetached {
                self = .detached
            } else {
                switch comment.status {
                case .open: self = .open
                case .sent: self = .sent
                case .fixed: self = .fixed
                case .declined: self = .notFixed
                }
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .open: "Open"
            case .sent: "Sent"
            case .fixed: "Fixed"
            case .notFixed: "Not Fixed"
            case .detached: "Detached"
            }
        }

        var systemImage: String {
            switch self {
            case .open: "circle"
            case .sent: "paperplane"
            case .fixed: "checkmark.circle.fill"
            case .notFixed: "exclamationmark.triangle.fill"
            case .detached: "questionmark.circle"
            }
        }

        var color: Color {
            switch self {
            case .open, .sent, .detached: .secondary
            case .fixed: SuijinColor.okText
            case .notFixed: SuijinColor.warningText
            }
        }
    }

    /// `text` on one line: line breaks and runs of spaces become single spaces.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    var body: some View {
        let badge = Badge(comment)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: SuijinSpacing.xs) {
                Label {
                    Text(badge.title)
                } icon: {
                    Image(systemName: badge.systemImage)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(badge.color)
                if !comment.anchor.isDetached {
                    Text(comment.anchor.startLine == comment.anchor.endLine
                         ? "Line \(comment.anchor.startLine)"
                         : "Lines \(comment.anchor.startLine)–\(comment.anchor.endLine)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("Comment Actions"))
            }
            Text(verbatim: Self.oneLine(comment.anchor.quote))
                .font(.callout)
                .italic()
                .foregroundStyle(comment.anchor.isDetached ? .tertiary : .secondary)
                .strikethrough(comment.anchor.isDetached)
                .lineLimit(1)
                .truncationMode(.tail)
            if !comment.body.isEmpty {
                Text(verbatim: comment.body)
                    .font(.callout)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reply = comment.agentReply, !reply.isEmpty {
                // The agent's words are data: shown as plain text, never rendered or linked.
                Label {
                    Text(verbatim: reply)
                        .lineLimit(10)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "arrowshape.turn.up.left")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { book.reveal(comment.id) }
        .listRowBackground(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
        .contextMenu { actions }
        .popover(isPresented: $isEditing, arrowEdge: .leading) {
            MarkdownCommentComposer(quote: comment.anchor.quote, note: comment.body, isNew: false,
                                    onSubmit: { note in
                                        book.update(comment.id, body: note)
                                        isEditing = false
                                    },
                                    onCancel: { isEditing = false })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(badge))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { book.reveal(comment.id) }
        .accessibilityAction(named: Text("Edit Note")) { isEditing = true }
        .accessibilityAction(named: Text("Delete")) { book.delete(comment.id) }
        .accessibilityActions {
            if comment.status.isResolved { Button("Reopen") { book.reopen(comment.id) } }
            if comment.status == .sent { Button("Send Again") { book.sendAgain(comment.id) } }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Edit Note", systemImage: "pencil") { isEditing = true }
        if comment.status == .sent, !comment.anchor.isDetached {
            Button("Send Again", systemImage: "paperplane") { book.sendAgain(comment.id) }
        }
        if comment.status.isResolved {
            Button("Reopen", systemImage: "arrow.uturn.backward") { book.reopen(comment.id) }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { book.delete(comment.id) }
    }

    private func accessibilityLabel(_ badge: Badge) -> Text {
        let quote = Self.oneLine(comment.anchor.quote)
        var parts = [String(localized: badge.title), String(localized: "on “\(quote)”")]
        if !comment.body.isEmpty { parts.append(String(localized: "Note: \(comment.body)")) }
        if let reply = comment.agentReply, !reply.isEmpty { parts.append(String(localized: "Agent replied: \(reply)")) }
        return Text(verbatim: parts.joined(separator: ". "))
    }
}
