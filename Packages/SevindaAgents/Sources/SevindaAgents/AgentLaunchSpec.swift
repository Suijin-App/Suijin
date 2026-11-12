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
    /// - claude: `claude [--settings <hooks file>] [--resume <id>] [prompt]`; the hook env for `sessionID` is merged
    ///   over `env` when both `hooks` and `sessionID` are given (without a session id the hooks are inert).
    /// - codex: `codex [resume <id>] [prompt]`; `hooks` is ignored (Claude-only).
    /// - shell: `binary` with no arguments.
    ///
    /// `resume` is the agent's own conversation id (`AgentResume`); an id that is not one is ignored.
    ///
    /// Both CLIs take the prompt as a trailing positional argument. A prompt starting with `-` is
    /// preceded by `--` so it is not parsed as an option. Blank prompts are dropped.
    public static func make(
        kind: AgentKind, binary: URL, cwd: URL, env: EnvPatch, initialPrompt: String?,
        hooks: ClaudeHooks.Installation?, sessionID: UUID? = nil, resume: String? = nil
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
            arguments += AgentResume.arguments(kind: .claude, sessionID: resume)
            arguments += promptArguments(prompt)
        case .codex:
            arguments += AgentResume.arguments(kind: .codex, sessionID: resume)
            arguments += promptArguments(prompt)
        case .shell:
            break
        }
        return AgentLaunchSpec(
            kind: kind, binary: binary, arguments: arguments, cwd: cwd, env: finalEnv,
            initialPrompt: kind == .shell ? nil : prompt)
    }

    static func promptArguments(_ prompt: String?) -> [String] {
        guard let prompt else { return [] }
        return prompt.hasPrefix("-") ? ["--", prompt] : [prompt]
    }
}
