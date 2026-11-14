# Changelog

## 0.1.0 (unreleased)

- Suijin checks for updates about once a day and from Suijin › Check for Updates…, and installs them in place. It
  asks `https://suijin.app/appcast.xml`, which forwards to the latest release on GitHub; Settings › General turns the
  automatic check off.
- "Don't ask again" in the question before closing a tab whose agent still works now does what it says; Settings ›
  General › Sessions turns the question back on. The checkbox used to belong to another question (starting an agent
  without permission checks), so ticking it had no effect on closing tabs.
- Settings › General has a Permissions section: Notifications, the background helper and Full Disk Access each show
  whether macOS allows them, what is lost without them, and a button to allow them or to open the right pane of
  System Settings. The states update when you come back from System Settings. Full Disk Access is optional; it is
  checked from a process the terminal host starts, which is how agents and shells run.
- Settings › Accounts can switch accounts automatically, separately for Claude Code and Codex and off by default.
  "Move running sessions when the default account changes" moves every running session on another account to the new
  default. "Switch automatically when an account hits its limit" moves a session whose account used up a usage
  window to the first account with room in an order you set; with none, the limit banner stays. Sessions move with
  their conversation, as Continue With Another Account does, only once the agent finished its turn and sits at its
  normal prompt (never while it waits at a permission request or a question), never back to an account still at its
  limit, and not again for a limit within ten minutes. A note in the pane (and a notification while Suijin is in the
  background) says where a session went and why. Shells and agents started in them never move; a running Codex, which
  tells Suijin neither its conversation nor when it is safely at its prompt, stays with a note.
- Continue With Another Account (session context menu, Session Ended view, usage popover) carries a Claude Code or
  Codex conversation to another managed account or your own login when an account runs out: Suijin ends the agent,
  places the conversation's history in the other account's folder (linked or copied, never moved or replacing a
  file) and resumes it in the same tab or pane with the same folder and permission mode. A running session whose
  account used up a usage window shows a banner offering the other accounts.
- Claude Code and Codex sessions start in a permission mode: Ask, Auto-Accept Edits, Plan or Skip All Permissions for
  Claude; Ask, Auto, Read-Only or Skip All Permissions for Codex. Settings › Agents sets each agent's default, and the
  Permissions submenu of the new-session, split and sidebar menus picks one for a single session. Resume Session, Start
  Again and New Session Like This keep the session's mode; a session that skips permission checks shows a warning
  badge, and starting one is confirmed first.
- An agent that exits on its own (Ctrl-C twice in Claude Code or Codex) now leaves its tab or pane for the Session
  Ended view instead of a dead terminal; a failed session shows its last output there.
- Resume Session on the Session Ended view continues a Claude Code or Codex conversation in the same tab or pane.
- Settings › Shortcuts lists every keyboard shortcut and mouse gesture, searchable by action or key. Help ›
  Keyboard Shortcuts (⌘/) opens it.
- Sevinda is now Suijin. The bundle identifier changed with the name, so macOS treats Suijin as a new app: allow
  notifications and the background helper again (Settings › General › Permissions), and Full Disk Access if you had
  granted it. Suijin starts with an empty data folder.
