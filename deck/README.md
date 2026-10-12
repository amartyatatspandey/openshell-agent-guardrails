# Deck

Open [`slideshow.html`](slideshow.html) in a browser. It's one self-contained file (fonts load from Google Fonts).

- **Next:** `→` `↓` `Space` `Page Down`, or click the right side of a slide
- **Previous:** `←` `↑` `Backspace` `Page Up`, or click the left side
- **Jump:** `Home` / `End`, or `#7` in the URL
- **Fullscreen:** `F`

Slide 7 is the interactive architecture map ([`slides/07_architecture.html`](slides/07_architecture.html), also opens on its own):

- Click any box with a `+` for what it does, its config, and what it can't do.
- Pick one of the ten controls (chips at the bottom, or keys `1`–`0`) to light the attempt path, the enforcing gate, and the exact OpenShell log line.
- The trace buttons light one flow at a time: verify run, denied egress, kernel denials, credential path, Kyverno bonus.
- **Play the run** steps through a whole `make verify` with a caption per step.
- Arrow keys still change slides. `Esc` closes a drawer.

Log lines on the slides are real output from `make verify` and `make kyverno` on OpenShell v0.1.3.

## Editing

Slides live in `slides/NN_name.html` and share `slides/base.css`. After editing, rebuild:

```sh
python3 deck/build.py
```
