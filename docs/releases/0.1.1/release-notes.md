Suijin 0.1.1 lets you edit Markdown and leave comments for your agents, adds a few ways to move around tabs and terminals, and fixes a crash and the background helper's growing memory.

## New

- **Edit Markdown in place.** A Markdown tab has an Edit mode (⇧⌘E) next to Read. Headings, bold, lists, task boxes, quotes and links show formatted as you type, and the Markdown punctuation appears only on the line you are editing. ⌘S saves exactly what you typed, without reformatting the rest of the file. When an agent changes the file while you have unsaved edits, Suijin asks before either version is lost. Tables and code blocks show as source in Edit; Read still renders them.

- **Comments for agents.** In Edit, select some text and choose Comment (⇧⌘M) to leave a note on it. The Comments column lists your notes and sends them to a running Claude Code or Codex session. The agent edits the file and answers each comment, which turns Fixed or Not Fixed with its reply; reopen a comment if you disagree. Comments stay in Suijin, never in your file, and follow their text as the file changes.

- **Screenshots in a terminal.** A screenshot on the clipboard (⌃⇧⌘4) pastes with ⌘V, and the screenshot tool's floating thumbnail, or an image dragged out of another app, can be dropped on a terminal. Claude Code and Codex attach it as they attach a file dropped from Finder. Suijin keeps the image for a week.

- **Move a tab into a split.** Drag a session tab from the tab bar onto a pane, or onto the terminal of a plain tab, and it becomes a pane on the side nearest to the pointer. A split tab moves with all its panes and keeps their arrangement. The tab's context menu has the same move as Move Tab to Selected Tab.

- **Tabs by number.** ⌘1 to ⌘8 select the tab at that position in the tab bar and ⌘9 selects the last tab, also while a terminal has the keyboard. Settings › Shortcuts lists them.

- **Text size per terminal.** ⌘+ and ⌘- make the text of the terminal you are typing in larger or smaller, and ⌘0 puts it back at the size set in Settings. The other panes and tabs keep theirs, and each session remembers its size until it is closed.

- **Copy a code block.** Every code block in the Markdown viewer has a copy button at its top corner. One click copies the whole block, including the part scrolled out of view.

## Fixed

- Closing a tab while Suijin was still checking the paths printed on its screen could crash the app the next time a modifier key was pressed or released, which ⌘W itself does. It no longer does.

- The background helper that keeps your sessions running held on to the output of every closed tab for a day, up to 8 MB each, so its memory in the Resource Manager grew with every tab you closed. It now lets go of a tab's output as soon as the tab is closed.

- In a narrow inspector, a pull request's "Review required" tag broke onto two lines beside the Open button. The tags now stay on one line and the button moves under them when there is no room. A merged or closed pull request no longer shows a review tag.

- The emoji field of a workspace's icon showed a rocket in full color while it was empty, so it looked filled in although Use Emoji stayed dimmed. An empty field now shows the word "Emoji".

## Updating

Suijin offers this version by itself within about a day, or at once from Suijin › Check for Updates…. Your running sessions keep running through the update while "Keep sessions running after quitting Suijin" is on in Settings › General, as it is by default.

The memory fix lives in the background helper, and Suijin replaces the helper only when no session is running, so that an update never ends your agents. If sessions are running when you update, the helper of the previous version stays until they have ended and you open Suijin again.

For a first install, download `Suijin-0.1.1.dmg` below, open it and drag Suijin to Applications. Suijin is signed with a Developer ID and notarized by Apple.

## Requirements

- macOS 15 or later. The Liquid Glass interface needs macOS 26 or later.
- For the built-in agents, Claude Code and/or Codex installed on your Mac; Settings › Agents shows what Suijin found.

Suijin is open source under the Apache License 2.0. Website: [suijin.app](https://suijin.app)
