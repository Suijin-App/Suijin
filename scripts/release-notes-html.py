#!/usr/bin/env python3
"""Turns a release's notes (Markdown) into the HTML the update window shows.

Sparkle shows an appcast item's description in a small web view. This handles the Markdown the notes use (see the
release skill's references/release-notes.md): paragraphs, `##` headings, `-` bullets with wrapped lines, **bold**,
`code`, [links](url) and ![images](url), and ends with a link to the release page. Anything else passes as text.

Usage: scripts/release-notes-html.py <release-notes.md> <release page URL>
"""
import html
import re
import sys


def inline(text: str) -> str:
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', text)
    return text


def convert(markdown: str) -> str:
    out: list[str] = []
    paragraph: list[str] = []
    items: list[list[str]] = []

    def flush() -> None:
        nonlocal paragraph, items
        if paragraph:
            out.append("<p>" + inline(" ".join(paragraph)) + "</p>")
            paragraph = []
        if items:
            out.append("<ul>" + "".join("<li>" + inline(" ".join(item)) + "</li>" for item in items) + "</ul>")
            items = []

    for raw in markdown.splitlines():
        line = raw.rstrip()
        image = re.fullmatch(r"\s*!\[([^\]]*)\]\((https?://[^)\s]+)\)", line)
        if not line.strip():
            # A blank line ends a paragraph; a list goes on across blank lines until other text starts.
            if paragraph:
                flush()
        elif image:
            flush()
            out.append(f'<p><img src="{html.escape(image.group(2))}" alt="{html.escape(image.group(1))}"></p>')
        elif line.startswith("## "):
            flush()
            out.append("<h2>" + inline(line[3:].strip()) + "</h2>")
        elif line.startswith("- "):
            if paragraph:
                flush()
            items.append([line[2:].strip()])
        elif items and raw.startswith("  "):
            items[-1].append(line.strip())
        else:
            if items:
                flush()
            paragraph.append(line.strip())
    flush()
    return "\n".join(out)


STYLE = (
    "<style>body{font:13px/1.5 -apple-system,sans-serif;margin:12px 14px;color:#1d1d1f}"
    "h2{font-size:14px;margin:16px 0 6px}p{margin:0 0 8px}ul{margin:0 0 8px;padding-left:20px}li{margin:0 0 5px}"
    "code{font:12px ui-monospace,Menlo,monospace;background:rgba(127,127,127,.16);padding:1px 4px;border-radius:4px}"
    "img{max-width:100%;height:auto;border-radius:6px}a{color:#0a66d8}"
    "@media (prefers-color-scheme:dark){body{color:#f5f5f7;background:#1e1e1e}a{color:#6cb1ff}}</style>"
)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8") as notes:
        body = convert(notes.read())
    page = html.escape(sys.argv[2])
    result = f'{STYLE}\n{body}\n<p><a href="{page}">Read these notes on GitHub</a></p>'
    # The description sits in a CDATA section, which this sequence would close.
    print(result.replace("]]>", "]]&gt;"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
