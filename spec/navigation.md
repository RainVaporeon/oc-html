# Navigation and history

Source: `bin/html.lua` (session loop), `lib/html/history.lua`, `lib/html/viewer.lua` (keys, cursor). Index: `SPEC.md`. URL rules: `spec/url.md` "Link resolution". Keys and the cursor: `spec/viewer.md`. Link data: `spec/layout.md` "Links and anchors". Reasons: `docs/rationale.md` "Navigation".

Status: for roadmap items 2 (link following) and 2a (visible cursor), with reload and abort. Approved by the user (2026-11-15).

## Session loop

- One session loop runs in the viewer path. It loads a target, shows the page, and acts on the action that the viewer returns.
- A target is a URL or an absolute local path. The first target comes from the command line (`spec/cli.md`).
- The viewer returns one of these actions: `link` (with the resolved target), `back`, `forward`, `reload`, `go` (with the typed text), `abort`, `quit`, `interrupted`.
- `quit` and `interrupted` end the loop (exit code 0 and 130). The other actions start a load.
- Print mode and the no-screen path load once and have no loop. They ignore the link data.

## Two phases of a load

Every load of a navigation (link, back, forward, go, reload, and an abort that loads again) has two phases.

Phase 1, open. The program checks and opens the target, in the loader coroutine. The page on screen stays in memory and on screen, and the user can scroll it, select links and use the keys of "During a load" while the program connects.
- Local target: it checks that the file exists and is a file, and opens it.
- Remote target: `fetch.open` runs (connect, status mapping, redirects, content type).
- A failure in phase 1 shows a popup over the current page. Nothing else changes: same page, same `top`, same `sel`, same history. The handle that phase 1 opened is closed.
- The popup text is the error line, plus `Reload to try again.` for the errors in "Retry line".
- On the first load of the session no page is on screen. A phase 1 failure there shows the broken page (an empty page with the title `[error] <target>`, the popup and the reload line for the retry errors). The session goes on, and `r` retries the target.

Stop check. When phase 1 succeeds, the loader checks the stop flags once more. The viewer loop handles the keys as they come, so a `z`, Backspace or Left that came during phase 1 has already stopped the load: the handle closed, the commit does not happen, and the page on screen stays (`## Abort`). Ctrl+C and a confirmed quit stop the load in the same way. The loader then yields `commit` to the loop.

Commit. When the stop check passes, the program commits:
1. It releases the old page: lines, links, anchors and base. No reference to them stays. The viewer loop then shows the new, empty live page in place of the old page (`spec/loading.md` "Content during load"). The status line keeps the loading text. The rows of the new page draw as its lines complete. `top` is 1 and no link is selected.
2. It settles the memory (`guard.settled_free`) and runs the size check (`spec/guard.md` "Size check before reading") on the new source.
3. It resets the guard and renders.

- The size check comes after the commit, because the old page must be gone before the free memory is measured.
- A failure after the commit (size check, read error, timeout, memory stop) gives a broken page: an empty page, a popup with the error line and `Reload to try again.` (when the error has the line, see "Retry line"), and the status `[error] <target>`. The broken page keeps its target, so reload and the history work (`spec/loading.md` "Errors after the frame").
- The page has its history entry from the commit on (see "History"): the commit appends the entry of a link or go load. An abort after the commit of a link or go load then drops it (`## Abort`).

## Targets

- A link target is resolved with `url.resolve` (`spec/url.md` "Link resolution"). The result is an `http(s)` URL or an absolute local path.
- A typed target (go prompt) uses the CLI classification: local path or URL, or a guessed URL (`spec/url.md` "Arguments without a scheme").
- A link from a remote page to `file:` is refused (`spec/url.md`). Any link that does not resolve (this one, an invalid URL, a URL over 2048 bytes) shows its popup when the user presses Enter. The status line shows the raw href while it is selected. An unsupported scheme is different: the resolver of the viewer returns the status-line notice, and Enter starts nothing.
- An unsupported scheme shows `<scheme>: links are not supported` in the status line until the next key. No load starts.

## Links that cannot open

- Enter on a link stored as false (href over 2048 bytes) shows `link too long` in the status line until the next key. No load starts.

