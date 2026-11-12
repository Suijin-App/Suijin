import MercuryTerminal
import MercuryUI
import SwiftUI

/// Settings → Terminal: theme cards with real palette previews, font family and size with a live sample.
struct TerminalSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var families: [String] = TerminalTheme.monospacedFamilies()

    private var themeID: String { model.setting(.terminalTheme) ?? "" }
    private var family: String? { model.setting(.terminalFontFamily) }
    private var fontSize: Double {
        model.setting(.terminalFontSize).flatMap(Double.init) ?? Double(TerminalTheme.defaultFontSize)
    }

    var body: some View {
        Form {
            Section {
                ThemeGrid(selection: themeID, family: family) { id in
                    model.setSetting(.terminalTheme, id.isEmpty ? nil : id)
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("New and visible terminals use the theme. Automatic uses Mercury Light or Mercury Dark to match the appearance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Font family", selection: Binding(
                    get: { family ?? "" },
                    set: { model.setSetting(.terminalFontFamily, $0.isEmpty ? nil : $0) }
                )) {
                    Text("Default (\(TerminalTheme.defaultFamily ?? String(localized: "System Monospaced")))").tag("")
                    ForEach(families, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                LabeledContent("Font size") {
                    HStack(spacing: MercurySpacing.s) {
                        Text("\(Int(fontSize)) pt").monospacedDigit()
                        Stepper("Font size", value: Binding(
                            get: { fontSize },
                            set: { model.setSetting(.terminalFontSize, String($0)) }
                        ), in: Double(TerminalTheme.minimumFontSize)...Double(TerminalTheme.maximumFontSize), step: 1)
                        .labelsHidden()
                    }
                }
            } header: {
                Text("Typography")
            } footer: {
                Text("Only monospaced fonts installed on this Mac are listed. A Nerd Font Mono family is the default when one is installed, so prompt icons render.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Draw terminals with the GPU", isOn: Binding(
                    get: { model.setting(.terminalGPURendering) != "false" },
                    set: { model.setSetting(.terminalGPURendering, $0 ? nil : "false") }
                ))
            } header: {
                Text("Rendering")
            } footer: {
                Text("Metal keeps scrolling smooth in long sessions. Turn it off if text in a terminal draws incorrectly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                FontPreview(theme: TerminalThemes.resolve(id: model.setting(.terminalTheme), isDark: colorScheme == .dark),
                            family: family, size: fontSize)
            } header: {
                Text("Preview")
            } footer: {
                Text("The selected theme and font as terminals draw them in the current appearance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Automatic first, then every built-in theme, light ones before dark ones.
private struct ThemeGrid: View {
    let selection: String
    let family: String?
    let select: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 180), spacing: MercurySpacing.l, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: MercurySpacing.l) {
            SelectableCard(isSelected: selection.isEmpty, title: "Automatic") { select("") } content: {
                TerminalSample(theme: TerminalThemes.mercuryLight, family: family)
                    .overlay {
                        TerminalSample(theme: TerminalThemes.mercuryDark, family: family)
                            .mask(alignment: .trailing) {
                                GeometryReader { proxy in
                                    Rectangle().frame(width: proxy.size.width / 2).frame(maxWidth: .infinity, alignment: .trailing)
                                }
                            }
                    }
            }
            ForEach(TerminalThemes.all) { theme in
                SelectableCard(isSelected: selection == theme.id, title: Text(verbatim: theme.name)) { select(theme.id) } content: {
                    TerminalSample(theme: theme, family: family)
                }
            }
        }
        .padding(.vertical, MercurySpacing.xs)
    }
}

/// A few lines of a shell session drawn in the theme's own colors: a prompt, `git status` and a cursor.
private struct TerminalSample: View {
    let theme: TerminalTheme
    let family: String?

    private func ansi(_ index: Int) -> Color { theme.ansi[index].color }

    var body: some View {
        let foreground = theme.foreground.color
        VStack(alignment: .leading, spacing: 1) {
            Text(colored([("~", ansi(4)), (" main", ansi(5)), (" ❯ ", ansi(2)), ("git status", foreground)]))
            Text(verbatim: "On branch main").foregroundStyle(foreground)
            Text(verbatim: "  modified: App.swift").foregroundStyle(ansi(2))
            Text(verbatim: "  deleted:  Old.swift").foregroundStyle(ansi(1))
            Text(verbatim: "?? Notes.md").foregroundStyle(ansi(3))
            HStack(spacing: 0) {
                Text(verbatim: "❯ ").foregroundStyle(ansi(2))
                Rectangle().fill(theme.cursor.color).frame(width: 4, height: 8)
            }
        }
        .font(Font(TerminalTheme.font(family: family, size: 7.5) as CTFont))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(6)
        .frame(width: 128, height: 76, alignment: .topLeading)
        .background(theme.background.color)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// The chosen font and size on the current theme: a prompt, test output and a diff hunk, so ANSI colors, symbols and
/// ligature-prone pairs show together. Lines clip at the edge instead of wrapping, like a terminal.
private struct FontPreview: View {
    let theme: TerminalTheme
    let family: String?
    let size: Double

    private func ansi(_ index: Int) -> Color { theme.ansi[index].color }

    private func prompt(_ command: String = "") -> Text {
        Text(colored([("~/mercury", ansi(4)), (" main", ansi(5)), (" *", ansi(3)), (" $ ", theme.foreground.color),
                      (command, theme.foreground.color)]))
    }

    var body: some View {
        let foreground = theme.foreground.color
        VStack(alignment: .leading, spacing: 0) {
            prompt("swift test")
            HStack(spacing: 0) {
                Text(verbatim: " PASS ").foregroundStyle(theme.background.color).background(ansi(2))
                Text(verbatim: " Tests/PreviewTests.swift").foregroundStyle(foreground)
            }
            Text(colored([(" ✓", ansi(2)), (" renders sample output ", foreground), ("(3ms)", ansi(8))]))
            Text(verbatim: " ✗ ligatures: => != >= <= ===").foregroundStyle(ansi(1))
            Text(verbatim: " ")
            prompt("git diff")
            Text(verbatim: "@@ -1,2 +1,3 @@").foregroundStyle(ansi(6))
            Text(verbatim: "-let size = 13").foregroundStyle(ansi(1))
            Text(verbatim: "+let size = 14").foregroundStyle(ansi(2))
            HStack(spacing: 0) {
                prompt()
                Rectangle().fill(theme.cursor.color).frame(width: size * 0.6, height: size * 1.1)
            }
        }
        .font(Font(TerminalTheme.font(family: family, size: size) as CTFont))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: true)
        .padding(MercurySpacing.m)
        .frame(maxWidth: .infinity, maxHeight: 260, alignment: .topLeading)
        .clipped()
        .background(theme.background.color, in: .rect(cornerRadius: MercuryRadius.control))
        .overlay {
            RoundedRectangle(cornerRadius: MercuryRadius.control).strokeBorder(.separator, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Terminal preview in \(theme.name)"))
    }
}

/// One line of terminal output: each run of text in its own color.
private func colored(_ runs: [(String, Color)]) -> AttributedString {
    runs.reduce(into: AttributedString()) { line, run in
        var part = AttributedString(run.0)
        part.foregroundColor = run.1
        line += part
    }
}
