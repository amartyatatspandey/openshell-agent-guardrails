#!/usr/bin/env python3
"""Build deck/slideshow.html: one self-contained file from deck/slides/*.html.

Each slide links slides/base.css; that link is replaced by the stylesheet
inline, because slides render from srcdoc where relative links don't resolve.
"""
import json
import pathlib

DECK = pathlib.Path(__file__).resolve().parent
SLIDES_DIR = DECK / "slides"
BASE_LINK = '<link rel="stylesheet" href="base.css">'
# Full-viewport slides that take clicks instead of advancing.
INTERACTIVE = {"07_architecture.html"}


def main() -> None:
    css = (SLIDES_DIR / "base.css").read_text()
    files = sorted(SLIDES_DIR.glob("[0-9][0-9]_*.html"))
    slides, live = [], []
    for i, path in enumerate(files):
        html = path.read_text().replace(BASE_LINK, "<style>\n" + css + "</style>")
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
