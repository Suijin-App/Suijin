# Code Review: Mercury Swift packages

Date: 2026-11-11 (Asia/Saigon). Read-only review; no source files were changed.

## Code Review Summary

### Scope
- Packages: MercuryCore, MercuryGit, MercuryPTYProtocol (MercuryPTYProtocol, MercuryPTYHostKit, CMercuryPTY), MercuryTerminal (incl. shell integration resources), MercuryAgents, MercuryAccounts, MercuryDiff (tree-sitter scanners excluded), Helpers/MercuryPTYHost/main.swift.
- About 7,500 lines of non-test source read. Most attention went to process/PTY lifecycle, account isolation and shell integration.
- Review focus: defects the passing test suites do not catch.
- Updated plans: none. This was a read-only review, and no plan file was given.

### Overall Assessment
The code is careful and well-reasoned. Fork/exec in the C shim is async-signal-safe. The scrollback and offset design gives a clean snapshot-to-live hand-off. Profile paths are checked for symlinks and overlap with the default homes. The hook command and the shell functions quote correctly, and no token reaches logs, errors or files.

Two real defects stand out, and one was confirmed by experiment:
1. Closing a hosted terminal tab leaves background jobs that ignore SIGHUP running as orphans.
2. Claude profile provisioning shares every unknown `~/.claude` directory, so it already symlinks a runtime directory (`session-states`) into each profile.

No critical issues were found.

### Critical Issues
None found.

### High Priority Findings

**H1. Hosted sessions leave HUP-ignoring background jobs running after terminate (verified)**
- Location: `Packages/MercuryPTYProtocol/Sources/MercuryPTYHostKit/PTYSession.swift:236-255` (`terminate`), `:279-286` (`processGroups`).
- Problem: `terminate` sends SIGHUP and later SIGKILL to only two process groups: the session leader's group and the terminal's current foreground group. An interactive zsh or bash with job control puts every background job in its own process group. A job that ignores SIGHUP (`nohup cmd &`, `trap '' HUP`, a disowned job, or a dev server an agent started in the background) is therefore never killed.
- Evidence: I ran a scratch harness that drives `PTYSession` with `zsh -f -i`, ran `nohup sleep 777 &` and `(trap '' HUP; exec sleep 778) &`, then called `terminate`. Both sleeps were still alive 2 s after the SIGKILL escalation, each in its own pgid. I killed them afterwards.
- Impact: this breaks the "No orphan processes" repo rule and the contract "SIGHUP → wait → SIGKILL; no orphan processes" on the default (hosted) engine. The in-process `PTYChannel` already handles this case through `proc_listpids(PROC_TTY_ONLY, …)`, so the two engines behave differently.
- Fix: at terminate time, list the processes attached to the slave tty, the same way `PTYChannel.attachedProcesses()` does. The helper keeps the slave open until `finish`, so the device number stays valid. Send SIGHUP and SIGCONT to each member's pgid. When the grace period ends, send SIGKILL to the remaining members, and do it before `finish` closes the fds. One way: keep the master open until the sweep, using the same idea as the `holdOpen` flag in PTYChannel. Add the nohup case above as a regression test.

**H2. Claude provisioning shares unknown `~/.claude` directories, which already includes a runtime-state folder**
- Location: `Packages/MercuryAccounts/Sources/MercuryAccounts/Claude/ClaudeProfileProvisioner.swift:42-68` (denylist plus `isSharedEntry`), `:91-93` (linking).
- Problem: every directory in the default home that is not on `runtimeStateEntries` or `historyEntries` gets symlinked into each profile. The current `~/.claude` on this machine contains `session-states/`, which is not on either list. Each profile therefore gets `home/session-states -> ~/.claude/session-states`.
- Impact: a managed-account Claude writes its per-session runtime state into the user's real `~/.claude`, and that state mixes across all accounts. This goes against the "never touch the user's own logins" rule and the provisioner's own "runtime state stays private" promise. Any runtime directory a future Claude release adds will be shared silently in the same way. `plugins/` is shared on purpose, but it means plugin installs made from a profile also write into `~/.claude/plugins`; that should be a deliberate, documented choice.
- Fix: replace the denylist with an allowlist of resource folders, for example `agents`, `commands`, `skills`, `hooks`, `output-styles`, `rules`, `plugins` (if intended) and `scripts`. Anything unknown should stay private. If the denylist must stay, add `session-states` at least, plus a test that fails when a non-allowlisted directory gets linked.

### Medium Priority Improvements

