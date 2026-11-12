import AppKit
import MarkdownUI
import MercuryDiff
import MercuryUI
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// A file opened from a terminal link: Markdown rendered natively, images shown, other text in a monospaced read-only
/// view; anything else offers to open in its default app. Reloads when the file changes (agents edit plans as you read).
struct FileViewer: View {
    let path: String
    @State private var content: Content = .loading
    @State private var watcher: DirectoryWatcher?
    @State private var code = CodeViewController()
    @State private var zoom = ImageZoomController()

    enum Content {
        case loading
        case markdown(String)
        case text(String)
        /// Source code in a language the highlighter knows.
        case code(String, language: String)
        case pdf
        case image(NSImage)
        case unsupported
        case missing
    }

    /// Larger files are not loaded whole; they open in their default app instead.
    nonisolated static let maximumTextSize = 2 * 1024 * 1024

    private var url: URL { URL(fileURLWithPath: path) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch content {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .markdown(let text):
                    let document = MarkdownDocument(text)
                    ScrollView {
                        VStack(alignment: .leading, spacing: MercurySpacing.l) {
                            if !document.frontMatter.isEmpty {
                                FrontMatterView(fields: document.frontMatter)
                            }
                            Markdown(document.body, baseURL: url.deletingLastPathComponent(), imageBaseURL: url.deletingLastPathComponent())
                                .markdownTheme(.mercury)
                                .textSelection(.enabled)
                        }
                            .frame(maxWidth: 860, alignment: .leading)
                            .padding(.horizontal, MercurySpacing.xl)
                            .padding(.vertical, MercurySpacing.l)
                            .frame(maxWidth: .infinity)
                    }
                    .environment(\.openURL, OpenURLAction { link in
                        NSWorkspace.shared.open(link)
                        return .handled
                    })
                case .code(let text, let language):
                    CodeTextView(text: text, language: language, controller: code)
                case .pdf:
                    PDFDocumentView(url: url)
                case .text(let text):
                    ScrollView([.vertical, .horizontal]) {
                        Text(verbatim: text)
                            .font(MercuryFont.mono)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(MercurySpacing.l)
                    }
                    .background(MercuryColor.codeBackground)
                case .image(let image):
                    ZoomableImageView(image: image, controller: zoom)
                case .unsupported:
                    ContentUnavailableView {
                        Label("No Preview", systemImage: "doc")
                    } description: {
                        Text("Mercury shows Markdown, code, text, images and PDFs. Open this file in its default app instead.")
                    } actions: {
                        Button("Open in Default App") { NSWorkspace.shared.open(url) }.glassButtonStyle()
                    }
                case .missing:
                    ContentUnavailableView("File Not Found", systemImage: "questionmark.folder",
                                           description: Text(verbatim: path))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: path) { await load() }
        .onAppear {
            watcher?.stop()
            watcher = DirectoryWatcher(directory: url.deletingLastPathComponent()) {
                Task { await load() }
            }
        }
        .onDisappear {
            watcher?.stop()
            watcher = nil
        }
    }

    private var header: some View {
        HStack(spacing: MercurySpacing.s) {
            Image(nsImage: FileIcons.icon(forPath: path))
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: MercurySpacing.s)
            headerControls
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            Button { NSWorkspace.shared.open(url) } label: {
                Label("Open in Default App", systemImage: "arrow.up.forward.app")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, MercurySpacing.l)
        .padding(.vertical, 6)
    }

    /// Per kind: the symbol menu for code, zoom buttons for images.
    @ViewBuilder
    private var headerControls: some View {
        switch content {
        case .code(let text, let language):
            let symbols = CodeSymbols.symbols(in: text, language: language)
            if !symbols.isEmpty {
                Menu {
                    ForEach(symbols, id: \.self) { symbol in
                        Button {
                            code.scroll(toLine: symbol.line)
                        } label: {
                            Label {
                                Text(verbatim: String(repeating: "  ", count: min(symbol.depth, 6)) + symbol.name)
                            } icon: {
                                Image(systemName: symbol.kind == .type ? "t.square" : "f.square")
                            }
                        }
                    }
                } label: {
                    Label("Symbols", systemImage: "list.bullet.indent")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(Text("Jump to a type or function (\(symbols.count))"))
            }
        case .image:
            HStack(spacing: 2) {
                Button { zoom.zoom(by: 1 / 1.25) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                    .keyboardShortcut("-", modifiers: .command)
                Button { zoom.fit() } label: { Label("Fit", systemImage: "arrow.down.right.and.arrow.up.left") }
                    .keyboardShortcut("0", modifiers: .command)
                Button { zoom.actualSize() } label: { Label("Actual Size", systemImage: "1.magnifyingglass") }
                Button { zoom.zoom(by: 1.25) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                    .keyboardShortcut("=", modifiers: .command)
            }
        default:
            EmptyView()
        }
    }

    private func load() async {
        let url = url
        content = await Task.detached { Self.read(url) }.value
    }

    nonisolated static func read(_ url: URL) -> Content {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return .missing }
        let size = (attributes[.size] as? Int) ?? 0
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased()) {
            guard size <= maximumTextSize, let text = try? String(contentsOf: url, encoding: .utf8) else { return .unsupported }
            return .markdown(text)
        }
        if let type, type.conforms(to: .pdf) { return .pdf }
        if let type, type.conforms(to: .image), let image = NSImage(contentsOf: url) { return .image(image) }
        guard size <= maximumTextSize, let data = try? Data(contentsOf: url) else { return .unsupported }
        // Text is whatever decodes as UTF-8 without NUL bytes, so source files with unknown extensions still show.
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return .unsupported }
        if let language = SyntaxHighlighter.language(forPath: url.path) { return .code(text, language: language) }
        return .text(text)
    }
}

