# MercuryTerminal — wave 1 report

Status: done. `swift test --package-path Packages/MercuryTerminal` passes 38 tests in 8 suites, with zero compiler
warnings after a clean target rebuild. The run includes the other agent's `HostedTerminalEngine.swift` and
`PTYHostClient.swift`, which arrived during this work and now compile.

## SwiftTerm pin

- **Pin: `exactVersion: 1.20.0`** (tag `v1.20.0`, revision `5d14406844143538cd8f8851d2d8a67c1fe443e5`).
- Why 1.20.0: it is the newest 1.x release and has the Metal renderer (`Apple/Metal/`). It builds cleanly with
  Swift 6.4 / Xcode 27.0 (27A266a), so no other version had to be tried. 1.99.0–1.99.3 are pre-2.0 builds whose APIs
  are still moving, so they were avoided.
- Build-tool plugin: **yes**, `SwiftTermBuildInfoPlugin` (it runs `SwiftTermBuildInfoGenerator`). `xcodebuild` needs
  `-skipPackagePluginValidation`, or the plugin must be trusted once in Xcode.
- It compiles `Apple/Metal/Shaders.metal` as a resource, so Xcode builds need the Metal Toolchain component.
- SwiftPM prints `warning: missing creator for mutated node: …SwiftTerm_SwiftTerm.bundle/Contents/MacOS`. This is a
  build-system notice about SwiftTerm's resource bundle, not a compiler warning. It is harmless.
- Suggested `project.yml` comment: "SwiftTerm 1.20.0, the newest 1.x (Metal renderer). It compiles a Metal shader
  (needs the Metal Toolchain) and ships the build-tool plugin SwiftTermBuildInfoPlugin (xcodebuild needs
  -skipPackagePluginValidation). 1.99.x are pre-2.0. An upgrade must re-check the paste and key paths that
  MercuryTerminalView overrides (`paste(_:)`, `send(data:)`, the delegate)."

## Headless throughput (SwiftTerm `Terminal`, no view, no PTY)

Test: `HeadlessThroughputTests` feeds a 120x40 terminal (10,000 lines of scrollback) in 8,192-line chunks. Each line
ends in `\r\n`, which is what a PTY delivers for `yes` (onlcr). With bare `\n` the cursor walks diagonally, which
does not measure the real case. Machine: arm64, macOS 27.2.

| Input | Debug | Release (`-c release`) |
|---|---|---|
| 2,000,000 x `y\r\n` (5.72 MB) | 3.7–3.9 s, 1.5 MB/s, ~0.53 M lines/s | 1.3–1.5 s, 3.3–4.1 MB/s, **1.15–1.43 M lines/s** |
| 200,000 x 79-char line (15.45 MB) | 2.6 s, 5.9 MB/s | 0.21 s, **69–75 MB/s**, ~0.97 M lines/s |

The cost is per line (scrolling), not per byte. A release build keeps up with about 1 M lines/s, which is far above
what a PTY delivers to the UI. UI FPS still has to be measured in the app.

The engine's end-to-end path is covered too. `yes | head -n 300000` through a real PTY is delivered completely
(900,005 bytes) and before the exit callback, in about 0.27 s in a debug build.

## What was built

- `TerminalEngine.swift` defines `TerminalSize`, `TerminalLaunch` and `@MainActor protocol TerminalEngine`, exactly
  as the contract says, plus `TerminalEngineError`.
