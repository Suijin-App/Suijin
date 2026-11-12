# Orca codex-accounts: behavior notes (resolves the phase 6 [UNVERIFIED] item)

Source read: `orca/src/main/codex-accounts/`, `src/main/codex/configuration/{homes,settings,toml}/`,
`src/main/codex/history/{bridges,rollouts,index}/`, `src/main/rate-limits/providers/codex/`.

## Home layout and ownership

- One `CODEX_HOME` per account: `<userData>/codex-accounts/<accountId>/home` (Mercury: `<dataRoot>/codex-homes/<uuid>/home`).
- Created with `mkdir -p`, then an ownership marker `home/.orca-managed-home` containing `<accountId>\n`
  (`codex-managed-home-lifecycle.ts`). Cleanup and every use require the marker.
- Ownership check (`host-codex-managed-home-ownership.ts`), all on realpaths:
  - the home must exist; canonical home must be inside the canonical accounts root and not equal to it;
  - with an expected account id, canonical home must equal `<root>/<id>/home` and the marker must read `<id>`;
  - the canonical home must not be inside the canonical `~/.codex`;
  - the marker must be a regular file (lstat).
  - A missing home/marker is "untrusted" (selection may be cleared); a read error is "indeterminate"
    (refuse the operation but keep state).

## auth.json (credentials, not Keychain)

- Credentials live in `CODEX_HOME/auth.json`. Shape used by Orca:
  `{ "auth_mode"?: "chatgpt" | "apikey" | ..., "OPENAI_API_KEY"?: string, "tokens": { "id_token": JWT,
  "access_token": string, "refresh_token": string, "account_id": string }, "last_refresh"?: string }`.
- Identity (`codex-auth-identity.ts`): decode the JWT payload of `tokens.id_token` (base64url, middle part):
  - email: `payload.email` or `payload["https://api.openai.com/profile"].email`;
  - providerAccountId: `tokens.account_id`, else `auth claims.chatgpt_account_id`, else `payload.chatgpt_account_id`,
    where auth claims = `payload["https://api.openai.com/auth"]`;
  - workspaceLabel: `auth.workspace_name`, `profile.workspace_name`, else derived from `auth.chatgpt_plan_type`
    (free/go/plus/pro -> "Personal (Free|Go|Plus|Pro)", team, business, enterprise, edu -> "Education");
  - workspaceAccountId: `auth.workspace_account_id`, else `tokens.account_id`, else `payload.chatgpt_account_id`.
  - Blank strings are treated as absent. Camel-case variants (`idToken`, `accountId`) are also accepted.
- A non-empty `OPENAI_API_KEY` in auth.json means an API-key login: identity is all null.
- Parse errors are reported without the raw JSON error (it could echo credential bytes).

## Login

- `codex login` (or `codex login --device-auth` for another device) with `CODEX_HOME=<home>` added to the
  inherited environment; stdin ignored, stdout/stderr piped (`codex-login-session.ts`).
- Browser link: the line after the marker `navigate to this url to authenticate:` (ANSI stripped), accepted only once
  trailing whitespace proves it is complete. Device auth: an `auth.openai.com` link followed by a
  "one-time code" line with a code like `ABCD-EFGH`.
- Timeouts: 180 s for the browser flow, 900 s for device auth (Mercury uses 10 min for both, per the task brief).
- Completion: process exit code 0. auth.json is snapshotted before spawn; once its bytes change, cancellation is
  refused (it would roll back an authenticated home). On Windows only, a changed auth.json triggers killing a
  lingering login process after a 5 s grace and still counts as success.
- Re-authentication goes through a staging home `<home>/<staging>` (config.toml copied in) because `codex login`
  revokes and deletes the current auth first; only a finished login replaces the home's auth.json.
- Adding an OAuth account is refused while `~/.codex/config.toml` pins a top-level `model_provider` other than
  `openai`.

## config.toml mirror

- `~/.codex/config.toml` is mirrored into each home on launch (`codex/configuration/settings/codex-config-mirror.ts`),
  written with mode 600 (MCP env tokens may be inside).
- Runtime-owned tables stay with the home: `[projects."<path>"]` (trust) and `[hooks.state.*]` (hook trust).
  A system `trust_level = "untrusted"` revocation wins over a runtime grant. `[mcp_servers.<name>]` that only the
  home defines are kept unless the system config owns the `mcp_servers` root or mirrored that name before.
- Relative values of path keys (`model_instructions_file`, `experimental_instructions_file`, `log_dir`,
  `sqlite_home`, `skills.config.path`, ...) are rewritten to absolute paths under `~/.codex`.
- A blank or missing source config never clears an existing home config (cloud-synced files may be unhydrated).
- Daemon socket guard: Codex >= 0.157 starts a daemon on `<CODEX_HOME>/app-server-control/app-server-control.sock`;
  when that path exceeds `sun_path` (103 bytes on macOS) Orca writes
  `[features] daemon_auto_start = false # orca: CODEX_HOME too long for the daemon socket` and strips it otherwise.
- Orca also "promotes" settings changed inside a home back into `~/.codex/config.toml` before mirroring. Mercury
  must not write `~/.codex`, so it does not port promotion (see the wave 1 report).

## Shared resources

- Symlinked from `~/.codex` into each home when the target is free: `skills`, `hooks`, `plugins`, `plugin-state`,
  `profile-v2`, `themes`, `prompts`, `.tmp/bundled-marketplaces`, `AGENTS.md` (`codex-home-paths.ts`). A stale link
  is removed when the source disappears; user-owned targets are left alone.
- `rules/*.rules` are copied as `_orca-global-<name>` so the home's own `default.rules` approvals win.

## Session history sharing

- Setting `codexShareHistoryAcrossAccounts`, absent = on (`codex-history-sharing.ts`).
- On launch/selection a background bridge hardlinks rollout files (`sessions/**/*.jsonl`, `*.jsonl.zst`) missing from
  the target home, taking sources in order: `~/.codex`, the legacy shared mirror, sibling account homes
  (`codex-account-session-bridge.ts`, `codex-session-link-pass.ts`). Hardlinks because Codex resume ignores
  symlinked JSONL; symlink fallback across volumes. Existing names are never replaced.
- It only links when the target's newest `state_<n>.sqlite` reports `backfill_state.status = 'complete'`, or the target
  has no DB but already has rollouts; otherwise it first creates the DB through `codex app-server` and afterwards
  heals the thread index in the DB for the bridged threads.

## Usage (rate limits)

- `GET https://chatgpt.com/backend-api/wham/usage`, 10 s timeout (`codex-backend-usage-client.ts`,
  `codex-backend-auth.ts`). Headers: `Authorization: Bearer <tokens.access_token>`, `User-Agent: codex-cli`,
  `OpenAI-Beta: codex-1`, `originator: Codex Desktop`, and `ChatGPT-Account-Id: <tokens.account_id>` when present.
- Response: `{ plan_type: string, rate_limit: { primary_window, secondary_window } }`, each window
  `{ used_percent: 0-100, limit_window_seconds, reset_at: epoch seconds }`. A response without a string `plan_type`
  is rejected.
- Classification: window length 300 min (+-1) = session (5 h), 10080 min (+-1) = weekly; unknown lengths fall back
  to primary = session, secondary = weekly.

## Removal

- Orca deletes the home tree (no `codex logout`). Mercury runs `codex logout` best-effort first, per the contract.
