# Code Review: App layer (App/**, AppTests/**)

Date: 2026-11-11 (Asia/Saigon). Read-only review; no source files were changed.

## Code Review Summary

### Scope
- Files reviewed: every Swift file under `App/` (AppModel, MercuryApp, RootView, Shell/, Features/{Terminal, Worktrees, Workspaces, Accounts, Diff, Settings}, Updates/) and `AppTests/` (SessionFlowTests, LoadTests, ScreenshotTests, UpdatesTests, DemoSeedTests). Package APIs read only where the app depends on their behavior (TerminalSession, HostedTerminalEngine, ShellLaunch, PTYSession exit codes, SessionManager retention, AgentLaunchSpec, ClaudeLaunchEnv, MercuryCore migrations).
- Lines of code analyzed: about 3,600 in App + AppTests.
- Review focus: session lifecycle, model/store consistency, observation, security/privacy, accounts flow, HIG/native-first rules.
- Updated plans: none (read-only review requested).

### Overall Assessment
The App layer is compact and well structured. Async IO is kept off the main actor, argument passing to git and the agent CLIs is injection-safe (argv, `exec "$0" "$@"`, `--end-of-options`, `--` before a dash-leading prompt), no tokens are put in argv or logs, and nothing writes to `~/.claude` or `~/.codex`. The serious problems sit in edges of the session lifecycle: one keyboard shortcut kills an agent from the wrong window, the orphan sweep kills sessions that belong to a different data root, removing a default account deletes the profile out from under running agents, and exit handling sends notifications that the user did not need.

### Critical Issues
None (no data-exposure or token-leak path found).

### High Priority Findings

**H1. ⌘W in Settings (or any non-main window) kills the selected agent session.**
`App/MercuryApp.swift:108-117`. `CommandGroup(replacing: .saveItem)` replaces the system "Close" item. The action checks only `model.selection` / `activeSession`, never which window is key. Failure scenario: the user opens Settings (⌘,) and presses ⌘W to close it. The selected Claude session in the main window gets SIGHUP and its tab is deleted, and Settings stays open. The Design Gallery window behaves the same way. Fix: route to the session only when the main window is key, and close the key window otherwise:
```swift
if NSApp.keyWindow?.identifier?.rawValue.hasPrefix("main") == true,   // or compare to the main Window scene's NSWindow
   let context = model.selection, model.activeSession(in: context) != nil {
    model.closeActive(in: context)
} else {
    NSApp.keyWindow?.performClose(nil)
}
```
A sturdier option is to drive it from `@FocusedValue` published by `SessionTabsView`, so the command only acts when the main window's detail area has focus. ⌘T, ⌥⌘T and ⌘D have the same blind spot (they start sessions in the main window while Settings is key), but they do not destroy anything.

**H2. The restore orphan sweep terminates sessions that belong to another data root.**
`App/Features/Terminal/SessionRuntime.swift:134-136`. Every running host session that this model's records do not claim gets terminated. There is one launchd helper per user, but data roots differ (`MERCURY_DATA_ROOT`, the DemoSeedTests workflow, the test host). Failure scenarios:
- (a) The user runs `xcodebuild test`. `SessionFlowTests.anotherDataRootLeavesForeignSessionsRunning` and `shellSessionSurvivesRestartInThePTYHost` call `bootstrap()` with a throwaway store, which sweeps and SIGHUPs every live agent of the user's real Mercury.
- (b) DemoSeedTests says to launch Mercury with `MERCURY_DATA_ROOT=<dir>/data`, which kills the user's real sessions (and the reverse).
- (c) The test `anotherDataRootLeavesForeignSessionsRunning` (`AppTests/SessionFlowTests.swift:125-142`) contradicts the implementation. It only passes because it checks `isRunning` right after `terminate` was sent, before the SIGHUP lands.

Fix: stamp every launch with `launch.metadata["mercury.dataRoot"] = model.dataRoot.path` (in `start` for shells too). In `restore`, sweep only sessions whose metadata matches. Then make the test wait (for example `eventually`) before asserting the session survives.