**M1. `settings.json` sync copies auth settings that override the managed login**
- Location: `ClaudeProfileProvisioner.swift:104-109`, `Claude/ClaudeSettingsSync.swift:25-36`.
- Problem: every top-level key of `~/.claude/settings.json` is copied into the profile. `ClaudeLaunchEnv` removes credential environment variables from the process, but the settings file can bring the same credentials back:
  - `env.ANTHROPIC_API_KEY`, `env.ANTHROPIC_AUTH_TOKEN` or `env.CLAUDE_CODE_OAUTH_TOKEN`.
  - `apiKeyHelper`, `awsAuthRefresh` or `awsCredentialExport`.
- Impact: Claude ranks these above the claude.ai OAuth login. A user with an `apiKeyHelper` or a key in settings `env` therefore runs every "managed account" on their personal key, and switching accounts does nothing.
- Fix: in the sync, drop or override auth-bearing keys: `apiKeyHelper`, `awsAuthRefresh`, `awsCredentialExport`, and inside `env` the variables listed in `ClaudeLaunchEnv.authEnvVars` plus auth-like `ANTHROPIC_CUSTOM_HEADERS`. Warn through `ProvisionWarning`.

**M2. The hosted terminal has no client-side backpressure, so a flood grows app memory without bound**
- Locations:
  - `MercuryPTYHostKit/PTYHostService.swift:97-104`: the send barrier releases the in-flight window.
  - `MercuryTerminal/PTYHostClient.swift:251-254`: each message is hopped to `DispatchQueue.main.async`.
  - `HostedTerminalEngine.swift:108-114`: the bytes are copied and fed to SwiftTerm synchronously.
- Problem: the helper's 1 MB window is released once XPC has *sent* a message, not once the app has *processed* it. The client receiver returns at once after queueing a main-queue block. Under sustained output (`yes`, `cat` of a large log, a runaway agent loop), messages of up to 256 KB pile up on the main queue faster than SwiftTerm can parse them. App memory then grows without bound and input and drawing starve.
- Impact: the in-process engine guards against this explicitly (high/low water marks and a 1 MB-per-turn cap in `PTYChannel`); the default engine does not. This comes from reading the code; I did not measure it.
- Fix: acknowledge consumption from the app. One option is a `consumed(sessionID, bytes)` XPC message after `onOutput`. Another is to make `output` take a reply block and release the window when that reply arrives. A cheaper alternative is to coalesce on the client: append to a per-engine buffer and keep one scheduled main-queue drain with a per-turn cap.

**M3. Login-shell PATH lookup skips `.zshrc`, so nvm/npm-installed agents are not found**
- Location: `MercuryAgents/AgentCatalog.swift:97-104` (`<shell> -l -c`), and `MercuryTerminal/ShellLaunch.swift:58-76` (agents start through `$SHELL -l -c 'exec …'`).
- Problem: a non-interactive login zsh reads `.zshenv`, `.zprofile` and `.zlogin`, but never `.zshrc`. Many users set PATH there: nvm, the `~/.local/bin` line suggested by the Claude installer, volta and others. For them `resolveBinary` fails with "agent not found". If the binary does resolve (for example through `fallbackPATH`), an npm-installed `claude` (`#!/usr/bin/env node`) still dies with `env: node: No such file or directory`, because the agent's own shell has the same PATH.
- Fix: query PATH with `-l -i -c` (keeping the markers, the timeout and stdin on /dev/null), or fall back to the interactive form when the login-only PATH cannot resolve the agent. Pass the resolved PATH into the agent launch environment through the `env` patch, so the agent's `node` resolves too.

### Low Priority Suggestions

