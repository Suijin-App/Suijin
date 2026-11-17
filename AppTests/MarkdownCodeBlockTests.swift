import AppKit
import MarkdownUI
import SwiftUI
import Testing
@testable import Suijin

/// The copy button of the Markdown viewer's code blocks: what it copies, and (with `SUIJIN_SCREENSHOTS` set) how the
/// blocks look at a narrow and a wide width, light and dark.
@MainActor
@Suite(.serialized)
struct MarkdownCodeBlockTests {
    @Test("the copied text is the code without the line break that ends it", arguments: [
        ("swift build\n", "swift build"),
        ("let a = 1\nlet b = 2\n", "let a = 1\nlet b = 2"),
        ("", ""),
        ("\n", ""),
        ("no line break", "no line break"),
        ("ends with blank lines\n\n\n", "ends with blank lines\n\n"),
        ("windows\r\n", "windows"),
        ("  indented\n\ttabbed\n", "  indented\n\ttabbed"),
    ])
    func copyText(content: String, expected: String) {
        #expect(MarkdownCodeBlock.copyText(content) == expected)
    }

    @Test("copying replaces the pasteboard's content with the whole block as plain text")
    func copyWritesThePasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("suijin.test.codeblock.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("earlier", forType: .string)
        let line = String(repeating: "a very long line that scrolls out of view ", count: 20)
        MarkdownCodeBlock.copy("\(line)\nsecond line\n", to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "\(line)\nsecond line")
    }

    @Test("the button shows the confirmation for about a second and a half")
    func confirmationDuration() {
        #expect(MarkdownCodeBlock.confirmationDuration == .seconds(1.5))
    }

    private static let sample = """
    # Copy buttons

    A block of one long line, with a language:

    ```sh
    xcodebuild -project Suijin.xcodeproj -scheme Suijin -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -allowProvisioningUpdates test
    ```

    A block of several lines, without a language:

    ```
    Outcome
      1. Open a Markdown file
      2. Press the copy button
      3. Paste anywhere
    ```

    A short one: `inline code` has no button.

    ```swift
    let x = 1
    ```
    """

    @Test("code blocks render with their copy button", .enabled(if: ProcessInfo.processInfo.environment["SUIJIN_SCREENSHOTS"] != nil),
          arguments: [("narrow", 460.0), ("wide", 1000.0)], [false, true])
    func screenshots(size: (String, Double), dark: Bool) throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SUIJIN_SCREENSHOTS"] ?? NSTemporaryDirectory())
        let content = ScrollView {
            Markdown(Self.sample)
                .markdownTheme(.suijin)
                .textSelection(.enabled)
                .frame(maxWidth: 860, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        let window = OffscreenWindow(contentRect: CGRect(x: 0, y: 0, width: size.1, height: 620), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: content)
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("markdown-code-\(size.0)-\(dark ? "dark" : "light").png"))
    }
}
