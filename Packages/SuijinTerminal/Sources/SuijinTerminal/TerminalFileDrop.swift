import AppKit
import QuartzCore

/// Files and folders dropped on a terminal become their paths on the command line, as Terminal.app and iTerm2 do:
/// each path shell-escaped, separated by single spaces, delivered as a paste (inside bracketed-paste markers when the
/// program asked for them) and never followed by Return. Delivering it as a paste is what lets Claude Code and Codex
/// recognize a dropped image path and attach the image instead of leaving the path as text.
public enum TerminalFileDrop {
    /// What a drop of `urls` puts on the command line; empty when none of them is a file URL.
    public static func text(for urls: [URL]) -> String {
        urls.filter(\.isFileURL).map { escape($0.path(percentEncoded: false).normalizedPathEnd) }.joined(separator: " ")
    }

    /// The bytes sent to the program for `text`: the paste markers around it when bracketed paste is on, otherwise the
    /// text alone. The text is one line, so the multi-line paste guard is never involved.
    public static func bytes(for text: String, bracketedPaste: Bool) -> [UInt8] {
        let content = Array(text.utf8)
        return bracketedPaste ? PasteGuard.bracketedPasteStart + content + PasteGuard.bracketedPasteEnd : content
    }

    /// A path as a shell word, Terminal.app style: characters the shell would interpret are escaped with a backslash,
    /// letters (any script), digits and `/ . _ - + , : @ % =` stay as they are. A name holding a control character (a
    /// line break, a tab) cannot be backslash-escaped (a backslash before a line break continues the line), so it is
    /// written in ANSI-C quotes (`$'…'`, understood by zsh and bash) with that character as an escape.
    static func escape(_ path: String) -> String {
        if path.unicodeScalars.contains(where: isControl) { return ansiCQuoted(path) }
        var escaped = ""
        escaped.reserveCapacity(path.count)
        for scalar in path.unicodeScalars {
            if !scalar.isASCII || isPlain(scalar) {
                escaped.unicodeScalars.append(scalar)
            } else {
                escaped.unicodeScalars.append("\\")
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    private static func isPlain(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "/", ".", "_", "-", "+", ",", ":", "@", "%", "=": true
        default: false
        }
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    private static func ansiCQuoted(_ path: String) -> String {
        var quoted = "$'"
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\\": quoted += "\\\\"
            case "'": quoted += "\\'"
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\t": quoted += "\\t"
            case _ where isControl(scalar): quoted += String(format: "\\x%02x", scalar.value)
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "'"
    }
}

private extension String {
    /// A folder's file URL ends in `/`; the path is written without it, as Terminal.app does. The root stays `/`.
    var normalizedPathEnd: String {
        var path = self
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

// MARK: Drop destination

extension SuijinTerminalView {
    /// The only drag type a terminal takes. Pane and tab drags carry types of their own (and plain text), so they pass
    /// through to the SwiftUI drop targets around the terminal and never reach the program.
    static let fileDropTypes: [NSPasteboard.PasteboardType] = [.fileURL]

    func registerForFileDrops() {
        registerForDraggedTypes(Self.fileDropTypes)
    }

    /// The file URLs on a drag's pasteboard, in the order they were dragged.
    static func droppedFileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL] ?? []).filter(\.isFileURL)
    }

    /// Whether a drag with this pasteboard would be taken now: it holds file URLs, the host allows drops
    /// (`acceptsFileDrop`, false while the session reconnects) and the screen is not hidden by a replay or catch-up.
    func canTakeFileDrop(from pasteboard: NSPasteboard) -> Bool {
        guard !isConcealed, acceptsFileDrop?() ?? true else { return false }
        return !Self.droppedFileURLs(on: pasteboard).isEmpty
    }

    /// Pastes the dropped paths and gives this terminal the keyboard. Returns whether anything was pasted.
    @discardableResult
    func takeFileDrop(from pasteboard: NSPasteboard) -> Bool {
        guard canTakeFileDrop(from: pasteboard) else { return false }
        let text = TerminalFileDrop.text(for: Self.droppedFileURLs(on: pasteboard))
        guard !text.isEmpty else { return false }
        send(data: TerminalFileDrop.bytes(for: text, bracketedPaste: isBracketedPasteMode)[...])
        window?.makeFirstResponder(self)
        return true
    }

    open override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileDragOperation(sender)
    }

    open override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileDragOperation(sender)
    }

    open override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        showsFileDropHighlight = false
    }

    open override func draggingEnded(_ sender: any NSDraggingInfo) {
        showsFileDropHighlight = false
    }

    open override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        canTakeFileDrop(from: sender.draggingPasteboard)
    }

    open override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        showsFileDropHighlight = false
        return takeFileDrop(from: sender.draggingPasteboard)
    }

    /// Copy (the system's plus cursor) when the drop would be taken; otherwise none, so the pointer shows the drop is
    /// refused.
    private func fileDragOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let takes = canTakeFileDrop(from: sender.draggingPasteboard) && !sender.draggingSourceOperationMask.isEmpty
        showsFileDropHighlight = takes
        guard takes else { return [] }
        return sender.draggingSourceOperationMask.contains(.copy) ? .copy : .generic
    }

    /// A thin accent-colored ring around the terminal while a file drag hovers over it, like the ring a text field shows
    /// for a drop. It is drawn on the container's layer, in the margin around the text (the terminal's own layer clips
    /// to its bounds, and a ring inside them would cover the first column), above the Metal surface; a layer, so it
    /// never takes a click. Without a container it sits just inside the terminal's edge. It is removed when hidden, so
    /// none is left behind when the terminal moves to another container.
    var showsFileDropHighlight: Bool {
        get { fileDropHighlightLayer != nil }
        set {
            guard newValue != showsFileDropHighlight else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            guard newValue else {
                fileDropHighlightLayer?.removeFromSuperlayer()
                return
            }
            wantsLayer = true
            let ring = CALayer()
            ring.name = Self.fileDropHighlightName
            ring.borderWidth = 2
            ring.cornerRadius = 4
            effectiveAppearance.performAsCurrentDrawingAppearance {
                ring.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
            }
            if let hostLayer = superview?.layer {
                ring.frame = frame.insetBy(dx: -4, dy: -4)
                // Above the terminal's own layer and everything in it.
                ring.zPosition = 1_000
                hostLayer.addSublayer(ring)
            } else {
                ring.frame = bounds
                ring.zPosition = 1_000
                layer?.addSublayer(ring)
            }
        }
    }

    private var fileDropHighlightLayer: CALayer? {
        let candidates = (superview?.layer?.sublayers ?? []) + (layer?.sublayers ?? [])
        return candidates.first { $0.name == Self.fileDropHighlightName }
    }

    private static let fileDropHighlightName = "suijin.fileDropHighlight"
}
