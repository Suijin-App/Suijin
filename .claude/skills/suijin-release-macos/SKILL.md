---
name: suijin-release-macos
description: "Release the Suijin macOS app from this repository: check the last released version, bump the version, write release notes with annotated screenshots, build, sign, notarize, publish the GitHub release, verify the update feed and announce the release on Discord. Use when asked to release, ship, publish or cut a version of Suijin, or to prepare its release notes. Not for building or testing the app during development, nor for changing how releases work (edit ./scripts/release-notarize.sh and docs/release-process.md instead)."
metadata:
  version: 1.3.0
---

# Suijin release (macOS)

Takes Suijin from a green `main` to a published GitHub release that installed copies update to, and proves each stage
before the next one starts. The reader of the result is the app's owner; the readers of the release notes are
Suijin's users. `docs/release-process.md` is the authority on how the pipeline works; this skill is the order of
work and the checks around it.

A release is hard to take back: every installed copy sees it within a day and installs it. So nothing is published
until every check before it passed, and the publish step itself waits for the owner's go-ahead.

## When to use

- "Release Suijin", "ship 0.1.1", "cut a new version", "publish the update", "write the release notes for the next version".
- Not for: day-to-day builds and tests (`./scripts/ci-local.sh`), changes to the release pipeline itself, or the
  website.

## Boundaries

- **Secrets.** The Developer ID certificate, the notary profile and the Sparkle private key live in the login
  Keychain. Never print, copy or export them, and never create them: if one is missing, stop and tell the owner the
  command from `docs/release-process.md` section 2.
- **Publishing.** `gh release create`, pushing a tag and deleting a release are outward-facing. Do them only after the
  owner confirmed in this conversation, with the version and the notes in front of them. A go-ahead for one release
  does not cover the next.
- **The Discord bot token** lives in TSSC (project Suijin, environment `prod`, secret `DISCORD_BOT_TOKEN`) and reaches
  the announcement script only through `tssc run`. Never print it, read it with `tssc secrets`, or write it to a file.
- **Announcing.** A message in `#releases` is outward-facing too, and it is covered by the owner's go-ahead for
  publishing that same release: once stage 10 passed, announce without asking again. Never announce a release that
  is not published or that failed stage 10.
- **The feed address** `https://suijin.app/appcast.xml` and the bundle identifier never change in a release.
- **Privacy in images.** Screenshots go into a public repository. No real email address, account name, host name,
  token or usage figure of the owner may be readable in them.
- A failed check is a stop, not a warning. Report it with its output; do not retry around it or weaken it.

## How to work

Run every command from the repository root. Each numbered stage ends with a check; go on only when it passed.

### 1. Check the inputs

```sh
.claude/skills/suijin-release-macos/scripts/check-release-inputs.sh
```

It verifies, without changing anything: `main` is clean and matches `origin/main`; the version in `project.yml`
against the last GitHub release (see stage 2); the tag is free; the changelog has a section; the Developer ID
identity, the notary profile, the feed address, a real `SUPublicEDKey`, and that `suijin.app/appcast.xml` redirects
to the latest release's appcast. Every `FAIL` must be resolved before stage 4. `WARN` lines are decisions for the
owner (open pull requests, an undated changelog).

### 2. Settle the version

- The last release is `gh release list --repo Suijin-App/Suijin --exclude-drafts --exclude-pre-releases --limit 1`.
  With none, this is the first release and `project.yml` already names it.
- `MARKETING_VERSION` must be higher than the last release: a fix-only release raises the last number, new features
  raise the middle one. Ask the owner when the choice is not obvious from the changes.
- `CURRENT_PROJECT_VERSION` is an integer that must grow with every release. Sparkle and the helper handover
  compare it, so a release whose build number did not grow is never offered to installed copies.

### 3. Collect what changed

Gather the facts first, then write.

```sh
git log --oneline --no-merges <last tag>..HEAD      # first release: the whole history
gh pr list --repo Suijin-App/Suijin --state merged --search "merged:>=<date of the last release>" --json number,title
```

Read the top section of `CHANGELOG.md` and compare it with those lists. Every change a user can notice must be in
the changelog, in the words of what the user sees; add what is missing and remove what never shipped. Internal work
(refactors, tests, docs, build scripts) stays out. If a commit's effect is unclear, read its diff instead of guessing.

### 4. Screenshots of what is new (when it can be shown)

