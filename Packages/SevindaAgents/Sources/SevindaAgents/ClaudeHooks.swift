import Foundation

/// One Claude Code hook invocation as recorded in a session's events file.
public struct ClaudeHookEvent: Sendable, Hashable {
    /// `hook_event_name`: Notification, Stop, UserPromptSubmit, SessionStart, ...
    public var name: String
    /// `message` (Notification events), when present.
    public var message: String?
    /// `notification_type` (Notification events), e.g. `permission_prompt`, `idle_prompt`, `auth_success`.
    public var notificationType: String?

    public init(name: String, message: String? = nil, notificationType: String? = nil) {
        self.name = name
        self.message = message
        self.notificationType = notificationType
    }
}

/// Claude Code hooks that report session activity to Sevinda without touching `~/.claude`.
///
/// `install(dataRoot:)` writes `<dataRoot>/hooks/claude-settings.json`, which Sevinda passes to
/// `claude --settings <file>`; Claude merges it with the user's own settings. Each hook appends its
/// stdin JSON as one line to `$SEVINDA_HOOK_EVENTS` (one file per session under `hooks/events`) and,
/// in a terminal with a session token, hands it to `"$SEVINDA_CLI" hook claude` so the orchestration
/// broker learns when the turn ends. Outside Sevinda the variables are unset and the hook only drains stdin.
///
/// The settings also allow the `sevinda` command without a permission prompt: a worker reports through it in a
/// terminal nobody watches, where a prompt would stall the whole orchestration.
public enum ClaudeHooks {
    public static let events = ["SessionStart", "UserPromptSubmit", "Notification", "Stop"]
    public static let eventsFileEnvKey = "SEVINDA_HOOK_EVENTS"
    public static let sessionIDEnvKey = "SEVINDA_SESSION_ID"
    static let hookTimeoutSeconds = 10

    public struct Installation: Sendable, Hashable {
        public var settingsFile: URL
        public var eventsDirectory: URL

        public init(settingsFile: URL, eventsDirectory: URL) {
            self.settingsFile = settingsFile
            self.eventsDirectory = eventsDirectory
        }

        public func eventsFile(sessionID: UUID) -> URL {
            eventsDirectory.appendingPathComponent("\(sessionID.uuidString).jsonl")
        }

        /// Creates the session's events file (0600) if needed and tightens an existing one.
        /// Call before launching the agent so the file is private even before the first hook runs.
        @discardableResult
        public func prepareEventsFile(sessionID: UUID) throws -> URL {
            try ClaudeHooks.makePrivateDirectory(eventsDirectory)
            let url = eventsFile(sessionID: sessionID)
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
            defer { close(descriptor) }
            guard fchmod(descriptor, 0o600) == 0 else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
            return url
        }

        public func env(sessionID: UUID) -> EnvPatch {
            EnvPatch(set: [
                ClaudeHooks.eventsFileEnvKey: eventsFile(sessionID: sessionID).path,
                ClaudeHooks.sessionIDEnvKey: sessionID.uuidString,
            ])
        }
    }

    /// The hook command. Claude runs it through a shell; the explicit `/bin/sh -c` keeps the
    /// semantics POSIX regardless of the user's shell. It prints nothing (stdout of
    /// UserPromptSubmit/SessionStart hooks becomes model context) and always exits 0 so it can
    /// never block or fail a turn. Newlines are stripped so each event is exactly one line, and the
    /// line is appended with a single `printf` so concurrent hooks do not interleave. `umask 077`
    /// keeps an events file the hook creates private (0600): it contains prompt text. The broker
    /// call (`sevinda hook claude`) gives up after a few seconds and never fails either.
    public static let hookCommand: String = {
        let script = [
            "umask 077",
            "exec >/dev/null 2>&1",
            "line=$(tr -d \"\\r\\n\")",
            "[ -n \"$line\" ] || exit 0",
            "[ -n \"${SEVINDA_HOOK_EVENTS:-}\" ] && printf \"%s\\n\" \"$line\" >> \"$SEVINDA_HOOK_EVENTS\"",
            "[ -n \"${SEVINDA_SESSION_TOKEN:-}\" ] && [ -x \"${SEVINDA_CLI:-}\" ] && printf \"%s\" \"$line\" | \"$SEVINDA_CLI\" hook claude",
            "exit 0",
        ].joined(separator: "; ")
        return "/bin/sh -c '\(script)'"
    }()

    /// Permission rules merged into the session's settings: the `sevinda` orchestration command runs without a prompt.
    public static let allowedCommands = ["Bash(sevinda:*)"]

    /// The settings document: `{"hooks": {Event: [{"hooks": [{"type": "command", ...}]}]}, "permissions": {"allow": [...]}}`.
    static func settingsJSON() throws -> Data {
        let handler: [String: Any] = ["type": "command", "command": hookCommand, "timeout": hookTimeoutSeconds]
        var hooks: [String: Any] = [:]
        for event in events { hooks[event] = [["hooks": [handler]]] }
        let document: [String: Any] = ["hooks": hooks, "permissions": ["allow": allowedCommands]]
        return try JSONSerialization.data(
            withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Creates `url` (and missing parents) and sets it to 0700, also when it already existed.
    static func makePrivateDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Writes the settings file (only when its content changed) and creates the events directory.
    /// `hooks/` and `hooks/events/` are 0700 because event files hold prompt text.
    @discardableResult
    public static func install(dataRoot: URL) throws -> Installation {
        let hooksDirectory = dataRoot.appendingPathComponent("hooks", isDirectory: true)
        let installation = Installation(
            settingsFile: hooksDirectory.appendingPathComponent("claude-settings.json"),
            eventsDirectory: hooksDirectory.appendingPathComponent("events", isDirectory: true))
        try makePrivateDirectory(hooksDirectory)
        try makePrivateDirectory(installation.eventsDirectory)
        let data = try settingsJSON()
        if (try? Data(contentsOf: installation.settingsFile)) != data {
            try data.write(to: installation.settingsFile, options: .atomic)
        }
        return installation
    }

    /// Parses JSON lines. Blank, malformed, nameless and truncated lines (e.g. a partially
    /// written last line) are skipped.
    public static func parseEvents(_ data: Data) -> [ClaudeHookEvent] {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).compactMap(parseLine)
    }

    static func parseLine(_ line: Data) -> ClaudeHookEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let name = object["hook_event_name"] as? String, !name.isEmpty
        else { return nil }
        return ClaudeHookEvent(
            name: name, message: object["message"] as? String,
            notificationType: object["notification_type"] as? String)
    }
}
