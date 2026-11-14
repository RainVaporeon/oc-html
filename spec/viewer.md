# Viewer

Source: `lib/html/viewer.lua`. Index: `SPEC.md`. The startup and the loading screen are in `spec/loading.md`.

## Status line

- The last screen row is a status line: page title (or file name, or URL), scroll position in percent, and a key hint. The status line is black on white.
- For an error status of a remote page, `[HTTP <code>] ` comes before the title (see `spec/fetch.md` "HTTP status and content type").
- The percent is `(top - 1) * 100 // (max_top - 1)`, where `top` is the first shown line and `max_top` the highest `top`. A page that fits on the screen shows 100%.
- The key hint is `Up Dn PgUp PgDn Home End q:quit`. When the title would keep fewer than 20 columns, the hint is `q:quit`.
- A long title is cut so the status line fits the screen width. A wide character never goes past the right edge.
- Control bytes in the title show as spaces.

## Keys

- Up/Down one line, PgUp/PgDn one screen, `q` to quit.
- Home shows line 1 at the top. End shows the last line on the last row above the status line.
- Scrolling stops at the start and at the end. Up at the start and Down at the end do nothing. A page that fits on the screen does not scroll.
- Key codes. The standard codes 199 (Home), 200 (Up), 201 (PgUp), 207 (End), 208 (Down) and 209 (PgDn) are always accepted. The NumPad codes 71 (Home), 72 (Up), 73 (PgUp), 79 (End), 80 (Down) and 81 (PgDn) are accepted only when the `key_down` char is 0. A NumPad digit (NumLock on, for example code 73 with char '9') never acts as a navigation key. Measurements behind the viewer rules: `docs/rationale.md` "Design: Viewer".
- Other keys and other events (for example `touch`) are ignored.
- Key repeat sends about 28 events per second after 500 ms (measured). Before a redraw, the viewer takes all queued scroll events and adds them up, so one redraw covers them.

## Quit

- `q` shows the prompt "Quit? (y/n)". `y`, `Y` or Enter quits. Any other key cancels. A `key_up` event does not answer the prompt.
- Ctrl+C quits at once, without the prompt. It arrives as `key_down` with char 3, then an "interrupted" event from `event.pull` (measured, not an error). The viewer quits on either one.

## Error popup

- When a remote page with an error status stops reading after the first byte (a read error or a read timeout), the viewer shows the part received. It then shows a popup over the page with the error line (`html: read error: <reason>` or `html: timed out reading ...`).
- A key closes the popup. The user then keeps browsing the partial page.
- When the user quits normally, the exit code is 0.
- Print mode and the no-screen path have no popup. See `spec/fetch.md` "HTTP status and content type".

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
- Error lines and `--stats` lines print after the screen restore, so they stay on the screen.
