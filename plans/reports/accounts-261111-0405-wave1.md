# MercuryAccounts, wave 1 report

Status: DONE_WITH_CONCERNS. `swift test --package-path Packages/MercuryAccounts` passes: 68 tests in 13 suites, run on a
clean build with zero compiler warnings under Swift 6 strict concurrency. `Tools/comment-lint` passes.
The public API matches `contracts.md` (section MercuryAccounts). Nothing was committed.

## Files

Everything is under `Packages/MercuryAccounts/`.

- `Sources/MercuryAccounts/ManagedAccountProvider.swift` holds the contract types (`AccountIdentity`, `UsageWindow`,
  `UsageSnapshot`, `LoginSession`, `ManagedAccountProvider`). It adds `InteractiveLoginSession` (`send(_:)` for
  Claude's pasted-code prompt) and the error types `AccountsError`, `LoginError` and `UsageError`.
- `Shared/` holds the helpers both providers use:
  - `FileOps`: POSIX file helpers with explicit modes, atomic and exclusive writes, and canonical paths. It also
    contains `PointerFile`.
  - `CommandRunner`: the injectable `CommandRunning` protocol, implemented with `Process`.
  - `HTTPTransport`: the injectable `HTTPTransport` protocol and `URLSessionTransport` (ephemeral session, 10 s
    timeout).
  - `ProcessLoginSession`: the login engine.
  - `CLIEnvironment`: finds the CLI binaries and builds the environment for the login and logout processes.
- `Claude/`: `ClaudeProfileStore`, `ClaudeProfileProvisioner`, `ClaudeSettingsSync`, `ClaudeStateCopy`,
  `ClaudeLoginRunner`, `ClaudeKeychainReader`, `ClaudeUsageClient`, `ClaudeLaunchEnv`, `ClaudeAccountProvider`.
- `Codex/`: the files the brief listed, plus `CodexTOML` (a line-level TOML scanner) and `CodexSharedResources`
  (resource links, rules, and session sharing).
- `Tests/MercuryAccountsTests/` has 6 files. Every test uses a temporary `realHome` and data root, a fake command
  runner (no real `security` call and no real login or logout), a fake HTTP transport, and fake CLI shell scripts.
- `plans/261110-2054-mercury-native-agent-orchestrator/reports/codex-accounts-notes.md` is the phase 6 step 1
  summary. It resolves the [UNVERIFIED] item about the `auth.json` shape, headers, and how `sessions/` is shared.

## What is ported from Orca

**Profile paths.** The Claude profile home is `<dataRoot>/claude-profiles/<uuid>/home` (lowercase uuid, because the
Keychain item name is a hash of the exact path string). Setup refuses a home that:
- falls outside that layout;
- has a symlink in any path component below the root;
- is equal to, inside, or around `~/.claude`, `~/.config/claude`, or the user's own `CLAUDE_CONFIG_DIR`. This check
  runs on canonical paths and is case-insensitive.

`profile.json` (600) is written last, so an interrupted setup runs again on the next launch. A marker that names a
different account is refused.

**Provisioning.**
- Folders in the default home are symlinked into the profile. Files are copied, keeping only the owner permission
  bits, so a status-line script stays executable.
- `CLAUDE.md` becomes `@~/.claude/CLAUDE.md`. If the user set their own config dir, the file is copied instead.
- These stay private to each profile: everything in `CLAUDE_RUNTIME_STATE_ENTRIES`, the history folders, hidden
  entries, and `daemon*` and `agent-memory*` entries.
- Entries the user owns are left alone.
- `settings.json` uses Orca's per-key digest sync. The record holds digests only and sits beside the profile, outside
  the home. Keys Claude saved inside the profile survive until the user changes the same key in the default home.
- `.claude.json` copies without the account-bound keys: the logout keys, `userID`, `machineID`, `primaryApiKey`,
  `*Cache*`, `cached*`, `passes*`, and `claudeCodeFirstTokenDate`. `projects`, `mcpServers` and `groveChoiceSeenAt`
  are merged entry by entry, keeping trust the profile granted and the newest Grove timestamp. A legacy
  `.config.json` file takes precedence, as in Orca.

**Keychain.**
- The service name is `Claude Code-credentials-<sha256(NFC dir)[0:8]>`. The Keychain account is `$USER`, or
  `claude-code-user` when that name is not Keychain-safe.
- Realpath aliases are found without creating anything. A path containing `..`, or a broken symlink on the way,
  gets no alias.
- Reads run `/usr/bin/security find-generic-password -s <service> -a <user> -w`. If there is no Keychain item, the
  profile's `.credentials.json` is used.
- The default item is never read. A broken Keychain is reported as an error and never falls back to the default
  login.
- The test vectors were computed independently with `shasum`. Orca's alias test cases are ported too. Orca's own tests
  have no vectors for the service hash.

**Usage.**
- Claude: `GET api.anthropic.com/api/oauth/usage` with the `oauth-2025-04-20` beta header. `utilization` or
  `used_percentage` is a percentage from 0 to 100. `resets_at` may be an ISO string (microsecond fractions are
  handled), epoch seconds, or epoch milliseconds.
- Codex: `GET chatgpt.com/backend-api/wham/usage` with Orca's headers, including `ChatGPT-Account-Id`. A response
  without `plan_type` is rejected. Windows are classified by length (300 and 10080 minutes, with one minute of drift
  allowed); otherwise primary is the session window and secondary the weekly one. `reset_at` is in epoch seconds.
- Every failure is a typed `UsageError`, and no error message contains a token.

**Login.** One `ProcessLoginSession` serves both CLIs:
- Output is an `AsyncStream` of lines with ANSI codes stripped.
- The default timeout is 10 minutes, and the session can be cancelled (SIGTERM, then SIGKILL after 2 s).
- An "access denied" message from Claude fails the login at once.
- The executable is injectable. Credential variables and parent-Claude session stamps are removed from the login
  environment.
- Codex completes when the process exits with code 0, or when the `auth.json` bytes change compared with a snapshot
  taken before start. In the second case the CLI gets a 5 s grace period, cancellation is refused, and the login
  still succeeds.
- Codex re-authentication goes through a staging home, as in Orca, so a failed login keeps the old credentials.
- `CodexLoginRunner.authURL(in:)` reads Orca's link marker. `deviceAuth` runs `login --device-auth`.

**Launch env and pointer files.**
- With a profile: `CLAUDE_CONFIG_DIR` and `MERCURY_CLAUDE_INJECTED_CONFIG_DIR` are set; `ANTHROPIC_API_KEY`,
  `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN` and `AWS_BEARER_TOKEN_BEDROCK` are removed, and so is
  `ANTHROPIC_CUSTOM_HEADERS` when it carries auth headers.
- Codex: `CODEX_HOME` and `MERCURY_CODEX_INJECTED_HOME` are set.
- With `nil` (default login): the user's own config dir and environment are kept, and only a value Mercury injected
  earlier is dropped.
- `writePointer` writes the home path (600, atomic) to `.../selected-host`. `nil` deletes the file.

**Codex home and config.**
- The home is created with mode 700, plus a `.mercury-managed-home` marker (600).
- Ownership is checked on realpaths as in Orca: the home must sit inside the root, must not overlap `~/.codex`, and
  the marker must match.
- Adding an account is refused when `~/.codex/config.toml` sets a `model_provider` other than `openai`.
- The config mirror:
  - writes `config.toml` with mode 600;
  - keeps the home's own `projects` trust (a system `untrusted` revocation still wins) and its `hooks.state` trust;
  - keeps MCP servers that only the home defines; hook trust scoped to the user's home is never shared;
  - rewrites relative path settings against `~/.codex`;
  - never lets a blank source clear a home's config;
  - always applies the daemon socket guard. Mercury's real home paths are longer than the 103-byte `sun_path` limit,
    so the guard is active in practice.
- Resource entries are symlinked (`skills`, `hooks`, `plugins`, …, `AGENTS.md`), and `rules/*.rules` are copied
  with a prefix.

**Removal.**
- Claude: run `claude auth logout` inside the profile (best effort), delete that profile's Keychain items in every
  spelling Orca uses (never the default item), then delete the folder. Shared folders are unlinked, never followed.
- Codex: run `codex logout` (best effort), then delete the folder.
- In both cases the pointer file is cleared if it named the removed home.

## Orca behavior deliberately not ported

1. **Claude history sharing** (`shareClaudeProfileHistory`). Orca moves a profile's `projects`, `todos`, `plans`,
   `history.jsonl` and similar folders into `~/.claude`, then links them back. That writes into `~/.claude`, which
   `CLAUDE.md` forbids. Consequence: each Claude profile keeps its own transcripts and its own `/resume` list.
   For the same reason the first-setup merge of a non-empty profile folder is not ported; that folder is reported as
   `userOwned`.
2. **Codex settings promotion.** Before mirroring, Orca writes settings changed inside a home back into
   `~/.codex/config.toml`. Mercury replaces this with a source-digest gate: the mirror runs only when the user's
   config changed, so changes made inside a home survive until then.
3. **Codex session index healing and state DB creation** (through `codex app-server`). Mercury hardlinks rollouts
   only when the target's `state_N.sqlite` shows a complete backfill, or when there is no DB yet but the home already
   has rollouts. It does not create the DB or heal the thread index. Bridged sessions may therefore not appear in
   `codex resume` until Codex indexes them itself, and a new home only receives links after Codex has run in it once.
4. **Claude hook installation into profiles.** Mercury passes hooks with `--settings` (contract).
5. **Claude's `.claude.json` file lock** (`updateClaudeGlobalConfig`). Mercury writes atomically (temp file and
   rename) but does not take Claude's lock. If Claude writes the file at the same moment, during the short
   read-modify-write before a launch, that write could be lost.