- `SwiftTermEngine` (with the internal `PTYChannel`) uses its own `forkpty`, not `LocalProcess`, because of three
  `LocalProcess` problems:
  - It reports the raw `waitpid` status as the exit code.
  - It sends SIGTERM to the pid only.
  - It cancels its exit monitor on terminate.

  The child is set up like this:
  - It gets default signal dispositions and an empty signal mask (an app that ignores SIGPIPE would otherwise break
    `yes | head`).
  - It closes every descriptor above 2, so another tab's PTY master cannot leak into it and keep that PTY alive.
  - Its master is CLOEXEC and non-blocking.

  Output is read on a serial queue and handed to the main actor in FIFO order, at most 1 MB per turn. Reads pause
  above 4 MB of backlog and resume below 1 MB. All output is delivered before `onExit`. Exit codes: a normal exit
  gives its code, death by a signal gives 128+N, and an unknown status gives nil.

  `terminate()` works like this:
  1. SIGHUP (+SIGCONT) to the child's group and to every process group attached to the PTY (`proc_listpids(PROC_TTY_ONLY)`).
  2. Wait `terminationGracePeriod` (default 2 s).
  3. SIGKILL every process still attached to the PTY, which also catches `nohup` jobs.

  The master stays open during this sequence, so the PTY's device number cannot be reused. Every signal is sent on
  the I/O queue, where the child is reaped, so a reaped PID is never signalled. Dropping an engine without
  `terminate()` hangs up and kills from `isolated deinit`.
- `MercuryTerminalView` (`open class`, a SwiftTerm `TerminalView` subclass):
  - Display and input only, through closures: `onInput`, `onSizeChange`, `onTitleChange`,
    `onCurrentDirectoryChange`, `onBell`, `onFocus`, `onKeyRoute`.
  - Paste guard hook: `onPasteReview(review, decide)` plus `pasteGuardPolicy`.
  - Theme and font-size apply, and Capstio's minimum-size guard, scroller fix and accessibility value.
  - Key handling and `NSTextInputClient` are untouched, so input methods (Vietnamese) keep SwiftTerm's own path.
    The key monitor acts only on ⌘ shortcuts.
  - OSC 52 clipboard writes are allowed and clipboard reads are refused. Links open only for http, https, file and
    mailto.
- `PasteGuard` ports Capstio's logic: command-line counting (blank lines, comments and `\` continuations do not
  count), bracketed-paste-aware bytes for Run and Paste only, and Paste only refused when it would run lines.
  Capstio's dangerous-command rules (CapstioCore) were not ported; only the multi-line confirmation was asked for.
- `TerminalKeyRouting` ports Capstio's router without the SSH and AI shortcuts. The view handles ⌘C/V/A/F itself.
  ⌘T, ⌘W, ⇧⌘[ / ⇧⌘], ⌘D and ⇧⌘D go to `onKeyRoute`. Every other ⌘ shortcut goes on to the app's menus; Capstio
  swallowed them instead.
- `TerminalTheme` ports Capstio's types and palettes. Capstio Light/Dark became `mercury-light` / `mercury-dark`
  with the same colors. Capstio's `TerminalThemePreference` stays app-side, replaced here by
  `TerminalThemes.resolve(id:isDark:)`.
- `TerminalSession` binds one engine to one view: view input goes to `write`, engine output to `feed`, grid changes to
  `resize`, and the exit to `onExit`. It also has `attached(scrollback:)` for hosted reattach.
- `ShellLaunch`:
  - `userShell()` reads `pw_shell`, falling back to `/bin/zsh`.
  - `interactiveShell` starts a login shell (`-l`) with the integration for zsh and bash; fish and other shells start
    as a plain `-l`.
  - `command` runs `$SHELL -l -c 'exec "$0" "$@"'`. fish uses `exec $argv`, and csh, tcsh, nu and others fall back to
    `/bin/zsh`.
  - `baseEnvironment()` strips launch-context variables (XPC_*, DYLD_*, __CF*, CLAUDECODE and CLAUDE_CODE_* from a
    parent Claude session, among others). It sets TERM=xterm-256color, COLORTERM=truecolor, TERM_PROGRAM=Mercury,
    MERCURY_TERMINAL=1, a UTF-8 LANG (`<lang>_<region>.UTF-8` when installed, else en_US.UTF-8; macOS 27 ships no
    `vi_VN` locale) and MERCURY_DATA_ROOT (inherited, else `~/Library/Application Support/Mercury`).
