#!/usr/bin/env python3
"""Announces a published Suijin release in the #releases channel of the Suijin Discord server.

The message is the opening paragraph of the release notes and a link to the release page. Nothing is posted unless
the release is published on GitHub and is the latest one, and a version that was already announced is not announced
again, so the script is safe to run twice.

Usage:
  tssc run --projectId=8f31fe47-25cc-44ac-bf3b-6020f39c7688 --env=prod -- \\
    .claude/skills/suijin-release-macos/scripts/announce-release-discord.py [--dry-run] [repository root]

--dry-run prints the message and the checks without posting; it needs no token.

Environment:
  DISCORD_BOT_TOKEN           the Suijin Bot's token, injected by `tssc run`; never printed
  SUIJIN_GITHUB_REPOSITORY    the GitHub repository (default Suijin-App/Suijin)
  SUIJIN_DISCORD_CHANNEL      the channel to post in (default #releases)
"""
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

# The #releases channel of the "Suijin App Community" server. An identifier, not a secret.
RELEASES_CHANNEL = "1571185523383476396"
# Discord refuses a message longer than this.
MESSAGE_LIMIT = 2000


def fail(message):
    print(f"FAIL  {message}")
    sys.exit(1)


def setting(root, name):
    """A quoted or bare value from project.yml, as the other release scripts read it."""
    with open(os.path.join(root, "project.yml"), encoding="utf-8") as file:
        for line in file:
            match = re.match(rf'^\s*{name}:\s*"?([^"\n]*?)"?\s*$', line)
            if match:
                return match.group(1)
    fail(f"project.yml has no {name}")


def opening_paragraph(notes):
    """The text before the first heading, with image lines dropped and line breaks joined."""
    lines = []
    for line in notes.splitlines():
        if line.startswith("#"):
            break
        if not line.strip().startswith("!["):
            lines.append(line.strip())
    paragraphs = [" ".join(part.split()) for part in "\n".join(lines).split("\n\n")]
    return "\n\n".join(part for part in paragraphs if part)


def announcement(version, repository, notes):
    heading = f"# Suijin {version} is out"
    link = f"Release notes and download: https://github.com/{repository}/releases/tag/v{version}"
    summary = opening_paragraph(notes)
    room = MESSAGE_LIMIT - len(heading) - len(link) - 4
    if len(summary) > room:
        summary = summary[: room - 1].rstrip() + "…"
    return "\n\n".join(part for part in (heading, summary, link) if part)


def discord(method, path, token, body=None):
    request = urllib.request.Request(
        "https://discord.com/api/v10" + path,
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={
            "Authorization": "Bot " + token,
            "User-Agent": "DiscordBot (https://suijin.app, 1.0)",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        fail(f"Discord answered {error.code} for {method} {path}: {error.read().decode()[:200]}")
    except urllib.error.URLError as error:
        fail(f"Discord could not be reached: {error.reason}")


def gh(*arguments):
    result = subprocess.run(["gh", *arguments], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ""


def main():
    arguments = [argument for argument in sys.argv[1:] if argument != "--dry-run"]
    dry_run = "--dry-run" in sys.argv[1:]
    root = arguments[0] if arguments else (
        subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip() or os.getcwd()
    )
    repository = os.environ.get("SUIJIN_GITHUB_REPOSITORY", "Suijin-App/Suijin")
    channel = os.environ.get("SUIJIN_DISCORD_CHANNEL", RELEASES_CHANNEL)
    version = setting(root, "MARKETING_VERSION")

    notes_path = os.path.join(root, "docs", "releases", version, "release-notes.md")
    if not os.path.isfile(notes_path):
        fail(f"{notes_path} is missing")
    with open(notes_path, encoding="utf-8") as file:
        message = announcement(version, repository, file.read())

    state = gh("release", "view", f"v{version}", "--repo", repository, "--json", "isDraft,isPrerelease",
               "-q", '"\\(.isDraft) \\(.isPrerelease)"')
    latest = gh("release", "list", "--repo", repository, "--exclude-drafts", "--exclude-pre-releases", "--limit", "1",
                "--json", "tagName", "-q", ".[0].tagName")
    published = state == "false false" and latest == f"v{version}"

    if dry_run:
        print(message)
        print()
        print(f"{len(message)} characters. Dry run: nothing was posted.")
        print(f"v{version} is {'published and the latest release' if published else 'NOT published as the latest release; a real run would stop here'}.")
        return

    if not published:
        fail(f"v{version} is not published as the latest release (latest: {latest or 'none'}); nothing was announced")
    token = os.environ.get("DISCORD_BOT_TOKEN", "")
    if not token:
        fail("DISCORD_BOT_TOKEN is not set; run this script through `tssc run` (see the usage at the top)")

    bot = discord("GET", "/users/@me", token)["id"]
    heading = message.splitlines()[0]
    for earlier in discord("GET", f"/channels/{channel}/messages?limit=50", token):
        if earlier["author"]["id"] == bot and earlier["content"].startswith(heading):
            print(f"PASS  Suijin {version} was already announced (message {earlier['id']}); nothing was posted")
            return
    posted = discord("POST", f"/channels/{channel}/messages", token, {"content": message, "allowed_mentions": {"parse": []}})
    print(f"PASS  Suijin {version} announced in Discord (message {posted['id']})")


if __name__ == "__main__":
    main()
