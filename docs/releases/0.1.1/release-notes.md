Suijin 0.1.1 fixes agent orchestration: a coordinator can now stop a worker it started, and workers that are over no longer linger in the sidebar.

## New

- **Stop a worker.** Ask the coordinator to stop or cancel a worker and it runs `suijin worker stop --to <worker>`. The worker's terminal ends and its tab closes by itself. A worker that finished on its own keeps its tab, as before.

- **A menu on worker rows.** Right-click a worker in the sidebar for **Show Worker** and **Close Worker**.

## Fixed

- A worker whose tab was closed stayed greyed out in the sidebar under its coordinator, with no way to remove it. It is no longer listed.

## Updating

Installed copies of 0.1.0 find this version by themselves within a day, or right away with Suijin › Check for Updates…. This is the first update Suijin delivers this way.

The background helper that keeps sessions alive is replaced only when it has no session, so an update never ends one. `worker stop` is handled by that helper: to use it, end your running sessions and open Suijin again once after updating.

For a first install, download `Suijin-0.1.1.dmg` below, open it and drag Suijin to Applications.

## Requirements

- macOS 15 or later. The Liquid Glass interface needs macOS 26 or later.
- For the built-in agents, Claude Code and/or Codex installed on your Mac.
