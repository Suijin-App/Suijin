import AppKit
import MarkdownUI
import SuijinDiff
import SuijinUI
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// A file opened from a terminal link: Markdown rendered natively, images shown, audio and video played in the system
/// player, other text in a monospaced read-only view; anything else offers to open in its default app. Follows the file
/// on disk (agents edit plans as you read): it reloads in place when written, and says so when the file is deleted or
/// moved away.
struct FileViewer: View {
    @Environment(AppModel.self) private var model
    let path: String
    let context: SessionContext
    @State private var file: FileViewerModel
    @State private var code = CodeViewController()
    @State private var zoom = ImageZoomController()
    @State private var media = MediaPlaybackController()

    enum Content {
        case loading
        case markdown(String)
        case text(String)
        /// Source code in a language the highlighter knows.
        case code(String, language: String)
        case pdf
        case image(NSImage)
        /// An audio or video file by type, before AVFoundation was asked whether it can play it (`load(_:)` does).
        case mediaFile
        /// Audio or video AVFoundation plays.
        case media(MediaInfo)
        /// Audio or video AVFoundation cannot play but Quick Look can preview.
        case quickLook
        /// Audio or video neither can show.
        case unplayable(isAudio: Bool)
        case unsupported
        case missing
    }

    /// Larger files are not loaded whole; they open in their default app instead.
    nonisolated static let maximumTextSize = 2 * 1024 * 1024

    init(path: String, context: SessionContext) {
        self.path = path
        self.context = context
        _file = State(initialValue: FileViewerModel(path: path))
    }

    private var url: URL { URL(fileURLWithPath: path) }
    private var content: Content { file.content }

