import Foundation

/// Keeps a profile's `settings.json` in step with the default home per top-level key.
///
/// A record of per-key digests from the last sync (digests, not values, so secrets in settings are not stored twice)
/// tells which keys the default home changed since. Only those keys are applied; every other key keeps the
/// profile's value, so settings Claude saved inside the profile itself (such as `/model`) survive the next launch.
/// Without a record the default home wins whole.
///
/// Auth-bearing settings never reach a profile: Claude ranks an API key helper, AWS credential hooks, a forced login
/// method or org, and credential variables in `env` above the profile's claude.ai login, so sharing them would run
/// every managed account on the user's personal credentials. (Orca shares them; Mercury deliberately does not.)
enum ClaudeSettingsSync {
    static let authKeys: Set<String> = [
        "apiKeyHelper", "awsAuthRefresh", "awsCredentialExport", "forceLoginMethod", "forceLoginOrgUUID",
    ]

    /// `settings` without auth-bearing entries, and the names of what was removed (names only, never values).
    static func withoutAuth(_ settings: [String: Any]) -> (settings: [String: Any], removed: [String]) {
        var result = settings
        var removed: [String] = []
        for key in authKeys.sorted() where result[key] != nil {
            result.removeValue(forKey: key)
            removed.append(key)
        }
        if var env = result["env"] as? [String: Any] {
            for key in ClaudeLaunchEnv.authEnvVars where env[key] != nil {
                env.removeValue(forKey: key)
                removed.append("env.\(key)")
            }
            if ClaudeLaunchEnv.isAuthLikeCustomHeaders(env["ANTHROPIC_CUSTOM_HEADERS"] as? String) {
                env.removeValue(forKey: "ANTHROPIC_CUSTOM_HEADERS")
                removed.append("env.ANTHROPIC_CUSTOM_HEADERS")
            }
            result["env"] = env
        }
        return (result, removed)
    }

    /// The sync outcome plus the auth settings that were held back.
    static func sync(source: URL, target: URL, record: URL) throws -> (outcome: ProvisionOutcome, withheld: [String]) {
        if try FileOps.lstatKind(target.path) == .symlink { return (.userOwned, []) }
        let input = FileOps.readJSONObject(source.path)
        var defaults: [String: Any]
        switch input {
        case .present(let value): defaults = value
        case .absent: defaults = [:]
        case .invalidJSON, .unreadable: throw ProvisionError.unreadable("Personal Claude settings are unreadable")
        }
        // Digests cover the filtered settings, so profiles synced before filtering lose these keys on the next pass.
        let (shared, withheld) = withoutAuth(defaults)
        defaults = shared
        let current = FileOps.readJSONObject(target.path)
        // A profile copy that does not parse is replaced; one that could not be read is never overwritten.
        if case .unreadable = current { throw ProvisionError.unreadable("Profile Claude settings are unreadable") }
        let lastSync = FileOps.readJSONObject(record.path)
        let digests = digest(defaults)

        var settings = defaults
        if case .present(let currentValue) = current, case .present(let last) = lastSync {
            settings = currentValue
            for key in Set(digests.keys).union(last.keys) {
                if let recorded = last[key] as? String, recorded == digests[key] { continue }
                if let value = defaults[key] {
                    settings[key] = value
                } else {
                    settings.removeValue(forKey: key)
                }
            }
        }

        let unchanged: Bool
        switch current {
        case .present(let value): unchanged = FileOps.jsonEqual(settings, value)
        case .absent: if case .absent = input { unchanged = true } else { unchanged = false }
        default: unchanged = false
        }
        var outcome = ProvisionOutcome.unchanged
        if !unchanged {
            try FileOps.writeAtomically(FileOps.prettyJSON(settings), to: target.path, mode: 0o600)
            outcome = .synced
        }
        let previous: [String: Any]? = if case .present(let last) = lastSync { last } else { nil }
        if previous.map({ !FileOps.jsonEqual($0, digests) }) ?? true {
            var data = FileOps.canonicalJSON(digests)
            data.append(0x0A)
            try FileOps.writeAtomically(data, to: record.path, mode: 0o600)
        }
        return (outcome, withheld)
    }

    static func digest(_ settings: [String: Any]) -> [String: String] {
        settings.mapValues { FileOps.sha256Hex(FileOps.canonicalJSON($0)) }
    }
}
