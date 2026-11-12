# UI responsiveness: tabs and inspector (2026-11-11)

## Outcome

Two causes were found and fixed. Both were confirmed with traces and with before/after numbers.

1. **Terminal reflow and repaint on every animation frame.** When the inspector (or sidebar) slides in or out, the
   terminal pane's width animates. On every frame (about 18 per toggle) SwiftTerm resized its grid, reflowed the whole
   scrollback, sent the program SIGWINCH and redrew the full screen. Resizes are now coalesced: the first change
   applies at once, later ones at most every 120 ms, and the last one always lands.
   - Main-thread work per inspector toggle dropped by **26–35%** in both Debug and Release.
   - Terminal drawing during the toggles dropped by **64–73%**, and scrollback reflow by **76–82%**.
2. **Title churn invalidating every tab and sidebar row.** Each terminal title update (an agent's title spinner) wrote
   to the observed `titles` dictionary. That re-rendered every title-bar tab and sidebar row, in every context, even
   though the text shown did not change. Only changes that are visible are stored now.
   - With one background shell updating its title 10 times a second, idle main-thread load fell from **7.0% to 2.3%**
     (Debug) and from **5.3% to 0.7%** (Release).
   - The worst idle turn in Release fell from 74.6 ms to 3.2 ms.

Tab switching and opening or closing tabs did not change measurably. What remains there is mostly system work:
SwiftUI/AppKit layout of the title-bar toolbar item and drawing the terminal that was just re-embedded. The two
design-level options for it are in "Remaining risks". I did not change either, because each would change visible
behavior.

## Method

- **Builds.** Debug and Release, built into `scratchpad/DD-perf`. Release is built with
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) MERCURY_PERF'` so the probe is compiled in. A copy of each app
  was kept from before the fixes (`base-*`) and after (`fix-*`), so both can be run alternately on the same machine.
- **Data.** `AppTests/PerfSeedTests.swift` (new, opt-in) seeds a temporary data root:
  - a git workspace of about 400 files with 3 worktrees, plus a folder workspace;
  - 14 hosted shells, each with about 3,000 lines of scrollback (8 of them in one worktree, so the tab strip
    overflows and scrolls).
  - There are no agents, so no account is touched.
  - `MERCURY_PERF_CLEANUP_ROOT` ends the shells again. That was done at the end, and no process is left under the seed
    folder.
- **Driver.** `App/Shell/PerfProbe.swift` (new). It only exists in `DEBUG` builds or builds with `MERCURY_PERF`, and
  only runs when `MERCURY_PERF_OUT` is set.
  - The scenario: tab switches (inspector closed, then open); inspector show (Files and Info) and hide; opening and
    closing file tabs; new and closed shell tabs; context switches.
  - The scenario runs twice: once quiet, and once ("churn") while a shell in another context rewrites its OSC title 10
    times a second. That simulates an agent's title spinner. Claude Code does set terminal titles (the binary has
    `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`), but I did not confirm the exact frame rate of its spinner.
  - A CFRunLoop observer measures the main thread:
    - `commit`: the run-loop turn that performed the action (SwiftUI update, layout and Core Animation commit);
    - `busy`: the main thread's awake time in the 700 ms after the action (animation frames and follow-up work);
    - `idle busy %`: load with nobody touching the app.
  - Each action is a points-of-interest signpost, so Time Profiler samples can be attributed per action.
- **Runs.**
  - Debug: 3 baseline runs and 2 after-fix runs. Release: 3 and 2. Each run has 6 rounds, and the medians are reported.
  - The after-fix runs were interleaved with a third baseline run, to keep machine load comparable.
  - Time Profiler was attached by pid for one Debug run before and one after the fixes.
  - Note: `xctrace --launch` resolves the app by bundle id and launched the user's DerivedData build instead. I
    stopped those instances; they ran only on the temp data root.

## Evidence (Time Profiler, Debug; main-thread samples are 1 ms each)