## Local files

- Any local file opens. A file that is not HTML goes through the same pipeline and shows at worst as bare text.
- A missing file gives the popup `html: file not found: <path>`. A directory gives `html: not a file: <path>`. These are phase 1 failures: the page on screen stays.
- A local base is the absolute path from `shell.resolve`. Link resolution is in `spec/url.md`.

## History

- `lib/html/history.lua` is a pure module. It has no `component` calls and holds no page content.
- It holds up to 32 entries. An entry is `{ target, top, sel }`: the target (URL or absolute path), the first shown line, and the selected link index (or nil).
- A new navigation (link, go, same-document link) cuts the entries after the current one and appends a new entry. When the list has 32 entries, the oldest entry drops.
- Before the program leaves a page (link, go, back, forward), it stores the current `top` and `sel` in the current entry.
- Back and Forward move the current index first. A phase 1 failure moves it back. A move to an entry with the same target as the page on screen (a same-document entry) loads nothing: it shows the page again at the saved `top`. A broken or aborted page is never the same document.
- Back and Forward move the current index and load that entry's target again. They use the cached copy of the page when the disk cache has one, and fetch it otherwise (`spec/cache.md`). A cached copy replays through the local-file path, but the page URL (its final URL, else the requested URL) is the base of its links and the name on the status line, not the path of the cache file. A copy that cannot be read is dropped, and the page is fetched. A re-visit of a history entry by Back or Forward is the only way to hit the cache: a new link or go always fetches. After the load, `top` and `sel` come from the entry, clamped to the new line and link counts.
- Back at the first entry and Forward at the last entry do nothing.
- A followed link whose target gives a mapped HTTP status (404 and others) shows the short page with its popup and becomes a new entry, like any page.
- A phase 1 failure adds no entry and changes no entry. A broken page keeps its entry.
- Reload keeps the current entry (see "Reload").

## Same-document links

- A link is a same-document link when its href is a `#fragment`, or when the resolved URL without the fragment equals the current target.
- A same-document link never loads. It sets `top` to the anchor line (clamped to `max_top`) and appends a history entry.
- An anchor line past `max_top` is clamped: the page scrolls as far as it can.
- A fragment with no matching anchor leaves `top` as it is. The entry is still appended.
- An empty fragment (`#`) goes to line 1.
- The anchor lookup decodes every `%XX` of the fragment and then hashes it (`spec/layout.md` "Links and anchors"). A remote link gives `#a%20b` for the id `a b` (the resolver percent-encodes), and a local link may hold the raw text. Both match.
- The URL fragment of the command line jumps to its anchor after the first load. An unknown fragment stays at the first `top`.

## Reload

- `r` or `R` reloads the page on screen. It loads the current entry's target again, with the two phases.
- After a failed phase 1, the page on screen is still the old page. Reload reloads that page, not the failed target.
- After the load, `top` and `sel` stay, clamped to the new line and link counts.
- A broken page reloads with `top` 1 and no selection.
- Reload replaces the current history entry. It adds no entry.
- Reload never reads the cache. It fetches the page and replaces the cached copy.
- After a redirect that the card followed, the history entry holds the requested URL, and reload requests that URL again. Known limit: the final URL is unknown (`spec/fetch.md` "Redirects").
- For a guessed URL, the suffix ` (no local file named <arg>)` stays on the errors of every reload of that target (`spec/url.md`).
- F5 does not reload.

## Abort

