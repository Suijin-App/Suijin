import AppKit
import SevindaGit
import SwiftUI
import Testing
@testable import SevindaDiff

@MainActor
struct DiffTextViewTests {
    private func window(for view: NSView, size: NSSize, dark: Bool = false) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        window.layoutIfNeeded()
        return window
    }

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @Test func showsTextAndGutterForSmallDiff() async {
        let view = DiffTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = window(for: view, size: view.frame.size)
        defer { window.close() }
        view.setDiff(Fixtures.swiftDiff, language: "swift")
        await view.highlightingCompleted()
        window.displayIfNeeded()
        #expect(view.textView.string == view.layout.text)
        #expect(view.textView.textLayoutManager != nil) // TextKit 2, not a TextKit 1 fallback
        #expect(view.gutter.ruleThickness > 40)
        #expect(!view.textView.isEditable && view.textView.isSelectable)
        // Setting the same diff again keeps the text storage untouched.
        let storage = view.textView.textStorage
        view.setDiff(Fixtures.swiftDiff, language: "swift")
        #expect(view.textView.textStorage === storage && view.textView.string == view.layout.text)
    }

    @Test func replacingTheDiffDropsPreviousHighlights() async throws {
        let view = DiffTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = window(for: view, size: view.frame.size)
        defer { window.close() }
        let layoutManager = try #require(view.textView.textLayoutManager)
        func coloredRuns() -> Int {
            var count = 0
            layoutManager.enumerateRenderingAttributes(from: layoutManager.documentRange.location, reverse: false) { _, attributes, _ in
                if attributes[.foregroundColor] != nil { count += 1 }
                return true
            }
            return count
        }
        view.setDiff(Fixtures.swiftDiff, language: "swift")
        await view.highlightingCompleted()
        #expect(coloredRuns() > 0)
        view.setDiff(Fixtures.largeSwiftDiff(lineCount: 20), language: nil)
        #expect(coloredRuns() == 0)
    }

    /// Regression: on screen the ruler received a dirty rect wider than itself and, unclipped, painted its
    /// opaque background over the whole text column (offscreen per-view captures could not show it).
    @Test func gutterNeverPaintsOutsideItsBounds() throws {
        let view = DiffTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let window = window(for: view, size: view.frame.size)
        defer { window.close() }
        view.setDiff(Fixtures.swiftDiff, language: nil)
        window.displayIfNeeded()
        let gutter = view.gutter
        #expect(gutter.clipsToBounds)

        // Draw with a dirty rect three times the gutter's width into a transparent bitmap.
        let width = Int(gutter.bounds.width) * 3
        let height = Int(gutter.bounds.height)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        gutter.draw(NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        NSGraphicsContext.restoreGraphicsState()

        let inside = try #require(rep.colorAt(x: Int(gutter.bounds.width) / 2, y: height / 2))
        let outside = try #require(rep.colorAt(x: width - 2, y: height / 2))
        #expect(inside.alphaComponent > 0.9)
        #expect(outside.alphaComponent == 0)
    }

    @Test func dynamicColorsFollowAppearance() {
        func resolved(_ color: NSColor, _ name: NSAppearance.Name) -> NSColor? {
            var result: NSColor?
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) }
            return result
        }
        #expect(resolved(DiffTheme.background, .aqua) != resolved(DiffTheme.background, .darkAqua))
        #expect(resolved(DiffTheme.addedBackground, .aqua)?.alphaComponent ?? 1 < 0.3)
    }

    /// The spike measurement: a 5,000-line diff in a 900×700 window, then 40 scroll steps through it.
    @Test func largeDiffLaysOutOnlyTheViewport() async {
        let diff = Fixtures.largeSwiftDiff(lineCount: 5_000)
        let view = DiffTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let window = window(for: view, size: view.frame.size)
        defer { window.close() }
        let clock = ContinuousClock()

        let load = clock.measure {
            view.setDiff(diff, language: nil)
            window.displayIfNeeded()
        }
        var steps: [Duration] = []
        let height = view.textView.frame.height
        for step in 1...40 {
            let y = height * CGFloat(step) / 41
            steps.append(clock.measure {
                view.textView.scroll(NSPoint(x: 0, y: y))
                window.displayIfNeeded()
            })
        }
        let highlightStart = clock.now
        view.setDiff(diff, language: "swift")
        await view.highlightingCompleted()
        let highlight = clock.now - highlightStart

        let sorted = steps.sorted()
        let average = steps.reduce(.zero, +) / steps.count
        print("[spike] TextKit 2 5,000 lines: load+first display \(load), scroll step avg \(average) p95 \(sorted[37]) max \(sorted[39]), highlight+apply \(highlight)")
        #expect(load < .milliseconds(1_000))
        #expect(average < .milliseconds(50))
        #expect(highlight < .seconds(5))
    }

    // MARK: - Snapshots (visual check)

    /// Renders the SwiftUI wrapper offscreen to PNGs. Opt-in: `SEVINDA_DIFF_SNAPSHOTS=<dir> swift test`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEVINDA_DIFF_SNAPSHOTS"] != nil))
    func snapshots() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SEVINDA_DIFF_SNAPSHOTS"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cases: [(String, FileDiff, String?)] = [
            ("swift", Fixtures.screenshotDiff, "swift"),
            ("large", Fixtures.largeSwiftDiff(lineCount: 5_000), "swift"),
        ]
        for (name, diff, language) in cases {
            for width in [600, 1200] as [CGFloat] {
                for dark in [false, true] {
                    let host = NSHostingView(rootView: DiffDocumentView(diff: diff, language: language))
                    host.sizingOptions = [] // fill the window like a pane, not the placeholder's ideal size
                    let size = NSSize(width: width, height: 560)
                    host.frame = NSRect(origin: .zero, size: size)
                    let window = window(for: host, size: size, dark: dark)
                    spin()
                    if let container = host.firstDescendant(of: DiffDocumentContainerView.self) {
                        if name == "large" {
                            container.textView.textView.scroll(NSPoint(x: 0, y: container.textView.textView.frame.height / 2))
                        }
                        await container.textView.highlightingCompleted()
                    }
                    spin(0.2)
                    window.displayIfNeeded()
                    let file = directory.appendingPathComponent("diff-\(name)-\(Int(width))-\(dark ? "dark" : "light").png")
                    try snapshot(host, to: file)
                    window.close()
                }
            }
        }
    }

    /// Placeholders are pure SwiftUI, which offscreen windows do not draw through `cacheDisplay`;
    /// `ImageRenderer` renders them on the pane background they appear on.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEVINDA_DIFF_SNAPSHOTS"] != nil))
    func placeholderSnapshots() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SEVINDA_DIFF_SNAPSHOTS"]))
        for (name, state) in [("binary", DiffPlaceholder.State.binary), ("nochanges", .noChanges)] {
            for width in [600, 1200] as [CGFloat] {
                for dark in [false, true] {
                    let content = DiffPlaceholder(state: state)
                        .frame(width: width, height: 560)
                        .background(Color(nsColor: DiffTheme.background))
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 2
                    let image = try #require(renderer.cgImage)
                    let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    try data.write(to: directory.appendingPathComponent("diff-\(name)-\(Int(width))-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    @Test func containerSwapsBetweenTextAndPlaceholder() {
        let container = DiffDocumentContainerView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        container.show(FileDiff(oldPath: "a.png", newPath: "a.png", isBinary: true), language: nil)
        #expect(container.textView.isHidden)
        #expect(container.firstDescendant(of: NSHostingView<DiffPlaceholder>.self)?.isHidden == false)
        container.show(Fixtures.swiftDiff, language: "swift")
        #expect(!container.textView.isHidden)
        #expect(container.firstDescendant(of: NSHostingView<DiffPlaceholder>.self)?.isHidden == true)
        container.show(FileDiff(oldPath: "a", newPath: "b"), language: nil)
        #expect(container.textView.isHidden)
    }

    /// Captures text through the print (PDF) drawing path, then rasterizes at 2x. `cacheDisplay` and
    /// `CALayer.render(in:)` both miss TextKit 2 text, whose fragment layers hold IOSurface contents.
    private func snapshot(_ view: NSView, to url: URL) throws {
        let pdf = view.dataWithPDF(inside: view.bounds)
        let page = try #require(NSPDFImageRep(data: pdf))
        let scale: CGFloat = 2
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
                                                pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = view.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        page.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}

extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstDescendant(of: type) { return match }
        }
        return nil
    }
}

extension Fixtures {
    static let screenshotDiff = FileDiff(oldPath: "Sources/Sevinda/SessionStore.swift", newPath: "Sources/Sevinda/SessionStore.swift", hunks: [
        DiffHunk(header: "@@ -12,9 +12,11 @@ final class SessionStore {", oldStart: 12, oldCount: 9, newStart: 12, newCount: 11, lines: [
            DiffLine(kind: .context, text: "    /// Sessions keyed by worktree path.", oldLine: 12, newLine: 12),
            DiffLine(kind: .context, text: "    private var sessions: [URL: Session] = [:]", oldLine: 13, newLine: 13),
            DiffLine(kind: .deleted, text: "    private let limit = 8", oldLine: 14, newLine: nil),
            DiffLine(kind: .added, text: "    private let limit: Int", oldLine: nil, newLine: 14),
            DiffLine(kind: .added, text: "    private let clock = ContinuousClock()", oldLine: nil, newLine: 15),
            DiffLine(kind: .context, text: "", oldLine: 15, newLine: 16),
            DiffLine(kind: .deleted, text: "    func start(_ agent: Agent, in worktree: URL) async throws -> Session {", oldLine: 16, newLine: nil),
            DiffLine(kind: .added, text: "    func start(_ agent: Agent, in worktree: URL, environment: [String: String] = [:], timeout: Duration = .seconds(30)) async throws -> Session {", oldLine: nil, newLine: 17),
            DiffLine(kind: .context, text: "        guard sessions.count < limit else { throw SessionError.tooMany(limit) }", oldLine: 17, newLine: 18),
            DiffLine(kind: .context, text: "\tlet session = try await agent.launch(at: worktree) // \"tab-indented\"", oldLine: 18, newLine: 19),
            DiffLine(kind: .added, text: "        session.deadline = clock.now + timeout", oldLine: nil, newLine: 20),
            DiffLine(kind: .context, text: "        sessions[worktree] = session", oldLine: 19, newLine: 21),
            DiffLine(kind: .context, text: "        return session", oldLine: 20, newLine: 22),
        ]),
        DiffHunk(header: "@@ -998,3 +1000,3 @@ extension SessionStore {", oldStart: 998, oldCount: 3, newStart: 1000, newCount: 3, lines: [
            DiffLine(kind: .context, text: "    /* Debug summary,", oldLine: 998, newLine: 1000),
            DiffLine(kind: .deleted, text: "       one line per session */ var summary: String { \"\\(sessions.count)\" }", oldLine: 999, newLine: nil),
            DiffLine(kind: .added, text: "       one line per session */ var summary: String { sessions.keys.map(\\.path).joined(separator: \"\\n\") }", oldLine: nil, newLine: 1001),
            DiffLine(kind: .noNewlineMarker, text: "\\ No newline at end of file", oldLine: nil, newLine: nil),
        ]),
    ])
}