    /// The path relative to the context's folder when it lies inside it, else with `~` for the home folder.
    private var displayPath: String {
        if let root = model.directory(of: context)?.standardizedFileURL.path, path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch content {
                case .loading, .mediaFile:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .media(let info):
                    MediaPlayerTab(path: path, context: context, info: info, revision: file.revision, controller: media)
                case .quickLook:
                    QuickLookPreview(url: url, revision: file.revision)
                case .unplayable(let isAudio):
                    ContentUnavailableView {
                        if isAudio {
                            Label("Can't Play This Audio", systemImage: "speaker.slash")
                        } else {
                            Label("Can't Play This Video", systemImage: "play.slash")
                        }
                    } description: {
                        Text("macOS can't play or preview “\(url.lastPathComponent)”. Open it in an app that supports its format.")
                    } actions: {
                        Button("Open in Default App") { NSWorkspace.shared.open(url) }.glassButtonStyle()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.glassButtonStyle()
                    }
                case .markdown(let text):
                    let document = MarkdownDocument(text)
                    ScrollView {
                        VStack(alignment: .leading, spacing: SuijinSpacing.l) {
                            if !document.frontMatter.isEmpty {
                                FrontMatterView(fields: document.frontMatter)
                            }
                            Markdown(document.body, baseURL: url.deletingLastPathComponent(), imageBaseURL: url.deletingLastPathComponent())
                                .markdownTheme(.suijin)
                                .textSelection(.enabled)
                        }
                            .frame(maxWidth: 860, alignment: .leading)
                            .padding(.horizontal, SuijinSpacing.xl)
                            .padding(.vertical, SuijinSpacing.l)
                            .frame(maxWidth: .infinity)
                    }
                    .environment(\.openURL, OpenURLAction { link in
                        NSWorkspace.shared.open(link)
                        return .handled
                    })
                case .code(let text, let language):
                    CodeTextView(text: text, language: language, controller: code)
                case .pdf:
                    PDFDocumentView(url: url, revision: file.revision)
                case .text(let text):
                    ScrollView([.vertical, .horizontal]) {
                        Text(verbatim: text)
                            .font(SuijinFont.mono)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(SuijinSpacing.l)
                    }
                    .background(SuijinColor.codeBackground)
                case .image(let image):
                    ZoomableImageView(image: image, controller: zoom)
                case .unsupported:
                    ContentUnavailableView {
                        Label("No Preview", systemImage: "doc")
                    } description: {
                        Text("Suijin shows Markdown, code, text, images and PDFs. Open this file in its default app instead.")
                    } actions: {
                        Button("Open in Default App") { NSWorkspace.shared.open(url) }.glassButtonStyle()
                    }
                case .missing:
                    ContentUnavailableView {
                        Label("File Deleted", systemImage: "doc.questionmark")
                    } description: {
                        Text("“\(url.lastPathComponent)” no longer exists at \(displayPath).")
                    } actions: {
                        Button("Close Tab") { model.closeFile(path, in: context) }.glassButtonStyle()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: model.fileLineReveal?.request, initial: true) { revealPendingLine() }
        .onChange(of: isCode) { revealPendingLine() }
        .task(id: path) {
            await file.start()
            // Follow the file until the tab closes or another tab is shown.
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            file.stop()
        }
    }

    private var isCode: Bool {
        if case .code = content { return true }
        return false
    }

    /// Scrolls to the line a terminal path asked for, once the code is shown; other kinds of file have no lines to go
    /// to, so the request is dropped.
    private func revealPendingLine() {
        guard let reveal = model.fileLineReveal, reveal.path == path else { return }
        if case .loading = content { return }
        model.fileLineReveal = nil
        guard isCode else { return }
        let code = code
        // After this update, so the text view exists and holds the text.
        DispatchQueue.main.async { code.scroll(toLine: reveal.line) }
    }

    private var header: some View {
        HStack(spacing: SuijinSpacing.s) {
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
            Spacer(minLength: SuijinSpacing.s)
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
        .padding(.horizontal, SuijinSpacing.l)
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
                    .keyboardShortcut(ShortcutCatalog.viewerZoomOut.shortcut)
                Button { zoom.fit() } label: { Label("Fit", systemImage: "arrow.down.right.and.arrow.up.left") }
                    .keyboardShortcut(ShortcutCatalog.viewerFit.shortcut)
                Button { zoom.actualSize() } label: { Label("Actual Size", systemImage: "1.magnifyingglass") }
                Button { zoom.zoom(by: 1.25) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                    .keyboardShortcut(ShortcutCatalog.viewerZoomIn.shortcut)
            }
        case .media(let info):
            Text(verbatim: info.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel(Text("Media info: \(info.summary)"))
        default:
            EmptyView()
        }
    }

    /// `read(_:)`, then for audio and video files AVFoundation's answer on whether it can play them.
    nonisolated static func load(_ url: URL) async -> Content {
        let content = read(url)
        guard case .mediaFile = content else { return content }
        return await MediaProbe.content(for: url)
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
        // Never read whole: the player streams it from disk.
        if MediaProbe.isMediaFile(url) { return .mediaFile }
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
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: SuijinSpacing.l, verticalSpacing: 6) {
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                GridRow {
                    Text(verbatim: field.key).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(verbatim: field.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .padding(SuijinSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: SuijinRadius.card))
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
        textView.backgroundColor = NSColor(SuijinColor.codeBackground)
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

    /// Replacing the text keeps the clip view's origin, so a reload (the file changed on disk) leaves the reader where
    /// they were.
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
        NSColor(SuijinColor.codeBackground).setFill()
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
        (scrollView as? CenteringScrollView)?.fitImage()
    }
}

/// An image that fits the pane at first and zooms with pinch, ⌘ or ⌥ with the mouse wheel, a double-click, ⌘+ / ⌘− / ⌘0
/// and the header buttons; a zoomed image pans by dragging.
struct ZoomableImageView: NSViewRepresentable {
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
        let imageView = PassThroughImageView()
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

    /// Shows `image`, fitted to the pane. A new version of the same file keeps the zoom and position the user chose;
    /// a fitted image is fitted again (its size may have changed).
    private func show(_ image: NSImage, in scrollView: NSScrollView) {
        guard let imageView = scrollView.documentView as? NSImageView else { return }
        let keepsZoom = imageView.image.map { old in
            guard let centering = scrollView as? CenteringScrollView else { return false }
            return abs(scrollView.magnification - centering.fitMagnification(for: old.size)) > 0.001
        } ?? false
        let origin = scrollView.contentView.bounds.origin
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        if keepsZoom {
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            scrollView.tile()
        } else {
            (scrollView as? CenteringScrollView)?.needsFit = true
        }
        scrollView.needsLayout = true
    }
}

/// The image itself takes no clicks, so presses and drags reach the scroll view, which pans and zooms.
final class PassThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Keeps a smaller-than-the-pane image centered instead of pinned to the bottom-left corner, and fits a new image
/// once the pane has its real size (fitting before layout would scale to a zero-sized pane). A fitted image stays
/// fitted when the pane is resized; one the user zoomed keeps its zoom.
final class CenteringScrollView: OverlayScrollView {
    var needsFit = false
    private var panStart: (mouse: NSPoint, origin: NSPoint)?
    /// The magnification of the last fit and the pane size it was made for.
    private var lastFit: (magnification: CGFloat, paneSize: NSSize)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = CenteringClipView()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the whole image, never enlarged past its own size.
    func fitImage() {
        guard let size = imageSize else { return }
        magnification = fitMagnification(for: size)
        lastFit = (magnification, contentSize)
    }

    /// The magnification that shows a whole image of `size`, never enlarged past its own size.
    func fitMagnification(for size: NSSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return max(min(contentSize.width / size.width, contentSize.height / size.height, 1), minMagnification)
    }

    private var imageSize: NSSize? { (documentView as? NSImageView)?.image?.size }

    /// Whether the image is larger than the pane, so there is something to pan.
    private var canPan: Bool {
        guard let document = documentView else { return false }
        let size = document.frame.size, visible = contentView.bounds.size
        return size.width > visible.width + 0.5 || size.height > visible.height + 0.5
    }

    // MARK: Mouse

    /// A mouse wheel with ⌘ (or ⌥) zooms around the pointer, as in Preview; without them the wheel scrolls. Trackpad
    /// pinches still go through the scroll view's own magnification.
    override func scrollWheel(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.option), event.scrollingDeltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }
        let steps = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 40 : event.scrollingDeltaY
        let factor = pow(1.15, max(min(steps, 4), -4))
        let point = contentView.convert(event.locationInWindow, from: nil)
        setMagnification(magnification * factor, centeredAt: point)
    }

    /// Dragging with the mouse pans a zoomed image; a double-click switches between the fitted and actual size.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let size = imageSize {
            let point = contentView.convert(event.locationInWindow, from: nil)
            let fit = fitMagnification(for: size)
            let target = abs(magnification - fit) < 0.001 && fit < 1 ? 1 : fit
            setMagnification(target, centeredAt: point)
            if target == fit { lastFit = (magnification, contentSize) }
            return
        }
        guard canPan else { return super.mouseDown(with: event) }
        panStart = (event.locationInWindow, contentView.bounds.origin)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = panStart else { return super.mouseDragged(with: event) }
        let scale = max(magnification, 0.0001)
        let delta = NSPoint(x: (event.locationInWindow.x - start.mouse.x) / scale,
                            y: (event.locationInWindow.y - start.mouse.y) / scale)
        let target = NSPoint(x: start.origin.x - delta.x, y: start.origin.y - delta.y)
        contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: target, size: contentView.bounds.size)).origin)
        reflectScrolledClipView(contentView)
    }

    override func mouseUp(with event: NSEvent) {
        guard panStart != nil else { return super.mouseUp(with: event) }
        panStart = nil
        NSCursor.pop()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if canPan { addCursorRect(contentView.frame, cursor: .openHand) }
    }


    /// A frame-based scroll view is not laid out again when only its size changes; `layout()` refits a fitted image.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    override func layout() {
        super.layout()
        guard contentSize.width > 1, contentSize.height > 1, let size = imageSize, size.width > 0, size.height > 0 else { return }
        let resizedWhileFitted = lastFit.map { abs(magnification - $0.magnification) < 0.001 && $0.paneSize != contentSize } ?? false
        if needsFit || resizedWhileFitted {
            needsFit = false
            fitImage()
            tile()
        }
    }

    override func tile() {
        super.tile()
        // Zooming changes whether the image can be panned, and so the cursor shown over it.
        window?.invalidateCursorRects(for: self)
        guard let document = documentView else { return }
        let clip = contentView
        var bounds = clip.bounds
        let size = document.frame.size
        if size.width < bounds.width { bounds.origin.x = -(bounds.width - size.width) / 2 }
        if size.height < bounds.height { bounds.origin.y = -(bounds.height - size.height) / 2 }
        if bounds.origin != clip.bounds.origin { clip.setBoundsOrigin(bounds.origin) }
    }
}

