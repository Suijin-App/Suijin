import Foundation
import SevindaCore

/// Everything needed to start one agent process: run `binary arguments` in `cwd` with `env`
/// applied to the base terminal environment.
public struct AgentLaunchSpec: Sendable, Hashable {
    public var kind: AgentKind
    public var binary: URL
    public var arguments: [String]
    public var cwd: URL
    public var env: EnvPatch
    /// Already included in `arguments`; kept for display and persistence.
    public var initialPrompt: String?

    public init(kind: AgentKind, binary: URL, arguments: [String], cwd: URL, env: EnvPatch, initialPrompt: String?) {
        self.kind = kind
        self.binary = binary
        self.arguments = arguments
        self.cwd = cwd
        self.env = env
        self.initialPrompt = initialPrompt
    }
}

public enum AgentLaunchSpecBuilder {
    /// Builds the launch for an interactive session.
    ///
    /// - claude: `claude [--settings <hooks file>] [permission flags] [--resume <id>] [prompt]`; the hook env for
    ///   `sessionID` is merged over `env` when both `hooks` and `sessionID` are given (without a session id the hooks
    ///   are inert).
    /// - codex: `codex [permission flags] [resume <id>] [prompt]`; `hooks` is ignored (Claude-only). The flags are
    ///   top-level options, so they go before the `resume` subcommand.
    /// - shell: `binary` with no arguments.
    ///
    /// `resume` is the agent's own conversation id (`AgentResume`); an id that is not one is ignored.
    /// `permissionMode` adds `permissionArguments`; nil or a mode the agent does not offer adds nothing.
    ///
    /// Both CLIs take the prompt as a trailing positional argument. A prompt starting with `-` is
    /// preceded by `--` so it is not parsed as an option. Blank prompts are dropped.
    public static func make(
        kind: AgentKind, binary: URL, cwd: URL, env: EnvPatch, initialPrompt: String?,
        hooks: ClaudeHooks.Installation?, sessionID: UUID? = nil, resume: String? = nil,
        permissionMode: AgentPermissionMode? = nil
    ) -> AgentLaunchSpec {
        let prompt = initialPrompt.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        var arguments: [String] = []
        var finalEnv = env
        switch kind {
        case .claude:
            if let hooks {
                arguments += ["--settings", hooks.settingsFile.path]
                if let sessionID { finalEnv = finalEnv.merging(hooks.env(sessionID: sessionID)) }
            }
            arguments += permissionArguments(kind: .claude, mode: permissionMode)
            arguments += AgentResume.arguments(kind: .claude, sessionID: resume)
            arguments += promptArguments(prompt)
        case .codex:
            arguments += permissionArguments(kind: .codex, mode: permissionMode)
            arguments += AgentResume.arguments(kind: .codex, sessionID: resume)
            arguments += promptArguments(prompt)
        case .shell:
            break
        }
        return AgentLaunchSpec(
            kind: kind, binary: binary, arguments: arguments, cwd: cwd, env: finalEnv,
            initialPrompt: kind == .shell ? nil : prompt)
    }

    /// The flags that start `kind` in `mode`. Verified against Claude Code 2.1.323 and codex-cli 0.167.2.
    ///
    /// - claude: `ask` none; `acceptEdits` and `plan` as `--permission-mode <mode>`; `bypass` as
    ///   `--dangerously-skip-permissions`.
    /// - codex: `ask` none (the user's `config.toml` decides); `auto` as `--sandbox workspace-write
    ///   --ask-for-approval on-request` (what the removed `--full-auto` did); `readOnly` as `--sandbox read-only`;
    ///   `bypass` as `--dangerously-bypass-approvals-and-sandbox`.
    ///
    /// A shell, nil, or a mode `kind` does not offer gives no flags.
    public static func permissionArguments(kind: AgentKind, mode: AgentPermissionMode?) -> [String] {
        guard let mode, mode.applies(to: kind) else { return [] }
        switch (kind, mode) {
        case (.claude, .acceptEdits): return ["--permission-mode", "acceptEdits"]
        case (.claude, .plan): return ["--permission-mode", "plan"]
        case (.claude, .bypass): return ["--dangerously-skip-permissions"]
        case (.codex, .auto): return ["--sandbox", "workspace-write", "--ask-for-approval", "on-request"]
        case (.codex, .readOnly): return ["--sandbox", "read-only"]
        case (.codex, .bypass): return ["--dangerously-bypass-approvals-and-sandbox"]
        default: return []
        }
    }

    static func promptArguments(_ prompt: String?) -> [String] {
        guard let prompt else { return [] }
        return prompt.hasPrefix("-") ? ["--", prompt] : [prompt]
    }
}
