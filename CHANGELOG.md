# Changelog

## 0.1.0 (unreleased)

The first release of Suijin: a native macOS app that runs Claude Code, Codex and any other command-line AI coding
agent side by side, each in a git worktree of its own.

- **Workspaces and worktrees.** Add a git repository or a plain folder as a workspace. Each agent gets a worktree on
  a branch of its own, so parallel changes never collide, and the sidebar shows every worktree with the status of the
  sessions running in it.
- **Tabs and split panes.** Start Claude Code, Codex or a shell in a tab, and run any other command-line agent in
  the shell. A tab splits into as many as ten panes; drag a pane by its header to rearrange it, or zoom the one you
  are reading.
- **Sessions that keep running.** Sessions run in a background helper, so quitting or updating Suijin does not stop
  your agents. When an agent exits, its tab shows a Session Ended view with **Resume Session** and **Start Again**.
- **Changes and pull requests.** Review what an agent changed in a native diff viewer, leave notes on a file or a
  line and send them back to the agent, then commit, push and open the pull request from the same tab.
- **Files and media.** Code, rendered Markdown, images, video and audio open in a tab next to your sessions.
- **Permission modes.** Every Claude Code and Codex session starts in a permission mode: Ask, Auto-Accept Edits,
  Plan or Skip All Permissions for Claude Code; Ask, Auto, Read-Only or Skip All Permissions for Codex. Settings sets
  the default for each agent, and a session that skips permission checks is confirmed first and marked with a badge.
- **Multiple accounts.** Add several managed Claude and Codex accounts without touching your own logins, and see
  each plan's usage in the status bar. **Continue With Another Account** carries a conversation to another account
  when one runs out, and optional automatic switching moves a session to the next account with room when its account
  hits a limit.
- **Agent orchestration.** Ask an agent for "Suijin workers" and it starts other Claude Code or Codex agents with the
  bundled `suijin` command, each in a tab of its own, answers their questions and collects their results.
- **Stats and usage.** Settings › Stats & Usage shows tokens, estimated cost and activity per day from the local
  Claude Code and Codex logs, and the Resource Manager shows the memory and CPU of running sessions.
- **Settings.** Light, dark or automatic appearance, 15 terminal themes, a searchable list of every keyboard
  shortcut (⌘/), and a Permissions section that shows whether macOS allows notifications, the background helper and
  Full Disk Access, with a button to allow each.
- **Updates.** Suijin checks for a new version about once a day and installs it in place; Settings › General turns
  the automatic check off. `suijin.app` counts those checks per day and app version, and keeps nothing else.
- **Private by design.** No account, no telemetry and no crash reports. Your code and your agents stay on your Mac.
- **Requirements.** macOS 15 or later; the Liquid Glass interface needs macOS 26 or later. Suijin is signed with a
  Developer ID, notarized by Apple and open source under the Apache License 2.0.