For each new or visibly changed feature, capture the real app and draw red hand-written notes on it, as the README
images do. Follow `references/screenshots.md`: it has the capture and annotation commands, the launch options that
open a given screen, and the privacy rules. Look at every image before using it. Save them as
`docs/releases/<version>/<name>.png`.

Skip an image when the feature cannot be shown honestly without a click you cannot make or without private data;
say so in the report instead of faking the screen.

### 5. Release notes and the release commit

Write `docs/releases/<version>/release-notes.md` from `references/release-notes.md` (structure, wording and how
images are linked). Then, on a branch `release/<version>`:

- `project.yml`: the version and build from stage 2.
- `CHANGELOG.md`: the section heading becomes `## <version> (<YYYY-MM-DD>)`; start a new `## <next> (unreleased)`
  section only if work for it already exists.
- `README.md`: the Status section names the released version and links to the latest release.
- `website/src/site.ts`: `releasedVersion` becomes the new version, which switches the site to its download
  wording.
- The notes and images from stages 4 and 5.

Commit as `chore: release <version>`, open a pull request, and merge it once the owner agrees. The release is built
from the merged commit on `main`, never from the branch.

### 6. Prove the code

```sh
./scripts/bootstrap.sh && ./scripts/ci-local.sh
```

It must be green. Run nothing else heavy on the Mac meanwhile (no other build, no site build, no browser captures):
four suites assert timings and fail under load (`MediaViewerTests`, `FileWatchingTests`, `TerminalCatchUpTests`,
`TerminalFeedSchedulerTests`). If only they fail, stop the other work, run `./scripts/ci-local.sh` once more, and
report both results. A second failure, or any other failure, stops the release.

A green last line is not enough for the app tests. When the app under test stops, the test tool starts it again and
runs only what was left, and the summary then counts those few tests as passed. Compare the number of app tests
with the previous run (it only grows), and check that no new report for Suijin appeared in
`~/Library/Logs/DiagnosticReports` during the run; a new report is a crash to fix, not a flaky test.

Then ask the owner whether the hands-on checks were done on this build: a terminal opens (the helper is registered),
a pane can be dragged, an orchestration run finishes, a notification arrives, and the items in section 7 of
`docs/release-process.md`. Tests cannot see these. If the owner skips them, record that in the report.

### 7. Build, sign, notarize

```sh
.claude/skills/suijin-release-macos/scripts/check-release-inputs.sh    # again: the merge changed main
./scripts/release-notarize.sh --dry-run                                  # must end with "Nothing found that blocks a real run"
./scripts/release-notarize.sh                                            # the real run; sends the app and the DMG to Apple
```

The real run takes several minutes (two notarizations). It publishes nothing. If it stops, read the step it names
and section 8 of `docs/release-process.md`; do not edit the script to get past a check.

### 8. Verify what was built

```sh
.claude/skills/suijin-release-macos/scripts/verify-release-artifacts.sh
```

It checks Gatekeeper and the stapled tickets, the version and feed inside the DMG, that the DMG opens as the
installer window, and that the appcast names this version, this build, the right download URL, the DMG's exact size
and a signature. Every line must be `PASS`.

Then look at what was built and use it; the scripts cannot see either:

- **Look at the DMG.** Mount `build/release/<version>/Suijin-<version>.dmg`, open its window, capture it and view the
  image: the background picture, the app and the Applications shortcut in their places, and Suijin's icon in the
  title and path bar. The window that flashes while the image is being made is a draft with a generic icon, not the
  result; judge only the finished image. Unmount it afterwards.
- **Use the release build.** Install the built app from that DMG to `/Applications` on this Mac (ask the owner
  first: it replaces their copy) and, with the owner, open a shell tab and an agent tab, quit and reopen, and
  confirm the sessions are still there. A Debug build run from Xcode shares the bundle identifier and the terminal
  host's registration with the release build, so a Mac that ran Debug builds can hide or cause problems; say in the
  report which builds ran on the Mac before this check.
- **Accounts, with the owner's real accounts.** With at least two managed accounts of one provider: Settings ›
  Accounts lists them and marks the default; a session started on one account answers; **Continue With Another
  Account** moves it to the other in the same tab and the agent still knows the conversation; changing the default
  with "Move running sessions when the default account changes" on moves a running session and leaves a note in its
  pane. Switching at a usage limit cannot be forced on demand: say that it rests on the automated tests unless a
  limit was really reached. A provider with fewer than two managed accounts is reported as not checked.

