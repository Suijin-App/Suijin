---
title: "Mercury v1: nine phases built in parallel, verified end to end"
date: 2026-11-10
summary: All 9 phases implemented with contract-first parallel agents; integration tests and real-app checks found 4 cross-agent bugs that unit tests missed.
---

# Mercury v1: nine phases built in parallel, verified end to end

## What happened
Built Mercury (native macOS agent orchestrator) from an empty folder: 8 Swift packages, the app, the launchd PTY host helper and the release pipeline. Six package agents worked in parallel against `plans/261110-2054-mercury-native-agent-orchestrator/contracts.md`; the controller owned the app glue, project.yml and integration.

Package tests were green early, but the integration layer found the real bugs:
- 10 flooding terminals froze the main thread for 50 s and grew the app to 1.6 GB: output was fed to SwiftTerm synchronously and the helper pushed without limit. Fixed across two packages with a budgeted `TerminalFeedScheduler` plus an `outputConsumed` → XPC `ack` window (protocol v2). Now 26 ms worst gap, 191 MB.
- The diff text column was blank in the real app: the gutter painted over the text because macOS no longer clips views to bounds. Offscreen per-view snapshots could not show it; only `screencapture -l` of a real window did.
- Restored sessions showed "Session Ended": the runtime map was `@ObservationIgnored`.
- Startup orphan cleanup killed sessions of other data roots (tests killed demo sessions). Sessions now carry `mercury.dataRoot`.
- Interactive login shells for agents printed the user's fastfetch before the TUI; PATH is now resolved once and passed through `env`, and agents launch with `-l -c`.

Two independent reviews (packages, app) found 2 + 5 high items, all fixed (orphan background jobs on terminate, symlinking unknown ~/.claude dirs, ⌘W in Settings killing an agent, duplicate exit notifications, default-account removal under running agents).

## Decision
Contract-first parallel agents with strict file ownership worked; cross-cutting changes (flow control) were specified by the controller and sent to both owners. UI verification must use real window captures.

## Next steps
- Sign in to 2 Claude + 2 Codex accounts and check `/status` and the usage bar.
- Approve outward release steps: Sparkle key, notarytool profile, first notarization, feed URL, 0.1.0 → 0.1.1 update test.
- `ak plan update` failed with "planstore: plan not found"; plan status left as is.

> Historical work record — not durable authority. Prefer docs/specs/ADRs for current decisions.
