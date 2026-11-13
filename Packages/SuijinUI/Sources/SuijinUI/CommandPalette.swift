import SwiftUI

/// One entry in the command palette (⌘⇧P).
public struct PaletteCommand: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let shortcut: String?
    public let run: @MainActor @Sendable () -> Void

    public init(id: String, title: String, subtitle: String = "", shortcut: String? = nil, run: @escaping @MainActor @Sendable () -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.run = run
    }
}

/// Each feature registers its own commands into the palette.
@MainActor
public protocol PaletteCommandProvider: AnyObject {
    var paletteCommands: [PaletteCommand] { get }
}

/// Filters and ranks commands by the string the user typed.
/// Case- and Vietnamese-diacritic-insensitive; a word-prefix match ranks before a mid-string match;
/// every word in the query must appear.
public enum PaletteFilter {
    public static func filter(_ commands: [PaletteCommand], query: String, limit: Int = 50) -> [PaletteCommand] {
        let words = normalize(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return Array(commands.prefix(limit)) }
        let scored = commands.compactMap { command -> (PaletteCommand, Int)? in
            let haystack = normalize(command.title + " " + command.subtitle)
            var score = 0
            for word in words {
                guard let range = haystack.range(of: word) else { return nil }
                let atWordStart = range.lowerBound == haystack.startIndex
                    || haystack[haystack.index(before: range.lowerBound)] == " "
                score += atWordStart ? 2 : 1
            }
            return (command, score)
        }
        return scored
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.1 != rhs.element.1 ? lhs.element.1 > rhs.element.1 : lhs.offset < rhs.offset
            }
            .prefix(limit)
            .map(\.element.0)
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "vi"))
            .replacingOccurrences(of: "đ", with: "d") // i18n-ignore: diacritic folding for search
    }
}

/// Palette UI: search field, list, ↑↓ Enter to run, Esc to close. Custom on purpose: macOS has no command
/// palette control; it is built from a native sheet, `TextField` and `List`, and keeps keyboard focus in the
/// field while ↑↓ move the highlighted row.
public struct CommandPaletteView: View {
    let commands: [PaletteCommand]
    let onClose: @MainActor () -> Void
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    public init(commands: [PaletteCommand], onClose: @escaping @MainActor () -> Void) {
        self.commands = commands
        self.onClose = onClose
    }

    private var results: [PaletteCommand] { PaletteFilter.filter(commands, query: query) }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "command").foregroundStyle(.secondary)
                TextField(text: $query) { Text("Search actions…", bundle: .module) }
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(runSelected)
                    .accessibilityIdentifier("palette.query")
            }
            .padding(SuijinSpacing.l)
            Divider()
            ScrollViewReader { proxy in
                List(Array(results.enumerated()), id: \.element.id) { index, command in
                    HStack {
                        Text(command.title)
                        Spacer()
                        if !command.subtitle.isEmpty { Text(command.subtitle).foregroundStyle(.secondary).font(.caption) }
                        if let shortcut = command.shortcut { Text(shortcut).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .listRowBackground(index == selection ? Color.accentColor.opacity(0.18) : Color.clear)
                    .onTapGesture { selection = index; runSelected() }
                    .id(index)
                }
                .listStyle(.plain)
                .frame(height: 340)
                .onChange(of: selection) { proxy.scrollTo(selection) }
            }
            if results.isEmpty {
                Text("No matching actions", bundle: .module).foregroundStyle(.secondary).padding()
            }
        }
        .frame(width: 600)
        .onAppear { focused = true }
        .onChange(of: query) { selection = 0 }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(results.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
    }

    private func runSelected() {
        guard results.indices.contains(selection) else { return }
        let command = results[selection]
        onClose()
        command.run()
    }
}