- `ShellIntegration.install(in: root)` writes `<root>/shell-integration/` and returns that directory. It contains:
  - The zsh `ZDOTDIR` wrappers `.zshenv`, `.zprofile`, `.zshrc` and `.zlogin`. Each one sources the user's file of the
    same name, at top level and with the user's ZDOTDIR set while it runs. They follow a ZDOTDIR that the user's
    `.zshenv` moves, and they fix the HISTFILE that `/etc/zshrc` derives from our ZDOTDIR. `.zshrc` then sources
    Mercury's functions. The last file read restores the user's ZDOTDIR, or unsets it.
  - `mercury.bashrc`.
  - The four function files.

  Files that are already up to date are not rewritten.
- Resources `claude-shell-function.{zsh,bash}` and `codex-shell-function.{zsh,bash}`:
  - Every run reads `$MERCURY_DATA_ROOT/claude-profiles/selected-host` (or `codex-homes/selected-host`).
  - An empty or missing pointer, a user-set `CLAUDE_CONFIG_DIR` / `CODEX_HOME`, or a missing `MERCURY_DATA_ROOT` runs
    `command claude` or `command codex` untouched.
  - A relative pointer is refused (exit 1, with a message on stderr).
  - A missing account folder is created with mode 700, as Orca does.
  - When routing to an account, the function runs in a subshell. The claude function unsets ANTHROPIC_API_KEY,
    ANTHROPIC_AUTH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN and AWS_BEARER_TOKEN_BEDROCK; the codex function unsets
    OPENAI_API_KEY.
  - If the user already defined a claude or codex function, nothing is defined (`typeset -f` check).

## Tests (Swift Testing)

- Shell integration (14 tests) uses real `zsh -l -i -c` and `bash --rcfile … -i -c` runs in a temp HOME whose path
  has a space, with fake `claude` / `codex` binaries on PATH that print their environment. The tests cover:
  - The startup order zshenv → zprofile → zshrc → zlogin, with no claude function yet while the user's .zshrc runs.
  - A `typeset` in the user's .zshrc staying global.
  - ZDOTDIR restored, and no wrapper variables left behind.
  - HISTFILE pointing into the user's directory.
  - A user ZDOTDIR, and one moved by .zshenv.
  - The pointer being honoured, a switch applying to the next run in the same shell, and an empty pointer giving the
    default login with the keys kept.
  - A user-set and an inline `CLAUDE_CONFIG_DIR` being honoured, a user function winning, and a relative pointer
    being refused.
  - The codex equivalents.
  - bash `.bash_profile`, the `.bashrc` fallback, the pointer, CLAUDE_CONFIG_DIR, a user function and codex.

  I checked that these tests can fail: with the `.zshrc` wrapper broken, 5 of them fail.
- SwiftTermEngine (9 tests):
  - `/bin/echo` output and exit 0, exit code 3, and SIGTERM giving 143.
  - Start validation, write, cwd and environment (UTF-8), and resize (`stty size`).
  - A complete flood delivered before the exit.
  - `terminate` on `sleep 100` with `pgrep -P` before and `kill(pid, 0)` after: no child is left and the grace period
    is not waited out.
  - `terminate` on a shell that ignores HUP running a `nohup sleep 100 &` job: the job is killed after the grace
    period.
  - Idempotent `terminate`.
- Paste guard (6), key routing (2), themes (1), shell launch (3, one of which runs `command()` end to end through the
  login shell), TerminalSession (2, binding through the real view and terminate), and headless throughput (2
  arguments).

## Deviations and decisions to confirm

1. bash cannot be both a login shell and use `--rcfile` (bash ignores `--rcfile` in login shells). Mercury therefore
   starts `bash --rcfile mercury.bashrc -i`, and that file reads what a login shell reads: /etc/profile, then the
   first of ~/.bash_profile, ~/.bash_login and ~/.profile, then ~/.bashrc if none exists. `shopt login_shell` reports
   off.