### 9. Publish (after the owner's go-ahead)

Show the owner: the version, the notes file, the list of images, and the results of stages 6 and 8. When they
confirm:

```sh
gh release create v<version> build/release/<version>/Suijin-<version>.dmg build/release/<version>/appcast.xml \
  --repo Suijin-App/Suijin --target "$(git rev-parse HEAD)" --title "Suijin <version>" \
  --notes-file docs/releases/<version>/release-notes.md
```

The DMG is listed first so it is uploaded before the appcast that points at it. Never pass `--draft` or
`--prerelease`: the feed follows `releases/latest`, which ignores both.

### 10. Verify what users get

```sh
.claude/skills/suijin-release-macos/scripts/verify-published-release.sh
```

It follows the feed as an installed copy does and checks that the appcast and the download are byte for byte what
was built, and that Gatekeeper accepts the download. Then:

- Open the release page and look at the rendered notes: every image loads.
- Deploy the website so it names the new version: with Node 24, in `website/`,
  `tssc run --projectId=8f31fe47-25cc-44ac-bf3b-6020f39c7688 --env=prod -- npm run deploy` (TSSC supplies
  `CLOUDFLARE_ACCOUNT_ID`; see `docs/release-process.md`, section 4), then confirm `curl -sI https://suijin.app/appcast.xml` still answers with the redirect and run this
  stage's script again.
- **Prove the update, when a version was released before.** On a Mac with the previous release installed and a
  session running, choose Suijin › Check for Updates…. Confirm, with the owner clicking: the window shows this
  version and its notes (not only a link); the update installs and the app comes back; a new shell tab opens, which
  proves the terminal host answers after the update; the session from before is still there or can be resumed
  (section 5 of `docs/release-process.md`). If any of these fails, go to stage 12 before anything is announced. For
  the first release there is nothing to update from; say that the update path stays unproven until the second.

### 11. Announce on Discord

Only after every line of stage 10 passed, the update check included:

```sh
tssc run --projectId=8f31fe47-25cc-44ac-bf3b-6020f39c7688 --env=prod -- \
  .claude/skills/suijin-release-macos/scripts/announce-release-discord.py
```

It posts the opening paragraph of the release notes and the link to the release page in `#releases` of the Suijin
Discord server, as Suijin Bot. It stops when the release is not the latest published one, and it does not post a
version twice. Add `--dry-run` (no `tssc run` needed) to read the message first. If `tssc` reports an expired
session, ask the owner to run `tssc login`; do not ask for the token.

### 12. If something is wrong after publishing

A broken release reaches users through the feed, so act quickly and tell the owner first. With their go-ahead,
`gh release delete v<version> --repo Suijin-App/Suijin --cleanup-tag --yes` makes the previous release the latest
again; copies that already updated keep the broken version until a fixed one with a higher build number ships.
Never reuse a build number that was published, also when the owner has a withdrawn version released again under
the same version number: the new build must be higher than every withdrawn one, or a copy of a withdrawn build is
never offered it. Withdrawing also means: the website goes back to the unreleased wording (`releasedVersion` in
`website/src/site.ts`, then deploy), so its Download button does not point at a deleted file, and the announcement
in `#releases` is removed, with the owner's go-ahead.

Replacing a published file in place (a DMG that opens wrong, an appcast with better notes) is possible with
`gh release upload --clobber`, DMG first and then the appcast with the new length and signature; it needs the
owner's go-ahead, and stage 8 and stage 10 are run again afterwards.

## Report

End with: the version and build released, the release URL, what each verification stage showed (with the failing
output if any), whether the release was announced on Discord, which hands-on checks the owner did or skipped, which features have no screenshot and why, and
anything still unproven.

## Resources

- `scripts/check-release-inputs.sh`: stage 1 and 7; read-only checks of the repository, the version, the Keychain
  items' presence and the feed.
- `scripts/verify-release-artifacts.sh`: stage 8; checks the built app, DMG and appcast.
- `scripts/verify-published-release.sh`: stage 10; checks the feed and the download against what was built.
- `scripts/announce-release-discord.py`: stage 11; posts the release in `#releases` on Discord.
- `scripts/capture-window.sh` and `scripts/annotate-screenshot.py`: stage 4; see `references/screenshots.md`.
- `references/screenshots.md`: open for stage 4.
- `references/release-notes.md`: open for stage 5.
- `docs/release-process.md` (in the repository): how the pipeline, the keys, the feed and the helper handover work.
