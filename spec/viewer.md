# Viewer

Source: `lib/html/viewer.lua`. Index: `SPEC.md`. The startup and the loading screen are in `spec/loading.md`.

## Status line

- The last screen row is a status line: page title (or file name, or URL), scroll position in percent, and a key hint. The status line is black on white.
- For an error status of a remote page, `[HTTP <code>] ` comes before the title (see `spec/fetch.md` "HTTP status and content type").
- The percent is `(top - 1) * 100 // (max_top - 1)`, where `top` is the first shown line and `max_top` the highest `top`. A page that fits on the screen shows 100%.
- The key hint is `Tab:link Enter:open Bksp:back r:reload ?:keys q:quit`. When the title would keep fewer than 20 columns (a screen narrower than 81 columns with a short title), the hint is `q:quit`.
- While a link is selected and visible, the left part shows `-> <resolved url or path>` in place of the title. On a short HTTP status page the `[HTTP ...]` prefix stays before it.
- Status texts: `<scheme>: links are not supported` (`spec/url.md` "Link resolution") and `[aborted] <target>` (`spec/navigation.md` "Abort"). The first one stays until the next key.
- A long title is cut so the status line fits the screen width. A wide character never goes past the right edge.
- Control bytes in the title show as spaces.

## Keys

- Up/Down one line, PgUp/PgDn one screen, `q` to quit. The keys for links and navigation follow below ("Link keys", "Navigation keys").
- Home shows line 1 at the top. End shows the last line on the last row above the status line.
- Scrolling stops at the start and at the end. Up at the start and Down at the end do nothing. A page that fits on the screen does not scroll.
- Key codes. The standard codes 199 (Home), 200 (Up), 201 (PgUp), 207 (End), 208 (Down) and 209 (PgDn) are always accepted. The NumPad codes 71 (Home), 72 (Up), 73 (PgUp), 79 (End), 80 (Down) and 81 (PgDn) are accepted only when the `key_down` char is 0. A NumPad digit (NumLock on, for example code 73 with char '9') never acts as a navigation key. Measurements behind the viewer rules: `docs/rationale.md` "Design: Viewer".
- Other keys and other events (for example `touch`) are ignored.
- Up and Down do not jump between links. They only scroll.
- Key repeat sends about 28 events per second after 500 ms (measured). Before a redraw, the viewer takes all queued scroll events and adds them up, so one redraw covers them.

## Link keys

- Tab selects the next link. Shift+Tab selects the previous link. Shift comes from `keyboard.isShiftDown`, given to the viewer as a dep. When the dep is missing, the viewer tracks `key_down` and `key_up` of the codes 42 and 54. A Shift held before the program starts is not seen by this fallback. This is accepted, because the main path asks `keyboard.isShiftDown`.
- Enter follows the selected link, only when the link is visible.
- Selection:
  - Tab with no selection, or with the selection off screen, picks the first link whose start line is at or after `top`. When no such link is visible, it picks the next link below and scrolls to it.
  - Tab with a selection picks the next link. When that link is off screen, the viewer scrolls the smallest amount that shows its start line.
  - Shift+Tab mirrors these rules, upward.
  - Scrolling keeps the selection. Enter acts only when the selected link is visible.
- After a popup or a prompt closes on Enter, Enter is ignored until a `key_up` for code 28. A held Enter then cannot follow a link.

## Navigation keys

- Left (code 203, or the NumPad code 75 with char 0) is Back. Right (205, or NumPad 77 with char 0) is Forward.
- Backspace (code 14, char 8) is Back, but only when no input field has focus. When an input field has focus (forms, later), Backspace deletes a character and is not Back. Forms rely on this rule. Reason: `docs/rationale.md` "Navigation".
- `g` opens the go prompt (`spec/navigation.md` "Go prompt"). The prompt accepts the space key, so a path with spaces can be typed.
- `r` and `R` reload the page (`spec/navigation.md` "Reload"). F5 does not reload.
- `z` aborts a page load (`spec/navigation.md` "Abort").
- `?` shows a key-list popup. It lists the keys of this section and of "Keys". Only Enter closes it.
- Back, Forward, reload and `g` start a load through the session loop (`spec/navigation.md`).