2. The paste guard policy defaults to `.always` (Capstio parity: confirm every multi-line paste). Claude Code and
   Codex enable bracketed paste, so pasting a multi-line prompt into them asks every time. `.unlessBracketedPaste`
   is available, and the app may want it for agent sessions.
3. The codex function ports only the pointer logic. Orca's codex-specific `--no-daemon`, identity and preflight
   wrappers belong to Orca's own hook and server model and were left out.
4. `ShellLaunch.interactiveShell` takes the integration root from `environment["MERCURY_DATA_ROOT"]` (default
   `~/Library/Application Support/Mercury`) and installs or refreshes the files on each launch. If they cannot be
   written, the shell still starts without the integration.
5. The exit code for death by a signal is 128+N, the shell convention, since the contract does not specify it.
6. Unknown ⌘ shortcuts go on to the app's menus instead of being swallowed as in Capstio.

## Observations

- Early on, while iterating, I saw two one-off test failures (the echo test failing fast; the flood once receiving 7
  extra bytes). Neither reproduced in more than 75 later full-suite and engine-suite runs. While investigating I
  found and fixed a real race: `terminate()` could enumerate PTY members, or signal the PID, after the channel had
  already reaped the child and freed the PTY. All signalling now happens on the I/O queue, and the tty sweep only runs
  while the master is held open. The PTY host kit tests running on this machine at the same time also kill process
  groups and may have contributed; I could not verify that.
- Fish is not installed here, so the fish `command()` form (`fish -l -c 'exec $argv' exe args…`) is untested.

## Unresolved questions

- Should agent sessions use `PasteGuardPolicy.unlessBracketedPaste` (the controller's or UI's call)?
- Is the bash non-login emulation (deviation 1) acceptable, or should bash start as a plain `-l` without the
  integration?

## Review fixes (code-reviewer-261111-0451-packages.md)

### M3: agent commands now see the PATH that `.zshrc` sets
- `ShellLaunch.command` now runs `$SHELL -l -i -c 'exec "$0" "$@"' <executable> <args…>` for zsh. For bash it uses
  `bash --rcfile <shell-integration>/mercury.bashrc -i -c …`, the same files as Mercury's interactive bash, or
  `bash -l -i -c …` when the integration files cannot be written. fish keeps `-l -c` (it reads its config in every
  mode). sh, dash and ksh keep `-l -c`. Other shells fall back to `/bin/zsh -l -i -c`.
- `exec` is kept, so the agent becomes the PTY's session process; the test checks that its PID equals
  `engine.processID`.
- `/usr/bin/env -u KEY NAME=value <binary> args…` still works. It runs after the profile, so the env patch wins over
  what the rc files export.
- Test (`AgentCommandTests`): a temp HOME whose `.zshrc` (or `.bash_profile`) is the only place that adds a directory
  to PATH. That directory holds a fake `fakenode` and a `#!/usr/bin/env fakenode` agent, which is how an
  npm-installed agent is shaped. The agent runs through `/usr/bin/env -u AGENT_SECRET AGENT_MODE=patched fakeagent
  "one arg"`. The test checks four things: node resolves, the patch wins over the rc export, the key is unset, and
  the agent kept the PTY's PID. With `-i` removed the zsh test fails, so it guards the fix.