/// A Markdown file split into its YAML front matter (`---` … `---` at the top, as plans and docs use) and its body.
/// The front matter is shown as fields; Markdown would otherwise read it as a setext heading.
struct MarkdownDocument {
    let frontMatter: [(key: String, value: String)]
    let body: String

    init(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            frontMatter = []
            body = text
            return
        }
        frontMatter = lines[1..<end].compactMap { line in
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { return nil }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return key.isEmpty ? nil : (key, value)
        }
        body = lines[(end + 1)...].joined(separator: "\n")
    }
}

/// Front matter fields in a native two-column grid on a quiet card.
private struct FrontMatterView: View {
    let fields: [(key: String, value: String)]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: MercurySpacing.l, verticalSpacing: 6) {
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                GridRow {
                    Text(verbatim: field.key).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(verbatim: field.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .padding(MercurySpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: MercuryRadius.card))
    }
}

/// Scroll commands for the code view (the header's symbol menu jumps to a line).
@MainActor
final class CodeViewController {
    weak var textView: NSTextView?

    func scroll(toLine line: Int) {
        guard let textView, let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        var location = 0, current = 1
        while current < line, location < text.length {
            location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
            current += 1
        }
        let range = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        textView.scrollRangeToVisible(range)
        textView.setSelectedRange(range)
        textView.showFindIndicator(for: range)
    }
}

/// Read-only source code with a line-number gutter, highlighted in the background with the diff viewer's
/// tree-sitter grammars. TextKit 1 here: the line-number ruler measures line fragments through the layout manager.
private struct CodeTextView: NSViewRepresentable {
    let text: String
    let language: String
    let controller: CodeViewController

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.backgroundColor = NSColor(MercuryColor.codeBackground)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scrollView = OverlayScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = textView.backgroundColor
        let ruler = LineNumberRuler(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        ruler.follow(scrollView.contentView)
        controller.textView = textView
        apply(to: textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        controller.textView = textView
        guard context.coordinator.shown != text else { return }
        apply(to: textView, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown: String?
        var task: Task<Void, Never>?
    }

    private func apply(to textView: NSTextView, coordinator: Coordinator) {
        coordinator.shown = text
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: LineNumberRuler.font, .foregroundColor: NSColor.labelColor,
        ]))
        (textView.enclosingScrollView?.verticalRulerView as? LineNumberRuler)?.textDidChange()
        coordinator.task?.cancel()
        let text = text, language = language
        coordinator.task = Task { @MainActor [weak textView] in
            let spans = await SyntaxHighlighter.highlight(text, language: language)
            guard !Task.isCancelled, let storage = textView?.textStorage, storage.string == text else { return }
            storage.beginEditing()
            for span in spans where NSMaxRange(span.range) <= storage.length {
                storage.addAttribute(.foregroundColor, value: span.token.color, range: span.range)
            }
            storage.endEditing()
        }
    }
}

/// Line numbers beside a TextKit 1 text view: only the visible lines are measured and drawn. Custom on purpose:
/// AppKit has no line-number ruler.
private final class LineNumberRuler: NSRulerView {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private weak var textView: NSTextView?
    /// UTF-16 offsets where each line starts.
    private var lineStarts: [Int] = [0]

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    /// Redraws the numbers as the code scrolls.
    func follow(_ clipView: NSClipView) {
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: clipView)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func boundsChanged() { needsDisplay = true }

    func textDidChange() {
        guard let text = textView?.string as NSString? else { return }
        var starts = [0]
        var index = 0
        while index < text.length {
            index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
            if index < text.length { starts.append(index) }
        }
        lineStarts = starts
        let digits = max(3, String(starts.count).count)
        ruleThickness = CGFloat(digits) * 8 + 16
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor(MercuryColor.codeBackground).setFill()
        bounds.fill()
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = (lineStarts.lastIndex { $0 <= characters.location } ?? 0)
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.numberFont, .foregroundColor: NSColor.tertiaryLabelColor]
        let origin = convert(NSPoint.zero, from: textView)
        while line < lineStarts.count, lineStarts[line] <= NSMaxRange(characters) {
            let glyph = layoutManager.glyphIndexForCharacter(at: lineStarts[line])
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = fragment.minY + textView.textContainerInset.height + origin.y
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (fragment.height - size.height) / 2), withAttributes: attributes)
            line += 1
        }
    }
}

