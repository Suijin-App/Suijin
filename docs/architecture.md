# Architecture

Mercury is one app target, one helper and a set of local Swift packages. The Xcode project is generated from
`project.yml` by `scripts/bootstrap.sh`.

## Package graph

```
MercuryUI            design system (tokens, glass styles, components); no domain dependency
MercuryCore          models and persistent state (GRDB, ~/Library/Application Support/Mercury/mercury.sqlite)
MercuryGit           the git CLI behind a typed API: worktrees, branches, unified diff parser and diff service
MercuryPTYProtocol   XPC contract between app and PTY host; MercuryPTYHostKit holds the helper's logic (sessions,
                     orchestration broker); MercuryCLIKit is the `mercury` command
MercuryTerminal      TerminalEngine protocol, SwiftTerm view, hosted (XPC) engine, shell launch and integration
MercuryAgents        agent catalog (claude, codex), launch specs, Claude hooks, status tracking
MercuryAccounts      managed Claude and Codex accounts: profile homes, login, identity, usage, launch env
MercuryDiff          native TextKit 2 diff view with tree-sitter highlighting
MercuryUsage         token usage and estimated cost from Claude Code and Codex JSONL logs (read-only), cached
                     incrementally in <dataRoot>/usage/cache.json; no dependency
```

Arrows point from a package to what it imports: `MercuryAgents → MercuryCore`, `MercuryAccounts → MercuryCore,
MercuryAgents`, `MercuryTerminal → SwiftTerm, MercuryPTYProtocol`, `MercuryDiff → MercuryGit, MercuryUI`; `MercuryUsage`
imports nothing (the app passes it the managed account homes). The app imports every package; packages never import
the app.

## Processes

- **Mercury.app** owns the UI, the database and git calls.
- **MercuryPTYHost** (`Contents/MacOS/MercuryPTYHost`, registered with `SMAppService.agent` from
  `Contents/Library/LaunchAgents/com.tekmium.mercury.ptyhost.plist`) owns every PTY and its process tree, keeps a
  scrollback ring buffer per session, and serves the Mach service `com.tekmium.mercury.ptyhost` over XPC. Sessions
  survive the app quitting or crashing; on launch the app lists the host's sessions and attaches again, replaying the
  scrollback. The helper exits once no session remains.

## Agent orchestration

