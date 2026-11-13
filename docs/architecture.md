# Architecture

Suijin is one app target, one helper and a set of local Swift packages. The Xcode project is generated from
`project.yml` by `scripts/bootstrap.sh`.

## Package graph

```
SuijinUI            design system (tokens, glass styles, components); no domain dependency
SuijinCore          models and persistent state (GRDB, ~/Library/Application Support/Suijin/suijin.sqlite)
SuijinGit           the git CLI behind a typed API: worktrees, branches, unified diff parser and diff service
SuijinPTYProtocol   XPC contract between app and PTY host; SuijinPTYHostKit holds the helper's logic (sessions,
                    orchestration broker); SuijinCLIKit is the `suijin` command
SuijinTerminal      TerminalEngine protocol, SwiftTerm view, hosted (XPC) engine, shell launch and integration
SuijinAgents        agent catalog (claude, codex), launch specs, Claude hooks, status tracking
SuijinAccounts      managed Claude and Codex accounts: profile homes, login, identity, usage, launch env
SuijinDiff          native TextKit 2 diff view with tree-sitter highlighting
SuijinUsage         token usage and estimated cost from Claude Code and Codex JSONL logs (read-only), cached
                    incrementally in <dataRoot>/usage/cache.json; no dependency
```

Arrows point from a package to what it imports: `SuijinAgents → SuijinCore`, `SuijinAccounts → SuijinCore,
SuijinAgents`, `SuijinTerminal → SwiftTerm, SuijinPTYProtocol`, `SuijinDiff → SuijinGit, SuijinUI`; `SuijinUsage`
imports nothing (the app passes it the managed account homes). The app imports every package; packages never import
the app.

## Processes

