# Contributing to Suijin

Thank you for helping. Every contribution follows the same four steps.

## 1. Open an issue first

Describe the bug or the change you propose in an [issue](https://github.com/Suijin-App/Suijin/issues) before writing
code, and wait for a maintainer to agree on the direction. A pull request without an issue is not reviewed.

## 2. Write the change

- Fork the repository and work on a branch of your own.
- Follow the repository rules in [`CLAUDE.md`](../CLAUDE.md); they apply to people and AI agents alike.
- Keep the change limited to what the issue describes.
- `scripts/ci-local.sh` must be green before you ask for a review.

## 3. Open a pull request for that issue

- Target `main`.
- Name the issue with a closing keyword in the description, for example `Closes #12`. The `linked-issue` check fails
  until the pull request closes an issue.
- Use a Conventional Commits title, for example `fix: keep the window layout when a session fails`.

## 4. Review and merge

The maintainer ([@vuvv-dev](https://github.com/vuvv-dev)) reviews every pull request, and only the maintainer merges.
A pull request is merged once it is approved and its checks pass.
