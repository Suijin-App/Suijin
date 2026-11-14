---
name: suijin-release-macos
description: "Release the Suijin macOS app from this repository: check the last released version, bump the version, write release notes with annotated screenshots, build, sign, notarize, publish the GitHub release and verify the update feed. Use when asked to release, ship, publish or cut a version of Suijin, or to prepare its release notes. Not for building or testing the app during development, nor for changing how releases work (edit ./scripts/release-notarize.sh and docs/release-process.md instead)."
metadata:
  version: 1.0.0
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
- The notes and images from stages 4 and 5.

Commit as `chore: release <version>`, open a pull request, and merge it once the owner agrees. The release is built
from the merged commit on `main`, never from the branch.

### 6. Prove the code

```sh
./scripts/bootstrap.sh && ./scripts/ci-local.sh
```

It must be green. Two suites are sensitive to machine load (`MediaViewerTests`, `FileWatchingTests`): if only they
fail, close other heavy work, run `./scripts/ci-local.sh app` once more, and report both results. A second failure,
or any other failure, stops the release.

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

It checks Gatekeeper and the stapled tickets, the version and feed inside the DMG, and that the appcast names this
version, this build, the right download URL, the DMG's exact size and a signature. Every line must be `PASS`.

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
- If an older version is installed somewhere, choose Suijin › Check for Updates… there and confirm it offers and
  installs this version and that running sessions survive (section 5 of `docs/release-process.md`). For the first
  release there is nothing to update from; say that the update path stays unproven until the second release.

### 11. If something is wrong after publishing

A broken release reaches users through the feed, so act quickly and tell the owner first. With their go-ahead,
`gh release delete v<version> --repo Suijin-App/Suijin --cleanup-tag --yes` makes the previous release the latest
again; copies that already updated keep the broken version until a fixed one with a higher build number ships.
Never reuse a version or build number that was published.

## Report

End with: the version and build released, the release URL, what each verification stage showed (with the failing
output if any), which hands-on checks the owner did or skipped, which features have no screenshot and why, and
anything still unproven.

## Resources

- `scripts/check-release-inputs.sh`: stage 1 and 7; read-only checks of the repository, the version, the Keychain
  items' presence and the feed.
- `scripts/verify-release-artifacts.sh`: stage 8; checks the built app, DMG and appcast.
- `scripts/verify-published-release.sh`: stage 10; checks the feed and the download against what was built.
- `scripts/capture-window.sh` and `scripts/annotate-screenshot.py`: stage 4; see `references/screenshots.md`.
- `references/screenshots.md`: open for stage 4.
- `references/release-notes.md`: open for stage 5.
- `docs/release-process.md` (in the repository): how the pipeline, the keys, the feed and the helper handover work.