- **Suijin.app** owns the UI, the database and git calls.
- **SuijinPTYHost** (`Contents/MacOS/SuijinPTYHost`, registered with `SMAppService.agent` from
  `Contents/Library/LaunchAgents/com.tekmium.suijin.ptyhost.plist`) owns every PTY and its process tree, keeps a
  scrollback ring buffer per session, and serves the Mach service `com.tekmium.suijin.ptyhost` over XPC. Sessions
  survive the app quitting or crashing; on launch the app lists the host's sessions and attaches again to those still
  running, replaying the scrollback. A session whose process ended meanwhile is recorded as ended without being shown
  (the host keeps an exited session's scrollback for a day). The helper exits once no session remains.

## Agent orchestration

An agent in a Suijin terminal can start worker agents with the bundled `suijin` CLI
(`Suijin.app/Contents/Helpers/suijin`, put on `PATH` only in Suijin's terminals), message them and get their results
back. The broker lives in the PTY host (`SuijinPTYHostKit/Orchestration`), one per data root, so delivery continues
while the app is closed:

- Every terminal gets `SUIJIN_SESSION_ID`, a random `SUIJIN_SESSION_TOKEN` (environment only, never arguments or
  logs) and the broker's addresses. The broker identifies callers by token; a terminal Suijin did not open is refused.
- Transport: one JSON line over `<dataRoot>/orchestration/broker.sock` (600, in a 700 directory; a path too long for
  `sun_path` moves to the user's temporary directory), or a file spool in the temporary directory for callers whose
  sandbox refuses sockets (Codex `workspace-write`).
- State: `<dataRoot>/orchestration/state.json`, written only by the helper (the app database has no orchestration
  tables). Work left by a previous helper process is closed on load.
- `worker start` is executed by the app (worktree, account, launch) through the XPC endpoint `orchestrationEndpoint`
  (protocol 3); with no app connected it is queued. The app mirrors the state for the sidebar's worker tree and the
  inspector, and posts a notification when a coordinator needs the user.
- Turn ends come from Claude's hooks (`suijin hook claude`) and Codex's `notify` (`-c notify=[…]` per launch, chained
  to the user's own). A message is typed once (bracketed paste, then Return) when the recipient is idle and the user
  has not typed there for 3 s. A worker that ends its turn or exits without `suijin done` is escalated.
- The guide (`App/Resources/Skills/suijin-orchestration/SKILL.md`) reaches Claude as a `--plugin-dir` plugin and
  managed Codex homes whose `skills` folder is their own; `~/.claude/skills` only through the Settings toggle.

The app speaks protocol 3 and still works with a protocol 2 helper (the user's sessions keep running); orchestration
stays off until `HelperVersionCheck` replaces that helper once it is idle.

## Agent sessions

A session runs in a context: a folder workspace, the main checkout of a git workspace, or a worktree. Launching an
agent combines:

1. `AgentLaunchSpec` (binary from the login-shell `PATH`, arguments, working directory);
2. the account's `EnvPatch` (`CLAUDE_CONFIG_DIR` or `CODEX_HOME`, auth variables removed) from `SuijinAccounts`;
3. for Claude, `--settings <dataRoot>/hooks/claude-settings.json`, whose hooks append events to
   `<dataRoot>/hooks/events/<session>.jsonl`; the app watches that file to know when an agent waits for input.

The launch goes through the user's login shell so `PATH` matches their terminal, then to the PTY host.

`claude` or `codex` typed in a shell session runs through Suijin's shell functions, which announce the run with a
private OSC written to the terminal (`ESC ] 6973 ; start;<agent>` and `end;<agent>;<status>`, the end also from the
prompt hook after Ctrl-C), and pass Claude the same `--settings` (shell sessions get `SUIJIN_CLAUDE_SETTINGS` and
`SUIJIN_HOOK_EVENTS`). While the agent runs, the session shows its logo, title, status and notifications, counts in
the stats and keeps its resume id (`ShellAgentSessions.swift`); the state is runtime-only and replayed from the
scrollback after a relaunch. The record stays a shell, and when the agent exits the tab is a shell again. `exec
claude`, `command claude` and a `claude` function of the user's bypass the functions and stay a plain shell.

## Accounts

Each managed account has its own home under the data root (`claude-profiles/<id>/home`, `codex-homes/<id>/home`).
Claude profiles share the user's `~/.claude` content through symlinks, copies and a per-key settings sync, but keep
their own credentials (a Keychain item named after the profile directory). The `selected-host` pointer files let the
`claude` and `codex` shell functions in Suijin terminals use the selected account. The user's own `~/.claude`,
`~/.codex` and default Keychain item are never written.

## Split tabs

A tab shows one session, or two to ten sessions as panes. `PaneLayout` (SuijinCore) is the pane tree: n-ary splits
along one axis with each child's share, the focused pane and a zoomed pane; its operations are pure and keep the tree
normalized. The app keeps one layout per split tab (`App/Features/Terminal/PaneLayouts.swift`, the only code that
changes them) and stores it as JSON in `pane_layout` (migration `v6_pane_layout`). Layouts come back at launch from the
session records alone, so a pane whose process ended shows its ended view in its cell; panes whose session is gone
are dropped, and a layout left with one pane becomes a plain tab again. The tab order stores split tabs by layout id.
A new pane (⌘D, ⇧⌘D, the title-bar split button, context menus) runs the agent of the `panes.defaultAgent` setting, by
default the focused pane's agent and account; the split button's menu can pick another for one pane.

Panes are rearranged by dragging a pane's header (`PaneDragAndDrop.swift`): a system drag session with a payload type
of its own (`com.tekmium.suijin.pane`, declared in `Info.plist`), so tab drags and pane drags never land on each
other. Over another pane, `PanePlacement(dropAt:in:)` (SuijinCore) picks one of five zones (an edge places the pane
beside it, the middle swaps the two), and dropping on the title-bar tab group moves the pane to a tab of its own.
⌃⌥⌘ arrows and Session ▸ Move Pane swap the focused pane with its neighbor. After any rearrangement,
`PaneRearrangeAnimation` slides each pane's layer from its old frame to its new one. The terminal views move into
their new containers and are never recreated.

## Keyboard shortcuts

`ShortcutCatalog` (`App/Features/Settings/ShortcutCatalog.swift`) defines every keyboard shortcut once; menu commands
and buttons bind `ShortcutCatalog.<entry>.shortcut`, and Settings › Shortcuts (Help › Keyboard Shortcuts, ⌘/) lists
the same entries with the mouse gestures. While a terminal has focus, `TerminalKeyRouter` (SuijinTerminal) handles
the tab, pane and edit shortcuts itself. `ShortcutCatalogTests` fails when a `.keyboardShortcut(…)` in the app does not
come from the catalog (sheets' standard Return and Esc buttons aside), when a terminal route has no catalog entry with
the same keys, or when a catalog shortcut would reach another route.

## Terminal output flow

Output travels PTY → helper → XPC → `HostedTerminalEngine` → `TerminalSession` → SwiftTerm. The app feeds SwiftTerm
through `TerminalFeedScheduler`: every session in turn, at most ~5 ms of parsing per main-loop turn, so a flooding
terminal never freezes the window. After each chunk the session calls `outputConsumed`, the engine acknowledges the
bytes to the helper (protocol version 2), and the helper only sends within a 2 MB window per client. A slow app
therefore pauses the helper's read, the kernel buffer fills and the program blocks, as in any terminal; app memory
stays bounded and the helper's scrollback stays complete.

## Session ownership

Every launch carries `suijin.session` and `suijin.dataRoot` metadata. On launch the app attaches to host sessions its
records name, and terminates only unknown running sessions tagged with its own data root, so another data root (a
second build, the tests) sharing the helper never loses its sessions. An exit Suijin caused (closing a tab, quitting
with sessions not kept) is not reported; other exits are recorded once and notified once. Either way the session's
runtime is released (the host forgets the session), so its tab or pane shows the Session Ended view; a failed session
keeps its last few output lines in memory for that view.

An ended Claude or Codex session can be resumed in place: the same record runs again with `claude --resume <id>` or
`codex resume <id>`, so its tab or pane, account and folder stay. The id (`agent_session.agentSessionID`, migration
`v7_agent_session_id`) comes from Claude's hook events (`session_id`, stored as soon as a hook reports it) or from the
resume hint the CLI prints as it exits (Codex reports its thread id only to the broker, so the hint comes first for it).

Each agent session starts in a permission mode (`AgentPermissionMode`, stored in `agent_session.permissionMode`,
migration `v8_permission_mode`, NULL meaning Ask): the per-agent default from Settings › Agents, or one picked in the
Permissions submenu; `AgentLaunchSpecBuilder.permissionArguments` maps it to CLI flags (Claude
`--permission-mode acceptEdits|plan` or `--dangerously-skip-permissions`; Codex `--sandbox …`/`--ask-for-approval …`
or `--dangerously-bypass-approvals-and-sandbox`, placed before `resume`). Resume, Start Again and New Session Like
This reuse the record's mode; headless text generation (`ReadOnlyAgentPolicy`) and agents typed in a shell are unaffected.

Agent launches go through a plain login shell (`-l -c`), with the `PATH` that `AgentCatalog.loginShellPATH` resolved
from an interactive login shell, passed through `/usr/bin/env` after the profile ran together with the account's
environment changes. Interactive shells get the full integration (`ZDOTDIR` wrapper, bash rcfile).

## Tests

- `swift test --package-path Packages/<name>` for each package.
- `AppTests` run inside the signed app: workspace and worktree flows, a shell in the real PTY host across a model
  restart, data-root isolation, launch environment, and a 10-terminal flood (`LoadTests`). Opt-in suites:
  `SUIJIN_AGENT_SMOKE=1` (real `claude`/`codex`), `SUIJIN_SEED_ROOT=<dir>` (demo data for screenshots),
  `SUIJIN_SCREENSHOTS=<dir>` (offscreen renders of forms; use real window captures for anything with a sidebar or
  overlapping views), `SUIJIN_ENDED_SHOT=<file>` (the Session Ended view, captured by window id with
  `screencapture -l`). Pass them with the `TEST_RUNNER_` prefix to `xcodebuild test`.
- `scripts/ci-local.sh` runs everything; it must be green before a phase closes.
