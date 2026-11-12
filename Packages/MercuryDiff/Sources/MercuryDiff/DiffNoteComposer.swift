import MercuryUI
import SwiftUI

/// The editor for a new note (or an edited one): a growing text field with Cancel and Save.
/// Return inserts a line break; ⌘Return saves and Escape cancels.
public struct DiffNoteComposer: View {
    private let title: String
    @Binding private var text: String
    private let saveTitle: String
    private let onCancel: () -> Void
    private let onSave: (String) -> Void
    @FocusState private var isFocused: Bool

    /// - Parameters:
    ///   - title: what the note is about, for example "Note on lines 3–7".
    ///   - saveTitle: the confirm button, "Add Note" or "Save".
    public init(title: String, text: Binding<String>, saveTitle: String,
                onCancel: @escaping () -> Void, onSave: @escaping (String) -> Void) {
        self.title = title
        _text = text
        self.saveTitle = saveTitle
        self.onCancel = onCancel
        self.onSave = onSave
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var body: some View {
        VStack(alignment: .leading, spacing: MercurySpacing.s) {
            Text(verbatim: title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(String(localized: "Write a note for the agent…", bundle: .module,
                             comment: "Placeholder of the diff note editor"),
                      text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...12)
                .focused($isFocused)
                .padding(MercurySpacing.s)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: MercuryRadius.control))
                .overlay(RoundedRectangle(cornerRadius: MercuryRadius.control).strokeBorder(MercuryColor.hairline))
                .accessibilityLabel(Text("Note", bundle: .module, comment: "Accessibility label of the diff note editor"))
            HStack {
                Spacer()
                Button(String(localized: "Cancel", bundle: .module, comment: "Discards a diff note being written"),
                       action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle) { onSave(trimmed) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .glassProminentButtonStyle()
                    .disabled(trimmed.isEmpty)
            }
            .controlSize(.small)
        }
        .padding(MercurySpacing.m)
        .background(MercuryColor.card, in: RoundedRectangle(cornerRadius: MercuryRadius.card))
        .overlay(RoundedRectangle(cornerRadius: MercuryRadius.card).strokeBorder(MercuryColor.hairline))
        .onAppear { isFocused = true }
    }
}
