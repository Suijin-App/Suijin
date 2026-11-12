import AppKit
import MercuryGit

/// Two-column diff: the old version on the left, the new one on the right, aligned row by row (see
/// `SideBySideLayout`). Each column is a `DiffTextView` without line wrapping; vertical scrolling is synchronized
/// through the clip views' bounds notifications, horizontal scrolling stays independent so a long line on one side
/// can be read without moving the other. Only the right column shows a vertical scroller.
@MainActor
public final class SideBySideDiffView: NSView {
    /// Below this width the columns are too narrow to read; the app falls back to the unified diff.
    public static let minimumWidth: CGFloat = 760

    let left = DiffTextView()
    let right = DiffTextView()
    private let divider = NSBox()
    public private(set) var diff: FileDiff?
    private var language: String?
    private(set) var layout = SideBySideLayout(diff: FileDiff(oldPath: nil, newPath: nil))
    private var observers: [NSObjectProtocol] = []
    private var isSyncing = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for column in [left, right] {
            column.wrapsLines = false
            column.translatesAutoresizingMaskIntoConstraints = false
            addSubview(column)
        }
        left.gutter.columns = .old
        right.gutter.columns = .new
        left.scrollView.hasVerticalScroller = false
        left.textView.setAccessibilityLabel(String(localized: "Old version", bundle: .module,
                                                   comment: "Accessibility label of the left column of a side-by-side diff"))
        right.textView.setAccessibilityLabel(String(localized: "New version", bundle: .module,
                                                    comment: "Accessibility label of the right column of a side-by-side diff"))
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = DiffTheme.separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor),
            left.topAnchor.constraint(equalTo: topAnchor),
            left.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            right.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            right.topAnchor.constraint(equalTo: topAnchor),
            right.bottomAnchor.constraint(equalTo: bottomAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor),
            right.widthAnchor.constraint(equalTo: left.widthAnchor),
        ])

        let center = NotificationCenter.default
        for (source, target) in [(left, right), (right, left)] {
            let clip = source.scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak source, weak target] _ in
                MainActor.assumeIsolated {
                    guard let self, let source, let target else { return }
                    self.syncVerticalScroll(from: source, to: target)
                }
            })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Shows `diff`; the same diff again is a no-op.
    public func setDiff(_ diff: FileDiff, language: String?) {
        guard diff != self.diff || language != self.language else { return }
        self.diff = diff
        self.language = language
        layout = SideBySideLayout(diff: diff)
        var oldMarks: [DiffTextView.WordMark] = []
        var newMarks: [DiffTextView.WordMark] = []
        for (row, changes) in layout.wordChanges {
            let leftStart = layout.left.rows[row].range.location
            let rightStart = layout.right.rows[row].range.location
            oldMarks += changes.old.map {
                DiffTextView.WordMark(range: NSRange(location: leftStart + $0.location, length: $0.length), color: DiffTheme.deletedWordBackground)
            }
            newMarks += changes.new.map {
                DiffTextView.WordMark(range: NSRange(location: rightStart + $0.location, length: $0.length), color: DiffTheme.addedWordBackground)
            }
        }
        left.show(layout.left, language: language, wordMarks: oldMarks)
        right.show(layout.right, language: language, wordMarks: newMarks)
    }

    /// Completes when both columns finished highlighting.
    func highlightingCompleted() async {
        await left.highlightingCompleted()
        await right.highlightingCompleted()
    }

    private func syncVerticalScroll(from source: DiffTextView, to target: DiffTextView) {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let sourceClip = source.scrollView.contentView
        let targetClip = target.scrollView.contentView
        let y = sourceClip.bounds.origin.y
        guard targetClip.bounds.origin.y != y else { return }
        targetClip.setBoundsOrigin(NSPoint(x: targetClip.bounds.origin.x, y: y))
        target.scrollView.reflectScrolledClipView(targetClip)
    }
}
