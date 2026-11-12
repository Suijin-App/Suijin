import AppKit
import Foundation
import SevindaCore
import SevindaGit

/// Changing how a workspace looks in the sidebar: icon and badge color.
extension AppModel {
    var workspaceIconDirectory: URL { dataRoot.appendingPathComponent("workspace-icons", isDirectory: true) }

    func setAppearance(of id: UUID, icon: WorkspaceIcon?, color: String?) async {
        guard var workspace = workspace(id) else { return }
        let oldImage: String? = if case .image(let file)? = workspace.icon { file } else { nil }
        workspace.icon = icon
        workspace.color = color
        await update(workspace)
        if let oldImage, icon != .image(oldImage) {
            try? FileManager.default.removeItem(at: workspaceIconDirectory.appendingPathComponent(oldImage))
        }
    }

    /// Uses a picture the user chose, scaled to 128 × 128 PNG and kept in the data root (the original may move).
    func importIcon(from url: URL, for id: UUID) async {
        await perform(String(localized: "Could not use this picture")) {
            guard let image = NSImage(contentsOf: url), let png = Self.squarePNG(image) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try await self.saveIcon(png, for: id)
        }
    }

    /// The avatar of the repository's GitHub owner (`origin` on github.com), fetched once when the user asks.
    func useGitHubAvatar(for id: UUID) async {
        await perform(String(localized: "Could not get the GitHub avatar")) {
            guard let workspace = self.workspace(id), let owner = await Self.githubOwner(of: workspace) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: String(localized: "This repository has no GitHub remote named origin.")])
            }
            var components = URLComponents(string: "https://github.com")!
            components.path = "/\(owner).png"
            components.queryItems = [URLQueryItem(name: "size", value: "128")]
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data), let png = Self.squarePNG(image) else {
                throw URLError(.badServerResponse)
            }
            try await self.saveIcon(png, for: id)
        }
    }

    /// Whether `origin` points at github.com, for showing the avatar option.
    static func githubOwner(of workspace: Workspace) async -> String? {
        guard workspace.kind == .git,
              let data = try? await GitRunner().run(["remote", "get-url", "origin"], in: URL(fileURLWithPath: workspace.path, isDirectory: true)),
              let remote = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        // git@github.com:owner/repo.git, https://github.com/owner/repo(.git), ssh://git@github.com/owner/repo
        let pattern = #"github\.com[:/]([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))/"#
        guard let match = remote.range(of: pattern, options: .regularExpression) else { return nil }
        let owner = remote[match].split(whereSeparator: { $0 == ":" || $0 == "/" }).dropFirst().first.map(String.init)
        return owner
    }

    private func saveIcon(_ png: Data, for id: UUID) async throws {
        try FileManager.default.createDirectory(at: workspaceIconDirectory, withIntermediateDirectories: true)
        // A new file name each time, so the badge reloads instead of showing a cached picture.
        let file = "\(id.uuidString)-\(Int(Date().timeIntervalSince1970)).png"
        try png.write(to: workspaceIconDirectory.appendingPathComponent(file), options: .atomic)
        await setAppearance(of: id, icon: .image(file), color: workspace(id)?.color)
    }

    /// The image center-cropped to a square and scaled to 128 px.
    static func squarePNG(_ image: NSImage) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = min(source.width, source.height)
        let crop = CGRect(x: (source.width - side) / 2, y: (source.height - side) / 2, width: side, height: side)
        guard let square = source.cropping(to: crop),
              let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: 128, height: 128))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }
}
