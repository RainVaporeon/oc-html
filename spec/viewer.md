# Viewer

Source: `lib/html/viewer.lua`. Index: `SPEC.md`. The startup and the loading screen are in `spec/loading.md`.

## Status line

- The last screen row is a status line: page title (or file name, or URL), scroll position in percent, and a key hint. The status line is black on white.
- For an error status of a remote page, `[HTTP <code>] ` comes before the title (see `spec/fetch.md` "HTTP status and content type").
- The percent is `(top - 1) * 100 // (max_top - 1)`, where `top` is the first shown line and `max_top` the highest `top`. A page that fits on the screen shows 100%.
- The key hint is `Tab:link Enter:open Bksp:back r:reload ?:keys q:quit`. When the title would keep fewer than 20 columns (a screen narrower than 81 columns), the hint is `?:keys q:quit`, so the key list stays easy to find. When the title would still keep fewer than 20 columns with that hint (a screen narrower than 42 columns), the hint is `q:quit`.
- While a link is selected and visible, the left part shows `-> <resolved url or path>` in place of the title. On a short HTTP status page the `[HTTP ...]` prefix stays before it.
- Status texts: `<scheme>: links are not supported` (`spec/url.md` "Link resolution") and `[aborted] <target>` (`spec/navigation.md` "Abort"). The first one stays until the next key.
- During a load the left part shows the phase or `<label> - Loading <n> KB of <m> KB` (exact texts and the rate limit: `spec/loading.md` "Status line during load"). The percent and the hint on the right stay. The percent counts the loaded part. A visible selected link still shows `-> <target>`.
- Tab prefix. With 2 or more tabs open, the left part starts with `[<i>/<n>] ` (`spec/tabs.md` "Behavior"). It also comes before `-> <url>`, the loading texts, `[error]` and `[aborted]`. A notice replaces the whole left part, including the prefix. `TITLE_MIN` counts the prefix. The viewer gets the prefix as `opts.tab_label`.
- Notices of 0.7.0a. They show in the left part until the next key, like `<scheme>: links are not supported`. The viewer gets one as `opts.notice`: `tab limit: 8 tabs`, `last tab: q quits`, `d: only web files can be downloaded`, `wait for the load, or press z`, `download running: z stops it`, `Saved <path> (<n> KB)` and `download stopped` (`spec/tabs.md`, `spec/download.md`).
- During a download the left part shows `Downloading <name> - <n> KB of <m> KB` (`spec/download.md` "Progress, keys and end").
- A long title is cut so the status line fits the screen width. A wide character never goes past the right edge.
- Control bytes in the title show as spaces.

## Keys

- PgUp/PgDn one screen (h-2 lines), Home/End the first and the last screen, Up/Down between links (see "Link keys"), `q` to quit. The keys for links and navigation follow below ("Link keys", "Navigation keys").
- Home shows line 1 at the top. End shows the last line on the last row above the status line.
- Scrolling stops at the start and at the end. Up at the start and Down at the end do nothing. A page that fits on the screen does not scroll.
- Key codes. The standard codes 199 (Home), 200 (Up), 201 (PgUp), 207 (End), 208 (Down) and 209 (PgDn) are always accepted. The NumPad codes 71 (Home), 72 (Up), 73 (PgUp), 79 (End), 80 (Down) and 81 (PgDn) are accepted only when the `key_down` char is 0. A NumPad digit (NumLock on, for example code 73 with char '9') never acts as a navigation key. Measurements behind the viewer rules: `docs/rationale.md` "Design: Viewer".
- New keys of 0.7.0a: `t` (new tab), `c` (close tab), `<` and `>` (previous and next tab), `!` (shell tab-out) and `d` (download). They are lowercase only, like `g`: the uppercase letters stay free. `classify` returns the actions `tab_new`, `tab_close`, `tab_prev`, `tab_next`, `shell` and `download`. The rules are in `spec/tabs.md`, `spec/shell.md` and `spec/download.md`. The digit keys are not tab keys (see "Key codes").
- Other keys and other events (for example `touch`) are ignored.
- Up and Down move between links, in the style of `links` and `lynx`. They never scroll one line. There is no one-line scroll key.
  - Down selects the next link whose start line is below the start line of the selected link and is on screen. When no link is selected, or the selection is off screen, it selects the first link whose start line is at or below `top` and on screen. The page does not scroll.
  - When no such link is on screen, Down scrolls one page down (the same step as PgDn, h-2 lines), then selects the first link whose start line is in the newly shown rows. When there is none, the selection stays as it was.
  - At the end of the page (`top` is the last top line), Down does nothing when no link is below on screen. It does not wrap. Tab keeps its wrap.
  - Up mirrors Down. It selects the previous link on screen (with no visible selection, the last link whose start line is at or above the bottom row). Else it scrolls one page up and selects the last link whose start line is in the newly shown rows. At the start of the page it does nothing and does not wrap.
  - On a page with no links, Up and Down scroll one page like PgUp and PgDn.
  - Links on one line are reached with Up and Down in document order: Down goes right, Up goes left.
  - NumPad 8 and 2 with char 0 act as Up and Down (see "Key codes"). Queued Up and Down keys apply in order, with one redraw.
