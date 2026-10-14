#!/usr/bin/env python3
"""Build deck/slideshow.html: one self-contained file from deck/slides/*.html.

Each slide links slides/base.css; that link is replaced by the stylesheet
inline, because slides render from srcdoc where relative links don't resolve.
"""
import json
import pathlib
import re

DECK = pathlib.Path(__file__).resolve().parent
SLIDES_DIR = DECK / "slides"
BASE_LINK = '<link rel="stylesheet" href="base.css">'
# Full-viewport slides that take clicks instead of advancing.
INTERACTIVE = {"07_architecture.html"}


def main() -> None:
    css = (SLIDES_DIR / "base.css").read_text()
    files = sorted(SLIDES_DIR.glob("[0-9][0-9]_*.html"))
    slides, live = [], []
    total = len(files)
    for i, path in enumerate(files):
        # Keep "PAGE NN / TT" and the "NN — " kicker in step with file order.
        src = path.read_text()
        fixed = re.sub(r"PAGE \d+ / \d+", f"PAGE {i + 1:02d} / {total}", src)
        fixed = re.sub(r'(<div class="kicker">(?:<span class="dot"></span>)?)\d{2} —', rf"\g<1>{i + 1:02d} —", fixed)
        if fixed != src:
            path.write_text(fixed)
        html = fixed.replace(BASE_LINK, "<style>\n" + css + "</style>")
        slides.append(html)
        if path.name in INTERACTIVE:
            live.append(i)
    # Keep "</script>" inside the strings from closing the shell's script tag.
    encoded = json.dumps(slides, ensure_ascii=False).replace("</", "<\\/")
    shell = (DECK / "shell.html").read_text()
    out = shell.replace("/*SLIDES*/", encoded).replace("/*INTERACTIVE*/", json.dumps(live))
    (DECK / "slideshow.html").write_text(out)
    print(f"slideshow.html: {len(slides)} slides, interactive {live}")


if __name__ == "__main__":
    main()
