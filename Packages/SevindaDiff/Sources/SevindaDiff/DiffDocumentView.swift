import AppKit
import SevindaGit
import SwiftUI

/// How a file diff is laid out.
public enum DiffDisplayMode: String, Sendable, CaseIterable {
    /// One column, deleted lines above their replacements.
    case unified
    /// The old version on the left, the new one on the right.
    case sideBySide
}

/// SwiftUI entry point for a single file's diff. Text diffs render in `DiffTextView` (unified) or
/// `SideBySideDiffView`; binary files and diffs without hunks show a system `ContentUnavailableView` instead.
///
/// With `notes`, the gutter offers a "+" to note lines (on the new side: the right column side by side) and saved
/// notes show between the lines they end on.
public struct DiffDocumentView: NSViewRepresentable {
    public let diff: FileDiff
    public let language: String?
    public let mode: DiffDisplayMode
    public let notes: DiffNotesConfiguration?

    /// - Parameter language: identifier from `SyntaxHighlighter.language(forPath:)`; nil disables highlighting.
    public init(diff: FileDiff, language: String?, mode: DiffDisplayMode = .unified, notes: DiffNotesConfiguration? = nil) {
        self.diff = diff
        self.language = language
        self.mode = mode
        self.notes = notes
    }

    public func makeNSView(context: Context) -> DiffDocumentContainerView {
        let view = DiffDocumentContainerView()
        view.show(diff, language: language, mode: mode, notes: notes)
        return view
    }

    public func updateNSView(_ nsView: DiffDocumentContainerView, context: Context) {
        nsView.show(diff, language: language, mode: mode, notes: notes)
    }
}

/// Hosts the unified diff, the side-by-side diff or a placeholder, swapping them without rebuilding the text views.
@MainActor
public final class DiffDocumentContainerView: NSView {
    let textView = DiffTextView()
    private(set) var sideBySideView: SideBySideDiffView?
    private var placeholder: NSHostingView<DiffPlaceholder>?
    let notesController = DiffNotesController()
    private var shownPath: String?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pin(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ diff: FileDiff, language: String?, mode: DiffDisplayMode = .unified, notes: DiffNotesConfiguration? = nil) {
        if shownPath != diff.displayPath {
            shownPath = diff.displayPath
            notesController.reset()
        }
        let state: DiffPlaceholder.State? = if diff.isBinary {
            .binary
        } else if diff.hunks.isEmpty {
            .noChanges
        } else {
            nil
        }
        if let state {
            textView.isHidden = true
            sideBySideView?.isHidden = true
            notesController.attach(primary: nil, mirror: nil)
            if let placeholder {
                placeholder.rootView = DiffPlaceholder(state: state)
                placeholder.isHidden = false
            } else {
                let host = NSHostingView(rootView: DiffPlaceholder(state: state))
                pin(host)
                placeholder = host
            }
            return
        }
        placeholder?.isHidden = true
        switch mode {
        case .unified:
            sideBySideView?.isHidden = true
            textView.isHidden = false
            textView.setDiff(diff, language: language)
            notesController.attach(primary: textView, mirror: nil)
        case .sideBySide:
            textView.isHidden = true
            let view = sideBySideView ?? {
                let view = SideBySideDiffView()
                pin(view)
                sideBySideView = view
                return view
            }()
            view.isHidden = false
            view.setDiff(diff, language: language)
            notesController.attach(primary: view.right, mirror: view.left)
        }
        notesController.update(notes)
    }

    private func pin(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

struct DiffPlaceholder: View {
    enum State { case binary, noChanges }
    let state: State

    var body: some View {
        switch state {
        case .binary:
            ContentUnavailableView {
                Label(String(localized: "Binary file", bundle: .module,
                             comment: "Title shown instead of a diff for a binary file"),
                      systemImage: "doc")
            } description: {
                Text(String(localized: "Binary files are not shown as text.", bundle: .module,
                            comment: "Explanation shown instead of a diff for a binary file"))
            }
        case .noChanges:
            ContentUnavailableView {
                Label(String(localized: "No textual changes", bundle: .module,
                             comment: "Title shown when a file diff has no hunks"),
                      systemImage: "equal.circle")
            } description: {
                Text(String(localized: "Only file metadata such as the mode or name changed.", bundle: .module,
                            comment: "Explanation shown when a file diff has no hunks"))
            }
        }
    }
}
