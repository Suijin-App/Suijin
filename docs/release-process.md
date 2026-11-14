# Release process

How Suijin ships outside the Mac App Store: Developer ID signing, notarization, a DMG, and in-app updates through
Sparkle 2. Releases are GitHub releases of this repository; installed copies find them through
`https://suijin.app/appcast.xml` (section 4). Every command runs from the repository root on the release Mac.

Never put in the repository: certificates (`.p12`, `.cer`), app-specific passwords, the Sparkle private key, App
Store Connect API keys. They all live in the release Mac's login Keychain.

## 1. Pieces

| Piece | Where |
|---|---|
| Sparkle 2 | Swift package in `project.yml`, pinned with `exactVersion`, linked to the `Suijin` target only. Its `sign_update` and `generate_keys` tools come with the package artifact (`<DerivedData>/SourcePackages/artifacts/sparkle/Sparkle/bin`). |
| In-app updater | `App/Updates/UpdaterController.swift` wraps `SPUStandardUpdaterController`. `UpdateCommands` adds Suijin → "Check for Updates…"; `UpdateSettingsSection` is the Updates section of Settings → General. |
| Helper handover | `App/Updates/HelperVersionCheck.swift` (section 5). |
| Sparkle keys in `App/Info.plist` | `SUFeedURL` (`https://suijin.app/appcast.xml`), `SUPublicEDKey` (the public half of the signing key, section 2.3), `SUEnableAutomaticChecks` (on), `SUScheduledCheckInterval` (86400, daily). |
| Update feed and website | `website/`: the Cloudflare Worker on `suijin.app`. It serves the website and redirects `/appcast.xml` to the `appcast.xml` asset of the latest GitHub release (section 4). |
| Scripts | `scripts/release-notarize.sh` (the whole pipeline, with `--dry-run`), `scripts/make-dmg.sh` (DMG and its signature), `scripts/dmg/` (the installer window's background and the volume icon, with `render.sh` to redraw them). |

A build whose `SUPublicEDKey` is not a real key never starts the updater (Settings → General → Updates says updates
are not configured), and `scripts/release-notarize.sh` refuses to release it, because copies installed from it could
never update.

## 2. One-time setup (Apple Developer account owner)

1. **Developer ID Application certificate** of team `YWSHDN5Y3H` in the login Keychain. Check (lists names only):
   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
   Xcode → Settings → Accounts must be signed in to an account of the team so `-allowProvisioningUpdates` can export.
   Suijin uses no restricted entitlement, so no Developer ID provisioning profile is needed.
2. **notarytool keychain profile**, created by the owner (the password never goes through a script or a file):
   ```sh
   xcrun notarytool store-credentials suijin-notary --apple-id <apple-id> --team-id YWSHDN5Y3H
   ```
   It asks for an app-specific password (appleid.apple.com). Another profile name works with
   `SUIJIN_NOTARY_PROFILE=<name>`. The release script does not look the profile up in a dry run, because that
   contacts Apple; the first real run is the check.
3. **Sparkle EdDSA key**, generated once by the owner for every Suijin
   release, under its own Keychain account so it never mixes with another app's key (Capstio uses the default
   account):
   ```sh
   <DerivedData>/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account suijin
   ```
   The private key is stored in the login Keychain; the command prints the public key. Paste it over the placeholder
   `REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY` of `SUPublicEDKey` in `App/Info.plist` and commit (the public key is not a
   secret). Print it again any time with `generate_keys --account suijin -p`.
   - Back the private key up outside the repository (`generate_keys --account suijin -x <file>`, store it in the
     company secret vault, delete the file). Losing it means installed copies can no longer be updated.
   - Another release Mac imports it with `generate_keys --account suijin -f <file>`.

## 3. Releasing

1. Bump the version in `project.yml`: `MARKETING_VERSION` (for example `0.1.1`) and `CURRENT_PROJECT_VERSION` (an
   integer that always grows; the helper handover in section 5 compares it, and Sparkle will once updates are on).
