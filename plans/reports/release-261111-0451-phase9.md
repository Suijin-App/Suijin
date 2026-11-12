# Phase 9 report: release pipeline

Status: DONE_WITH_CONCERNS. The pipeline is built and `scripts/release-notarize.sh --dry-run` succeeds end to end on
this Mac. No notarization, Sparkle key generation or upload was run.

## Files

| File | Change |
|---|---|
| `scripts/release-notarize.sh` | New (ported from Capstio). Archive, Developer ID export, nested helper signature check with inside-out re-sign fallback, `codesign --verify --deep --strict`, notarize and staple the app, DMG, notarize and staple the DMG, `spctl`, Sparkle `sign_update`, appcast entry. `--dry-run` really builds, signs, verifies and makes the DMG, then skips notarize, staple and `sign_update`. Real runs refuse a placeholder `SUPublicEDKey`. |
| `scripts/make-dmg.sh` | New. Stages the app with an Applications symlink, `hdiutil` UDZO, signs and verifies the DMG. It does not use `create-dmg` styling, because Mercury has no DMG background art and the Finder automation would prompt. |
| `docs/release-process.md` | New. Covers prerequisites (Developer ID, `mercury-notary` profile, `generate_keys --account mercury`), steps, hosting, the helper handover, the 0.1.0 → 0.1.1 verification, the clean-machine checklist, troubleshooting and rollback. |
| `App/Updates/UpdaterController.swift` | New. `UpdaterController.shared` wraps `SPUStandardUpdaterController(startingUpdater: false)`. `start()` only starts it when `SUPublicEDKey` is a real 32-byte key. |
| `App/Updates/UpdateCommands.swift` | New. `UpdateCommands` adds "Check for Updates…" after About. `UpdateSettingsSection` is a `Section` for a `Form`. |
| `App/Updates/HelperVersionCheck.swift` | New. `HelperVersionCheck.run()` is described below. |
| `App/Info.plist` | Added `SUFeedURL` (placeholder `https://mercury.tekmium.com/appcast.xml`), `SUPublicEDKey` (placeholder), `SUEnableAutomaticChecks`, `SUScheduledCheckInterval` 86400. |
| `project.yml` | Added the Sparkle package (`exactVersion: 2.10.1`, the newest 2.x tag; it builds) and linked it to the `Mercury` target only. |
| `AppTests/UpdatesTests.swift` | New. 5 tests covering the key gate, the shipped plist and host build parsing/staleness. |

## How `HelperVersionCheck` works

1. It runs a handshake and parses the host build: `"0.1.0 (12)"` gives `12`, and `dev` gives none.
2. It compares that build with the app's `CFBundleVersion`.
3. If they differ and no session is running, it calls `shutdownHostIfIdle()`. It then polls the handshake (20 × 250 ms) until the helper launchd starts from the new bundle answers. The result is `.replaced`, or `.pending` if no new helper answers in time.
4. If any session is running, it does nothing and returns `.deferred`, so a running session is never killed.
5. A failed handshake gives `.unavailable`.

## Hooks for the controller to apply (files I do not own)

In `App/MercuryApp.swift`:

```swift
.commands { MercuryCommands(model: model); UpdateCommands() }
```

In the main window's `.task`, after `await model.runtimes.bootstrap()`:

```swift
await HelperVersionCheck.run()
UpdaterController.shared.start()
```

In `App/Features/Settings/SettingsView.swift` `GeneralSettings`, inside the `Form`:

```swift
UpdateSettingsSection()
```

## Verification

- `scripts/bootstrap.sh` and the dev `xcodebuild … build` passed (exit 0) with no Swift warnings outside `SourcePackages`. I passed the extra `-packageAuthorizationProvider netrc` flag; without it SwiftPM blocks on a Keychain prompt for github.com, which is what hung the controller's build.
- `xcodebuild test -only-testing:MercuryAppTests/UpdatesTests`: 5 of 5 passed.
- `Tools/comment-lint/comment-lint.py`: all comments are in English.
- `scripts/release-notarize.sh --dry-run`: exit 0, 12 steps.
  - The signing identity is `Developer ID Application: Thang Tran (YWSHDN5Y3H)`, which is installed, so the Apple Development fallback was not needed. The fallback is implemented but untested.
  - Helper: `Identifier=com.tekmium.mercury.ptyhost`, `flags=0x10000(runtime)`, Developer ID authority, `Timestamp=` present. The export signed it correctly, so the re-sign branch did not run.
  - The app passes `--deep --strict`, has Developer ID, runtime and a timestamp, and has no `get-task-allow`. The LaunchAgent plist and Sparkle.framework are present.
  - The DMG (11.3 MB) is signed and verifies.
  - `spctl` reports `rejected, source=Unnotarized Developer ID`, which is expected before notarization.
  - Blockers listed for a real run: only the placeholder `SUPublicEDKey`.
  - Output is in `build/release/0.1.0/`.

## Concerns

- During the first dry-run attempt the build failed in the controller's in-flight `App/Features/Terminal/SessionActions.swift` (missing `UUID`). A later build failed in `Packages/MercuryAccounts/.../ClaudeProfileProvisioner.swift:112` (exclusivity violation). Both were fixed upstream by others; the retry built clean. I did not touch those files.
- Command-line builds do not sync strings into `Localizable.xcstrings`, and it is still empty. The new UI strings appear there on the next Xcode IDE build, the same as the existing strings.
- When "Keep sessions running after quitting" is off, a Sparkle relaunch ends sessions, the same as a normal quit. This is documented, and Mercury does not postpone the relaunch.

## Unresolved questions (for the user)

1. Confirm the feed host `https://mercury.tekmium.com/appcast.xml` and the download base before the first public build.
2. Approve the outward actions:
   - generating the Sparkle key (`generate_keys --account mercury`) and pasting the public key into `App/Info.plist`;
   - creating the `mercury-notary` profile;
   - the first real notarization of 0.1.0;
   - the clean-machine test and the 0.1.0 → 0.1.1 update test.