- **L1. Swift code runs between fork and exec in the in-process engine.** `MercuryTerminal/PTYChannel.swift:97-115`. The child iterates a Swift array literal and calls through the Swift runtime after `forkpty` in a multithreaded app. That is exactly what the CMercuryPTY comment says Swift cannot guarantee. The engine is only a fallback, but `mercury_pty_spawn` (or a small C child routine) should be reused here.
- **L2. SIGKILL escalation can target a reaped pgid.** `PTYSession.swift:250-252`. `killpg(group, SIGKILL)` for the leader's pid and the captured foreground pgid runs 2 s after the SIGHUP, even if `finish` has already reaped the leader. If every member is gone, that pgid number is free for reuse. Reuse within 2 s is unlikely given sequential pids, but it is not impossible, and `PTYChannel` already guards against it. Skip the killpg when the group no longer has members on this tty, which follows naturally from the H1 fix.
- **L3. A timed-out attach leaks a helper attachment.** `PTYHostClient.swift:136-164, 299-307`. If `attach` times out after 10 s and the helper's reply arrives later, the helper keeps a live attachment for this client. `routeOutput` then finds no `engines` entry and drops the bytes without calling `detach`, so the helper streams that session to the app until the connection ends. Call `hostProxy?.detach(sessionID)` in the timeout and error paths of `attach`, or detach when output arrives for an unknown session.
- **L4. Hook event logs are world-readable.** `MercuryAgents/ClaudeHooks.swift:85` creates `hooks/` and `hooks/events/` with default permissions (0755), and the hook's `>>` creates `*.jsonl` as 0644 under umask 022. These files hold the full UserPromptSubmit payloads: prompt text, cwd and transcript paths. `~/Library` is 0700, so the exposure is small, but the repo rule asks for 700/600 on private data. Create the directories as 0700 and add `umask 077;` to the hook script.
- **L5. git inherits the app's `GIT_*` environment.** `MercuryGit/GitRunner.swift:63-70`. If the app was started with `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` or `GIT_CONFIG_*` set (launched from a hook, a script, or a Claude Code session in another repo), every status, diff and worktree call targets the wrong repository. Strip `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`, `GIT_COMMON_DIR` and `GIT_CONFIG_PARAMETERS`.
- **L6. Ref arguments can be read as git options.** `Worktree.swift:42` (`base`) and `DiffService.swift:56` (`merge-base <branch>`). A value starting with `-` is parsed as an option. Insert `--end-of-options` before revision arguments.

### Checked and not reported
- **CMercuryPTY:** only async-signal-safe calls between fork and exec, status-pipe failure reporting, the child reaped on failure, and the master and slave closed by the read source's cancel handler. No fd leak was found.
- **Scrollback to live stream:** `attach` registers the cursor at `totalWritten` inside the session queue, so there is no gap and no duplicate. The exit is delivered only after the last byte.
- **XPC replies:** every reply block (handshake, list, spawn, attach) is called exactly once on every path. The client side guards each call with `ResumeOnce` and a timeout.
- **Shell integration:**
  - zsh: the user's ZDOTDIR is restored in `.zlogin`, or at the end of `.zshrc` for a non-login shell. The user's `.zshrc` is sourced once, and HISTFILE is repaired.
  - bash: the login files are emulated through `--rcfile`.
  - The functions defer to a user-set `CLAUDE_CONFIG_DIR` / `CODEX_HOME` and to a user-defined function, and quote every path.
- **Env patches survive the user's profile:** `ClaudeLaunchEnv` / `EnvPatch` changes are applied by `/usr/bin/env` after the login shell has run that profile, so a key it exports cannot win.
- **Profile store safety:** the `<root>/<uuid>/home` shape is enforced, symlinks below the root are rejected, overlap with the default homes is rejected in both directions, writes are atomic and exclusive with mode 600, and removal never follows links.
- **Keychain:** profile items are never the unsuffixed default item, and tokens stay in memory.
- **Git and diff parsing:** the `-z` name-status and worktree-list parsing are correct, the hunk parser counts lines down, and `\ No newline` is handled.
- **GRDB:** `save` performs an update, then an insert, never a REPLACE, so cascades cannot fire by accident. Foreign keys are on.

### Positive Observations
- The scrollback-as-source-of-truth design (absolute offsets, per-attachment windows) is simple and holds up.
- The C shim is the right call, and it is commented precisely.
- Writes to profiles and Codex homes go through careful, POSIX-explicit file operations: lstat checks, link-free paths, atomic rename and exclusive link.
- Codex re-login goes through a staging folder, so a failed sign-in never destroys the existing credentials.

### Recommended Actions
1. Fix H1 by sweeping the tty's members on terminate, and add a nohup regression test.
2. Fix H2 by switching provisioning to an allowlist, or at least excluding `session-states`.
3. Fix M1 by stripping auth-bearing keys from the synced `settings.json`.
4. Fix M2 by adding an app-side consumption acknowledgement or client-side coalescing.
5. Fix M3 by resolving PATH with an interactive login shell and passing it to the agent.
6. Handle L1 through L6 as time allows.

### Metrics
- Type coverage: not measured (Swift 6 strict concurrency is on in every package).
- Test coverage: not measured; all package suites pass, as stated in the task.
- Linting issues: none observed. comment-lint was not run.

### Unresolved Questions
1. Codex session sharing hardlinks `~/.codex/sessions/**/*.jsonl` into account homes (`CodexSharedResources.swift:131`). When an account resumes a shared conversation, Codex appends to the same inode, so the user's `~/.codex` rollouts change. Is that accepted under the "never touch `~/.codex`" rule?
2. Should `plugins/` be shared at all, given that plugin installs made from a profile then write into `~/.claude/plugins`?
3. Should H1 kill a `nohup`ed job in a hosted tab? The in-process engine does, and the contract says it should, but some users run long jobs under `nohup` on purpose.