| Action (windows) | Frame | Before | After |
|---|---|---|---|
| inspector.files.show (8) | `TerminalView.draw` | 821 | 283 |
| | `Buffer.reflow` | 288 | 68 |
| inspector.info.show (8) | `TerminalView.draw` | 816 | 222 |
| | `Buffer.reflow` | 276 | 50 |
| inspector.hide (16) | `TerminalView.draw` | 1605 | 582 |
| | all main-thread samples | 3831 | 2773 |

- **Per-frame resizes.** A temporary size log showed the terminal frame stepping, for example, 950 → 952 → 958 → … →
  1230 points: about 18 grid resizes per inspector toggle. Each one went through `MercuryTerminalView.setFrameSize` →
  `TerminalView.processSizeChange` → `Terminal.resize` → `Buffer.reflow`, then `sizeChanged` → `engine.resize`, which
  sends SIGWINCH.
- **`displayTitle` cost.** In the baseline it accounted for 44–74 samples per action group, because it built a
  `CharacterSet` on every call and was called by every tab and row on every invalidation. It is no longer among the
  top frames.

## Fixes

1. **Resize coalescing.** `Packages/MercuryTerminal/Sources/MercuryTerminal/MercuryTerminalView.swift:71-108`
   - Adds `resizeThrottle` (0.12 s), with a leading and trailing edge.
   - The view applies sizes immediately when it is not in a window, and for the first change after a quiet period.
     Tab switches and first layouts are therefore not delayed.
   - Tests: `Packages/MercuryTerminal/Tests/MercuryTerminalTests/TerminalSupportTests.swift`, suite
     "Terminal view resizing". 61 animated frames produce 2 grid changes and end on the final size; a single change
     applies at once.
2. **Clipping during the coalescing window.** `App/Features/Terminal/TerminalPane.swift:82-84`: the container is set
   to `clipsToBounds = true`, so a terminal that is briefly wider than its pane cannot draw over the inspector.
3. **Title writes.**
   - `App/Features/Terminal/SessionRuntime.swift:285-290`, in `makeRuntime` (`view.onTitleChange`). This is my only edit
     in this file. I did not touch `makeLaunch` or the hook handling. The diff at lines 228-232 of that file belongs to
     the Branch C agent.
   - `titles[id]` is now written only when the shown title changes.
4. **Shared title normalization.** `App/Features/Terminal/AgentLogo.swift:54-68`
   - `displayTitle` now uses a new `shownTitle(_:)` helper, with static `CharacterSet` and `Set` values.
   - Output is identical: a generic or empty title falls back to `session.title`.
5. **`worktrees` rewrites.** `App/AppModel.swift:246-248`: `refreshWorktrees` only assigns `worktrees[id]` when the
   list changed. It runs on every selection change and every time the app becomes active, and every view that
   resolves a directory reads `worktrees`. The probe shows no measurable gain for this one; it is a correctness and
   cost guard.
6. **`statusError` rewrites.** `App/Features/SourceControl/SourceControlModel.swift:162`: the 5-second git status poll
   no longer re-publishes an unchanged `statusError = nil`, which invalidated the toolbar items and the inspector panel
   every poll.
7. **Toolbar icon caching.** `App/Features/Terminal/SessionTabsView.swift:314-355`: `NewSessionMenu.buttonIcon` and
   `menuIcon` are cached per agent. A new `NSImage` on every render made the toolbar refresh the item's menu form
   (`AppKitToolbarItem.updateMenuFormRepresentation` showed up in every action).
8. **Tooling.**
   - `App/Shell/PerfProbe.swift` (new) and its hook at `App/MercuryApp.swift:46-48`.
   - `AppTests/PerfSeedTests.swift` (new). Its tests are opt-in by environment and skipped otherwise.
   - `Mercury.xcodeproj` was regenerated with `xcodegen` (from the unchanged `project.yml`) to pick up the new files.

## Before / after (median ms; commit = the action's own turn, busy = main thread in the 700 ms after it)

