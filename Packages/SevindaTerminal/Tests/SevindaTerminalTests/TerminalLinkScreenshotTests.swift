import AppKit
import Foundation
import Testing
@testable import SevindaTerminal

/// Offscreen renders of underlined paths in a terminal, light and dark, narrow and wide, with and without the hover
/// emphasis. Runs when `SEVINDA_SCREENSHOTS` names an output folder; the images are reviewed by eye. The output imitates
/// a shell, Claude Code and Codex with plain text (no agent runs).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SEVINDA_SCREENSHOTS"] != nil))
struct TerminalLinkScreenshotTests {
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SEVINDA_SCREENSHOTS"] ?? NSTemporaryDirectory())

    static let sample = [
        "\u{1b}[32m~/Code/demo\u{1b}[0m $ ls",
        "Package.swift  README.md  Sources  docs",
        "\u{1b}[32m~/Code/demo\u{1b}[0m $ git status --short",
        " M Sources/App/main.swift",
        "?? docs/plan.md",
        "",
        "\u{1b}[1m⏺\u{1b}[0m Update(Sources/App/main.swift)",
        "  ⎿  Updated Sources/App/main.swift with 3 additions and 1 removal",
        "\u{1b}[1m⏺\u{1b}[0m Read `docs/plan.md` and https://developer.apple.com/documentation/appkit",
        "  ⎿  Edited …/App/Views/Sidebar.swift (elided: not underlined)",
        "",
        "• Edited Sources/App/main.swift:12:4 (+3 -1)",
        "• Ran swift test — see /tmp/demo/build/logs/very/long/path/that/wraps/over/the/edge/of/the/terminal/report.txt",
        "  missing/file.swift is not underlined: it does not exist",
    ]

    private func render(_ name: String, width: CGFloat, dark: Bool, hover: Bool) async throws {
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: width, height: 340), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view = SevindaTerminalView(frame: CGRect(x: 0, y: 0, width: width, height: 340))
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        view.apply(dark ? TerminalThemes.sevindaDark : TerminalThemes.sevindaLight)
        view.apply(fontSize: 13)
        // The files of the imaginary project; anything else does not exist.
        let files: Set<String> = ["Package.swift", "README.md", "Sources", "docs", "Sources/App/main.swift", "docs/plan.md",
                                  "/tmp/demo/build/logs/very/long/path/that/wraps/over/the/edge/of/the/terminal/report.txt"]
        view.linkResolver = { matches in
            matches.map { files.contains($0.text) ? TerminalFileTarget(path: "/Users/demo/Code/demo/" + $0.text, isDirectory: false) : nil }
        }
        let bytes = Array(Self.sample.joined(separator: "\r\n").utf8)
        view.feed(byteArray: bytes[...])
        view.scanLinksNow()
        #expect(await waitUntil(timeout: .seconds(2)) { view.shownLinks.count >= 8 })
        if hover { view.linkController.overlay.emphasized = 1 }
        try await Task.sleep(for: .milliseconds(150))
        // The terminal's background is its layer's color, which caching the display leaves out: paint it first.
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        let composed = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        composed.size = view.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: composed)
        view.nativeBackgroundColor.setFill()
        view.bounds.fill()
        image.draw(in: view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(composed.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }

    @Test func underlinedPaths() async throws {
        for (label, width) in [("narrow", CGFloat(640)), ("wide", CGFloat(1000))] {
            for dark in [false, true] {
                try await render("paths-\(label)", width: width, dark: dark, hover: false)
                try await render("paths-hover-\(label)", width: width, dark: dark, hover: true)
            }
        }
    }
}