**H3. Removing the default managed account deletes the profile under running sessions.**
`App/Features/Accounts/AccountsController.swift:144-155`. Sessions started without an explicit account (⌘T, the ＋ primary action, NoSessionView, "Default" in the sheets) store `accountID == nil`, but `launchEnv` resolves them to the default managed account (`AccountsController.swift:43`). `remove` stops only `session.accountID == account.id`. Failure scenario: account A is the default and three Claude tabs run on it. The user removes A. All three keep running with `CLAUDE_CONFIG_DIR` pointing at a deleted folder, and their Keychain items are gone, so they fail mid-turn with auth or file errors. Fix: persist the resolved account on the record at start, so `AgentSessionRecord.accountID` is always the account actually used. Alternatively, in `remove` also stop sessions with `accountID == nil` of that provider while A was the default. Persisting is better: it also makes "Start Again" (`SessionTabsView.swift:276`) reuse the same account after the default changes.

**H4. Relaunch re-notifies "Exited" for every ended agent tab, and rewrites `endedAt`.**
`SessionRuntime.swift:105-128` together with `sessionExited` at `:279-288`. The helper keeps exited sessions for 24 h (`SessionManager.exitedRetention`). `restore()` re-attaches to any host session it finds, whatever `record.state` is. `HostedTerminalEngine.attach` then delivers the stored exit, so `sessionExited` runs again: it upserts `endedAt = Date()` and posts "Exited with code N". Failure scenario: two agents finished yesterday evening and their tabs are still open. Every launch the next morning posts two stale notifications and resets their end times. Fix: in `restore`, when `!info.isRunning` and the record is already `.exited`/`.failed`, show the scrollback without wiring the exit path. A simpler option is to have `sessionExited` return early (no upsert, no notify) when `record.endedAt != nil`.

**H5. Quitting with "Keep sessions" off (or in the in-process fallback) marks every agent Failed and posts a notification per agent.**
`SessionRuntime.swift:304-312`. `prepareForQuit` calls `terminate(id)` but never removes the records. Each SIGHUP exit (`128+1 = 129`, see `PTYHostProtocol.swift:56`) runs `sessionExited`. That sets `state = .failed` and posts "Exited with code 129" for every agent that is not the visible one, while the app is quitting. The in-process fallback (unsigned debug builds, Login Item disabled) always takes this path. On the next launch every tab shows "Session Ended / Failed, exited with code 129". Fix: add a flag on the registry, for example `isQuitting` or a per-runtime `endedByUser`, that `terminate` sets before signalling. `sessionExited` then records `.exited` and skips the notification for exits Mercury caused.

### Medium Priority Improvements

**M1. A failed re-attach leaves the host session running unseen.**
`SessionRuntime.swift:115-132`. `claimed.insert(hostID)` runs before `engine.attach`. When attach throws, the runtime is dropped, but the host session is never terminated and the record stays `.running`. The tab shows "Session Ended" while the agent keeps working or burning tokens in the helper, and nothing in the UI can stop it. Fix: claim only after a successful attach (so the orphan sweep catches it), or call `PTYHostClient.shared.terminate(hostID)` and mark the record ended in the `catch`.

**M2. Notifications have no `UNUserNotificationCenterDelegate`.**
`SessionRuntime.swift:316-334`; no delegate exists anywhere in `App/`. `notify` deliberately posts while the app is active but another tab or worktree is selected. Without `userNotificationCenter(_:willPresent:)` returning `.banner`, macOS does not show banners for the frontmost app, so the case the code guards for (an agent waiting in a tab you are not looking at) is silently dropped. Clicking a notification also does nothing with `userInfo["session"]`, so it does not select that session's context and tab. Fix: set a delegate in `MercuryAppDelegate.applicationDidFinishLaunching`. `willPresent` should return `[.banner, .sound]`, and `didReceive` should select `model.context(of:)` and the session tab. Also consider identifier `"\(record.id)"` (no timestamp) so a flapping waiting/running agent replaces its notification instead of stacking them.

**M3. Removing a workspace leaves `selection` on a dead worktree, with no confirmation.**
`App/AppModel.swift:157-166` and `App/Shell/SidebarView.swift:81`. Only `.workspace(id)` selections are reset. If a worktree of that workspace was selected, `selection` keeps pointing at a deleted worktree. The detail area then shows "No Workspace Selected", the lastSelection setting is persisted, and ⌘T fails silently. The same happens in `refreshWorktrees` (`AppModel.swift:208-215`) when a selected worktree disappears. Separately, "Remove Workspace" stops every session in every worktree of the repository with no `.confirmationDialog`, while worktree and account removal both confirm (HIG: confirm destructive actions). Fix: reset the selection when `workspaceID(of: selection) == id` or when `directory(of: selection) == nil`, drop `selectedTab` entries for removed contexts, and add a confirmation that says how many sessions will stop.

