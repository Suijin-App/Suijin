import CryptoKit
import Foundation

/// Reads Claude Code's OAuth credentials for a profile.
///
/// Claude 2.1+ stores a config dir's login in the generic password `Claude Code-credentials-<sha256(NFC dir)[0:8]>`
/// (the unsuffixed item belongs to the default login) under the account `$USER`, or `claude-code-user` when the
/// user name is not Keychain-safe. Reads go through `/usr/bin/security` because the item's ACL trusts that tool and
/// the `claude` binary, not Suijin, so the Security framework would prompt. Tokens stay in memory only.
public struct ClaudeKeychainReader: Sendable {
    public static let defaultService = "Claude Code-credentials"
    static let fallbackUser = "claude-code-user"
    static let securityTool = URL(fileURLWithPath: "/usr/bin/security")
    /// `security` exit code for a missing item.
    static let itemNotFound: Int32 = 44

    let runner: any CommandRunning
    let user: String

    public init(runner: any CommandRunning = ProcessCommandRunner(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.runner = runner
        user = Self.keychainUser(environment: environment)
    }

    static func keychainUser(environment: [String: String]) -> String {
        let user = [environment["USER"], environment["USERNAME"], NSUserName()]
            .compactMap { $0 }.first { !$0.isEmpty } ?? ""
        let valid = !user.isEmpty && user.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil
        return valid ? user : fallbackUser
    }

    /// The Keychain service Claude uses for `configDir`; `nil` is the default login.
    public static func serviceName(configDir: String?) -> String {
        guard let configDir else { return defaultService }
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(defaultService)-\(hex.prefix(8))"
    }

    /// `configDir` plus its canonical spelling, resolved through existing ancestors without creating anything.
    /// A path with `..` or a broken symlink on the way gets no guessed alias.
    static func aliases(configDir: String) -> [String] {
        var aliases = [configDir]
        var missing: [String] = []
        var existing = configDir
        while true {
            do {
                if let real = try FileOps.realpath(existing) {
                    let canonical = missing.reduce(real) { FileOps.join($0, $1) }
                    if canonical != configDir { aliases.append(canonical) }
                    break
                }
            } catch {
                break
            }
            if configDir.split(separator: "/").contains("..") { break }
            // A dangling link has no known target; do not invent its alias.
            if (try? FileOps.lstatKind(existing)) != nil { break }
            let parent = (existing as NSString).deletingLastPathComponent
            if parent == existing || parent.isEmpty { break }
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = parent
        }
        return aliases
    }

    /// Literal spellings Claude may have hashed into a service name: aliases, `~/...`, `$HOME/...`, with and
    /// without a trailing slash.
    static func spellings(configDir: String, userHome: String) -> [String] {
        var result: [String] = []
        func add(_ value: String) { if !result.contains(value) { result.append(value) } }
        for dir in aliases(configDir: configDir) {
            var trimmed = dir
            while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
            var variants = [trimmed]
            if trimmed.hasPrefix(userHome + "/") {
                let rest = trimmed.dropFirst(userHome.count)
                variants += ["~\(rest)", "$HOME\(rest)"]
            }
            for variant in variants {
                add(variant)
                add(variant + "/")
            }
        }
        return result
    }

    /// The raw credentials JSON for a profile. Only the profile's own items are tried, never the default login's.
    func readCredentials(configDir: String) async throws -> String? {
        for dir in Self.aliases(configDir: configDir) {
            let service = Self.serviceName(configDir: dir)
            // A profile must never fall back to the default login's credentials.
            guard service != Self.defaultService else { continue }
            if let value = try await readItem(service: service) { return value }
        }
        return nil
    }

    /// One generic password through `security`; nil when the item is missing or empty.
    private func readItem(service: String) async throws -> String? {
        let result = try await runner.run(
            Self.securityTool, ["find-generic-password", "-s", service, "-a", user, "-w"],
            environment: nil, timeout: 3)
        if result.timedOut { throw UsageError.keychainUnavailable }
        if result.exitCode == 0 {
            let value = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        let stderr = String(decoding: result.stderr, as: UTF8.self).lowercased()
        if result.exitCode == Self.itemNotFound || stderr.contains("could not be found") { return nil }
        throw UsageError.keychainUnavailable
    }

    /// The user's own `CLAUDE_CONFIG_DIR`, if set in `environment` and not one Suijin injected for a profile.
    /// A leading `~` is expanded against `realHome`.
    public static func defaultLoginConfigDir(environment: [String: String], realHome: URL) -> URL? {
        guard let raw = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        if let injected = environment[ClaudeLaunchEnv.injectedConfigDirEnv]?.trimmingCharacters(in: .whitespaces),
           !injected.isEmpty, URL(fileURLWithPath: injected).standardizedFileURL == URL(fileURLWithPath: raw).standardizedFileURL {
            return nil
        }
        let path = raw == "~" ? realHome.path : raw.hasPrefix("~/") ? realHome.path + raw.dropFirst(1) : raw
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// The OAuth access token of the user's own default login, read-only and kept in memory.
    ///
    /// This is deliberately separate from the profile lookup, which never falls back to the default login. With a
    /// user `CLAUDE_CONFIG_DIR` (`configDir`), Claude keys the item by that folder, so its scoped items come first and
    /// the unsuffixed default item second; without one only the unsuffixed item is read. The last resort is
    /// `.credentials.json` in the config folder (`~/.claude` by default). Throws `keychainUnavailable` only when the
    /// Keychain could not be read and no file holds a token either.
    public func defaultLoginAccessToken(configDir: URL?, realHome: URL) async throws -> String? {
        var keychainError: Error?
        var services: [String] = []
        if let configDir {
            services += Self.aliases(configDir: configDir.path).map { Self.serviceName(configDir: $0) }
        }
        services.append(Self.defaultService)
        var seen = Set<String>()
        for service in services where seen.insert(service).inserted {
            do {
                if let json = try await readItem(service: service), let token = Self.accessToken(fromJSON: json) {
                    return token
                }
            } catch {
                keychainError = error
            }
        }
        let dir = configDir ?? realHome.appendingPathComponent(".claude", isDirectory: true)
        if let data = try? FileOps.readData(dir.appendingPathComponent(".credentials.json").path),
           let token = Self.accessToken(fromJSON: String(decoding: data, as: UTF8.self)) {
            return token
        }
        if let keychainError { throw keychainError }
        return nil
    }

    /// The OAuth access token of a profile: its Keychain item, else its `.credentials.json`.
    func accessToken(configDir: URL) async throws -> String? {
        if let json = try await readCredentials(configDir: configDir.path), let token = Self.accessToken(fromJSON: json) {
            return token
        }
        let file = configDir.appendingPathComponent(".credentials.json").path
        guard let data = try? FileOps.readData(file) else { return nil }
        return Self.accessToken(fromJSON: String(decoding: data, as: UTF8.self))
    }

    static func accessToken(fromJSON json: String) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    /// Deletes every Keychain item a profile may own. The default login's item is never touched.
    func deleteItems(configDir: String, userHome: String) async {
        for spelling in Self.spellings(configDir: configDir, userHome: userHome) {
            let service = Self.serviceName(configDir: spelling)
            guard service != Self.defaultService else { continue }
            // Each call removes one item for the service; stop at the first failure (none left).
            for _ in 0..<4 {
                let result = try? await runner.run(
                    Self.securityTool, ["delete-generic-password", "-s", service], environment: nil, timeout: 3)
                guard result?.exitCode == 0 else { break }
            }
        }
    }
}
