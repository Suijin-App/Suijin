#!/usr/bin/env python3
"""Fail when a code comment is not written in English.

Repository rule (CLAUDE.md): every comment in source code is English. Only comments are checked,
never string literals (test data may contain Vietnamese to exercise Unicode handling).
Text inside `backticks` is ignored so comments can quote identifiers or sample values.

Usage: Tools/comment-lint/comment-lint.py [paths...]   (defaults to tracked + untracked files)
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
VIETNAMESE = re.compile(r"[àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ]", re.IGNORECASE)
CODE_SPAN = re.compile(r"`[^`]*`")

HASH_STYLE = {".sh", ".py", ".yml", ".yaml", ".toml"}
HASH_NAMES = re.compile(r"^(Dockerfile.*|entrypoint\.sh|sshd_config|\.gitignore)$")
SLASH_STYLE = {".swift", ".js", ".ts", ".css"}


def strip_strings(line: str, quotes: str) -> str:
    """Blank out quoted string contents so comment markers inside strings are not treated as comments."""
    out, quote, escaped = [], None, False
    for ch in line:
        if quote:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == quote:
                quote = None
                out.append(ch)
                continue
            out.append(" ")
        else:
            if ch in quotes:
                quote = ch
            out.append(ch)
    return "".join(out)


def slash_comments(text: str, template_literals: bool):
    """Scan the whole file so strings that span lines (Swift multi-line strings, JS template literals) are skipped."""
    i, n, line = 0, len(text), 1
    while i < n:
        ch = text[i]
        if ch == "\n":
            line += 1
            i += 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            yield line, text[i:end]
            i = end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            yield line, text[i:end]
            line += text.count("\n", i, end)
            i = end
        elif text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = n if end < 0 else end + 3
            line += text.count("\n", i, end)
            i = end
        elif ch == '"' or ch == "'" and template_literals or ch == "`" and template_literals:
            i += 1
            while i < n and text[i] != ch and (ch == "`" or text[i] != "\n"):
                if text[i] == "\\":
                    i += 1
                if i < n and text[i] == "\n":
                    line += 1
                i += 1
            i += 1
        else:
            i += 1


def comments(path: pathlib.Path):
    """Yield (line number, comment text) pairs."""
    text = path.read_text(encoding="utf-8", errors="replace")
    suffix = path.suffix
    if suffix in SLASH_STYLE:
        yield from slash_comments(text, template_literals=suffix != ".swift")
    elif suffix in HASH_STYLE or HASH_NAMES.match(path.name):
        for number, raw in enumerate(text.splitlines(), 1):
            if number == 1 and raw.startswith("#!"):
                continue
            line = strip_strings(raw, "\"'")
            index = line.find("#")
            if index >= 0:
                yield number, raw[index:]
        if suffix == ".py":
            for match in re.finditer(r'"""(.*?)"""', text, re.S):
                yield text[: match.start()].count("\n") + 1, match.group(1)
    elif suffix == ".sql":
        for number, raw in enumerate(text.splitlines(), 1):
            index = strip_strings(raw, "'").find("--")
            if index >= 0:
                yield number, raw[index:]
    elif suffix in {".html", ".xml", ".plist", ".entitlements", ".storyboard", ".xib"}:
        for match in re.finditer(r"<!--(.*?)-->", text, re.S):
            yield text[: match.start()].count("\n") + 1, match.group(1)


def files(arguments):
    if arguments:
        return [pathlib.Path(a).resolve() for a in arguments]
    listed = subprocess.run(["git", "ls-files", "-co", "--exclude-standard"], cwd=ROOT, capture_output=True, text=True, check=True)
    return [ROOT / p for p in listed.stdout.splitlines() if (ROOT / p).is_file()]


def main() -> int:
    problems = 0
    for path in files(sys.argv[1:]):
        try:
            found = list(comments(path))
        except (UnicodeDecodeError, IsADirectoryError):
            continue
        for number, comment in found:
            if VIETNAMESE.search(CODE_SPAN.sub("", comment)):
                problems += 1
                print(f"{path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}:{number}: {comment.strip()[:110]}")
    if problems:
        print(f"\n✗ {problems} comment(s) are not in English. Rule: all code comments are English (CLAUDE.md).")
        return 1
    print("✓ all code comments are in English")
    return 0


if __name__ == "__main__":
    sys.exit(main())
