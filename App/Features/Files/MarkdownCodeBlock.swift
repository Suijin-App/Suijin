import AppKit
import MarkdownUI
import SuijinUI
import SwiftUI

/// A code block of the Markdown viewer: GitHub's block (monospaced text that scrolls sideways on a rounded
/// background, here in a color that follows the appearance) with a copy button at its top trailing corner. The button
/// sits outside the scroll view, so it stays in place while the code scrolls, and covers only its own area, so the
/// text under the rest of the block can still be selected.
struct MarkdownCodeBlock: View {
    let configuration: CodeBlockConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var copied = false
    @State private var confirmation: Task<Void, Never>?

    /// How long the button shows that the code was copied.
    static let confirmationDuration: Duration = .milliseconds(1500)

    var body: some View {
        ScrollView(.horizontal) {
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.225))
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(.em(0.85))
                }
                .padding(SuijinSpacing.l)
        }
        .background(SuijinColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topTrailing) { copyButton.padding(6) }
        .onHover { isHovered = $0 }
        .markdownMargin(top: 0, bottom: 16)
    }

    /// Always visible, so it is found without hovering; fainter until the pointer is over the block.
    private var copyButton: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.callout)
                .frame(width: 18, height: 18)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .glassButtonStyle()
        .controlSize(.small)
        .opacity(isHovered || copied ? 1 : 0.75)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .animation(reduceMotion ? nil : .default, value: copied)
        .help(copied ? Text("Copied") : Text("Copy"))
        .accessibilityLabel(copied ? Text("Copied") : Text("Copy code"))
    }

    private func copy() {
        Self.copy(configuration.content)
        copied = true
        AccessibilityNotification.Announcement(String(localized: "Copied")).post()
        confirmation?.cancel()
        confirmation = Task {
            try? await Task.sleep(for: Self.confirmationDuration)
            if !Task.isCancelled { copied = false }
        }
    }

    /// Puts a block's code on a pasteboard (the clipboard by default) as plain text.
    static func copy(_ content: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(copyText(content), forType: .string)
    }

    /// What is copied for a block's content: the code without the line break that ends its last line. Blank lines the
    /// author left at the end of the block are part of the code and stay.
    nonisolated static func copyText(_ content: String) -> String {
        guard let last = content.last, last.isNewline else { return content }
        return String(content.dropLast())
    }
}
