# Release process

How Mercury ships outside the Mac App Store: Developer ID signing, notarization, a DMG, and in-app updates through
Sparkle 2. Every command runs from the repository root on the release Mac.

Never put in the repository: certificates (`.p12`, `.cer`), app-specific passwords, the Sparkle private key, App
Store Connect API keys. They all live in the release Mac's login Keychain.

## 1. Pieces

| Piece | Where |
|---|---|
| Sparkle 2 | Swift package in `project.yml`, pinned with `exactVersion`, linked to the `Mercury` target only. Its `sign_update` and `generate_keys` tools come with the package artifact (`<DerivedData>/SourcePackages/artifacts/sparkle/Sparkle/bin`). |
| In-app updater | `App/Updates/UpdaterController.swift` wraps `SPUStandardUpdaterController`. `UpdateCommands` adds Mercury → "Check for Updates…"; `UpdateSettingsSection` is the Updates section of Settings → General. |
| Helper handover | `App/Updates/HelperVersionCheck.swift` (section 5). |
| Sparkle keys in `App/Info.plist` | `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks` (on), `SUScheduledCheckInterval` (86400, daily). |
| Scripts | `scripts/release-notarize.sh` (the whole pipeline, with `--dry-run`), `scripts/make-dmg.sh` (DMG and its signature). |

The feed URL `https://mercury.tekmium.com/appcast.xml` and the download base `https://mercury.tekmium.com/downloads`
are **placeholders to be confirmed** before the first public build. Changing `SUFeedURL` after a release strands every
installed copy, so settle it first (the script checks that `App/Info.plist` and the script agree).

## 2. One-time setup (Tekmium account owner)

1. **Developer ID Application certificate** of team `YWSHDN5Y3H` in the login Keychain. Check (lists names only):
   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
   Xcode → Settings → Accounts must be signed in to an account of the team so `-allowProvisioningUpdates` can export.
   Mercury uses no restricted entitlement, so no Developer ID provisioning profile is needed.
2. **notarytool keychain profile**, created by the owner (the password never goes through a script or a file):
   ```sh
   xcrun notarytool store-credentials mercury-notary --apple-id <apple-id> --team-id YWSHDN5Y3H
   ```
   It asks for an app-specific password (appleid.apple.com). Another profile name works with
   `MERCURY_NOTARY_PROFILE=<name>`. The release script does not look the profile up in a dry run, because that
   contacts Apple; the first real run is the check.
3. **Sparkle EdDSA key**, generated once by the owner for every Mercury release, under its own Keychain account so it
   never mixes with another app's key (Capstio uses the default account):
   ```sh
   <DerivedData>/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account mercury
   ```
   The private key is stored in the login Keychain; the command prints the public key. Paste it over the placeholder
   `REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY` of `SUPublicEDKey` in `App/Info.plist` and commit (the public key is not a
   secret). Print it again any time with `generate_keys --account mercury -p`.
   - Back the private key up outside the repository (`generate_keys --account mercury -x <file>`, store it in the
     company secret vault, delete the file). Losing it means installed copies can no longer be updated.
   - Another release Mac imports it with `generate_keys --account mercury -f <file>`.

While `SUPublicEDKey` is the placeholder the app never starts the updater (Settings → General → Updates says the build
has no update signing key) and `scripts/release-notarize.sh` refuses to ship.

## 3. Releasing

1. Bump the version in `project.yml`: `MARKETING_VERSION` (for example `0.1.1`) and `CURRENT_PROJECT_VERSION` (an
   integer that always grows; Sparkle compares it, and the helper handover in section 5 compares it too).
2. `scripts/ci-local.sh` must be green.
3. Dry run:
   ```sh
   scripts/release-notarize.sh --dry-run
   ```
   It archives, exports, signs, verifies and builds the DMG for real under `build/release/<version>/`, skips
   notarization, stapling and the Sparkle signature, and lists at the end what would stop a real run (for example the
   placeholder Sparkle key). Without a Developer ID certificate it signs with Apple Development and warns; such a build
   is for checking the pipeline only.