/// A scroll view whose scrollers always float over the content and fade out, whatever the system's "Show scroll
/// bars" setting. Legacy scrollers take room from the content, so a code view reflowed and jumped inward the moment
/// a long line started to need a horizontal scroller (for example when the inspector opened).
class OverlayScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autohidesScrollers = true
        scrollerStyle = .overlay
        // AppKit resets every scroll view to the preferred style when the setting (or the mouse) changes.
        NotificationCenter.default.addObserver(self, selector: #selector(preferredStyleChanged),
                                               name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// With overlay scrollers AppKit lays the clip view under a vertical ruler; keep the content beside it.
    override func tile() {
        super.tile()
        guard hasVerticalRuler, rulersVisible, let ruler = verticalRulerView else { return }
        var frame = contentView.frame
        let overlap = ruler.frame.maxX - frame.minX
        guard overlap > 0 else { return }
        frame.origin.x += overlap
        frame.size.width -= overlap
        contentView.frame = frame
    }

    @objc private func preferredStyleChanged() {
        DispatchQueue.main.async { [weak self] in self?.scrollerStyle = .overlay }
    }
}

/// Zoom commands for the image view (header buttons and shortcuts).
@MainActor
final class ImageZoomController {
    weak var scrollView: NSScrollView?

    func zoom(by factor: CGFloat) {
        guard let scrollView else { return }
        let center = NSPoint(x: scrollView.contentView.bounds.midX, y: scrollView.contentView.bounds.midY)
        scrollView.setMagnification(scrollView.magnification * factor, centeredAt: center)
    }

    func actualSize() { scrollView?.magnification = 1 }

    /// Whole image visible, never enlarged past its own size.
    func fit() {
        guard let scrollView, let image = (scrollView.documentView as? NSImageView)?.image, image.size.width > 0, image.size.height > 0 else { return }
        let available = scrollView.contentSize
        let scale = min(available.width / image.size.width, available.height / image.size.height, 1)
        scrollView.magnification = max(scale, scrollView.minMagnification)
    }
}

/// An image that fits the pane at first and zooms with pinch, ⌘+ / ⌘− / ⌘0 and the header buttons.
private struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    let controller: ImageZoomController

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = CenteringScrollView()
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 32
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.backgroundColor = .windowBackgroundColor
        let imageView = NSImageView()
        imageView.imageScaling = .scaleNone
        scrollView.documentView = imageView
        controller.scrollView = scrollView
        show(image, in: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        controller.scrollView = scrollView
        if (scrollView.documentView as? NSImageView)?.image !== image { show(image, in: scrollView) }
    }

    private func show(_ image: NSImage, in scrollView: NSScrollView) {
        guard let imageView = scrollView.documentView as? NSImageView else { return }
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        (scrollView as? CenteringScrollView)?.needsFit = true
        scrollView.needsLayout = true
    }
}

/// Keeps a smaller-than-the-pane image centered instead of pinned to the bottom-left corner, and fits a new image
/// once the pane has its real size (fitting before layout would scale to a zero-sized pane).
private final class CenteringScrollView: OverlayScrollView {
    var needsFit = false

    override func layout() {
        super.layout()
        if needsFit, contentSize.width > 1, contentSize.height > 1,
           let image = (documentView as? NSImageView)?.image, image.size.width > 0, image.size.height > 0 {
            needsFit = false
            magnification = max(min(contentSize.width / image.size.width, contentSize.height / image.size.height, 1), minMagnification)
            tile()
        }
    }

    override func tile() {
        super.tile()
        guard let document = documentView else { return }
        let clip = contentView
        var bounds = clip.bounds
        let size = document.frame.size
        if size.width < bounds.width { bounds.origin.x = -(bounds.width - size.width) / 2 }
        if size.height < bounds.height { bounds.origin.y = -(bounds.height - size.height) / 2 }
        if bounds.origin != clip.bounds.origin { clip.setBoundsOrigin(bounds.origin) }
    }
}

/// A PDF with the system viewer (scroll, zoom, select, search with ⌘F through the responder chain).
private struct PDFDocumentView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

extension Theme {
    /// GitHub's theme on the window's own background: its text style paints a fixed white or near-black page behind
    /// every paragraph (and its tables alternate with that color), which showed as a second background in dark mode.
    @MainActor static let mercury = Theme.gitHub
        .text {
            ForegroundColor(.primary)
            BackgroundColor(nil)
            FontSize(16)
        }
        .table { MarkdownTable(configuration: $0) }
}

/// GitHub's table with the system's separator and alternating row colors instead of its fixed page colors.
private struct MarkdownTable: View {
    let configuration: BlockConfiguration

    var body: some View {
        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .markdownTableBorderStyle(.init(color: Color(nsColor: .separatorColor)))
            .markdownTableBackgroundStyle(
                .alternatingRows(Color.clear, Color(nsColor: .alternatingContentBackgroundColors[1]))
            )
            .markdownMargin(top: 0, bottom: 16)
    }
}