## Visible cursor

- The selected link shows in reverse video. Depth 8 and 4: black text on the link color 0x6699FF. Depth 1: black on white.
- At depth 1 an unselected link looks like normal text. This is accepted.
- The GPU has no hardware cursor, so the viewer draws the highlight itself. It covers the cells of the link from its start to its end, on every line that the link spans.
- The viewer redraws the old and the new selection when the selection changes, and draws the selection in new rows when the page scrolls.
- The input cursor of the go prompt is a reverse-video cell at the end of the text.

## Quit

- `q` shows the prompt "Quit? (y/n)". `y`, `Y` or Enter quits. Any other key cancels. A `key_up` event does not answer the prompt.
- Ctrl+C quits at once, without the prompt. It arrives as `key_down` with char 3, then an "interrupted" event from `event.pull` (measured, not an error). The viewer quits on either one.

## Error popup

- When a page breaks off after the frame opened (a read error, a read timeout or a memory stop), the viewer shows no part of it. It shows a popup over an empty page with two lines: the error line (`html: read error: <reason>`, `html: timed out reading ...` or the memory message) and `Reload to try again.` (`spec/loading.md` "Errors after the frame").
- The popup shows the error text and an `[OK]` button under it. Only Enter closes the popup. Esc does not. The viewer ignores all other keys while the popup shows (Ctrl+C still quits at once). After OK the user can scroll the empty page and quit.
- The Enter rule of "Link keys" applies: after Enter closes it, Enter is ignored until the `key_up` of code 28.
- When the user quits normally, the exit code is 0.
- Print mode and the no-screen path have no popup. See `spec/fetch.md` "HTTP status and content type".
- A popup also reports an error after the frame opened (`spec/loading.md` "Errors after the frame"). The page behind it is empty. The status line shows `[error]` and the URL. After OK the user can scroll and quit as usual.
- A status that the card reports as a connect failure (404, 500, ...) shows the short page behind a popup of two lines: `[HTTP <code>] <phrase>` and the URL (for example `[HTTP 404] Not Found`, then `http://example.com/`). A code with no known phrase shows `[HTTP <code>]`, then the URL. The status line shows `[HTTP <code>] <phrase>` and does not repeat the code. With no phrase it shows `[HTTP <code>] <url>`. See `spec/fetch.md` "HTTP error statuses".

## Resolution

- When the TUI opens, the viewer sets the resolution to `gpu.maxResolution()` if the current resolution is different. `--no-rescale` skips this.
- The viewer then reads the size with `gpu.getResolution()`.
- On every exit path, the viewer restores the resolution it found at start.

## Colors

- Colors depend on `gpu.getDepth()`. Depth 8 and 4 use colors for headings, links and emphasis, given as RGB values. Depth 1 uses plain text, white on black. Palette indices are not used.
- Color values: NORMAL 0xFFFFFF, HEADING 0xFFFF33, EMPHASIS 0xFFCC33, LINK 0x6699FF, PRE 0x33CC33. The status line is black on white.
- The viewer caches the current foreground and background. It calls `setForeground` and `setBackground` only on a change (measured: a call costs as much as a `fill`, also with the same color). Both calls return the old color (measured).

## Drawing

- Scrolling moves the screen content with `gpu.copy` and draws only the new rows. `copy` leaves the source row as it was (measured), so the viewer always draws the new row. A scroll of up to h-2 lines (including PgUp, PgDn and short Home or End jumps) uses `copy` and draws only the exposed rows. A larger jump redraws all rows.
- One `gpu.set` call draws one same-style piece of a line. A call costs the same for 1 or 160 characters.

## Exit

- On exit (normal, error or Ctrl+C) the viewer restores the colors and the resolution, calls `term.clear()` and sets the cursor. The `term` cursor is stale after direct GPU drawing (measured), so the viewer must set it.
- Error lines print after the screen restore, so they stay on the screen.