**M4. The sidebar only matches `git worktree list` at launch.**
`refreshWorktrees` runs from `load()`, `addWorkspace` and a kind change. Phase 04 acceptance requires "`git worktree list` khớp với sidebar". Worktrees an agent or the user creates or removes in a terminal (`git worktree add …`, common with Claude Code) do not appear or disappear until relaunch. Fix: call `refreshWorktrees` from the existing `RootView.onChange(of: model.selection)` and on `NSApplication.didBecomeActiveNotification`. Watching `<repo>/.git/worktrees` with the existing `DirectoryWatcher` is the zero-latency variant.

**M5. Diff pane: stale results overwrite newer ones, and a failed diff spins forever.**
`App/Features/Diff/DiffScreen.swift:73-116`. `GitRunner` does not honour task cancellation (no cancellation handling in MercuryGit). Failure scenarios:
- (a) Select a large file A, then quickly select B. A's `.task(id:)` is cancelled but still finishes later and sets `diff = A`, so B's row is highlighted while A's diff is shown. Toggling the scope picker can likewise show a stale file list. The watcher-triggered `Task` (`:77`) is never cancelled and races the same way.
- (b) `diff = try? …` sets `nil` on error while `selectedPath != nil`, so the right pane shows `ProgressView` indefinitely, with no error state (CLAUDE.md: every view has empty, loading and error states).

Fix: capture `let path = selectedPath, scope = scope` and assign only if `!Task.isCancelled && selectedPath == path && self.scope == scope`. Keep a `diffError` state and show `ContentUnavailableView` for it.

**M6. `DirectoryWatcher` can be freed while its FSEvents stream is live.**
`App/Features/Diff/DirectoryWatcher.swift:16` passes `passUnretained(self)`, and `stop()` must run before release. `ChangesView.onAppear` (`DiffScreen.swift:75-79`) overwrites `watcher` without stopping the previous one, and there is no deinit safety net. If `onAppear` fires twice without an `onDisappear` in between (SwiftUI does not guarantee strict pairing, for example on window re-show or inspector toggles), the old watcher is released with a running stream, and the next file event dereferences freed memory. Fix: `watcher?.stop()` before assigning in `onAppear`. Better still, use `.task(id: directory)` with `defer`/`onCancel` cleanup, or pass `retain`/`release` callbacks in the `FSEventStreamContext` so the stream owns a reference.

### Low Priority Suggestions

- **L1.** ⌘W with the Changes tab selected, or in a context with no sessions, closes the whole main window (`MercuryApp.swift:110-113`). With `applicationShouldTerminateAfterLastWindowClosed == false`, the app is left with no window, and only the Window menu or a Dock click brings it back. Consider a no-op (or selecting the last session tab) while the Changes tab is selected.
- **L2.** Closing a tab that runs an agent (✕, ⌘W, context menu) terminates it with no confirmation (`SessionTabsView.swift:87`). Terminal.app and iTerm confirm when a foreground process runs. Since ⌘W is one key away from ⌘Q/⌘E in agent workflows, consider confirming when `activity` is `.running` or `.waitingForInput`.
- **L3.** `start()` failure path (`SessionRuntime.swift:164-170`) leaves the hook events file prepared in `makeLaunch` behind, and an exit delivered while `terminal.start` is still awaiting finds no record yet (`sessionExited` guard), so the record is saved as `.running`. The outcome is harmless after the next restore, but `record.state = runtime.terminal.hasExited ? .exited : .running` would be exact.
- **L4.** `split(in:)` (`SessionActions.swift:42-50`): if the primary tab is closed while the shell is starting, `splits[primary]` is set for a dead primary. The new shell then counts as a secondary and disappears from the tab strip while it runs. Re-check `sessions.contains { $0.id == primary }` after the await, and otherwise leave the shell as its own tab.
- **L5.** `NewWorktreeSheet.isValid` (`NewWorktreeSheet.swift:68-70`) checks only for spaces. `createWorktree` runs `FileManager.createDirectory(at: path.deletingLastPathComponent())` before git validates the name, so names git rejects, such as `a..b`, `foo/`, `x.lock` or `../x` under a custom worktree root, can still leave empty folders behind. Validate with `git check-ref-format --branch` (or a local equivalent) before creating directories.
- **L6.** A first-login home created by `beginAdding` is left on disk if the app quits while the LoginSheet is open (`AccountsController.swift:106-112`). Sweeping `claude-profiles`/`codex-homes` folders that have no record at launch would clean this up.
- **L7.** `restore()` (in-process branch) and `refreshWorktrees` run before `runtimes.bootstrap()` (`MercuryApp.swift:43-44`), so the "keep a worktree whose agent still runs" guard (`AppModel.swift:209`) never applies at launch. A worktree removed externally while the app was closed loses its records, and its still-running host sessions are then swept by the orphan sweep (H2) without the user seeing them. This is acceptable once H2 is fixed, but it is worth a comment.

