import Foundation

/// Copies the shareable part of the user's Claude global state (`~/.claude.json`) into a profile.
///
/// Keys bound to the signed-in account (login, caches, identifiers, a Console key) never cross. `projects`,
/// `mcpServers` and `groveChoiceSeenAt` merge per entry so a profile keeps its own projects, servers, trust grants
/// and newest Grove confirmations; any other shared key takes the default value; keys only the profile has stay.
enum ClaudeStateCopy {
    /// Logout keys and subscription notices of Claude 2.1.x; onboarding state stays shareable.
    static let logoutStateKeys: [String] = [
        "oauthAccount", "additionalModelOptionsCache", "additionalModelOptionsAnsweredAt",
        "additionalModelCostsCache", "modelAccessCache", "orgModelDefaultCache", "cachedArtifactRoster",
        "artifactRosterDenied", "lastSeenOrgDefaultUpdatedAt", "clientDataCache", "clientDataCacheSlots",
        "autoCompactWindowsCache", "cachedUsageUtilization", "metricsStatusCache", "metricsStatusCacheByPrincipal",
        "githubWebConnectionStatusCache", "startupPrefetchedAt", "subscriptionNoticeCount",
        "hasAvailableSubscription",
    ]

    static let accountBoundKeys: Set<String> = Set(logoutStateKeys).union([
        "userID", "machineID", "firstStartTime", "firstStartVersion",
        // A copied Console key would override the account's own login.
        "primaryApiKey",
        // Claude never refetches this account-specific date.
        "claudeCodeFirstTokenDate",
    ])

    static let mergedByEntry: Set<String> = ["projects", "mcpServers", "groveChoiceSeenAt"]

    static func isAccountBound(_ key: String) -> Bool {
        // Logout leaves further account caches such as groveConfigCache and passes*.
        accountBoundKeys.contains(key) || key.contains("Cache") || key.hasPrefix("cached") || key.hasPrefix("passes")
    }

    /// Claude's global state file for a config dir: a legacy `<dir>/.config.json` wins, else `.claude.json` in the
    /// config dir, or in the user's home when no config dir is set.
    static func stateFile(configDir: URL?, realHome: URL) -> URL {
        let legacyDir = configDir ?? realHome.appendingPathComponent(".claude", isDirectory: true)
        let legacy = legacyDir.appendingPathComponent(".config.json")
        if (try? FileOps.lstatKind(legacy.path)) != nil { return legacy }
        return (configDir ?? realHome).appendingPathComponent(".claude.json")
    }

    static func copy(source: URL, target: URL) throws -> ProvisionOutcome {
        if try FileOps.lstatKind(target.path) == .symlink { return .userOwned }
        let input: [String: Any]
        switch FileOps.readJSONObject(source.path) {
        case .present(let value): input = value
        case .absent: return .absent
        case .invalidJSON, .unreadable: throw ProvisionError.unreadable("Personal Claude state is unreadable")
        }
        let shared = input.filter { !isAccountBound($0.key) }

        if try FileOps.lstatKind(target.path) == nil {
            // Publish without replacing a file Claude created concurrently.
            if try FileOps.createExclusively(FileOps.prettyJSON(shared), at: target.path, mode: 0o600) {
                return .synced
            }
        }
        let current: [String: Any]
        switch FileOps.readJSONObject(target.path) {
        case .present(let value): current = value
        case .absent: current = [:]
        case .invalidJSON, .unreadable: throw ProvisionError.unreadable("Profile Claude state is unreadable")
        }
        var config = current
        for (key, value) in shared {
            config[key] = mergedByEntry.contains(key) ? merge(key, current: current[key], source: value) : value
        }
        if FileOps.jsonEqual(config, current) { return .unchanged }
        try FileOps.writeAtomically(FileOps.prettyJSON(config), to: target.path, mode: 0o600)
        return .merged
    }

    static func merge(_ key: String, current: Any?, source: Any) -> Any {
        guard let current = current as? [String: Any], let source = source as? [String: Any] else { return source }
        var merged = current.merging(source) { _, theirs in theirs }
        if key == "projects" {
            for (path, entry) in source {
                // Keep trust granted in this account, including just before launch.
                if let own = current[path] as? [String: Any], own["hasTrustDialogAccepted"] as? Bool == true,
                   var entry = entry as? [String: Any] {
                    entry["hasTrustDialogAccepted"] = true
                    merged[path] = entry
                }
            }
        }
        if key == "groveChoiceSeenAt" {
            // Claude trusts a confirmation only while it is fresh, so keep each account's newest one.
            for (account, seenAt) in current {
                guard let mine = JSONNumber.double(seenAt) else { continue }
                if let theirs = JSONNumber.double(source[account]), theirs >= mine { continue }
                merged[account] = seenAt
            }
        }
        return merged
    }

    /// `oauthAccount` of a state file, read for the account list.
    static func identity(stateFile: URL) -> AccountIdentity? {
        guard case .present(let state) = FileOps.readJSONObject(stateFile.path),
              let account = state["oauthAccount"] as? [String: Any]
        else { return nil }
        func text(_ key: String) -> String? {
            let value = (account[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        guard let email = text("emailAddress") else { return nil }
        return AccountIdentity(
            email: email, organization: text("organizationName"),
            accountID: text("accountUuid") ?? text("organizationUuid"))
    }
}