2. `scripts/ci-local.sh` must be green.
3. Dry run:
   ```sh
   scripts/release-notarize.sh --dry-run
   ```
   It archives, exports, signs, verifies and builds the DMG for real under `build/release/<version>/`, skips
   notarization and stapling, and lists at the end what would stop a real run (for example a missing Developer ID
   certificate). Without a Developer ID certificate it signs with Apple Development and warns; such a build is for
   checking the pipeline only.
4. Real run:
   ```sh
   scripts/release-notarize.sh
   ```
   Steps:
   1. Check the tools, that `App/Info.plist` carries the feed `https://suijin.app/appcast.xml` and a real
      `SUPublicEDKey`, and the team's Developer ID identity.
   2. `xcodegen generate`, `xcodebuild archive` of the Release configuration with hardened runtime
      (`-skipPackagePluginValidation -allowProvisioningUpdates`).
   3. Export with `method developer-id`.
   4. Check the nested helper `Contents/MacOS/SuijinPTYHost` with `codesign -dvvv`: identifier
      `com.tekmium.suijin.ptyhost`, Developer ID authority of the team, `runtime` flag, a secure timestamp. If the
      export left any of that out, re-sign inside out (helper, then the app with its own entitlements); Sparkle's
      nested code keeps the export's signature.
   5. `codesign --verify --deep --strict`, Developer ID, team, hardened runtime, timestamp, no `get-task-allow`,
      LaunchAgent plist and Sparkle.framework present, version and build match `project.yml`.
   6. Notarize the app (`xcrun notarytool submit --keychain-profile suijin-notary --wait`) and staple it, so the app
      inside the DMG carries its ticket. A rejection prints Apple's log.
   7. Build and sign the DMG (`scripts/make-dmg.sh`: the app beside an Applications shortcut on a background picture, with a volume icon, UDZO; needs `brew install create-dmg`).
   8. Notarize and staple the DMG.
   9. Gatekeeper: `spctl --assess --type execute -vv Suijin.app` must say `accepted`, `source=Notarized Developer
      ID`; the DMG is checked with `spctl --assess --type open --context context:primary-signature -vv`.

   10. Sign the DMG for Sparkle (`sign_update --account suijin`; the key that signs must be the one in
       `SUPublicEDKey`) and write `appcast.xml`: one item with the version, the build, the minimum macOS, the
       release notes and the download with its signature and length. The notes come from
       `docs/releases/<version>/release-notes.md`, turned into HTML by `scripts/release-notes-html.py`, so the
       update window shows them; without that file the item only links to the release page.

   Nothing is uploaded. Output stays in `build/release/<version>/` (ignored by git).
5. Publish: write the release notes from `CHANGELOG.md`, then create the GitHub release with the two files, the DMG
   first (the script prints this command with the real paths):
   ```sh
   gh release create v<version> build/release/<version>/Suijin-<version>.dmg build/release/<version>/appcast.xml \
     --repo Suijin-App/Suijin --title "Suijin <version>" --notes-file <release-notes.md>
   ```
   The release must be a normal one (not a draft or pre-release): `releases/latest` only follows those. Then check
   the feed: `curl -sIL https://suijin.app/appcast.xml` must end in `200`, and the download URL in the appcast must
   return the `length` it names.
6. Run the checks in section 6.
7. Announce the release in `#releases` of the Suijin Discord server, as Suijin Bot. The bot's token is in TSSC
   (project Suijin, environment `prod`, secret `DISCORD_BOT_TOKEN`) and is never written anywhere else:
   ```sh
   tssc run --projectId=8f31fe47-25cc-44ac-bf3b-6020f39c7688 --env=prod -- \
     .claude/skills/suijin-release-macos/scripts/announce-release-discord.py
   ```
   The script posts the opening paragraph of the release notes and the link to the release page. It stops when the
   release is not the latest published one and does not post a version twice; `--dry-run` prints the message.

