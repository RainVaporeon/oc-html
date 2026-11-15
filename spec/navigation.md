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

Phase 1, open. The program checks and opens the target. The page on screen stays in memory and on screen.
- Local target: it checks that the file exists and is a file, and opens it.
- Remote target: `fetch.open` runs (connect, status mapping, redirects, content type).
- A failure in phase 1 shows a popup over the current page. Nothing else changes: same page, same `top`, same `sel`, same history. The handle that phase 1 opened is closed.
- The popup text is the error line, plus `Reload to try again.` for the errors in "Retry line".
- On the first load of the session no page is on screen. A phase 1 failure there shows the broken page (an empty page with the title `[error] <target>`, the popup and the reload line for the retry errors). The session goes on, and `r` retries the target.

Commit. When phase 1 succeeds, the program commits:
1. It releases the old page: lines, links, anchors and base. No reference to them stays.
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
- Back and Forward move the current index and load that entry's target again. They fetch the page again: no page content is kept. After the load, `top` and `sel` come from the entry, clamped to the new line and link counts.
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
- After a redirect that the card followed, the history entry holds the requested URL, and reload requests that URL again. Known limit: the final URL is unknown (`spec/fetch.md` "Redirects").
- For a guessed URL, the suffix ` (no local file named <arg>)` stays on the errors of every reload of that target (`spec/url.md`).
- F5 does not reload.

## Abort

- `z` stops a load at once. It works in phase 1 and after the commit. The handle closes.
- Abort in phase 1: the page on screen was never released, so it stays. Nothing else changes.
- Abort after the commit of a new navigation (a link or a go): the old page is already released. `z` loads the previous history entry again (two phases). The aborted target gets no history entry: `z` drops the entry of the target that was loading. With no previous entry, the entry stays and the empty `[aborted] <target>` page shows.
- Abort after the commit of a reload, back, forward or of the load of the previous entry: the entry of the page that was loading stays (the current index is unchanged). The old page is already released, so the program shows the empty page with the status `[aborted] <target>`. `r` reloads it.
- Abort with no previous entry (the first page of the session): the program shows an empty page with the target and the status `[aborted] <target>`. `r` reloads it. This holds also for `z` in phase 1 of the very first load, when no page is on screen: the empty `[aborted] <target>` page shows, and `r` retries.
- Ctrl+C still exits at once. `q` still asks to quit (`spec/viewer.md` "Quit").

## During a load

- The loading screen rules apply to every navigation load: the status phases, `q`, Ctrl+C and no scrolling (`spec/loading.md`). `z` is added.
- Other keys do nothing during a load.
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
