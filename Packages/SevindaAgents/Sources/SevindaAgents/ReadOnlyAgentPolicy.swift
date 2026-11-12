import Foundation

/// Command lines that run `claude` and `codex` headless for text generation (commit messages, pull request text)
/// with no way to change files. Flags verified against Claude Code 2.1.322 and codex-cli 0.166.0.
///
/// The prompt carries all the context the agent needs (the diff, recent commits), so neither agent gets a tool that
/// writes, runs commands or reaches the network.
public enum ReadOnlyAgentPolicy {
    /// `claude -p`, prompt on stdin, plain text on stdout.
    ///
    /// - `--tools ""`: no built-in tool at all (no Bash, Edit, Write, NotebookEdit, WebFetch, ...).
    /// - `--disallowedTools`: denies the writing and command tools again, plus every MCP tool, in case a setting or a
    ///   future version adds tools back.
    /// - `--strict-mcp-config` without `--mcp-config`: no MCP server starts.
    /// - `--settings {"disableAllHooks":true}`: the user's hooks (which may run scripts or write files) stay off.
    /// - `--permission-mode dontAsk`: anything not allowed is refused instead of prompting (there is no one to ask).
    /// - `--no-session-persistence`: no transcript is written under the account's config directory.
    /// - `--disable-slash-commands`: skills and commands cannot be invoked from the prompt.
    public static func claudeArguments() -> [String] {
        [
            "-p",
            "--output-format", "text",
            "--tools", "",
            "--disallowedTools", "Bash,Edit,Write,MultiEdit,NotebookEdit,WebFetch,WebSearch,Task,mcp__*",
            "--strict-mcp-config",
            "--settings", #"{"disableAllHooks":true}"#,
            "--permission-mode", "dontAsk",
            "--no-session-persistence",
            "--disable-slash-commands",
        ]
    }

    /// `codex [--no-daemon] exec ... -`, prompt on stdin, the final message written to `outputFile`.
    ///
    /// - `--sandbox read-only` with `approval_policy="never"`: commands the model runs cannot write, and a write
    ///   (including `apply_patch`) that would need approval is refused, not asked.
    /// - `--ignore-user-config` and `--ignore-rules`: the user's `config.toml` (MCP servers, `notify` programs, hooks,
    ///   profiles) and execpolicy rules are not loaded; sign-in still comes from `CODEX_HOME`.
    /// - `features.plugins=false`, `features.apps=false`: no plugin or app connector loads.
    /// - `--ephemeral`: no session files are written.
    /// - `--skip-git-repo-check`: also works in a checkout codex does not trust yet.
    /// - `noDaemon`: the user's "Run without the shared background server" setting (`--no-daemon` is a top-level
    ///   option, so it comes before `exec`).
    public static func codexArguments(outputFile: URL, noDaemon: Bool) -> [String] {
        (noDaemon ? ["--no-daemon"] : []) + [
            "exec",
            "--sandbox", "read-only",
            "-c", #"approval_policy="never""#,
            "--ignore-user-config",
            "--ignore-rules",
            "-c", "features.plugins=false",
            "-c", "features.apps=false",
            "--ephemeral",
            "--skip-git-repo-check",
            "--color", "never",
            "--output-last-message", outputFile.path,
            "-",
        ]
    }

    /// Variables that make a CLI agent think it runs inside another agent session (when Sevinda itself was started
    /// from one), or that point it at Sevinda's interactive hook files. They are removed for headless runs.
    static let isolatedVariables: Set<String> = [
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "SEVINDA_SESSION_ID", "SEVINDA_SESSION_TOKEN",
        "SEVINDA_HOOK_EVENTS",
        "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED", "CODEX_THREAD_ID",
    ]
}
