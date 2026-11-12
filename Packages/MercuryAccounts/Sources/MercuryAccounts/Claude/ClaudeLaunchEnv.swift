import Foundation
import MercuryAgents

/// Environment changes for launching `claude` under a profile or the default login.
public enum ClaudeLaunchEnv {
    /// Credentials in the environment that would override a profile's own login.
    public static let authEnvVars: [String] = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "AWS_BEARER_TOKEN_BEDROCK",
    ]
    /// Set beside every `CLAUDE_CONFIG_DIR` Mercury injects, so the shell function can tell it from the user's own.
    public static let injectedConfigDirEnv = "MERCURY_CLAUDE_INJECTED_CONFIG_DIR"

    /// `home` = profile: set `CLAUDE_CONFIG_DIR`, strip credential variables (and `ANTHROPIC_CUSTOM_HEADERS` when it
    /// carries auth headers). `nil` = default login: keep the user's own `CLAUDE_CONFIG_DIR` and ambient auth, and
    /// only drop a `CLAUDE_CONFIG_DIR` that Mercury itself injected earlier. Both drop the session stamps a parent
    /// Claude leaves in the environment.
    public static func patch(home: URL?, inheritedEnv: [String: String]) -> EnvPatch {
        var patch = EnvPatch(unset: Set(CLIEnvironment.claudeSessionStampKeys))
        guard let home else {
            if let injected = inheritedEnv[injectedConfigDirEnv], !injected.isEmpty,
               inheritedEnv["CLAUDE_CONFIG_DIR"] == injected {
                patch.unset.formUnion(["CLAUDE_CONFIG_DIR", injectedConfigDirEnv])
            }
            return patch
        }
        patch.unset.formUnion(authEnvVars)
        if isAuthLikeCustomHeaders(inheritedEnv["ANTHROPIC_CUSTOM_HEADERS"]) {
            patch.unset.insert("ANTHROPIC_CUSTOM_HEADERS")
        }
        patch.set["CLAUDE_CONFIG_DIR"] = home.path
        patch.set[injectedConfigDirEnv] = home.path
        return patch
    }

    static func isAuthLikeCustomHeaders(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return value.range(of: "authorization|x-api-key|api-key|bearer", options: [.regularExpression, .caseInsensitive])
            != nil
    }
}
