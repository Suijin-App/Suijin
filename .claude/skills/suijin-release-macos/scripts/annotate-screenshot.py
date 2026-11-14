#!/usr/bin/env python3
"""Draws red hand-written notes and arrows over a screenshot, and covers private regions, in the style of the README
images. Renders with headless Google Chrome; the output keeps the input's transparency.

Usage:
  annotate-screenshot.py <input.png> <output.png> <spec.json> [--width 2200]

The spec is JSON. Coordinates are pixels in the OUTPUT image (the input scaled to --width):
  {
    "notes":  [{"x": 40, "y": 740, "text": "the coordinator\\nand its workers", "rotate": -4, "size": 44}],
    "arrows": [{"path": "M 190 720 C 260 640, 260 440, 208 366", "dashed": false}],
    "covers": [{"x": 190, "y": 430, "w": 130, "h": 32, "color": "rgb(236,236,238)"}]
  }
- notes: text at its top-left corner; "\\n" breaks the line; rotate in degrees; size in pixels (default 44).
- arrows: an SVG path; the arrowhead is drawn at the end of the path. "dashed" draws a dashed line.
- covers: an opaque rectangle over something private (an email, a host name). Pick the background colour around it.
"""
import argparse
import html
import json
import pathlib
import struct
import subprocess
import sys
import tempfile

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
INK = "#E5484D"


def png_size(path: pathlib.Path) -> tuple[int, int]:
    with path.open("rb") as file:
        header = file.read(24)
    if header[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"annotate-screenshot: {path} is not a PNG")
    return struct.unpack(">II", header[16:24])


def main() -> None:
    parser = argparse.ArgumentParser(description="Draw red notes and arrows over a screenshot.")
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("spec", type=pathlib.Path)
    parser.add_argument("--width", type=int, default=2200)
    arguments = parser.parse_args()
    if not pathlib.Path(CHROME).exists():
        sys.exit("annotate-screenshot: Google Chrome is needed to render the notes")
    spec = json.loads(arguments.spec.read_text())
    source_width, source_height = png_size(arguments.input)
    width = arguments.width
    height = round(source_height * width / source_width)

    notes = "".join(
        f'<div class="note" style="left:{note["x"]}px;top:{note["y"]}px;font-size:{note.get("size", 44)}px;'
        f'transform:rotate({note.get("rotate", 0)}deg)">{html.escape(note["text"]).replace(chr(10), "<br>")}</div>'
        for note in spec.get("notes", [])
    )
    def arrow_tag(arrow: dict) -> str:
        dash = ' stroke-dasharray="18 16"' if arrow.get("dashed") else ""
        return f'<path d="{html.escape(arrow["path"])}"{dash} marker-end="url(#head)"/>'

    arrows = "".join(arrow_tag(arrow) for arrow in spec.get("arrows", []))
    covers = "".join(
        f'<div class="cover" style="left:{cover["x"]}px;top:{cover["y"]}px;width:{cover["w"]}px;height:{cover["h"]}px;'
        f'background:{html.escape(cover.get("color", "rgb(236,236,238)"))}"></div>'
        for cover in spec.get("covers", [])
    )
    page = f"""<!doctype html><html><head><meta charset="utf-8"><style>
*{{margin:0;padding:0}} html,body{{width:{width}px;height:{height}px;overflow:hidden;background:transparent}}
img{{position:absolute;left:0;top:0;width:{width}px;height:{height}px}}
.note{{position:absolute;font-family:"Bradley Hand","Noteworthy",cursive;font-weight:700;line-height:1.08;color:{INK};
 white-space:nowrap;transform-origin:left top;text-shadow:0 0 6px #fff,0 0 6px #fff,0 0 12px #fff,0 0 12px #fff}}
svg{{position:absolute;left:0;top:0;width:{width}px;height:{height}px;filter:drop-shadow(0 0 3px #fff) drop-shadow(0 0 3px #fff)}}
path{{fill:none;stroke:{INK};stroke-width:6;stroke-linecap:round}}
.cover{{position:absolute;border-radius:8px}}
</style></head><body><img src="{arguments.input.resolve().as_uri()}">{covers}
<svg viewBox="0 0 {width} {height}"><defs><marker id="head" viewBox="0 0 12 12" refX="9" refY="6" markerWidth="5"
 markerHeight="5" orient="auto-start-reverse"><path d="M1 1 L10 6 L1 11" style="stroke-width:2.4;stroke-dasharray:none"/></marker></defs>{arrows}</svg>
{notes}</body></html>"""

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as folder:
        page_path = pathlib.Path(folder) / "page.html"
        page_path.write_text(page)
        result = subprocess.run(
            [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
             "--default-background-color=00000000", f"--window-size={width},{height}",
             f"--screenshot={arguments.output.resolve()}", page_path.as_uri()],
            capture_output=True, text=True)
    if result.returncode != 0 or not arguments.output.exists():
        sys.exit(f"annotate-screenshot: Chrome could not render the image\n{result.stderr[-400:]}")
    print(f"annotated: {arguments.output} ({width}x{height})")


if __name__ == "__main__":
    main()