Optional environment (none holds a secret): `SUIJIN_NOTARY_PROFILE`, `SUIJIN_TEAM_ID`, `SUIJIN_SIGNING_IDENTITY`,
`SUIJIN_RELEASE_DIR`, `SUIJIN_SPARKLE_ACCOUNT`, `SUIJIN_GITHUB_REPOSITORY`. See the header of `scripts/release-notarize.sh`.

## 4. How updates reach installed copies

- **The feed address is permanent.** Every build asks `https://suijin.app/appcast.xml` for as long as it is installed.
  Changing `SUFeedURL` strands every copy already out, so it stays; what can change is what answers there.
- **suijin.app redirects.** `website/` is the Cloudflare Worker bound to `suijin.app`: an Astro site built to static
  files, plus `website/worker/index.js`, which answers `/appcast.xml` with a 302 to
  `https://github.com/Suijin-App/Suijin/releases/latest/download/appcast.xml`. Only that path runs the Worker; every
  other request is a static file. Deploy with `npm run deploy` in `website/` (Node 24, after `npx wrangler login`,
  with `CLOUDFLARE_ACCOUNT_ID` set to the account that holds the `suijin.app` zone). After every deploy, check that
  `curl -sI https://suijin.app/appcast.xml` still answers with that redirect: a broken feed stops every installed
  copy from updating. Moving the downloads elsewhere later means changing that redirect and nothing in the app.
- **GitHub holds the files.** Each release has `Suijin-<version>.dmg` and `appcast.xml` as assets. The appcast names
  only the newest version, which is all Sparkle needs.
- **Signatures.** Sparkle installs a download only when its EdDSA signature matches `SUPublicEDKey`. The private key
  is in the release Mac's login Keychain (section 2.3). Losing it means no installed copy can ever update, so back it
  up outside the repository.
- **What is sent.** A check requests the appcast with the app's name and version in the user agent; system profiling
  is off. The Privacy text in `App/Features/Settings/LegalDocuments.swift` says so and must stay true.
- **What is counted.** The Worker counts each request for `/appcast.xml` under its day and the app version from the
  user agent, in a Workers KV namespace, and keeps nothing else (no address, no identifier). An installed copy checks
  about once a day, so a day's count approximates the copies in use; it is an estimate, not an install count.
  `website/checks.sh` prints the counts. The Privacy text names this too.

## 5. Updates and the PTY host helper

- Once updates are on (section 4), Sparkle checks daily; the user turns that off in Settings → General → Updates, or
  checks by hand from Suijin → "Check for Updates…" or the "Check Now" button. The download must carry a valid EdDSA
  signature for the key in `SUPublicEDKey`, or Sparkle refuses it.
- Installing an update quits Suijin the normal way, so running sessions stay in the PTY host helper when "Keep
  sessions running after quitting Suijin" is on (the default); with it off, quitting ends them as usual.
- **Helper handover.** Sparkle replaces the whole bundle, including `Contents/MacOS/SuijinPTYHost`, but the helper
  process launchd started from the old bundle keeps running. At launch, after the sessions bootstrap, the app runs
  `HelperVersionCheck`: it asks the helper for its build through the `PTYHostClient` handshake (`"0.1.0 (1)"`) and
  compares the build number with its own `CFBundleVersion`.
  - Same build, or a development helper reporting `dev`: nothing to do.
  - Different build and no session running: the app calls `shutdownHostIfIdle()`, the old helper exits, and launchd
    starts the new binary from the updated bundle on the next connection. The check waits until the new helper
    answers (up to about 5 s).
  - Different build with sessions running: the old helper is left alone, so no session is ever killed by an update.
    It exits by itself once its sessions end and Suijin disconnects; the next launch gets the new helper. The XPC
    protocol version guards compatibility in between (a protocol mismatch makes the client ask the helper to exit
    when idle and report the mismatch).
  - The launchd registration (`SMAppService.agent`) points at a path inside the bundle, so it survives the update and
    needs no re-registration.

## 6. Verification

- **Gatekeeper:** `spctl --assess --type execute -vv build/release/<version>/export/Suijin.app` prints
  `accepted` and `source=Notarized Developer ID`; `xcrun stapler validate` passes for the app and the DMG.
