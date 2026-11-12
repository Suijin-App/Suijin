# Changelog

## 0.1.0 (unreleased)

- An agent that exits on its own (Ctrl-C twice in Claude Code or Codex) now leaves its tab or pane for the Session
  Ended view instead of a dead terminal; a failed session shows its last output there.
- Resume Session on the Session Ended view continues a Claude Code or Codex conversation in the same tab or pane.
- Settings › Shortcuts lists every keyboard shortcut and mouse gesture, searchable by action or key. Help ›
  Keyboard Shortcuts (⌘/) opens it.
- Mercury is now Sevinda. The first launch moves an existing install (workspaces, accounts, settings) to the
  new name; see `docs/architecture.md`, "Moving an install from the old name".
