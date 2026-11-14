# Screenshots for release notes

Real windows of the real app, with the app in front so the glass effects render as in use, then red hand-written
notes drawn on top. Nothing here changes the owner's own Suijin or its data: captures run in a separate copy of the
app on a throwaway data folder.

## Privacy rules (the repository is public)

Before using any image, look at it at full size and make sure none of these is readable:

- an email address, anywhere: session titles ("Claude · name@…"), the sidebar, the Accounts page, the usage popover;
- the Mac's host name or user name in a shell prompt or a banner the shell prints at start;
- usage figures of the owner's accounts when the release note is not about them; the Stats & Usage page reads the
  owner's real logs and is off limits unless the owner agrees;
- tokens, API keys, private repository or folder names.

Prefer avoiding the problem (neutral demo data, a settings page that shows nothing personal) over covering it. When a
detail cannot be avoided, cover it with an opaque rectangle (`covers` in the annotation spec), never a blur, and
check the result.

## 1. Build and pick a data folder

Build the app once (`./scripts/ci-local.sh app`, or any `xcodebuild` of the scheme); the capture script uses the
newest Debug build in DerivedData. Use a data folder outside the repository, with a short neutral path, because
shell prompts print it: for example `~/suijin-demo/data`. Remove the folder when done.

Demo content (a git workspace with worktrees and running shell sessions) comes from the seed test:

```sh
TEST_RUNNER_SUIJIN_SEED_ROOT=$HOME/suijin-demo xcodebuild -project Suijin.xcodeproj -scheme Suijin \
  -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -allowProvisioningUpdates \
  test -only-testing:SuijinAppTests/DemoSeedTests
```

It starts real `claude` and `codex` sessions with the owner's own login, whose titles carry the owner's email. For
images, give those sessions neutral titles in the seeded database before launching (the app is not running then):

```sh
sqlite3 ~/suijin-demo/data/suijin.sqlite "update agent_session set title = 'Claude · demo' where title like '%@%'"
```

A scene the seed does not build (a split of four agents, an orchestration run, a new feature's state) needs a
temporary change to `AppTests/DemoSeedTests.swift` or a temporary launch option in the app. That is acceptable for
capturing, with two conditions: revert it with `git checkout` before anything is committed, and say in the report
that the scene was staged.

## 2. Capture

```sh
.claude/skills/suijin-release-macos/scripts/capture-window.sh --data-root ~/suijin-demo/data \
  --out /tmp/shots/<name>.png -- <launch options>
```

The script launches a separate copy in front at 1480×850, captures its main window and quits it. Launch options the
app understands (Debug builds):

| Option | Opens |
|---|---|
| `-SuijinInitialSettings <page>` | Settings at `general`, `agents`, `accounts`, `terminal`, `stats`, `shortcuts` or `about` |
| `-SuijinInitialTab changes` | the Changes tab of the selected worktree |
| `-SuijinOpenFile <absolute path>` | that file in a viewer tab (Markdown, code, image, video, audio) |
| `-SuijinDemoPanes <n>` | a split tab of n shell panes in the selected context |
| `-SuijinOnboarding <step>` | the welcome tour at that step |
| `-inspector.shown YES -inspector.tab info` | the inspector on its info tab (`files` for the file list) |

Any `-Suijin…` option also keeps the welcome tour closed; pass `-SuijinInitialTab none` for a plain main window.
Dark appearance is a stored setting, not a launch option:
`sqlite3 <data>/suijin.sqlite "insert or replace into setting(key,value) values('ui.appearance','dark')"`.

Menus, popovers and anything that needs a click cannot be opened this way. Either stage the state with a temporary
launch option (as above) or leave the image out.

## 3. Annotate

```sh
.claude/skills/suijin-release-macos/scripts/annotate-screenshot.py /tmp/shots/<name>.png \
  docs/releases/<version>/<name>.png /tmp/shots/<name>.json
```

The spec format is in the script's header: `notes` (red hand-written text), `arrows` (SVG paths ending in an
arrowhead; `"dashed": true` for a movement), `covers` (opaque rectangles over private details). Coordinates are
pixels of the 2200-wide output.

What makes a note useful:

- One to three notes per image; each names what is new, in a few words a user would say.
- Put text on empty areas (the bottom of the sidebar, blank terminal space), not over the thing it points at.
- An arrow goes from the note to the exact control; curve it around content instead of through it.
- After rendering, view the image: no note clipped at an edge, no arrow hiding the detail it points to, covers
  fully opaque.

## 4. Clean up

- End the demo sessions the terminal host still runs: they are the host's child processes whose working directory
  is under the demo folder. Stop only those; the owner's own sessions share the same host.
- Remove the demo folder and the temporary captures.
- `git status` must show no leftover change in `App/` or `AppTests/`.
