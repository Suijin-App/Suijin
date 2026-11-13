import AppKit
import SwiftUI

/// The `Lệnh tương đương` (equivalent command) strip under every operation: shows the real shell command and lets the user copy it.
/// Every feature that changes the server must show this strip (SPEC §6.1). Custom on purpose: no system view
/// shows a selectable one-line command with a copy button; it is built from native `Text` and a borderless button.
public struct CommandEquivalentView: View {
    let command: String
    @State private var copied = false

    public init(_ command: String) {
        self.command = command
    }

    public var body: some View {
        HStack(spacing: SuijinSpacing.s) {
            Text("Equivalent command", bundle: .module).font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(command)
                    .font(SuijinFont.monoSmall)
                    .textSelection(.enabled)
                    .lineLimit(1)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            } label: {
                Label { copied ? Text("Copied", bundle: .module) : Text("Copy", bundle: .module) } icon: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
            }
            .buttonStyle(.borderless)
            .help(Text("Copy Command", bundle: .module))
        }
        .padding(.horizontal, SuijinSpacing.m)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: SuijinRadius.control).fill(SuijinColor.codeBackground))
        .overlay(
            RoundedRectangle(cornerRadius: SuijinRadius.control)
                .strokeBorder(SuijinColor.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .onChange(of: command) { copied = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Equivalent command", bundle: .module))
    }
}