/// Centers a document smaller than the visible area. Done in `constrainBoundsRect`, which AppKit consults on every
/// scroll, zoom and resize, so later scrolling cannot pin the image back to the bottom-left corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let size = documentView?.frame.size else { return rect }
        if size.width < rect.width { rect.origin.x = -(rect.width - size.width) / 2 }
        if size.height < rect.height { rect.origin.y = -(rect.height - size.height) / 2 }
        return rect
    }
}

/// A PDF with the system viewer (scroll, zoom, select, search with ⌘F through the responder chain).
/// `revision` changes when the file changed on disk; the new document opens on the page that was shown.
private struct PDFDocumentView: NSViewRepresentable {
    let url: URL
    let revision: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        context.coordinator.revision = revision
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard view.document?.documentURL != url || context.coordinator.revision != revision else { return }
        context.coordinator.revision = revision
        let pageIndex = view.currentPage.flatMap { view.document?.index(for: $0) }
        let document = PDFDocument(url: url)
        view.document = document
        if let pageIndex, let page = document?.page(at: min(pageIndex, max(0, (document?.pageCount ?? 1) - 1))) {
            view.go(to: page)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var revision = 0
    }
}

extension Theme {
    /// GitHub's theme on the window's own background: its text style paints a fixed white or near-black page behind
    /// every paragraph (and its tables alternate with that color), which showed as a second background in dark mode.
    @MainActor static let suijin = Theme.gitHub
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
