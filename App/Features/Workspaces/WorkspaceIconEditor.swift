import AppKit
import SevindaCore
import SevindaUI
import SwiftUI

/// Popover to pick a workspace's icon (symbol, emoji, picture, GitHub avatar, or the default letter) and color.
struct WorkspaceIconEditor: View {
    @Environment(AppModel.self) private var model
    let workspaceID: UUID
    @State private var emoji = ""
    @State private var githubOwner: String?

    static let symbols = [
        "folder.fill", "chevron.left.forwardslash.chevron.right", "terminal.fill", "server.rack", "cpu.fill",
        "shippingbox.fill", "globe", "sparkles", "hammer.fill", "paintpalette.fill", "cube.fill", "bolt.fill",
        "brain.head.profile", "iphone", "desktopcomputer", "cloud.fill", "lock.fill", "book.fill",
    ]

    var body: some View {
        if let workspace = model.workspace(workspaceID) {
            VStack(alignment: .leading, spacing: MercurySpacing.m) {
                HStack(spacing: MercurySpacing.m) {
                    WorkspaceBadge(workspace: workspace, imageDirectory: model.workspaceIconDirectory, size: 40)
                    VStack(alignment: .leading) {
                        Text(verbatim: workspace.name).font(.headline).lineLimit(1)
                        Text("Icon and color in the sidebar").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("Symbol").font(.subheadline.weight(.semibold))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 9), spacing: 6) {
                    ForEach(Self.symbols, id: \.self) { name in
                        Button { set(icon: .symbol(name), color: workspace.color) } label: {
                            Image(systemName: name)
                                .font(.system(size: 14))
                                .frame(width: 30, height: 30)
                                .background(workspace.icon == .symbol(name) ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(Text(verbatim: name))
                        .accessibilityLabel(Text(verbatim: name))
                    }
                }
                Text("Color").font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    Button { set(icon: workspace.icon, color: nil) } label: {
                        Circle().fill(.secondary)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.primary.opacity(workspace.color == nil ? 0.8 : 0), lineWidth: 2).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .help(Text("Default (follows the system)"))
                    .accessibilityLabel(Text("Default color"))
                    ForEach(WorkspacePalette.colors, id: \.self) { hex in
                        let selected = workspace.color == hex
                        Button { set(icon: workspace.icon, color: hex) } label: {
                            Circle().fill(WorkspacePalette.color(named: hex))
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(.primary.opacity(selected ? 0.8 : 0), lineWidth: 2).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: hex))
                    }
                }
                HStack {
                    TextField("Emoji", text: $emoji, prompt: Text(verbatim: "🚀"))
                        .frame(width: 70)
                        .onSubmit(applyEmoji)
                    Button("Use Emoji", action: applyEmoji).disabled(emoji.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Divider()
                HStack {
                    Button("Choose Picture…", action: choosePicture)
                    if githubOwner != nil {
                        Button("GitHub Avatar") { Task { await model.useGitHubAvatar(for: workspaceID) } }
                            .help(Text("Download the avatar of \(githubOwner ?? "") from github.com"))
                    }
                    Spacer()
                    Button("Reset") { set(icon: nil, color: nil) }
                }
            }
            .padding(MercurySpacing.l)
            .frame(width: 340)
            .task { githubOwner = await AppModel.githubOwner(of: workspace) }
        }
    }

    private func set(icon: WorkspaceIcon?, color: String?) {
        Task { await model.setAppearance(of: workspaceID, icon: icon, color: color) }
    }

    private func applyEmoji() {
        // One grapheme: the first emoji the user typed.
        guard let first = emoji.trimmingCharacters(in: .whitespaces).first else { return }
        set(icon: .emoji(String(first)), color: model.workspace(workspaceID)?.color)
        emoji = ""
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Use Picture")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.importIcon(from: url, for: workspaceID) }
    }
}
