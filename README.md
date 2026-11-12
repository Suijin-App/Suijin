# Mercury

A native macOS app that runs Claude Code and Codex agents side by side, each in its own git worktree (or straight in a
plain folder), with multiple managed accounts per provider and a native diff viewer.

## Requirements

- macOS 15 or later (Liquid Glass on macOS 26+), Xcode 27, `xcodegen` (`brew install xcodegen`).
- The Metal Toolchain for SwiftTerm's renderer: `xcodebuild -downloadComponent metalToolchain`.

## Build

```sh
scripts/bootstrap.sh            # generate Mercury.xcodeproj from project.yml
scripts/ci-local.sh             # package tests + app build and tests
open Mercury.xcodeproj
```

The first time you build in Xcode, it stops with "Plugin “SwiftTermBuildInfoPlugin” from package “SwiftTerm” must be
enabled". Click the error and choose **Trust & Enable**. SwiftTerm ships this build-tool plugin, and Xcode asks once per
machine and again after a SwiftTerm upgrade. Command-line builds skip the prompt with `-skipPackagePluginValidation`.

See `CLAUDE.md` for repository rules, `docs/architecture.md` for the package layout and `docs/release-process.md`
for signing, notarization and Sparkle updates.
