# Ownership and contracts for the three parallel branches

Plan 1 is implemented: read `docs/architecture.md`, `CLAUDE.md` and
`plans/261110-2054-mercury-native-agent-orchestrator/contracts.md` first. Every branch keeps Swift 6 strict concurrency,
zero warnings, English comments, English UI text, real Liquid Glass via `MercuryUI` helpers, native controls first.

## Shared rules

- Build the app only with your own derived data path in the scratchpad
  (`-derivedDataPath /private/tmp/claude-501/-Users-vudev-Self-Works-Mercury/1576978f-1db6-47e9-b17a-cc05890df824/scratchpad/DD-<branch>`)
  and always pass `-skipPackagePluginValidation -packageAuthorizationProvider netrc -allowProvisioningUpdates`. Never use
  `build/DerivedData` or `build/DD-controller`.
- After changing `project.yml` run `scripts/bootstrap.sh`.
- Another branch may break the build for a minute while it edits; wait and retry, never edit files you do not own.
- Never touch the real `~/.claude`, `~/.claude.json`, `~/.codex`, Keychain or the user's real Mercury data root
  (`~/Library/Application Support/Mercury`); tests use temp dirs. The app's real PTY helper is shared: tests that start
  sessions must use their own data root and clean up only their own sessions.
- Do not commit.

## Branch A — diff notes and side-by-side diff (phases 1–2)

Owns: `Packages/MercuryDiff/**`, `Packages/MercuryCore/Sources/MercuryCore/DiffNote.swift`,
`Packages/MercuryCore/Sources/MercuryCore/Migrations+DiffNotes.swift` (migration id `v3_diff_note`),
MercuryCore tests for notes, `App/Features/Diff/**`.
Sends notes into a session through `SessionRuntimeRegistry.runtime(for:)?.terminal` (read-only use of
`App/Features/Terminal/SessionRuntime.swift`; it may add a small public method there only via a new file
`App/Features/Diff/SessionRuntime+Paste.swift` extension).
Store API to add on `MercuryStore` (in `DiffNote.swift` as an extension): `diffNotes(worktreeID:)`, `save(_: DiffNote)`,
`deleteDiffNote(id:)`.

## Branch B — commit, push, pull requests (phases 3–4)

Owns: `Packages/MercuryGit/Sources/MercuryGit/{Status,Staging,Commit,Push,GitHubCLI}.swift` (+ tests),
`Packages/MercuryAgents/Sources/MercuryAgents/{HeadlessTextGenerator,ReadOnlyAgentPolicy,CommitMessagePrompt,PullRequestPrompt}.swift`
(+ tests), `App/Features/SourceControl/**`.
Integration points already wired by the controller: `SourceControlSection(context:)` (inspector of git contexts),
`SourceControlToolbarItems(context:)` (toolbar, git contexts), `PullRequestBadge(worktreeID:)` (sidebar worktree row) in
`App/Features/SourceControl/SourceControlHooks.swift` — replace their bodies, keep the names and initializers.
Headless agents run with the account env of the context (`AccountsController.launchEnv(for:accountID:)`).

## Branch C — orchestration (phases 5–6)

Owns: `Packages/MercuryPTYProtocol/**` (protocol additions + HostKit broker), `Helpers/MercuryPTYHost/**`,
`Tools/MercuryCLI/**` (new target), `project.yml` (only to add the CLI target and embed it), MercuryCore
`Orchestration/**` and `Migrations+Orchestration.swift` (migration id `v4_orchestration`),
`Packages/MercuryAgents/Sources/MercuryAgents/ClaudeHooks.swift` (Stop hook → `mercury hook`),
`Packages/MercuryAccounts/Sources/MercuryAccounts/Codex/CodexNotifyConfig.swift`, `App/Resources/Skills/**`,
`App/Features/Orchestration/**`, and in `App/Features/Terminal/SessionRuntime.swift` only the launch environment
(`makeLaunch`: `MERCURY_SESSION_TOKEN`, CLI on `PATH`) and the hook-event handling.
The app owns the database file; the helper must not write it concurrently. Recommended: the broker keeps its own
store under `<dataRoot>/orchestration/` (or asks the connected app over XPC), and `worker start` is executed by the app
(worktree creation, account env, launch) through a host → client XPC request; when no app is connected the broker
queues it and reports it clearly.
