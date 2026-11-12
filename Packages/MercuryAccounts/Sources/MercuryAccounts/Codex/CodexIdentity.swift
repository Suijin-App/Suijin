import Foundation

/// Identity claims of a Codex `auth.json`, read from the JWT payload of `tokens.id_token` (never verified: the file
/// is local and only labels the account in the UI).
public struct CodexAuthIdentity: Sendable, Hashable {
    public var email: String?
    public var providerAccountID: String?
    public var workspaceLabel: String?
    public var workspaceAccountID: String?
    /// `auth.json` holds an API key instead of a ChatGPT login.
    public var isAPIKey = false
}

public enum CodexIdentity {
    static let authClaims = "https://api.openai.com/auth"
    static let profileClaims = "https://api.openai.com/profile"

    /// Parses an auth.json document; nil when it is not a JSON object. Errors never echo the file's bytes.
    public static func parse(_ data: Data) -> CodexAuthIdentity? {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let key = raw["OPENAI_API_KEY"] as? String, !key.trimmingCharacters(in: .whitespaces).isEmpty {
            return CodexAuthIdentity(isAPIKey: true)
        }
        let tokens = raw["tokens"] as? [String: Any]
        let idToken = normalized(tokens?["id_token"] as? String ?? tokens?["idToken"] as? String)
        let payload = idToken.flatMap(jwtPayload)
        let auth = payload?[authClaims] as? [String: Any]
        let profile = payload?[profileClaims] as? [String: Any]
        // Blank ids must not shadow the fallbacks.
        let tokenAccountID = normalized(tokens?["account_id"] as? String ?? tokens?["accountId"] as? String)
        return CodexAuthIdentity(
            email: normalized(payload?["email"] as? String) ?? normalized(profile?["email"] as? String),
            providerAccountID: tokenAccountID ?? normalized(auth?["chatgpt_account_id"] as? String)
                ?? normalized(payload?["chatgpt_account_id"] as? String),
            workspaceLabel: normalized(auth?["workspace_name"] as? String)
                ?? normalized(profile?["workspace_name"] as? String) ?? planLabel(auth?["chatgpt_plan_type"] as? String),
            workspaceAccountID: normalized(auth?["workspace_account_id"] as? String) ?? tokenAccountID
                ?? normalized(payload?["chatgpt_account_id"] as? String))
    }

    /// The decoded middle part of a JWT (base64url without padding).
    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Codex tokens often omit `workspace_name` but name the plan.
    static func planLabel(_ plan: String?) -> String? {
        switch normalized(plan)?.lowercased() {
        case "free": "Personal (Free)"
        case "go": "Personal (Go)"
        case "plus": "Personal (Plus)"
        case "pro": "Personal (Pro)"
        case "team": "Team"
        case "business": "Business"
        case "enterprise": "Enterprise"
        case "edu": "Education"
        default: nil
        }
    }

    static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// The user's own Codex home: `CODEX_HOME` when set and not one Mercury injected for an account, else
    /// `~/.codex`. A leading `~` is expanded against `realHome`.
    public static func defaultLoginHome(environment: [String: String], realHome: URL) -> URL {
        let fallback = realHome.appendingPathComponent(".codex", isDirectory: true)
        guard let raw = normalized(environment["CODEX_HOME"]) else { return fallback }
        if let injected = normalized(environment[CodexLaunchEnv.injectedHomeEnv]),
           URL(fileURLWithPath: injected).standardizedFileURL == URL(fileURLWithPath: raw).standardizedFileURL {
            return fallback
        }
        let path = raw == "~" ? realHome.path : raw.hasPrefix("~/") ? realHome.path + raw.dropFirst(1) : raw
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// Access token and ChatGPT account id for the usage request, kept in memory only.
    static func backendCredentials(_ data: Data) -> (accessToken: String, accountID: String?)? {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = raw["tokens"] as? [String: Any],
              let token = normalized(tokens["access_token"] as? String)
        else { return nil }
        return (token, normalized(tokens["account_id"] as? String))
    }
}
