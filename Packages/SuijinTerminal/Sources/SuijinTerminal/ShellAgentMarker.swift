import Foundation
import SwiftTerm

/// What Suijin's `claude` and `codex` shell functions report about an agent they run, as a private OSC written to
/// the terminal (`ESC ] 6973 ; <payload> BEL`, see the shell integration's `__suijin_agent_begin`):
///
/// - `start;<agent>`: the agent is about to start in the shell;
/// - `end;<agent>;<status>`: it is done (`status` is its exit status, empty when the shell did not know it).
///
/// The agent is the program's name (`claude`, `codex`); the app decides which names it knows. Anything else is
/// ignored, so a program printing a malformed sequence changes nothing.
public enum ShellAgentMarker: Sendable, Hashable {
    case started(agent: String)
    case ended(agent: String, status: Int32?)

    /// The OSC code; private to Suijin (not used by xterm, iTerm2, kitty, WezTerm or VS Code).
    public static let oscCode = 6973

    /// Longest agent name accepted: the names are short words, and a long one is not a marker Suijin wrote.
    static let maximumNameLength = 32

    /// The marker in an OSC payload (the bytes after `6973;`), nil when it is not one.
    public static func parse<Bytes: Collection<UInt8>>(_ payload: Bytes) -> ShellAgentMarker? {
        guard payload.count <= 128, let text = String(bytes: payload, encoding: .utf8) else { return nil }
        let fields = text.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2, isAgentName(fields[1]) else { return nil }
        switch (fields[0], fields.count) {
        case ("start", 2):
            return .started(agent: fields[1])
        case ("end", 2):
            return .ended(agent: fields[1], status: nil)
        case ("end", 3):
            return .ended(agent: fields[1], status: fields[2].isEmpty ? nil : Int32(fields[2]))
        default:
            return nil
        }
    }

    static func isAgentName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= maximumNameLength
            && name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" }
    }
}

extension SuijinTerminalView {
    /// Calls `handler` for every agent marker in the output this view parses (scrollback replays included, in order).
    /// Setting it again replaces the previous handler.
    public func onShellAgentMarker(_ handler: @escaping @MainActor (ShellAgentMarker) -> Void) {
        // SwiftTerm parses on the thread that feeds the view, which is the main thread (`TerminalFeedScheduler`).
        getTerminal().registerOscHandler(code: ShellAgentMarker.oscCode) { payload in
            guard let marker = ShellAgentMarker.parse(payload) else { return }
            MainActor.assumeIsolated { handler(marker) }
        }
    }
}