### Positive Observations
- Injection safety is solid end to end. Prompts and branches always travel as argv (`exec "$0" "$@"`, `--end-of-options`, `--` before a prompt that starts with a dash), and the env patch goes through `/usr/bin/env` after the login shell, so a profile-exported `ANTHROPIC_API_KEY` cannot override the managed account.
- Account isolation respects the repository rules. Hooks go through `--settings`, credentials stay in providers, and `UsageStatusItem` deliberately hides the user's own login instead of reading it.
- `closeSession` orders its work so the exit callback finds no record. `TerminalSession` resumes the terminate waiter before `onExit`, and the removal happens synchronously after the await, so a deliberate close posts no notification.
- `SessionRuntimeRegistry.runtimes` is now observed, while the hot paths (`ticker`, `hooks`, `usesHost`) are `@ObservationIgnored`. Callbacks use `[weak runtime]` / `[weak self]` throughout.
- Native-first is followed: `NavigationSplitView`, `.inspector`, `Form`, `Gauge`, `ContentUnavailableView`, and system split views. The one custom control, the tab strip, carries the required justification comment. Accessibility labels are present on icon-only controls.

### Recommended Actions
1. Fix H1 (scope ⌘W/⌘T/⌘D to the main window) before anyone else uses the build. A stray ⌘W in Settings is destructive.
2. Fix H2 (data-root-scoped sweep) before running AppTests again on a machine with live agents.
3. Fix H3 by persisting the resolved account on each session record.
4. Fix H4 and H5 together with a single rule: only an exit Mercury did not cause, on a record not already ended, updates state and notifies.
5. Add the notification delegate (M2), then address M3–M6.

### Metrics
- Type coverage: Swift 6 strict concurrency; no `Any` escapes found in App code.
- Test coverage: not measured. AppTests cover workspace/worktree CRUD, host restart and restore, and the account env ordering. Nothing covers the exit-notification paths, account removal with default-account sessions, or the cross-data-root sweep (whose test is a false positive, see H2).
- Build/tests: green, 14 passed and 4 skipped; 0 compiler warnings in Mercury code.

## Build and test run
I ran `xcodebuild -scheme Mercury test` into a scratch derived-data path. It succeeded: 14 Swift Testing tests in 6 suites passed, and 4 were skipped (screenshot, seed and agent-draw tests are gated by environment variables). There were no compiler warnings in Mercury code. The XCTest summary line reads "Executed 0 tests" because all the tests are Swift Testing, so `ci-local.sh`'s `grep 'Executed N tests'` reports a misleading count.

`anotherDataRootLeavesForeignSessionsRunning` passed after 0.123 s, which fits the race described in H2: the SIGHUP had not landed yet when the test asserted. That suite runs `bootstrap()` against the shared user helper, so this review's own test run may have swept live sessions of the user's real Mercury, if any were running.

## Unresolved Questions
1. Is terminating host sessions that no record knows about (the "database was reset" case) still wanted once sessions are tagged with their data root? Or should foreign-root sessions always be left alone and untagged legacy sessions be swept?
2. Should closing a running agent tab ask for confirmation (L2), or is instant close an intended product decision?