6. **Copy-link `BROWSER` helper** (`claude-sign-in-browser.ts`). Mercury streams the CLI output instead and lets the
   browser open normally. Not verified: whether `claude auth login` prints the URL when stdout is not a TTY. If it
   does not, the UI cannot offer "Copy link".
7. Also not ported: WSL and Windows paths, Orca's legacy migrations, and Codex reset credits.
   - The "covered by system default" routing and the 5 s background refresh: Mercury provisions synchronously
     because it is file work only.
   - The `CLAUDE_CODE_CUSTOM_OAUTH_URL` state-file suffix.
   - Codex credential-absence grace, identity matching against saved records, and rebasing
     `marketplaces.openai-bundled.source` in the config (the `.tmp/bundled-marketplaces` link is ported).
8. **Codex keyring credential store.** When `cli_auth_credentials_store` puts credentials in the system keyring there
   is no `auth.json`, so identity and usage return nil or `notSignedIn`. Orca has the same limitation.

## Deviations from Orca, chosen on purpose

- **Claude launch env.** Credential variables are removed for managed profiles only, as the plan requires. The
  default login keeps the user's ambient auth, as Orca's terminal launches do. Orca removes them only in probes.
- **Codex launch env.** API key variables are not removed, which matches Orca. They are removed from the login
  environment.
