import Foundation
import SuijinCore
import Testing
@testable import SuijinAgents

/// The flags each permission mode adds, alone and together with the hook settings, a resumed conversation, an account's
/// environment and a prompt.
struct PermissionModeLaunchTests {
    static let claudeID = "0f4c3a52-7d1e-4b8a-9c2d-5e6f7a8b9c0d"
    static let codexID = "019a5f3e-8c2b-7d41-a9e0-3b6c1d2e4f50"
    let hooks = ClaudeHooks.Installation(settingsFile: URL(fileURLWithPath: "/data/hooks/claude-settings.json"),
                                         eventsDirectory: URL(fileURLWithPath: "/data/hooks/events"))
    let account = EnvPatch(set: ["CLAUDE_CONFIG_DIR": "/acct"], unset: ["ANTHROPIC_API_KEY"])
    let codexAccount = EnvPatch(set: ["CODEX_HOME": "/acct"], unset: ["OPENAI_API_KEY"])

    static let claudeFlags: [AgentPermissionMode: [String]] = [
        .ask: [],
        .acceptEdits: ["--permission-mode", "acceptEdits"],
        .plan: ["--permission-mode", "plan"],
        .bypass: ["--dangerously-skip-permissions"],
    ]
    static let codexFlags: [AgentPermissionMode: [String]] = [
        .ask: [],
        .auto: ["--sandbox", "workspace-write", "--ask-for-approval", "on-request"],
        .readOnly: ["--sandbox", "read-only"],
        .bypass: ["--dangerously-bypass-approvals-and-sandbox"],
    ]

    @Test func everyModeOfEveryAgent() {
        for mode in AgentPermissionMode.allCases {
            #expect(AgentLaunchSpecBuilder.permissionArguments(kind: .claude, mode: mode) == Self.claudeFlags[mode] ?? [])
            #expect(AgentLaunchSpecBuilder.permissionArguments(kind: .codex, mode: mode) == Self.codexFlags[mode] ?? [])
            #expect(AgentLaunchSpecBuilder.permissionArguments(kind: .shell, mode: mode).isEmpty)
        }
        #expect(AgentLaunchSpecBuilder.permissionArguments(kind: .claude, mode: nil).isEmpty)
        #expect(AgentLaunchSpecBuilder.permissionArguments(kind: .codex, mode: nil).isEmpty)
    }

    @Test(arguments: AgentPermissionMode.modes(for: .claude))
    func claudeModeGoesAfterTheSettingsAndBeforeResumeAndPrompt(_ mode: AgentPermissionMode) throws {
        let session = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let spec = AgentLaunchSpecBuilder.make(
            kind: .claude, binary: URL(fileURLWithPath: "/bin/claude"), cwd: URL(fileURLWithPath: "/w"), env: account,
            initialPrompt: "fix it", hooks: hooks, sessionID: session, resume: Self.claudeID, permissionMode: mode)
        let flags = try #require(Self.claudeFlags[mode])
        #expect(spec.arguments == ["--settings", "/data/hooks/claude-settings.json"] + flags
                + ["--resume", Self.claudeID, "fix it"])
        // The account and the hooks still reach the environment.
        #expect(spec.env.set["CLAUDE_CONFIG_DIR"] == "/acct")
        #expect(spec.env.set["SUIJIN_SESSION_ID"] == session.uuidString)
        #expect(spec.env.unset == ["ANTHROPIC_API_KEY"])
    }

    @Test(arguments: AgentPermissionMode.modes(for: .codex))
    func codexModeGoesBeforeTheResumeSubcommand(_ mode: AgentPermissionMode) throws {
        let spec = AgentLaunchSpecBuilder.make(
            kind: .codex, binary: URL(fileURLWithPath: "/bin/codex"), cwd: URL(fileURLWithPath: "/w"), env: codexAccount,
            initialPrompt: "-explain", hooks: hooks, sessionID: UUID(), resume: Self.codexID, permissionMode: mode)
        let flags = try #require(Self.codexFlags[mode])
        #expect(spec.arguments == flags + ["resume", Self.codexID, "--", "-explain"])
        #expect(spec.env == codexAccount)
    }

    @Test func aModeTheAgentLacksAddsNothing() {
        let claude = AgentLaunchSpecBuilder.make(kind: .claude, binary: URL(fileURLWithPath: "/bin/claude"),
                                                 cwd: URL(fileURLWithPath: "/w"), env: .empty, initialPrompt: nil,
                                                 hooks: nil, permissionMode: .readOnly)
        #expect(claude.arguments.isEmpty)
        let codex = AgentLaunchSpecBuilder.make(kind: .codex, binary: URL(fileURLWithPath: "/bin/codex"),
                                                cwd: URL(fileURLWithPath: "/w"), env: .empty, initialPrompt: nil,
                                                hooks: nil, permissionMode: .plan)
        #expect(codex.arguments.isEmpty)
        let shell = AgentLaunchSpecBuilder.make(kind: .shell, binary: URL(fileURLWithPath: "/bin/zsh"),
                                                cwd: URL(fileURLWithPath: "/w"), env: .empty, initialPrompt: nil,
                                                hooks: nil, permissionMode: .bypass)
        #expect(shell.arguments.isEmpty)
    }
}
