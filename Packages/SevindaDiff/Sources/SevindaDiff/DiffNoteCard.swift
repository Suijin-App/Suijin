import SevindaUI
import SwiftUI

/// A saved note: where it points, whether it was sent, a warning when the noted lines changed since, the text, and
/// Edit/Delete. Editing swaps the text for a composer; saving an edit marks the note unsent again (the owner does
/// that when it persists the change).
public struct DiffNoteCard: View {
    private let note: DiffNoteItem
    private let onSave: (String) -> Void
    private let onDelete: () -> Void
    @State private var isEditing = false
    @State private var draft = ""

    public init(note: DiffNoteItem, onSave: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        self.note = note
        self.onSave = onSave
        self.onDelete = onDelete
    }

    public var body: some View {
        if isEditing {
            DiffNoteComposer(title: Self.title(for: note.anchor), text: $draft,
                             saveTitle: String(localized: "Save", bundle: .module, comment: "Saves an edited diff note"),
                             onCancel: { isEditing = false },
                             onSave: { body in
                                 isEditing = false
                                 if body != note.body { onSave(body) }
                             })
        } else {
            VStack(alignment: .leading, spacing: SevindaSpacing.xs) {
                HStack(spacing: SevindaSpacing.s) {
                    Label {
                        Text(verbatim: Self.title(for: note.anchor))
                    } icon: {
                        Image(systemName: "text.bubble")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    status
                        .lineLimit(1)
                    if note.isStale {
                        Label {
                            Text("Lines changed", bundle: .module, comment: "Badge on a note whose lines changed since it was written")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(.caption)
                        .foregroundStyle(SevindaColor.warningText)
                        .lineLimit(1)
                        .help(Text("The noted lines changed since this note was written; it may no longer match.",
                                   bundle: .module, comment: "Help of the stale note badge"))
                    }
                    Spacer(minLength: 0)
                    Button {
                        draft = note.body
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .help(Text("Edit Note", bundle: .module, comment: "Edits a diff note"))
                    .accessibilityLabel(Text("Edit Note", bundle: .module, comment: "Edits a diff note"))
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .help(Text("Delete Note", bundle: .module, comment: "Deletes a diff note"))
                    .accessibilityLabel(Text("Delete Note", bundle: .module, comment: "Deletes a diff note"))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                Text(verbatim: note.body)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, SevindaSpacing.m)
            .padding(.vertical, SevindaSpacing.s)
            .background(SevindaColor.card, in: RoundedRectangle(cornerRadius: SevindaRadius.card))
            .overlay(RoundedRectangle(cornerRadius: SevindaRadius.card).strokeBorder(SevindaColor.hairline))
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder private var status: some View {
        if note.isSent {
            Label {
                Text("Sent", bundle: .module, comment: "Badge on a diff note already handed to an agent")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.caption)
            .foregroundStyle(SevindaColor.okText)
        } else {
            Text("Unsent", bundle: .module, comment: "Badge on a diff note not handed to an agent yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// "Note on line 4", "Note on lines 3–7", "Note on file".
    public static func title(for anchor: DiffNoteAnchor) -> String {
        String(localized: "Note on \(anchor.label)", bundle: .module, comment: "Header of a diff note; the argument is its location")
    }
}
