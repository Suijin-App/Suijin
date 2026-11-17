# Changelog

## 0.1.2 (2026-11-17)

- **Large diffs open at once.** In Changes, a file with a long diff (a bundled stylesheet, a lock file) took seconds
  to minutes to show, and Suijin seemed to hang, because reading the diff slowed down with the square of its length.
  A 59,000-line diff now opens in a fraction of a second.
- **Changes stays responsive while files change.** In a project where files change all the time (a dev server, an
  agent at work), the Changes tab started a new reload at every change even when the last one was still running, so
  slow reloads piled up and Suijin could hang. It now runs one reload at a time and follows it with a single reload
  for everything that changed meanwhile. It also no longer reads the whole list of changes again to show one file, and
  ignores the files git writes inside `.git/objects` and `.git/logs`.
- **Saves wait for another copy of Suijin.** While a second copy of Suijin used the same data (a development build
  next to the installed app), saving could fail at once with "database is locked", and a split tab's arrangement
  could be lost. Suijin now waits a moment for the other copy and then saves.

## 0.1.1 (2026-11-16)

- **Fixed a crash after closing a terminal.** Closing a tab while Suijin was still checking the paths printed on its
  screen could crash the app the next time a modifier key was pressed or released, which ⌘W itself does.
- **The terminal host gives memory back.** Closing a tab now makes the helper drop that session's scrollback at
  once; before, it kept up to 8 MB per ended session for a day, so its memory grew with every tab closed. A session
  that ends on its own while Suijin is closed keeps only the last 256 KB, which is all Suijin reads of it.
- **Edit Markdown in place.** A Markdown tab has an Edit mode (⇧⌘E) next to Read: headings, bold, lists, task
  boxes, quotes and links show formatted as you type, and the Markdown punctuation appears only on the line you are
  editing. ⌘S saves exactly what you typed, without reformatting the rest of the file. When an agent changes the
  file while you have unsaved edits, Suijin asks before either version is lost. Tables and code blocks show as
  source in Edit; Read still renders them.
- **Comments for agents.** In Edit, select some text and choose Comment (⇧⌘M) to leave a note on it. The Comments
  column lists the notes and sends them to a running Claude Code or Codex session. The agent edits the file and
  reports each comment with `suijin comment resolve`, and the comment turns Fixed or Not Fixed with the agent's
  reply; reopen it if you disagree. Comments stay in Suijin's database, never in your file, and follow their text
  as the file changes.
- **Screenshots in a terminal.** A screenshot on the clipboard (⌃⇧⌘4) pastes with ⌘V, and the screenshot tool's
  floating thumbnail, or an image dragged out of another app, can be dropped on a terminal. Suijin saves the image
  as a PNG in its caches folder and pastes the file's path, as it does for a file dropped from Finder, so Claude Code
  and Codex attach it. Saved images are removed after a week.
- **Tabs by number.** ⌘1 to ⌘8 select the tab at that position in the tab bar and ⌘9 selects the last tab, also
  while a terminal has the keyboard. Settings › Shortcuts lists them.
- **Copy a code block.** Every code block in the Markdown viewer has a copy button at its top corner; one click
  copies the whole block, including the part scrolled out of view.
- **Move a tab into a split.** Drag a session tab from the tab bar onto a pane, or onto the terminal of a plain
  tab, and it becomes a pane on the side nearest to the pointer; a split tab moves with all its panes and keeps
  their arrangement. The same move is in the tab's context menu as Move Tab to Selected Tab.
- **Text size per terminal.** ⌘+ and ⌘- make the text of the terminal you are typing in larger or smaller, and ⌘0
  puts it back at the size set in Settings; the other panes and tabs keep theirs. Each session remembers its size
  until it is closed, across launches too.
- **Pull request tags stay on one line.** In a narrow inspector "Review required" broke onto two lines beside the
  Open button; the button now moves under the tags when there is no room. A merged or closed pull request no longer
  shows a review tag.
- **The emoji field of a workspace's icon looks empty when it is.** The field showed a rocket as its placeholder, in
  full color, so it looked filled in while Use Emoji stayed dimmed. The placeholder is now the word "Emoji".

## 0.1.0 (2026-11-15)

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
  when one runs out. Two options, off by default, move sessions for you when the default account changes or when an
  account hits a usage limit. Settings › Accounts notes that using several accounts this way may be against the
  provider's terms.
- **Agent orchestration.** Ask an agent for "Suijin workers" and it starts other Claude Code or Codex agents with the
  bundled `suijin` command, each in a tab of its own, answers their questions and collects their results. Ask it to
  stop a worker and it does (`suijin worker stop`): the worker's terminal ends and its tab closes by itself. Worker
  rows in the sidebar have a menu with **Show Worker** and **Close Worker**.
- **Stats and usage.** Settings › Stats & Usage shows tokens, estimated cost and activity per day from the local
  Claude Code and Codex logs, and the Resource Manager shows the memory and CPU of running sessions.
- **Welcome tour.** The first launch opens a short tour of workspaces, sessions, changes and accounts, with whole-window
  captures, hand-written notes and four water sprites that follow the pointer and answer a click. Help › Welcome to
  Suijin opens it again.
- **Settings.** Light, dark or automatic appearance, 15 terminal themes, a searchable list of every keyboard
  shortcut (⌘/), and a Permissions section that shows whether macOS allows notifications, the background helper and
  Full Disk Access, with a button to allow each and a **Repair** button when the background helper is not working.
  Settings › About links to the website, the source code, the community and the sponsor page.
- **Updates.** Suijin checks for a new version about once a day and installs it in place; Settings › General turns
  the automatic check off. `suijin.app` counts those checks per day and app version, and keeps nothing else.
- **Private by design.** No account, no telemetry and no crash reports. Your code and your agents stay on your Mac.
- **Requirements.** macOS 15 or later; the Liquid Glass interface needs macOS 26 or later. Suijin is signed with a
  Developer ID, notarized by Apple and open source under the Apache License 2.0.
