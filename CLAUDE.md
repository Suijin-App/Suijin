# Sevinda — repository rules

These rules apply to everyone working in this repository, people and AI agents alike.

Sevinda is a native macOS app (Swift 6, SwiftUI/AppKit, macOS 15+, real Liquid Glass on macOS 26+) that runs several
Claude Code and Codex agents side by side, one git worktree each, with multiple managed accounts and a native diff
viewer. Local only: no SSH, no remote hosts, no cloud.

## Language

- **Every comment in source code is written in English**, in every file type (Swift, shell, Python, YAML, plist).
- **User interface text is English only**, and still lives in String Catalogs (`*.xcstrings`) so other languages can
  be added later: use `Text("…")` / `String(localized:)` (with `bundle: .module` inside packages), never a plain
  `String` that reaches the screen without going through localization.
- Plans in `plans/` may be written in Vietnamese; product docs in `docs/` and commit messages are English.
- **Commit messages** follow Conventional Commits, e.g. `feat: add worktree sheet`.
- **Commit author.** Every commit is authored and committed as `vuvv-dev <vuvo.dev.work@gmail.com>` (the repository's
  local git config sets it); never commit under another identity or pass `--author`.

Check: `Tools/comment-lint/comment-lint.py` (also runs in `scripts/ci-local.sh checks`).

## User interface

- **Native first.** Use the system SwiftUI/AppKit component whenever one exists: `NavigationSplitView`,
  `TabView`, segmented `Picker`, `Table`, `List`, `Form`, `.toolbar`, `.inspector`, `.searchable`,
  `.contextMenu`, `Menu`, `.sheet`/`.alert`/`.confirmationDialog`, `ProgressView`, `Gauge`, `Charts`, etc.
  Do not rebuild a control the system already provides (for example a hand-made tab bar, segmented
  control, toolbar, search field or table header). A custom view is allowed only when no native
  component fits; say why in a comment.
- **Real Liquid Glass only.** Glass comes from the system APIs (`.glassEffect`, `GlassEffectContainer`,
  `.buttonStyle(.glass)` / `.glassProminent`, toolbars, sidebars and sheets, which adopt it
  automatically). Never fake it with `.ultraThinMaterial` stacks, blur, gradients, strokes or shadows
  that imitate glass.
- **Polish.** Follow the macOS Human Interface Guidelines: standard spacing, SF Symbols, system fonts and
  colors (`.secondary`, `.tint`), keyboard shortcuts on menu commands, full light/dark support,
  accessibility labels on every control.
- **No broken layouts or icons.** SF Symbols only, sized with `.font`/`.imageScale` (never `.resizable()` on a
  symbol or a non-square frame). Content changes must not widen the window: give panes min/ideal widths, truncate
  long text, wrap or scroll long commands. Every view has empty, loading and error states (`ContentUnavailableView`).
- **Verify visually.** Before calling UI work done, render the new screens offscreen (hosted test,
  `NSHostingView` snapshot) at a narrow and a wide window width in light and dark mode, look at the images, and fix
  anything clipped, misaligned or overflowing.

## Sevinda-specific rules

- **Workspaces, not repositories.** A workspace is a git repository (`kind == .git`: worktrees and diffs) or a plain
  folder (`kind == .folder`: agents run straight in it). Shared code (sidebar, sessions, status, accounts) never
  assumes git; only worktree creation/removal and the diff viewer require `kind == .git`.
- **Never touch the user's own logins.** Nothing writes to `~/.claude`, `~/.claude.json`, `~/.codex` or the default
  `Claude Code-credentials` Keychain item. Managed accounts live under `~/Library/Application Support/Sevinda`.
  Claude hooks are passed with `claude --settings <file>`, never installed into the user's settings.
  One exception: continuing a conversation on "Your own login" may add that one conversation's history files under
  `~/.claude/projects/<encoded cwd>/` or `~/.codex/sessions/YYYY/MM/DD/`, creating the folder, never replacing an
  existing file, and touching nothing else there (`ConversationTransfer`).
- **Never print, log or persist tokens.** Credentials are read into memory only; profile directories are 700, files 600.
- **No orphan processes.** Every terminal runs in the PTY host helper (`SevindaPTYHost`) so it survives the app
  quitting; closing a tab terminates its session (SIGHUP, then SIGKILL). Tests that spawn processes clean them up.
- **Package boundaries.** The graph is documented in `docs/architecture.md`; packages never import the app, and
  `SevindaUI` imports no domain package.
- **Verify before done.** `scripts/ci-local.sh` must be green (package tests, app build, no compiler warnings in
  Sevinda code).