- `z`, `Z`, Backspace and Left (also NumPad Left with char 0) stop a load at once. They work in phase 1 and after the commit. The handle closes. Backspace and Left abort a load as `z` does, and they do not go back a second time. Right stops the load and goes forward (`## During a load`).
- Abort in phase 1: the page on screen was never released, so it stays. Nothing else changes. A `z` (or Backspace or Left) seen up to the stop check before the commit counts as phase 1 (`## Two phases of a load`): the previous page is not fetched again. After the commit the screen is blank, so the abort shows as a load of the previous page.
- Abort after the commit of a new navigation (a link or a go): the old page is already released. `z` loads the previous history entry again (two phases). The load takes the cached copy of that page when there is one, so it makes no request (`spec/cache.md`). An aborted load is never cached. The aborted target gets no history entry: `z` drops the entry of the target that was loading. With no previous entry, the entry stays and the empty `[aborted] <target>` page shows.
- Abort after the commit of a reload, back, forward or of the load of the previous entry: the entry of the page that was loading stays (the current index is unchanged). The old page is already released, so the program shows the empty page with the status `[aborted] <target>`. `r` reloads it.
- Abort with no previous entry (the first page of the session): the program shows an empty page with the target and the status `[aborted] <target>`. `r` reloads it. This holds also for `z` in phase 1 of the very first load, when no page is on screen: the empty `[aborted] <target>` page shows, and `r` retries.
- Ctrl+C still exits at once. `q` still asks to quit (`spec/viewer.md` "Quit"): the load goes on while the prompt shows. The viewer loop reads all these keys (`spec/loading.md` "Keys during load").
- Right is not an abort. During a load it is a Forward action (`## During a load`).

## During a load

- The loading screen rules apply to every navigation load: the status phases, the live page, `q` and Ctrl+C (`spec/loading.md`). `z`, Backspace and Left abort the load (`## Abort`).
- A load is a coroutine that the viewer loop drives. The loop shows the old page until the commit and the live page after it. Nothing calls `os.sleep` during a load.
- Scroll keys, Tab, Shift+Tab, Up, Down and the selection work on the page that is shown: the old page in phase 1, the loaded part after the commit.
- Enter on a visible link, `g` (once a text is submitted), Forward and `r` first stop the load: the loop closes the handle, ends the coroutine and aborts the cache writer. Then the action goes to the session loop as if no load had run. A page left before it finished is not cached, so Back to it fetches.
  - The page that was left after the commit keeps its history entry (the commit appended it), with the `top` and `sel` of the moment. The loaded lines, links and base serve as the page for the action, so a link of the loaded part resolves against the base of that page.
  - A stop before the commit leaves the old page as it was. A Back or Forward load that was in phase 1 moves the history index back, as an abort does.
  - Forward at the last history entry does nothing (`## History`), so it does not stop the load. This includes the first load of the session.
- Enter on a link that is not complete yet is not possible: a link joins the selection when its start line is complete.
- Back, Left, Backspace and `z` use the rules of `## Abort`. Enter on a link, `g`, `r` and Forward (with a later entry) leave the page: the loaded part is the page for the action, and the history entry that the commit appended stays.
- A memory stop during the render (`guard.tick` raises inside the coroutine) ends the coroutine with an error. The session loop makes the broken page and the popup, as for any failure after the commit.
- At most one connection is open at any time. Each phase 1 failure closes its handle. Each end of a load closes its handle. The card allows 4 open connections (`spec/fetch.md` "Internet card API"), so a leaked handle would break later loads.

## Retry line

- These errors carry `Reload to try again.` as a second popup line: the retry errors of `fetch.open` (`retry` is true: see `spec/fetch.md` "Errors") and every broken page (a body read error, a body timeout, a memory stop during the render, a local read error).
- These errors carry no reload line: not an HTML page, compressed response, no internet card, HTTP disabled, too large by the size check before reading (known `Content-Length` or file size), unsupported scheme, redirect errors.
- The popup of a mapped HTTP status keeps its two lines (`spec/viewer.md` "Error popup").

## Go prompt

- `g` opens the go prompt on the status row: `Go to: <text>`. The text starts empty.
- Printable ASCII 0x20 (space) to 0x7E appends the character, so a local path may hold spaces. Backspace deletes the last character. A clipboard event appends its text.
- Enter submits. An empty Enter cancels. Esc cancels. Esc is an input here, not a popup.
- Ctrl+C exits at once.
- The text uses the CLI classification: local path or URL, or a guessed URL. A bad entry (an invalid URL, an unsupported scheme) gives a popup and the session stays on the current page.
- The input cursor is a reverse-video cell at the end of the text.
- The key hint does not list the scroll keys (`Up Dn PgUp PgDn Home End`). The `?` popup lists them (`spec/viewer.md`).
- A submitted target starts a load with the `go` action and, on success, a new history entry.
