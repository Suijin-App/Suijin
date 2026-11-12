import AppKit
import MercuryCore
import MercuryUI
import SwiftUI

/// The badge of a workspace in the sidebar, kept as quiet as the system's own sidebar icons: a monochrome SF Symbol,
/// an emoji, a picture, or by default the first letter of the name on a neutral tile. A color the user chose tints the
/// glyph only, never a filled background. Custom on purpose: AppKit has no project-avatar control.
struct WorkspaceBadge: View {
    let workspace: Workspace
    let imageDirectory: URL
    var size: CGFloat = 22

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Group {
            switch workspace.icon {
            case .image(let file):
                if let image = NSImage(contentsOf: imageDirectory.appendingPathComponent(file)) {
                    Image(nsImage: image).resizable().scaledToFill()
                        .clipShape(shape)
                        .overlay(shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                } else {
                    monogram(shape)
                }
            case .emoji(let emoji):
                Text(verbatim: emoji).font(.system(size: size * 0.78))
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: size * 0.68))
                    .foregroundStyle(glyphStyle)
            case nil:
                monogram(shape)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var glyphStyle: AnyShapeStyle {
        workspace.color.map { AnyShapeStyle(WorkspacePalette.color(named: $0)) } ?? AnyShapeStyle(.secondary)
    }

    private func monogram(_ shape: RoundedRectangle) -> some View {
        Text(verbatim: String(workspace.name.trimmingCharacters(in: .punctuationCharacters).prefix(1)).uppercased())
            .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
            .foregroundStyle(glyphStyle)
            .frame(width: size, height: size)
            .background(.quaternary, in: shape)
    }
}

/// Glyph colors the user can pick for a badge: the system colors, stored by name, so they adapt to light and dark like
/// the rest of macOS. Without one the badge uses the secondary label color.
enum WorkspacePalette {
    static let colors: [String] = ["blue", "purple", "pink", "red", "orange", "yellow", "green", "teal", "gray"]

    static func color(named name: String) -> Color {
        switch name {
        case "blue": .blue
        case "purple": .purple
        case "pink": .pink
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "teal": .teal
        case "gray": .gray
        default: .secondary
        }
    }
}
