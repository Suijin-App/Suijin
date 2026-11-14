# Release notes

The notes are read on the GitHub release page and linked from the update window of the app. Write them for someone
who uses Suijin and has not read the code.

## Structure

```markdown
One or two sentences: what this release is about.

## New

- **Name of the feature.** What you can do now, in a sentence or two. Where to find it.

  ![What the image shows](https://raw.githubusercontent.com/Suijin-App/Suijin/v<version>/docs/releases/<version>/<name>.png)

## Changed

- What behaves differently, and what to do about it if anything.

## Fixed

- What went wrong before, in the user's terms, and that it no longer does.

## Updating

How this version reaches people: the in-app updater, or the DMG for a first install. Anything they must do once
(for example granting a permission again).

## Requirements

macOS version, and what must be installed (Claude Code and/or Codex).
```

Leave out a section that would be empty. Order entries by how many people they affect.

## Wording

- Say what the user sees and can do, not what the code does: "Closing a busy tab stops asking once you tick Don't ask again", not "persist the suppression flag".
- One change per bullet. Lead with the feature's name in bold for New; plain sentences for Changed and Fixed.
- Name the place: the menu, the Settings page, the shortcut.
- State limits plainly when a feature has them ("Full Disk Access is optional").
- No internal identifiers, ticket numbers, file names or pull request numbers.
- The first release has no "since last version": describe what Suijin does, grouped as in the README, and keep
  Fixed out unless something was fixed since a build people already had.

## Sources and checks

- Every bullet must trace to an entry in `CHANGELOG.md` for this version; the changelog is the complete list, the
  notes are the readable version of it.
- Do not promise what was not verified. If a path is unproven (for example the first in-app update), do not
  describe it as working; describe what the user should expect.
- Image links use the tag (`v<version>`) so they keep working when files move later. The tag is created by
  `gh release create`, so the images must be on `main` in the release commit before publishing; until then preview
  the notes with the local files.
- Read the finished notes once as a user would, then check every claim against the changelog.
