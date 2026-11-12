import AppKit
import SevindaUI
import SwiftUI

/// Every keyboard shortcut and mouse gesture of Sevinda, grouped and searchable by action or by key ("split", "⌘D").
/// Read-only: the list comes from `ShortcutCatalog`, which the menus and buttons bind their shortcuts from.
struct ShortcutsSettings: View {
    @State private var query: String

    /// `-SevindaShortcutsSearch <text>` starts with that search, for screenshots.
    init(initialQuery: String = UserDefaults.standard.string(forKey: "SevindaShortcutsSearch") ?? "") {
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        let sections = ShortcutCatalog.sections(matching: query)
        VStack(spacing: 0) {
            ShortcutSearchField(text: $query)
                // Lined up with the grouped form's sections below.
                .padding(.horizontal, SevindaSpacing.xl + SevindaSpacing.xs)
                .padding(.top, SevindaSpacing.s)
            if sections.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxHeight: .infinity)
            } else {
                Form {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.shortcuts) { ShortcutRow(entry: $0) }
                            ForEach(section.gestures) { GestureRow(gesture: $0) }
                        } header: {
                            Text(section.group.title)
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
    }
}

/// An action, its description, and its shortcut as a key cap. VoiceOver reads "Split Right, Command D".
private struct ShortcutRow: View {
    let entry: AppShortcut

    var body: some View {
        LabeledContent {
            KeyCap(shortcut: entry.glyphs)
        } label: {
            Text(entry.title)
            if let detail = entry.detail { Text(detail) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(String(localized: entry.title)), \(ShortcutSpeech.label(for: entry.glyphs))"))
        .accessibilityHint(entry.detail.map { Text($0) } ?? Text(verbatim: ""))
    }
}

/// An action and the mouse gesture that performs it.
private struct GestureRow: View {
    let gesture: MouseGesture

    var body: some View {
        LabeledContent {
            Label {
                Text(gesture.gesture)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: gesture.systemImage)
            }
            .foregroundStyle(.secondary)
        } label: {
            Text(gesture.title)
            if let detail = gesture.detail { Text(detail) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(String(localized: gesture.title)), \(String(localized: gesture.gesture))"))
        .accessibilityHint(gesture.detail.map { Text($0) } ?? Text(verbatim: ""))
    }
}

/// AppKit's search field. Custom bridge because `.searchable` places its field in the window toolbar, which Settings
/// hide while they cover the window.
private struct ShortcutSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = String(localized: "Search shortcuts by action or key")
        field.setAccessibilityLabel(String(localized: "Search shortcuts"))
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        // The clear button changes the text without a text-change notification; the action reports it.
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.controlSize = .large
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .large))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            searchChanged(field)
        }

        @objc func searchChanged(_ field: NSSearchField) {
            if text.wrappedValue != field.stringValue { text.wrappedValue = field.stringValue }
        }
    }
}
