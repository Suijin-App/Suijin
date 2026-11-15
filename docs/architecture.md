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
SuijinMarkdown      the live-rendered Markdown editor: tree-sitter syntax tree over the source, style runs and
                    hideable markers, TextKit 1 text view; no domain dependency
SuijinUsage         token usage and estimated cost from Claude Code and Codex JSONL logs (read-only), cached
                    incrementally in <dataRoot>/usage/cache.json; no dependency
```

Arrows point from a package to what it imports: `SuijinAgents → SuijinCore`, `SuijinAccounts → SuijinCore,
SuijinAgents`, `SuijinTerminal → SwiftTerm, SuijinPTYProtocol`, `SuijinDiff → SuijinGit, SuijinUI`; `SuijinUsage`
imports nothing (the app passes it the managed account homes), and `SuijinMarkdown` imports only the tree-sitter
Markdown grammar (the app passes it a theme and a code highlighter). The app imports every package; packages never import
the app.

## Processes

- **Suijin.app** owns the UI, the database and git calls.
- **SuijinPTYHost** (`Contents/MacOS/SuijinPTYHost`, registered with `SMAppService.agent` from
  `Contents/Library/LaunchAgents/com.tekmium.suijin.ptyhost.plist`) owns every PTY and its process tree, keeps a
  scrollback ring buffer per session, and serves the Mach service `com.tekmium.suijin.ptyhost` over XPC. Sessions
  survive the app quitting or crashing; on launch the app lists the host's sessions and attaches again to those still
  running, replaying the scrollback. A session whose process ended meanwhile is recorded as ended without being shown.
  The helper keeps nothing of a session the app ended or has recorded as ended: `terminate` ends its processes and,
  once every attached client has received the exit, drops its scrollback and metadata. A session that exits on its
  own while no app has recorded it keeps the last 256 KB of its scrollback (the app reads only the end of a failure
  and an agent's resume hint) for up to a day. The helper exits once no session remains.

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
- `worker stop` (coordinator only) settles the worker's dispatch, drops messages it has not received, and ends its
  session in the helper as closing a tab does. The app sees the dispatch's optional `stoppedAt` and closes the tab.
  The sidebar hides a settled worker once its session is gone.
- The guide (`App/Resources/Skills/suijin-orchestration/SKILL.md`) reaches Claude as a `--plugin-dir` plugin and
  managed Codex homes whose `skills` folder is their own; `~/.claude/skills` only through the Settings toggle.

- `comment list` and `comment resolve` answer the Markdown comments the user sent to a session (see Markdown editor
  and comments). The app tells the broker which comments wait on which session (`registerComments`,
  `withdrawComments`, and the whole list again after every connect with `syncComments`); the broker accepts
  `resolve` only from the session a comment was sent to, answers every other caller with the same "no such comment"
  failure, keeps each result in `state.json` until the app acknowledges it (`commentResultsApplied`), and hands
  results over with `commentsResolved`, at once or when the app connects again.

The app speaks protocol 4 and still works with a protocol 2 or 3 helper (the user's sessions keep running).
Orchestration needs protocol 3 and agents answering comments needs protocol 4; each stays off, and the Comments
column says so, until `HelperVersionCheck` replaces that helper once it is idle.

## Markdown editor and comments

A Markdown file tab has two modes (the Read/Edit switch in its header, ⇧⌘E): Read is the MarkdownUI reader, Edit is
the native editor of `SuijinMarkdown`.

- **The source is the truth.** The editor's text is the file's Markdown, character for character; rendering is
  attributes only, and nothing regenerates Markdown from a model. Saving (⌘S, `MarkdownFile.write`) writes that text
  to a file beside the original and puts it in the original's place, so a reader never sees half a file and the
  permissions and extended attributes stay; it follows symbolic links, keeps a byte order mark and CRLF line endings,
  and changes no line the user did not edit.
- **Parsing.** `MarkdownSyntaxTree` keeps a tree-sitter block tree of the source and reparses it incrementally on
  each edit (documents over 150,000 UTF-16 units reparse when typing pauses); the text of paragraphs and headings is
  parsed with the inline grammar when it is styled. `MarkdownStyler` turns the tree into style runs and markers;
  front matter is recognized by one rule shared with the reader (`MarkdownFrontMatter`).
- **Hidden markers.** Markers away from the lines of the selection are laid out as zero-width control characters
  (the layout manager's glyph delegate), so they stay in the text for copy, undo, search and accessibility; a list
  bullet is drawn as a dot, a task box as a checkbox that toggles `[ ]`/`[x]` in the source, a thematic break as a
  rule. Code blocks, tables and front matter show as source on a background, with nothing hidden.
- **The file on disk.** `MarkdownEditSession` (kept in `AppModel` while the tab is open, so undo history and scroll
  position survive switching tabs) compares the file with what it last loaded or saved: its own save changes
  nothing, another writer's version replaces the text when there are no unsaved changes, and with unsaved changes a
  bar offers Reload or Keep My Changes; nothing is overwritten or dropped without an answer. Closing a tab or
  quitting with unsaved changes asks to save.
- **Comments** live in the database (`markdown_comment`, per workspace or worktree and file path); the file is never
  touched. A comment keeps the quoted text, up to 64 characters of context on each side, its UTF-16 offsets and
  lines. While the file is edited the offsets move edit by edit (`MarkdownCommentAnchoring.shift`); when the text is
  replaced each comment is searched for again (`resolve`: same place, then the quote by context and distance, then
  an intact context around a rewritten span), and one that is not found is marked detached and kept.
- **Sending.** The Comments column pastes the unsent comments into a running session of the context (bracketed
  paste, like diff notes, after saving the file) with a short id per comment and the instructions for
  `suijin comment resolve`. The agent's result (`fixed` or `declined`, with a reply of at most 500 characters shown
  as plain text) is applied in one transaction, only to a comment still waiting on that session and not sent again
  since the answer was given. Writes of one file's comments run in order, and a moved comment writes its position
  columns only, so a late write cannot undo a newer status or bring back a deleted comment.

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
of its own (`com.tekmium.suijin.pane`, declared in `Info.plist`), so a pane never lands where a tab reorders. Over
another pane, `PanePlacement(dropAt:in:)` (SuijinCore) picks one of five zones (an edge places the pane beside it,
the middle swaps the two), and dropping on the title-bar tab group moves the pane to a tab of its own.
⌃⌥⌘ arrows and Session ▸ Move Pane swap the focused pane with its neighbor. After any rearrangement,
`PaneRearrangeAnimation` slides each pane's layer from its old frame to its new one. The terminal views move into
their new containers and are never recreated.

The other way round, a whole tab moves into another tab (`AppModel.mergeTab`): a plain tab becomes one pane, a split
tab is added as a group that keeps its arrangement (`PaneLayout.inserting(_:beside:edge:)` taking a layout), and its
own layout is deleted. Tabs are dragged the way panes are, by the same AppKit drag source laid over the tab, with a
type of their own (`com.tekmium.suijin.tab`, also in `Info.plist`), and `PaneDragState` knows the dragged tab from the
drag's start to its end. Both payloads are plain strings written straight to the drag's pasteboard: an item provided
lazily (`NSItemProvider`, SwiftUI's `onDrag`) under a custom type reaches AppKit as a promised file, and a terminal
takes that as a dropped file before any drop target around it is asked. Every pane takes a tab, and so does the
terminal of a plain tab, which then becomes a split tab in its place; a Changes or file tab is refused because it holds
no session. A tab has nothing to swap with, so `PaneEdge(nearestTo:in:)` divides the pane into four zones and the
nearest edge takes the drop; a zoomed pane takes it too and the tab shows every pane again. Each tab of the title bar
is a drop target of its own (another tab reorders) that lies over the tab group, so the tabs take a dragged pane as
well as the group does; otherwise only the gaps between them would.
The tab's context menu (Move Tab to Selected Tab) and VoiceOver actions on the tab do the same without a drag.

## Keyboard shortcuts

`ShortcutCatalog` (`App/Features/Settings/ShortcutCatalog.swift`) defines every keyboard shortcut once; menu commands
and buttons bind `ShortcutCatalog.<entry>.shortcut`, and Settings › Shortcuts (Help › Keyboard Shortcuts, ⌘/) lists
the same entries with the mouse gestures. While a terminal has focus, `TerminalKeyRouter` (SuijinTerminal) handles
the tab, pane, text size and edit shortcuts itself. `ShortcutCatalogTests` fails when a `.keyboardShortcut(…)` in the
app does not come from the catalog (sheets' standard Return and Esc buttons aside), when a terminal route has no
catalog entry with the same keys, or when a catalog shortcut would reach another route.

⌘S (Save), ⇧⌘E (Edit or Read Markdown) and ⇧⌘M (Add Comment) act on the selected Markdown tab only; their menu
items are disabled on every other tab, so typed in a terminal they do nothing.

⌘+, ⌘- and ⌘0 are one catalog entry each with two meanings, by where the keyboard is: in a terminal they change that
terminal's text size, in the file viewer they zoom its image. A terminal's size is the size in Settings › Terminal
plus an offset in points kept per session (`App/Features/Terminal/TerminalTextZoom.swift`, user defaults key
`terminal.fontSizeOffsets`), so a zoomed terminal stays that much larger when the setting changes; the offset follows
the session between tabs and panes and is dropped when the session closes.

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

## System permissions

Suijin depends on three things macOS controls, shown in Settings › General › Permissions (`App/Features/Settings/Permissions`).
It only reads them; the user grants and revokes them in System Settings, and the states are read again whenever the app
becomes active.

- **Notifications** (`UNUserNotificationCenter`): banners when an agent waits or finishes.
- **Background helper** (`SMAppService.agent` status): without it the PTY host cannot run and sessions end with the app.
- **Full Disk Access** (optional): agents and shells are children of the PTY host, and macOS decides file access by the
  process responsible for them, so the check runs there: `FullDiskAccessProbe` (SuijinTerminal) starts a short `sh`
  through the host that lists `~/Library/Safari`, `Mail` or `Messages` and reads its exit status (0 listed, 1 exists but
  not listable, 2 none exists). When the host is unavailable, sessions run in the app and the same check runs in
  process. There is no public API for this permission; an inconclusive check is shown as Unknown, never as allowed.
  Reading `com.apple.TCC/TCC.db` is no use: without the permission that folder looks missing.

Suijin uses no Accessibility, Automation, Screen Recording, camera or microphone API.

## Tests

- `swift test --package-path Packages/<name>` for each package.
- `AppTests` run inside the signed app: workspace and worktree flows, a shell in the real PTY host across a model
  restart, data-root isolation, launch environment, and a 10-terminal flood (`LoadTests`). Opt-in suites:
  `SUIJIN_AGENT_SMOKE=1` (real `claude`/`codex`), `SUIJIN_SEED_ROOT=<dir>` (demo data for screenshots),
  `SUIJIN_SCREENSHOTS=<dir>` (offscreen renders of forms; use real window captures for anything with a sidebar or
  overlapping views), `SUIJIN_ENDED_SHOT=<file>` (the Session Ended view, captured by window id with
  `screencapture -l`). Pass them with the `TEST_RUNNER_` prefix to `xcodebuild test`.
- App tests share the real PTY host, so each one ends the sessions it started (see `CLAUDE.md`). To check after a
  run: no file under `~/Library/Application Support/Suijin/pty-host/sessions` should name a temporary data root in
  `suijin.dataRoot`.
- `scripts/ci-local.sh` runs everything; it must be green before a phase closes.