4. Real run:
   ```sh
   scripts/release-notarize.sh
   ```
   Steps:
   1. Check the tools, `SUPublicEDKey` (refuses the placeholder), `SUFeedURL`, and the team's Developer ID identity.
   2. `xcodegen generate`, `xcodebuild archive` of the Release configuration with hardened runtime
      (`-skipPackagePluginValidation -allowProvisioningUpdates`).
   3. Export with `method developer-id`.
   4. Check the nested helper `Contents/MacOS/MercuryPTYHost` with `codesign -dvvv`: identifier
      `com.tekmium.mercury.ptyhost`, Developer ID authority of the team, `runtime` flag, a secure timestamp. If the
      export left any of that out, re-sign inside out (helper, then the app with its own entitlements); Sparkle's
      nested code keeps the export's signature.
   5. `codesign --verify --deep --strict`, Developer ID, team, hardened runtime, timestamp, no `get-task-allow`,
      LaunchAgent plist and Sparkle.framework present, version and build match `project.yml`, real `SUPublicEDKey`.
   6. Notarize the app (`xcrun notarytool submit --keychain-profile mercury-notary --wait`) and staple it, so the app
      inside the DMG and inside Sparkle updates carries its ticket. A rejection prints Apple's log.
   7. Build and sign the DMG (`scripts/make-dmg.sh`: the app plus an Applications shortcut, UDZO).
   8. Notarize and staple the DMG.
   9. Gatekeeper: `spctl --assess --type execute -vv Mercury.app` must say `accepted`, `source=Notarized Developer
      ID`; the DMG is checked with `spctl --assess --type open --context context:primary-signature -vv`.
   10. Sign the DMG for Sparkle with `sign_update --account mercury` (private key from the Keychain).
   11. Write the appcast entry to `build/release/<version>/appcast-item.xml`.

   Nothing is uploaded. Output stays in `build/release/<version>/` (ignored by git).
