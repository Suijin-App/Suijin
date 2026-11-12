import CryptoKit
import Foundation
import SevindaPTYProtocol

/// A live terminal Mercury opened, as the broker knows it from the helper's spawn.
struct SessionBinding: Sendable, Hashable {
    /// The PTY host session id (what the broker writes to).
    var hostSessionID: String
    /// The app's session UUID (`MERCURY_SESSION_ID`, metadata `mercury.session`).
    var sessionID: String
    /// `claude`, `codex`, or nil for a shell.
    var agent: OrchestrationAgent?
    var isRunning = true
}

/// Maps session tokens to the terminals they were issued to. Only a SHA-256 digest of each token is kept, so the
/// helper's memory never holds a token it could leak; tokens are never logged or written to disk. Callers are
/// identified by token alone: a caller cannot claim another session's identity by naming it.
struct CallerIdentity {
    private var byDigest: [String: String] = [:]          // token digest -> app session id
    private(set) var sessions: [String: SessionBinding] = [:] // app session id -> binding

    /// Tokens shorter than this are refused when a session registers (the app issues 32 random bytes).
    static let minimumTokenLength = 32

    static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    mutating func register(token: String, binding: SessionBinding) {
        guard token.count >= Self.minimumTokenLength else { return }
        if let previous = sessions[binding.sessionID] {
            byDigest = byDigest.filter { $0.value != previous.sessionID }
        }
        byDigest[Self.digest(token)] = binding.sessionID
        sessions[binding.sessionID] = binding
    }

    /// The session `token` was issued to, while that session runs.
    func caller(token: String?) -> SessionBinding? {
        guard let token, token.count >= Self.minimumTokenLength,
              let id = byDigest[Self.digest(token)], let binding = sessions[id], binding.isRunning
        else { return nil }
        return binding
    }

    func binding(sessionID: String) -> SessionBinding? {
        sessions[sessionID]
    }

    func binding(hostSessionID: String) -> SessionBinding? {
        sessions.values.first { $0.hostSessionID == hostSessionID }
    }

    /// The session ended: its token stops working.
    mutating func markExited(hostSessionID: String) -> SessionBinding? {
        guard var binding = binding(hostSessionID: hostSessionID) else { return nil }
        binding.isRunning = false
        sessions[binding.sessionID] = binding
        byDigest = byDigest.filter { $0.value != binding.sessionID }
        return binding
    }
}