- During a load the same keys work on the loaded part (see "Live source").
- Key repeat sends about 28 events per second after 500 ms (measured). Before a redraw, the viewer takes all queued scroll, Up, Down and Tab events in order and applies them, so one redraw covers them.

## Link keys

- Tab selects the next link. Shift+Tab selects the previous link. Shift comes from `keyboard.isShiftDown`, given to the viewer as a dep. When the dep is missing, the viewer tracks `key_down` and `key_up` of the codes 42 and 54. A Shift held before the program starts is not seen by this fallback. This is accepted, because the main path asks `keyboard.isShiftDown`.
- Enter follows the selected link, only when the link is visible.
- Selection:
  - Tab with no selection, or with the selection off screen, picks the first link whose start line is at or after `top`. When no such link is visible, it picks the next link below and scrolls to it. When no link starts at or below `top`, it wraps to the first link of the page and scrolls the smallest amount that shows it.
  - Tab with a selection picks the next link. When that link is off screen, the viewer scrolls the smallest amount that shows its start line.
  - Shift+Tab mirrors these rules, upward. With no selection and no link at or above the bottom row, it wraps to the last link of the page and scrolls the smallest amount that shows it.
  - The order of links wraps. Tab on the last link selects the first link. Shift+Tab on the first link selects the last link. The scroll rule is the same: the smallest scroll that shows the start line of the target. With one link, the selection stays. With no link, nothing happens. With no visible selection, the rules above apply, including the wrap to the first or last link. With no link, nothing happens. "Link" means any entry the user can select. Entries of other kinds (input fields) will join the same order.
  - Scrolling keeps the selection. Enter acts only when the selected link is visible.
- After a popup or a prompt closes on Enter, Enter is ignored until a `key_up` for code 28. A held Enter then cannot follow a link.

## Navigation keys

- Left (code 203, or the NumPad code 75 with char 0) is Back. Right (205, or NumPad 77 with char 0) is Forward.
- Backspace (code 14, char 8) is Back, but only when no input field has focus. When an input field has focus (forms, later), Backspace deletes a character and is not Back. Forms rely on this rule. Reason: `docs/rationale.md` "Navigation".
- `g` opens the go prompt (`spec/navigation.md` "Go prompt"). The prompt accepts the space key, so a path with spaces can be typed.
- `r` and `R` reload the page (`spec/navigation.md` "Reload"). F5 does not reload.
- `z` aborts a page load (`spec/navigation.md` "Abort"). During a load, Backspace and Left abort it too. Right, Enter on a link, `g` and `r` stop the load and act (`spec/navigation.md` "During a load"). `z` does nothing when no load runs.
- `t`, `c`, `<`, `>`, `!` and `d` (see "Keys"). During a load they stop the load or are refused (`spec/navigation.md` "During a load"). During a download only `z` stops it (see "Job kind").
- `?` shows a key-list popup. It lists the keys of this section and of "Keys". Only Enter closes it.
- Back, Forward, reload and `g` start a load through the session loop (`spec/navigation.md`).

## Live source

- `session.show(lines, opts)` can show a page that is still loading. `opts.live` is the live source: `{ lines, count(), links(), title() }`, with `lines` the layout lines (they only grow), `count()` the number of complete lines and `links()` the link table `{ span, href, count }` of the layout. `opts.load` is the driver: `drive()` runs the loader one step and returns `"wait", seconds`, `"slice"`, `"commit"` or `"done"`, and `status()` returns the label and the tail of the status line (`spec/loading.md`). Without `opts.live` the page is the fixed `lines` and `opts.links`. `opts.load` without `opts.live` is phase 1: the old page, or an empty page, with a phase text in the status line.
- The loop of the viewer drives the loader. Each pass it calls `drive()`, then refreshes the live page, then pulls an event: with the timeout of a `wait`, with 0 after a `slice`, and with 1 s when the load is over. A `commit` or a `done` makes `show` return the action `commit` or `done` (with `top` and `sel`). The session loop then shows the new page or the final page. The nested prompts (quit, go, help) drive the loader too, so loading goes on behind them. A `commit` or a `done` that comes during a prompt waits until the prompt closes.
- Refresh: `max_top` uses `count()`. The rows whose line became complete since the last pass and that are inside the window draw (the rest of the window is not redrawn). A link joins the selection list when its start line is at most `count()`. The last link span can still grow, so the loop reads it again at each pass, and when the selected link grew, it draws the rows of that link again. The view never scrolls by itself.
- `z`, Backspace and Left return the action `abort` while a load runs (the load is not over yet). With no load, Backspace and Left are Back.
- The status line is redrawn only when its text changes. The loader limits the byte count updates (`spec/loading.md`).