- **Helper signature:** `codesign -dvvv Suijin.app/Contents/MacOS/SuijinPTYHost` shows
  `Authority=Developer ID Application: … (YWSHDN5Y3H)`, `flags=0x10000(runtime)` and a `Timestamp=` line.
- **Sparkle 0.1.0 → 0.1.1 with helper replacement** (once updates are on):
  1. Install 0.1.0 (build 1) from its DMG, start a shell session, quit Suijin with sessions kept, relaunch, and
     confirm the session re-attaches.
  2. End every session. Publish 0.1.1 (build 2) to the appcast, then Suijin → "Check for Updates…" and install.
  3. After the relaunch: Suijin → About shows 0.1.1 (2), and
     `log show --last 5m --predicate 'subsystem == "com.tekmium.suijin" AND category == "helper-version"'` shows
     `PTY host replaced: 0.1.0 (1) -> 0.1.1 (2)`. `ps -o lstart,command -p $(pgrep -f SuijinPTYHost)` shows a helper
     started after the update.
  4. Repeat with a session left running during the update: the session survives, the log says the helper stays until
     its sessions end, and after ending them and relaunching Suijin the new helper runs.
  5. Tamper test: an appcast item whose `sparkle:edSignature` does not match the DMG is refused by Sparkle.

## 7. Clean-machine checklist

On a new macOS user account (or a fresh Mac) that never ran a Suijin build:

- [ ] Download the DMG through a browser (so it is quarantined), open it: no Gatekeeper warning, the window shows
      Suijin.app and the Applications shortcut.
- [ ] Drag to Applications, launch: no "unidentified developer" or "damaged" dialog.
- [ ] Suijin appears in System Settings → General → Login Items as a background item; allow it if macOS asks.
- [ ] Add a git workspace and a plain folder, create a worktree, start Claude Code, Codex and a shell session.
- [ ] Quit with sessions kept, relaunch: the sessions re-attach with their scrollback.
- [ ] Settings → General → Updates says updates are not configured (until section 4 is done; then the automatic
      check toggle shows and "Check Now" works).
- [ ] `~/.claude`, `~/.claude.json` and `~/.codex` are unchanged by Suijin.
- [ ] Console has no code-signing or library-validation errors for Suijin, SuijinPTYHost or Sparkle.

## 8. Troubleshooting

| Symptom | Fix |
|---|---|
| `App/Info.plist has a SUFeedURL` | Updates are not set up yet; remove it, or finish section 4 first. |
| `notarytool could not submit` | The `suijin-notary` profile is missing or its app-specific password expired; run `store-credentials` again. |
| Notarization `Invalid` | The script prints Apple's log; usually a nested binary without Developer ID, hardened runtime or timestamp. |
| `helper is not signed with Developer ID` after re-signing | The identity in `SUIJIN_SIGNING_IDENTITY` is not the team's Developer ID Application certificate. |
| `xcodebuild` hangs resolving Sparkle | The Keychain waits for permission to use github.com credentials; allow it (the script passes `-packageAuthorizationProvider netrc`). |

Do not re-sign the app by hand with `codesign --deep`: it breaks the signatures of Sparkle's XPC services. Use
`--deep` only to verify.

## 9. Rollback

- **Bad release, few installs:** stop handing out its DMG; once updates are on, remove its item from `appcast.xml`
  (keep the DMG so whoever downloaded it can reinstall).
- **Already installed widely:** Sparkle does not downgrade. Ship a fix with a higher `CURRENT_PROJECT_VERSION` (it may
  be the previous good code with only the version bumped).
- **Sparkle private key leaked:** generate a new key, ship one release signed with the **old** key that carries the
  **new** `SUPublicEDKey`, sign every later release with the new key, and delete the old key everywhere.
- **Developer ID certificate or app-specific password leaked:** revoke it on developer.apple.com / appleid.apple.com,
  create a new one, run `store-credentials` again.