- `AgentCatalog.loginShellPATH` in MercuryAgents uses the same `-l -c` form. It is outside this package and still
  needs `-i` (reviewer's fix 5).

### L1: no Swift code between fork and exec
- There is a new C target, `CMercuryTerminalPTY`, internal to this package and imported with `internal import`.
  Its `mercury_terminal_spawn` does `openpty`, then `fork`, then in the child only async-signal-safe calls: setsid,
  TIOCSCTTY, dup2, closing every descriptor above 2, an empty signal mask, SIG_DFL for every signal, chdir and
  execve.
- Failures up to and including exec come back through a close-on-exec status pipe, and the failed child is reaped.
  `start` now throws `spawnFailed(errno)` for an exec failure, instead of the process exiting with 127. A new test
  covers ENOEXEC.

### Two engine bugs found while chasing the earlier flakes (both fixed)
1. **Deadlock in reaping.** macOS posts the process-exit event when the child *starts* exiting. A child whose last
   output is still queued in the tty stays in state `E` until the master reads it. The exit handler called a
   blocking `waitpid` on the same serial queue that reads the master, so the child waited for a read and the read
   waited for the child. This hung one full run, and it is the probable cause of the earlier "echo output empty"
   flake, since the tty drain gives up and discards the output. Reaping is now polled (`WNOHANG` every 5 ms) while
   reading continues.
2. **Output lost when the last slave descriptor closes.** The parent now keeps its own slave descriptor
   (close-on-exec) until the channel has drained after the exit, so the tty cannot discard queued output when the
   child exits.
- The other flake ("7 or 22 extra bytes") is not cross-talk. I verified that with an fd-identity check on every
  read. It is the macOS tty emitting `y\r\r\n` when a write blocks halfway through the onlcr conversion under load.
  The flood test now counts lines instead of bytes.

## Main-thread budget for output (load-test fix)

- **Contract:** `TerminalEngine.outputConsumed(_ byteCount: Int)`, with a default no-op in a protocol extension.
- **`TerminalFeedScheduler`** (`@MainActor`, `.shared`, injectable) works like this:
  - Sessions buffer their output; nothing is fed synchronously in `onOutput`.
  - The scheduler drains sessions round-robin in 16 KB chunks until a 5 ms budget is spent (monotonic
    `ContinuousClock`). After each chunk it calls `engine.outputConsumed(n)`.
  - It then yields through `DispatchQueue.main.asyncAfter` (1 ms), so the run loop sleeps, Core Animation commits
    and drawing and input get a turn. A `main.async` loop would never let the run loop wait.
  - After a quiet period the first turn runs immediately, so keystroke echo is not delayed.
  - Diagnostics: `pendingByteCount`, `longestTurn` and `turnCount`.
- **`TerminalSession`:**
  - `pendingByteCount` and `fedByteCount`.
  - The exit is delivered only after all output before it has been fed.
  - `attached(scrollback:)` goes through the scheduler and is placed ahead of any live output that already arrived.
    Scrollback bytes are not reported through `outputConsumed`.
  - `terminate()` returns once the session's exit has been delivered, bounded by `exitTimeout`, default 5 s.
- **`SwiftTermEngine` flow control:** `TerminalSession` turns it on automatically for a `SwiftTermEngine`, or it can
  be enabled with `enableConsumptionFlowControl()`. While it is on, PTY reads pause once more than 4 MB has been
  delivered but not consumed, and resume below 1 MB. A flooding terminal's footprint therefore stays bounded instead
  of growing with the backlog. The hosted engine keeps the default no-op until the PTY agent implements its own.
- **Tests (`TerminalFeedSchedulerTests`):**
  - Output is fed before the exit, and nothing is fed synchronously.
  - An exit with no pending output is delivered once.
  - Exact round-robin order across two sessions (`ABABABAAAAAAA`).
  - `outputConsumed` totals equal the engine bytes fed, excluding scrollback.
  - Scrollback comes before live output.
  - 20 MB across 4 sessions in Debug: about 610–700 turns, with the **longest turn 9.5–11 ms** (asserted < 50 ms).
- **Ticker gap:** a main-actor ticker measures the longest stretch in which nothing else could run. Run alone, it
  shows the longest gap at 11–18 ms. In the parallel full suite it also contains other suites' main-actor work (up
  to about 240 ms), so it is printed, not asserted.

`swift test --package-path Packages/MercuryTerminal`: 47 tests in 10 suites pass, with zero compiler warnings after
a clean rebuild. 12 more consecutive full runs passed (skipping the slow benchmark).