An agent in a Mercury terminal can start worker agents with the bundled `mercury` CLI
(`Mercury.app/Contents/Helpers/mercury`, put on `PATH` only in Mercury's terminals), message them and get their results
back. The broker lives in the PTY host (`MercuryPTYHostKit/Orchestration`), one per data root, so delivery continues
while the app is closed:

- Every terminal gets `MERCURY_SESSION_ID`, a random `MERCURY_SESSION_TOKEN` (environment only, never arguments or
  logs) and the broker's addresses. The broker identifies callers by token; a terminal Mercury did not open is refused.
- Transport: one JSON line over `<dataRoot>/orchestration/broker.sock` (600, in a 700 directory; a path too long for
  `sun_path` moves to the user's temporary directory), or a file spool in the temporary directory for callers whose
  sandbox refuses sockets (Codex `workspace-write`).
- State: `<dataRoot>/orchestration/state.json`, written only by the helper (the app database has no orchestration
  tables). Work left by a previous helper process is closed on load.
- `worker start` is executed by the app (worktree, account, launch) through the XPC endpoint `orchestrationEndpoint`
  (protocol 3); with no app connected it is queued. The app mirrors the state for the sidebar's worker tree and the
  inspector, and posts a notification when a coordinator needs the user.
- Turn ends come from Claude's hooks (`mercury hook claude`) and Codex's `notify` (`-c notify=[…]` per launch, chained
  to the user's own). A message is typed once (bracketed paste, then Return) when the recipient is idle and the user
  has not typed there for 3 s. A worker that ends its turn or exits without `mercury done` is escalated.
- The guide (`App/Resources/Skills/mercury-orchestration/SKILL.md`) reaches Claude as a `--plugin-dir` plugin and
  managed Codex homes whose `skills` folder is their own; `~/.claude/skills` only through the Settings toggle.

The app speaks protocol 3 and still works with a protocol 2 helper (the user's sessions keep running); orchestration
stays off until `HelperVersionCheck` replaces that helper once it is idle.

## Agent sessions

A session runs in a context: a folder workspace, the main checkout of a git workspace, or a worktree. Launching an
agent combines:

1. `AgentLaunchSpec` (binary from the login-shell `PATH`, arguments, working directory);
2. the account's `EnvPatch` (`CLAUDE_CONFIG_DIR` or `CODEX_HOME`, auth variables removed) from `MercuryAccounts`;
3. for Claude, `--settings <dataRoot>/hooks/claude-settings.json`, whose hooks append events to
   `<dataRoot>/hooks/events/<session>.jsonl`; the app watches that file to know when an agent waits for input.

The launch goes through the user's login shell so `PATH` matches their terminal, then to the PTY host.

## Accounts

Each managed account has its own home under the data root (`claude-profiles/<id>/home`, `codex-homes/<id>/home`).
Claude profiles share the user's `~/.claude` content through symlinks, copies and a per-key settings sync, but keep
their own credentials (a Keychain item named after the profile directory). The `selected-host` pointer files let the
`claude` and `codex` shell functions in Mercury terminals use the selected account. The user's own `~/.claude`,
`~/.codex` and default Keychain item are never written.

## Split tabs

A tab shows one session, or two to ten sessions as panes. `PaneLayout` (MercuryCore) is the pane tree: n-ary splits
along one axis with each child's share, the focused pane and a zoomed pane; its operations are pure and keep the tree
normalized. The app keeps one layout per split tab (`App/Features/Terminal/PaneLayouts.swift`, the only code that
changes them) and stores it as JSON in `pane_layout` (migration `v6_pane_layout`). Layouts come back at launch from the
session records alone, so a pane whose process ended shows its ended view in its cell; panes whose session is gone
are dropped, and a layout left with one pane becomes a plain tab again. The tab order stores split tabs by layout id.

## Terminal output flow

Output travels PTY → helper → XPC → `HostedTerminalEngine` → `TerminalSession` → SwiftTerm. The app feeds SwiftTerm
through `TerminalFeedScheduler`: every session in turn, at most ~5 ms of parsing per main-loop turn, so a flooding
terminal never freezes the window. After each chunk the session calls `outputConsumed`, the engine acknowledges the
bytes to the helper (protocol version 2), and the helper only sends within a 2 MB window per client. A slow app
therefore pauses the helper's read, the kernel buffer fills and the program blocks, as in any terminal; app memory
stays bounded and the helper's scrollback stays complete.

## Session ownership

Every launch carries `mercury.session` and `mercury.dataRoot` metadata. On launch the app attaches to host sessions its
records name, and terminates only unknown running sessions tagged with its own data root, so another data root (a
second build, the tests) sharing the helper never loses its sessions. An exit Mercury caused (closing a tab, quitting
with sessions not kept) is not reported; other exits are recorded once and notified once.

Agent launches go through a plain login shell (`-l -c`), with the `PATH` that `AgentCatalog.loginShellPATH` resolved
from an interactive login shell, passed through `/usr/bin/env` after the profile ran together with the account's
environment changes. Interactive shells get the full integration (`ZDOTDIR` wrapper, bash rcfile).

## Tests

- `swift test --package-path Packages/<name>` for each package.
- `AppTests` run inside the signed app: workspace and worktree flows, a shell in the real PTY host across a model
  restart, data-root isolation, launch environment, and a 10-terminal flood (`LoadTests`). Opt-in suites:
  `MERCURY_AGENT_SMOKE=1` (real `claude`/`codex`), `MERCURY_SEED_ROOT=<dir>` (demo data for screenshots),
  `MERCURY_SCREENSHOTS=<dir>` (offscreen renders of forms; use real window captures for anything with a sidebar or
  overlapping views). Pass them with the `TEST_RUNNER_` prefix to `xcodebuild test`.
- `scripts/ci-local.sh` runs everything; it must be green before a phase closes.
