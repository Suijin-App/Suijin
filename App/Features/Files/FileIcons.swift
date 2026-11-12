import AppKit
import UniformTypeIdentifiers

/// File icons by type, as Finder shows them (including types apps declare, such as `.tsx` from an editor), rendered
/// once into a bitmap and cached by extension. System icons draw lazily: an icon handed straight to SwiftUI can first
/// draw as the generic document and never redraw, and asking per file returned a placeholder that changed after a
/// click. A rendered bitmap is the same image everywhere.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(forPath path: String, isDirectory: Bool = false) -> NSImage {
        let ext = isDirectory ? "/folder" : (path as NSString).pathExtension.lowercased()
        if let cached = cache[ext] { return cached }
        let image: NSImage
        if !isDirectory, let badge = badges[ext] {
            image = Self.badge(badge.text, color: badge.color)
        } else {
            image = rendered(NSWorkspace.shared.icon(for: isDirectory ? .folder : type(forExtension: ext)))
        }
        cache[ext] = image
        return image
    }

    /// The file's icon at 128 pt (the audio player shows it large), cached by extension like `icon(forPath:)`.
    static func largeIcon(forPath path: String) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        if let cached = largeCache[ext] { return cached }
        let image = rendered(NSWorkspace.shared.icon(for: type(forExtension: ext)), points: 128)
        largeCache[ext] = image
        return image
    }

    private static var largeCache: [String: NSImage] = [:]

    /// The extension's type; media containers no installed app declares (`.mkv`, `.opus`) get the movie or audio
    /// icon instead of a blank document.
    private static func type(forExtension ext: String) -> UTType {
        let type = UTType(filenameExtension: ext)
        if type?.isDeclared != true, MediaProbe.mediaExtensions.contains(ext) {
            return MediaProbe.audioExtensions.contains(ext) ? .audio : .movie
        }
        return type ?? .data
    }

    /// Source types macOS draws as a blank page (or mistakes: `.ts` resolves to an MPEG video type), shown as a
    /// labelled badge in the language's usual color, as code editors do.
    private static let badges: [String: (text: String, color: NSColor)] = {
        let ts = (text: "TS", color: NSColor(srgbRed: 0.19, green: 0.47, blue: 0.78, alpha: 1))
        let js = (text: "JS", color: NSColor(srgbRed: 0.85, green: 0.70, blue: 0.10, alpha: 1))
        let json = (text: "{}", color: NSColor(srgbRed: 0.80, green: 0.50, blue: 0.10, alpha: 1))
        let markdown = (text: "MD", color: NSColor(srgbRed: 0.35, green: 0.40, blue: 0.48, alpha: 1))
        let yaml = (text: "YML", color: NSColor(srgbRed: 0.60, green: 0.20, blue: 0.25, alpha: 1))
        let shell = (text: "SH", color: NSColor(srgbRed: 0.25, green: 0.55, blue: 0.30, alpha: 1))
        let html = (text: "<>", color: NSColor(srgbRed: 0.89, green: 0.30, blue: 0.15, alpha: 1))
        let css = (text: "CSS", color: NSColor(srgbRed: 0.40, green: 0.30, blue: 0.75, alpha: 1))
        return [
            "ts": ts, "tsx": ts, "mts": ts, "cts": ts,
            "js": js, "jsx": js, "mjs": js, "cjs": js,
            "json": json, "jsonc": json,
            "md": markdown, "markdown": markdown, "mdx": markdown,
            "yml": yaml, "yaml": yaml, "toml": (text: "TML", color: yaml.color),
            "sh": shell, "zsh": shell, "bash": shell,
            "html": html, "htm": html, "xml": html,
            "css": css, "scss": css,
            "py": (text: "PY", color: NSColor(srgbRed: 0.22, green: 0.44, blue: 0.65, alpha: 1)),
            "go": (text: "GO", color: NSColor(srgbRed: 0.00, green: 0.62, blue: 0.75, alpha: 1)),
            "rs": (text: "RS", color: NSColor(srgbRed: 0.72, green: 0.33, blue: 0.20, alpha: 1)),
            "kt": (text: "KT", color: NSColor(srgbRed: 0.50, green: 0.35, blue: 0.85, alpha: 1)),
            "java": (text: "JV", color: NSColor(srgbRed: 0.75, green: 0.35, blue: 0.20, alpha: 1)),
            "sql": (text: "SQL", color: NSColor(srgbRed: 0.30, green: 0.45, blue: 0.60, alpha: 1)),
        ]
    }()

    /// A rounded tile in the language color with its short name in white, drawn at 64 px.
    private static func badge(_ text: String, color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 6), xRadius: 12, yRadius: 12)
            color.setFill()
            tile.fill()
            let size: CGFloat = text.count >= 3 ? 19 : 25
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .heavy), .foregroundColor: NSColor.white,
            ]
            let label = text as NSString
            let measured = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: (rect.width - measured.width) / 2, y: (rect.height - measured.height) / 2), withAttributes: attributes)
            return true
        }
        return rendered(image)
    }

    /// Draws the icon at 2× of `points` (32 pt, the most the file views use) now, so nothing is resolved later.
    private static func rendered(_ icon: NSImage, points: CGFloat = 32) -> NSImage {
        var rect = NSRect(x: 0, y: 0, width: points * 2, height: points * 2)
        guard let cgImage = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return icon }
        return NSImage(cgImage: cgImage, size: NSSize(width: points, height: points))
    }
}