## Visible cursor

- The selected link shows in reverse video. Depth 8 and 4: black text on the link color 0x6699FF. Depth 1: black on white.
- At depth 1 an unselected link looks like normal text. This is accepted.
- The GPU has no hardware cursor, so the viewer draws the highlight itself. It covers the cells of the link from its start to its end, on every line that the link spans.
- The viewer redraws the old and the new selection when the selection changes, and draws the selection in new rows when the page scrolls.
- The input cursor of the go prompt is a reverse-video cell at the end of the text.

## Key list popup

- `?` shows exactly these 11 lines (0.7.0a):
```
Tab, Shift+Tab: next, previous link
Enter: open the selected link
Left, Bksp, Right: back, forward
r: reload
g: go to a URL or a file
Up, Down: move between links
PgUp, PgDn, Home, End: scroll
t, c: new tab, close tab
<, >: previous, next tab
d: download, !: shell
q: quit, ?: this list
```
- `s.popup` keeps at most `rows - 2` lines, and the blank line and `[OK]` count. On a tier 1 screen (50x16), `rows` is 15, so the text can have at most 11 lines. A test pins that the key list fits 16 rows.

## Status-row prompt

- The go prompt, the new-tab prompt and the save prompt are one generic prompt on the status row. It takes a label (` Go to: `, ` New tab: `, ` Save to: `) and a plain initial text (empty for go and new tab, the default path for save). The input cursor is a reverse-video cell at the end of the text.
- Typing: printable ASCII 0x20 to 0x7E adds a character, Backspace deletes one character, a clipboard event adds its text. Enter submits. A blank Enter cancels. Esc also cancels in the code, but Minecraft catches Esc in game, so no feature depends on it. Ctrl+C exits at once.
- The initial text is plain text, not a placeholder: Backspace deletes it one character at a time.
- The load (or the download) goes on while a prompt is open, and the loader is driven behind it (`spec/loading.md` "Keys during load").

## Confirm prompt

- ` Overwrite <name>? (y/n)` (the save prompt, `spec/download.md` "Prompt") answers `y` or `Y` only. Enter and every other key cancel. This differs from the quit prompt, where Enter confirms. Reason: a held Enter must not overwrite a file.

## Job kind

- The viewer drives one job: a page load or a download. `opts.load` carries a `kind`, `"page"` or `"download"` (default `"page"`).
- With kind `"page"`, `z`, Backspace and Left return `abort`, and the keys of `spec/navigation.md` "During a load" apply.
- With kind `"download"`, only `z` returns `abort`. Backspace, Left, Right, Enter on a link, `r`, `g`, `t`, `c`, `<`, `>`, `!` and `d` set the notice `download running: z stops it` and do nothing else. `q` and Ctrl+C work as in "Quit" (`spec/download.md` "Progress, keys and end").

## Open option `enter_held`

- `viewer.open` takes the option `enter_held` (true or false, default false). When true, Enter is ignored until the `key_up` of code 28, as after a popup (see "Link keys"). The session loop sets it after the return from the shell (`spec/shell.md` "Sequence").

## Quit

- `q` shows the prompt "Quit? (y/n)". With 2 or more tabs the prompt is ` Quit and close <n> tabs? (y/n)` (the viewer gets it as `opts.quit_text`). `y`, `Y` or Enter quits. Any other key cancels. A `key_up` event does not answer the prompt.
- Ctrl+C quits at once, without the prompt. It arrives as `key_down` with char 3, then an "interrupted" event from `event.pull` (measured, not an error). The viewer quits on either one.
- During a load the prompt works the same way, and loading goes on while it shows (`spec/loading.md` "Keys during load"). The viewer loop reads the key: it is the only reader of events. A key that answers the prompt cancels it, also `z`, Backspace and Left. A `key_up` event only updates the Shift state.

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
