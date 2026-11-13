import Foundation
import SuijinTerminal

extension SessionRuntime {
    enum PasteError: LocalizedError {
        case notRunning
        case noBracketedPaste

        var errorDescription: String? {
            switch self {
            case .notRunning:
                String(localized: "The session is not running.")
            case .noBracketedPaste:
                String(localized: "The program in this session does not accept pasted text yet. Wait until its prompt is ready, then try again.")
            }
        }
    }

    /// Puts `text` on the session's prompt as one bracketed paste (`ESC[200~ … ESC[201~`), so an agent TUI takes the
    /// line breaks as part of the prompt instead of running each line. With `pressReturn`, Return follows a moment
    /// later as a separate keystroke, which TUIs that debounce pastes take as "send".
    ///
    /// Refuses when the program has not turned bracketed paste on: the lines would then run one by one.
    func paste(_ text: String, pressReturn: Bool) throws {
        guard terminal.isRunning else { throw PasteError.notRunning }
        guard terminal.view.isBracketedPasteMode,
              let bytes = PasteGuard.bytes(for: text, action: .pasteOnly, bracketedPaste: true) else {
            throw PasteError.noBracketedPaste
        }
        terminal.send(bytes)
        guard pressReturn else { return }
        Task { @MainActor [terminal] in
            try? await Task.sleep(for: .milliseconds(200))
            terminal.send([UInt8(ascii: "\r")])
        }
    }
}
