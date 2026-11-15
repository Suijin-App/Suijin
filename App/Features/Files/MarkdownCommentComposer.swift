import SuijinUI
import SwiftUI

/// The popover that adds a comment on the selected text, or edits a comment's note: the quoted text and a note
/// field. Return adds, Esc cancels; the note may stay empty when the selection says enough.
struct MarkdownCommentComposer: View {
    let quote: String
    @State var note: String
    /// A new comment ("Add") or an existing one ("Save").
    let isNew: Bool
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SuijinSpacing.m) {
            Text(verbatim: MarkdownCommentCard.oneLine(quote))
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .accessibilityLabel(Text("Commented text: \(MarkdownCommentCard.oneLine(quote))"))
            TextField("Note for the agent (optional)", text: $note, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { onSubmit(note) }
                .accessibilityLabel(Text("Note"))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { onSubmit(note) }
                    .keyboardShortcut(.defaultAction)
                    .glassProminentButtonStyle()
            }
        }
        .padding(SuijinSpacing.l)
        .frame(width: 320)
        .onAppear { isFocused = true }
    }
}