| Scenario | Debug before | Debug after | Release before | Release after |
|---|---|---|---|---|
| Idle with title churn, busy % | 7.0% | 2.3% | 5.3% (max turn 74.6) | 0.7% (max turn 3.2) |
| Inspector Files show, busy | 285 | 211 | 265 | 175 |
| Inspector Info show, busy | 350 | 279 | 320 | 243 |
| Inspector hide, busy | 241 | 201 | 228 | 159 |
| Inspector Files show (churn), busy | 310 | 208 | 267 | 193 |
| Inspector hide (churn), busy | 255 | 176 | 248 | 167 |
| Tab switch, commit / busy | 54 / 115 | 48 / 142 | 36 / 94 | 31 / 115 |
| Tab switch (churn), commit / busy | 24 / 97 | 36 / 128 | 34 / 152 | 26 / 111 |
| Inspector Info show, commit | 99 | 102 | 96 | 95 |
| New shell tab, busy | 278 | 274 | 273 | 263 |
| File tab open, busy | 256 | 251 | 258 | 258 |
| Context switch, commit | 64 | 71 | 57 | 56 |

Tab-switch numbers vary by ±30 ms between runs in both directions, so I read them as unchanged. The raw samples are
in `scratchpad/results/*.jsonl`, and the summary comes from `scratchpad/summarize.py`.

## Tests

- `swift test --package-path Packages/MercuryTerminal`: 53 tests in 12 suites pass.
- App tests via `xcodebuild test` in `DD-perf`: 26 tests in 15 suites pass. The two `SessionFlowTests` failures you
  expected did not occur in this run.
- No compiler warnings in Mercury code. I fixed one that the probe introduced.
- I captured the app window of the fixed build at rest (`scratchpad/results/fix-window.png`). The terminal inset is
  unchanged and nothing is clipped.

## Remaining risks and what is left on the table

- **Visual change during resizes.** For up to 120 ms the terminal keeps its previous size:
  - while the inspector opens, the right edge is clipped;
  - while it closes, the terminal background shows in the gap;
  - then the grid reflows once.
  - During a live window resize, reflow now happens at about 8 per second instead of every event. Programs receive
    fewer SIGWINCHes, which is intended.
- **Info inspector first frame is about 95 ms in both Debug and Release.** This is SwiftUI measuring the grouped
  `Form` inside the inspector column (`ScrollViewUtilities.sizeThatFits`, `GroupedFormRowLayout`, TextKit 2 for
  selectable path text). It is rebuilt on every show because `.inspector` discards its content. Not changed.
- **Tab open/close animation.** `.animation(.snappy, value: tabs)` on `ToolbarTabBar` animates the toolbar item's
  width, and `NSToolbarView` re-tiles on every frame (`_itemViewMinSize:maxSize:`), about 37 ms of main-thread time
  per open or close (Debug).
  - Option: give the item a fixed width and animate only the capsule inside it.
  - Trade-off: the transparent area would capture title-bar drags. This needs your decision.
- **Tab switch with an overflowing strip.** `reader.scrollTo(tab, anchor: .center)` animates a recentering scroll on
  every switch, even when the tab is already visible, which re-lays the toolbar item each frame.
  - Option: `anchor: nil` (scroll only when needed).
  - Trade-off: it changes the centering behavior, so it needs your decision.
- **SwiftTerm internals (not editable here).** On every display update, `TerminalView.updateTextBlinkLifecycle` →
  `visibleBlinkRows` scans every visible cell (about 8 ms per tab switch in Debug). A re-embedded terminal is also
  redrawn in full. Both are worth raising upstream.
- **Not measured with real agents.** The seed uses shells only. Agent TUIs repaint on SIGWINCH, so the resize fix
  should matter more with them, but this is unmeasured.
- **Unmeasured, untouched.**
  - `WorkspaceBadge` reads an image icon from disk (`NSImage(contentsOf:)`) in its body. My seed has no image icons.
    File names change with every edit, so a cache keyed by path would be safe.
  - `FileTreeView` reads folders synchronously on the main thread. It did not show up with this seed, which has a
    small root.

## Unresolved questions

- Should the title-bar tab group stop animating its own width, and should it stop recentering on every switch? Both
  are UX decisions.