5. Write the release notes page `release-notes/<version>.html` (Sparkle's update dialog shows it).
6. Publish (section 4), then run the checks in section 6.

Optional environment (none holds a secret): `MERCURY_NOTARY_PROFILE`, `MERCURY_TEAM_ID`, `MERCURY_SIGNING_IDENTITY`,
`MERCURY_RELEASE_DIR`, `MERCURY_DOWNLOAD_BASE_URL`, `MERCURY_SPARKLE_ACCOUNT`, `SPARKLE_BIN`. See the header of
`scripts/release-notarize.sh`.

## 4. Hosting the appcast and downloads

- Static HTTPS hosting by Tekmium (host to be confirmed):
  - `https://mercury.tekmium.com/appcast.xml`: the appcast, exactly the `SUFeedURL` built into the app.
  - `https://mercury.tekmium.com/downloads/Mercury-<version>.dmg`: the DMG.
  - `https://mercury.tekmium.com/downloads/release-notes/<version>.html`: release notes.
- First appcast:
  ```xml
  <?xml version="1.0" encoding="utf-8"?>
  <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
      <title>Mercury</title>
    </channel>
  </rss>
  ```
  For every release insert `appcast-item.xml` at the top of `<channel>` and keep the older items.
- Upload the DMG first and the appcast second; an appcast that points at a missing file makes the app report a
  download error.
- After publishing: `curl -I` on the DMG returns 200 and the `length` given in the appcast.

## 5. Updates and the PTY host helper

- Sparkle checks daily; the user turns that off in Settings → General → Updates, or checks by hand from Mercury →
  "Check for Updates…" or the "Check Now" button. The download must carry a valid EdDSA signature for the key in
  `SUPublicEDKey`, or Sparkle refuses it.
- Installing an update quits Mercury the normal way, so running sessions stay in the PTY host helper when "Keep
  sessions running after quitting Mercury" is on (the default); with it off, quitting ends them as usual.
- **Helper handover.** Sparkle replaces the whole bundle, including `Contents/MacOS/MercuryPTYHost`, but the helper
  process launchd started from the old bundle keeps running. At launch, after the sessions bootstrap, the app runs
  `HelperVersionCheck`: it asks the helper for its build through the `PTYHostClient` handshake (`"0.1.0 (1)"`) and
  compares the build number with its own `CFBundleVersion`.
  - Same build, or a development helper reporting `dev`: nothing to do.
  - Different build and no session running: the app calls `shutdownHostIfIdle()`, the old helper exits, and launchd
    starts the new binary from the updated bundle on the next connection. The check waits until the new helper
    answers (up to about 5 s).
  - Different build with sessions running: the old helper is left alone, so no session is ever killed by an update.
    It exits by itself once its sessions end and Mercury disconnects; the next launch gets the new helper. The XPC
    protocol version guards compatibility in between (a protocol mismatch makes the client ask the helper to exit
    when idle and report the mismatch).
  - The launchd registration (`SMAppService.agent`) points at a path inside the bundle, so it survives the update and
    needs no re-registration.

## 6. Verification

- **Gatekeeper:** `spctl --assess --type execute -vv build/release/<version>/export/Mercury.app` prints
  `accepted` and `source=Notarized Developer ID`; `xcrun stapler validate` passes for the app and the DMG.
- **Helper signature:** `codesign -dvvv Mercury.app/Contents/MacOS/MercuryPTYHost` shows
  `Authority=Developer ID Application: … (YWSHDN5Y3H)`, `flags=0x10000(runtime)` and a `Timestamp=` line.
- **Sparkle 0.1.0 → 0.1.1 with helper replacement:**
  1. Install 0.1.0 (build 1) from its DMG, start a shell session, quit Mercury with sessions kept, relaunch, and
     confirm the session re-attaches.
  2. End every session. Publish 0.1.1 (build 2) to the appcast, then Mercury → "Check for Updates…" and install.
  3. After the relaunch: Mercury → About shows 0.1.1 (2), and
     `log show --last 5m --predicate 'subsystem == "com.tekmium.mercury" AND category == "helper-version"'` shows
     `PTY host replaced: 0.1.0 (1) -> 0.1.1 (2)`. `ps -o lstart,command -p $(pgrep -f MercuryPTYHost)` shows a helper
     started after the update.
  4. Repeat with a session left running during the update: the session survives, the log says the helper stays until
     its sessions end, and after ending them and relaunching Mercury the new helper runs.
  5. Tamper test: an appcast item whose `sparkle:edSignature` does not match the DMG is refused by Sparkle.

## 7. Clean-machine checklist

On a new macOS user account (or a fresh Mac) that never ran a Mercury build:

- [ ] Download the DMG through a browser (so it is quarantined), open it: no Gatekeeper warning, the window shows
      Mercury.app and the Applications shortcut.
- [ ] Drag to Applications, launch: no "unidentified developer" or "damaged" dialog.
- [ ] Mercury appears in System Settings → General → Login Items as a background item; allow it if macOS asks.
- [ ] Add a git workspace and a plain folder, create a worktree, start Claude Code, Codex and a shell session.
- [ ] Quit with sessions kept, relaunch: the sessions re-attach with their scrollback.
- [ ] Settings → General → Updates shows the automatic check toggle and "Check Now" works (no update, or the update
      dialog when a newer item is published).
- [ ] `~/.claude`, `~/.claude.json` and `~/.codex` are unchanged by Mercury.
- [ ] Console has no code-signing or library-validation errors for Mercury, MercuryPTYHost or Sparkle.

## 8. Troubleshooting

| Symptom | Fix |
|---|---|
| `SUPublicEDKey ... placeholder` | Do section 2.3 and paste the public key into `App/Info.plist`. |
| `notarytool could not submit` | The `mercury-notary` profile is missing or its app-specific password expired; run `store-credentials` again. |
| Notarization `Invalid` | The script prints Apple's log; usually a nested binary without Developer ID, hardened runtime or timestamp. |
| `helper is not signed with Developer ID` after re-signing | The identity in `MERCURY_SIGNING_IDENTITY` is not the team's Developer ID Application certificate. |
| `sign_update could not sign` | No Sparkle key for account `mercury` in this Keychain; import it with `generate_keys --account mercury -f <file>`. |
| `xcodebuild` hangs resolving Sparkle | The Keychain waits for permission to use github.com credentials; allow it (the script passes `-packageAuthorizationProvider netrc`). |

Do not re-sign the app by hand with `codesign --deep`: it breaks the signatures of Sparkle's XPC services. Use
`--deep` only to verify.

## 9. Rollback

- **Bad release, few installs:** remove its item from `appcast.xml` (keep the DMG so whoever downloaded it can
  reinstall). Copies that did not update no longer see it.
- **Already installed widely:** Sparkle does not downgrade. Ship a fix with a higher `CURRENT_PROJECT_VERSION` (it may
  be the previous good code with only the version bumped).
- **Sparkle private key leaked:** generate a new key, ship one release signed with the **old** key that carries the
  **new** `SUPublicEDKey`, sign every later release with the new key, and delete the old key everywhere.
- **Developer ID certificate or app-specific password leaked:** revoke it on developer.apple.com / appleid.apple.com,
  create a new one, run `store-credentials` again.