- **Codex login timeout.** 10 minutes, per the brief. Orca uses 180 s, or 900 s with device auth.
- **File modes.** Copied profile files keep only the owner permission bits (600 or 700). Orca keeps the full source
  mode.
- **Removal runs logout first**, as the contract says. Orca only deletes the Keychain items (Claude) or the folder
  (Codex).

## Integration notes for other packages

- MercuryTerminal shell functions: Mercury sets `MERCURY_CLAUDE_INJECTED_CONFIG_DIR` and `MERCURY_CODEX_INJECTED_HOME`
  next to every config dir it injects. A `CLAUDE_CONFIG_DIR` that differs from its marker value was set by the user.
- App:
  - Pass `userConfigDir` (the login shell's `CLAUDE_CONFIG_DIR`) and the login-shell `environment` into
    `ClaudeAccountProvider`.
  - Call `prepareForLaunch(home:)` before every agent launch.
  - Merge `launchEnv(home:)` with the hooks `EnvPatch`.
  - Ignore `usage` errors.
- `CodexAccountProvider(shareSessions:)` maps to the "share history across accounts" setting, which defaults to on.

## Concerns for the controller

1. **Hardlinked Codex sessions share the inode with `~/.codex/sessions`.** If an account resumes a conversation that
   started under the default login, Codex appends to the same file the user's own Codex reads. This is Orca's intended
   sharing, and the plan makes it the default, but it is indirect write access to `~/.codex` content. Please confirm
   it should stay on by default. Setting `shareSessions: false` turns it off.
2. **Login cancellation only signals the CLI process itself.** Grandchild processes are not in a separate process
   group. The real `claude` and `codex` are single binaries, and the fake-CLI tests left no orphaned processes.

## Unresolved questions

- Does `claude auth login --claudeai` print the sign-in URL to a non-TTY stdout? Mercury relies on that for the
  "Copy link" button. Verifying it needs a real login, which this phase was not allowed to run.

## Review fixes (H2, M1 from code-reviewer-261111-0451-packages.md)

After these fixes, `swift test --package-path Packages/MercuryAccounts` passes 73 tests in 14 suites, with zero
compiler warnings and a clean comment lint. All new tests use temporary homes. They are in
`Tests/MercuryAccountsTests/ReviewFixTests.swift`.

- **H2: shared folders now use an allow list.**
  - Only these folders in the default home are symlinked into a profile: `agents`, `commands`, `skills`, `hooks`,
    `output-styles`, `rules`, `plugins` and `scripts` (`ClaudeProfileProvisioner.sharedDirectories`). Any other
    folder is reported as `absent` and never linked. That includes `session-states` and any runtime folder a future
    Claude adds.
  - `plugins` stays shared, as decided, and the code documents that plugin installs then land in `~/.claude/plugins`.
  - Files still follow the existing exclusion list. They are copied into the profile, so a file never writes back
    into `~/.claude`.
  - Orca has no allow list; it links every folder that is not on its deny list. This is a deliberate deviation.
  - Test: `onlyAllowListedFoldersAreLinked`. It also proves the fake `realHome` is byte-for-byte unchanged afterwards.
- **M1: auth settings no longer reach a profile.**
  - `ClaudeSettingsSync` removes these keys before computing digests and before syncing: `apiKeyHelper`,
    `awsAuthRefresh`, `awsCredentialExport`, `forceLoginMethod` and `forceLoginOrgUUID`.
  - Inside `env` it removes `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`,
    `AWS_BEARER_TOKEN_BEDROCK`, and `ANTHROPIC_CUSTOM_HEADERS` when it carries auth headers.
  - Each removed key is reported as a `ProvisionWarning` by name, never by value.
  - The digests now cover the filtered settings, so a profile synced before this fix drops those keys on its next
    launch.
  - Orca shares `apiKeyHelper` on purpose (its provisioning test asserts it). This is a deliberate deviation.
  - Tests: `authSettingsAreNeverSyncedIntoAProfile` and `authSettingsCopiedBeforeTheFilterAreRemovedOnTheNextSync`.
- **Codex had the same kind of problem.**
  - The mirrored `~/.codex/config.toml` could carry `forced_login_method = "api"` or the older
    `preferred_auth_method = "apikey"` / `"api"`, at top level or under `[profiles.*]`. Either one makes Codex demand
    an API key instead of the home's ChatGPT login.
  - `CodexConfigMirror.withoutAPIKeyLogin` now removes them before every mirror.
  - Kept on purpose, as in Orca: `forced_chatgpt_workspace_id` and `cli_auth_credentials_store` (they constrain the
    login rather than replace it), and `forced_login_method = "chatgpt"`.
  - API key environment variables were already handled: `auth.json` is per home, custom `model_provider` pins are
    refused when an account is added, and the login runs without `OPENAI_API_KEY` and `CODEX_API_KEY`.
  - A `filterVersion` field in the mirror record forces homes mirrored before this fix to be mirrored again.
  - Orca does not filter these settings.
  - Tests: `codexMirrorDropsAPIKeyLoginModes` and `homesMirroredBeforeTheFilterAreMirroredAgain`.
