import SevindaUI
import SwiftUI

/// The editor for a new note (or an edited one): a growing text field with Cancel and Save.
/// Return inserts a line break; ⌘Return saves and Escape cancels.
public struct DiffNoteComposer: View {
    /// Saves the note; the app's shortcut list shows this same value.
    public static let saveShortcut = KeyboardShortcut(.return, modifiers: .command)

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
        VStack(alignment: .leading, spacing: SevindaSpacing.s) {
            Text(verbatim: title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(String(localized: "Write a note for the agent…", bundle: .module,
                             comment: "Placeholder of the diff note editor"),
                      text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...12)
                .focused($isFocused)
                .padding(SevindaSpacing.s)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: SevindaRadius.control))
                .overlay(RoundedRectangle(cornerRadius: SevindaRadius.control).strokeBorder(SevindaColor.hairline))
                .accessibilityLabel(Text("Note", bundle: .module, comment: "Accessibility label of the diff note editor"))
            HStack {
                Spacer()
                Button(String(localized: "Cancel", bundle: .module, comment: "Discards a diff note being written"),
                       action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle) { onSave(trimmed) }
                    .keyboardShortcut(Self.saveShortcut)
                    .glassProminentButtonStyle()
                    .disabled(trimmed.isEmpty)
            }
            .controlSize(.small)
        }
        .padding(SevindaSpacing.m)
        .background(SevindaColor.card, in: RoundedRectangle(cornerRadius: SevindaRadius.card))
        .overlay(RoundedRectangle(cornerRadius: SevindaRadius.card).strokeBorder(SevindaColor.hairline))
        .onAppear { isFocused = true }
    }
}
