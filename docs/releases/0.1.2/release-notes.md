Suijin 0.1.2 fixes the Changes tab hanging Suijin in large projects: long diffs open at once, and a project whose files keep changing no longer slows the app down.

## Fixed

- In Changes, a file with a long diff, such as a bundled stylesheet or a lock file, took seconds to minutes to show, and Suijin seemed to hang meanwhile. A diff of 59,000 lines now opens in a fraction of a second.

- In a project where files change all the time, for example while a dev server or an agent is at work, the Changes tab started reading the changes again at every change, even while the last read was still going. Slow reads piled up and could keep your Mac's processors busy until Suijin stopped responding. The tab now does one read at a time and, when it is done, one more for everything that changed meanwhile.

- While a second copy of Suijin used the same data, such as a development build next to the installed app, saving could fail with "database is locked", and a split tab's arrangement could be lost. Suijin now waits a moment for the other copy and then saves.

## Updating

Suijin offers this version by itself within about a day, or at once from Suijin › Check for Updates…. Your running sessions keep running through the update while "Keep sessions running after quitting Suijin" is on in Settings › General, as it is by default.

For a first install, download `Suijin-0.1.2.dmg` below, open it and drag Suijin to Applications. Suijin is signed with a Developer ID and notarized by Apple.

## Requirements

- macOS 15 or later. The Liquid Glass interface needs macOS 26 or later.
- For the built-in agents, Claude Code and/or Codex installed on your Mac; Settings › Agents shows what Suijin found.

Suijin is open source under the Apache License 2.0. Website: [suijin.app](https://suijin.app)
