import Foundation
import MercuryAgents

/// Environment changes for launching `codex` under an account home or the default login.
public enum CodexLaunchEnv {
    /// Set beside every `CODEX_HOME` Mercury injects, so the shell function can tell it from the user's own.
    public static let injectedHomeEnv = "MERCURY_CODEX_INJECTED_HOME"

    /// `home` = account: `CODEX_HOME` points at it. `nil` = default login: the user's own `CODEX_HOME` stays, and only
    /// a value Mercury injected earlier is dropped. Like Orca, API key variables are left alone: Codex reads its
    /// login from `CODEX_HOME/auth.json`.
    public static func patch(home: URL?, inheritedEnv: [String: String]) -> EnvPatch {
        guard let home else {
            if let injected = inheritedEnv[injectedHomeEnv], !injected.isEmpty, inheritedEnv["CODEX_HOME"] == injected {
                return EnvPatch(unset: ["CODEX_HOME", injectedHomeEnv])
            }
            return .empty
        }
        return EnvPatch(set: ["CODEX_HOME": home.path, injectedHomeEnv: home.path])
    }
}
