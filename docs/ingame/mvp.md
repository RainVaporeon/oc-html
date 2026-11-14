# In-game checklist: MVP 0.1.0a

`<BASE>` is your raw URL of the repository.

Report back: a short pass or fail per step, the file `stats-large.txt` in `./datacollection/`, and any error text or a screenshot of a wrong screen.

Do not test Ctrl+Alt+C.

## 1. Install

1. `wget -f <BASE>/releases/0.1.0a/html-install.lua /home/html-install.lua`
2. Run `/home/html-install.lua`. No reboot is needed.

## 2. Pages

- `wiki.html` and `large.html` are already on the machine from earlier runs.
- Fetch one more real page, for example the Wikipedia Lua article: `wget -f <URL> /home/lua.html`

## 3. Viewer on a depth-8 screen (tier 3)

Run `html wiki.html`. Check:

- [ ] Colors for headings, links, emphasis and pre.
- [ ] The status line shows the title, the percent and the key hint.
- [ ] Scrolling works with the arrow keys, PgUp, PgDn, Home and End.
- [ ] The same works with the NumPad keys with NumLock off.
- [ ] With NumLock on, the NumPad digits do NOT scroll.
- [ ] `q` shows "Quit? (y/n)".
- [ ] `n` cancels the prompt.
- [ ] `y` quits.
- [ ] Ctrl+C quits at once.
- [ ] After exit, the resolution, the colors and the shell prompt are back to normal.

## 4. `--no-rescale`

1. Set a smaller resolution: `resolution 80 25`
2. Run `html --no-rescale wiki.html`. Check that it keeps 80x25. Quit.
3. Run `html wiki.html`. Check that it switches to the maximum resolution and restores 80x25 on exit.

## 5. Stats

1. Run `html --stats --stats-out /home/stats-large.txt large.html`
2. Scroll to the end. Quit.
3. Report the file `stats-large.txt`. Put it in `./datacollection/`.

## 6. Print mode

Run `html --print --width 40 basic.html` only if `basic.html` is still on the machine. Check that the text is wrapped at 40 columns.

## 7. Depth-4 (tier 2) and depth-1 (tier 1) screens

For each screen:

- [ ] Open `wiki.html`.
- [ ] Depth 4: the colors are readable.
- [ ] Depth 1: the text is plain.
- [ ] Quit cleanly.

## 8. Errors

- [ ] `html nofile.html` prints one line: file not found.
- [ ] `html /home` prints one line: not a file.
- [ ] Press Ctrl+C during the render of `large.html`. It prints one line `html: interrupted`. The prompt is usable.
