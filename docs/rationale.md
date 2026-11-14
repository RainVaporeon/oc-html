# Rationale and measurements behind the spec

This file is informative. The rules are in `SPEC.md` (index) and `spec/`. Each section here names the spec file that it explains. The measured machine facts are in `docs/probe/FACTS.md`.

## Commands (stats lines)

Explains `spec/probe.md` and `spec/cli.md` "Home directory".


- `delta` (free_before - free_after) is unreliable. The game has no `collectgarbage`, so a reading includes garbage, and garbage from earlier work (module loading) can be collected during the run. Measured: delta was -164198 bytes on a 98891-byte page.
- `shell.resolve` does not expand `~` (measured: it gives `/home/~`). This is why `bin/html.lua` expands `~` itself.

## Design: Pipeline

Explains `spec/pipeline.md` and `spec/tokenizer.md` "Implementation rules".


- Module cache (step 1). OpenOS keeps every required module in `package.loaded` until a reboot. No code removes an entry, and every program shares the same table. So after an update, `require` can return the module of an older version. (Seen in 0.0.2a: the new `bin/html.lua` called `guard.lowest_free`, which the cached 0.0.1a guard did not have.)
- Tokenizer (step 2). Measured: `gsub` 94 KB/s, plain `find` 6338 KB/s.
- Tokenizer (step 2). Measured costs (probe v2): plain `find` about 3.2 us per call (6821 KB/s), `string.byte` of 1 byte about 61 ns, `sub` of 80 bytes about 260 ns, `t[#t+1] = v` 17.2 M ops/s against `table.insert` 9.0 M.
- Layout (step 3). Measured: one string per line with style bytes uses 80 bytes per line; a table of styled pieces used 322.

## Design: Viewer

Explains `spec/viewer.md`.


- Measured: the user's keyboard sends PgUp, PgDn, Home and End as NumPad codes with char 0.
- Measured: t3 had 120x60 on a GPU with a 160x50 maximum. This was a user-set resolution.

## Design: Limits and graceful failure

Explains `spec/guard.md` and `spec/errors.md`.


- Doubling term of the reserve. Reason: the lines table holds one slot per line. When it is full, Lua doubles its array from c to 2c slots and keeps the old slots until the copy ends, so the doubling needs 2c slots of 16 real bytes at once. Measured: the 8192 to 16384 doubling cost 72818 units, and on large.html free memory hit 0 at that doubling (0.0.4a). For c = 8192 the term is 145636 (under the base reserve). For c = 16384 it is 291271.
- Raw readings. A raw reading can be up to about 1.3 MB too low (measured), because garbage is not collected yet. The readings form a saw-tooth, because the incremental GC frees garbage during the render. Garbage never makes an allocation fail: a failed allocation runs a full GC and retries.
- Live cost per line B. Measured in 0.0.4a: about 66.5 per line on large.html, 46 to 76 between settles that saw a GC. (The 0.0.3a values of 160 and 410 were a wrong estimate.)
- Rule change from the first draft: the first draft settled on every raw reading under reserve / 2 and kept B at 410 or more. On a simulated 11302-line run with the measured saw-tooth, that gave 37 settles and 3.7 s of settle yields. The rule above gives 9 settles and 88 yields (0.9 s). With the doubling term and the new cost constants it gives 13 settles and 127 yields (1.3 s): the higher reserve above 8192 lines adds settles. In game, 0.0.4a gave 12 settles and 118 yields on large.html.
- Decision against a forced GC. The measured kernel GC on every 10th yield is enough. The trick depends on the behavior of a failed allocation, which is not measured in game.
- Controlled errors as strings. This design does not depend on how error tables pass through `pcall` and `xpcall` (see `docs/probe/FACTS.md`, run t3), This is simpler than error tables.

## Remote fetching: decisions

Decided by the user (2026-11-14). `spec/fetch.md` and `spec/url.md` state each rule; this list records the decisions and their IDs:
- The response is streamed into the renderer. It is not saved to a cache file first.
- D1: The program uses the card component directly, not the OpenOS `internet` library (see `spec/fetch.md` "Internet card API").
- D2: The body of a 4xx or 5xx response renders. The program does not stop. The status code shows in the viewer, and on stderr in `--print` mode (see `spec/fetch.md` "HTTP status and content type").
  - Measured (netprobe v1, 2026-11-15): the card gives no body for a 4xx or 5xx status. `finishConnect()` fails with a reason that holds the status, so no body is readable. The program maps the reason back to a code, shows the short page, and reports `[HTTP <code>] <phrase>` in a popup (`spec/fetch.md` "HTTP error statuses"). The rule "the body renders" stays for a card that gives a body; its tests are marked "not seen in game".
- D3: Latin-1 and Windows-1252 convert to UTF-8. All other charsets pass through as UTF-8 (see `spec/fetch.md` "Charset").
- D4: An argument without a scheme is a local file when that file exists. Otherwise, when it looks like a host, it is `http://<arg>` (see `spec/url.md` "Arguments without a scheme").
- D5 (Q5): An argument whose last label is `html`, `htm`, `xhtml`, `txt` or `lua` stays a local file. A missing `x.html` gives `html: file not found: x.html` (see `spec/url.md` "Arguments without a scheme").
- D6 (Q6): The exit code is 0 when an error status (4xx, 5xx) renders, in the viewer and in `--print` mode (see `spec/fetch.md` "HTTP status and content type").

## Errors keep the session

Decided by the user (2026-11-15). Rules: `spec/loading.md` "Errors after the frame".

- The program will support tabs. A tab that fails to load must not end the whole program, so an error after the frame opened shows in a popup and the user stays in the viewer.
- The rule covers every fetch error after the frame: cannot connect, timeout, read error, too many open connections, not text/html, too large. A page that breaks off shows no lines ("Broken pages are not rendered").
- Print mode, the no-screen path and the errors before the frame keep the stderr line and the exit codes. Without a screen there is no session to keep, and a shell script needs the exit code.
- Ctrl+C still exits at once with code 130. It is the user's explicit request to leave.

## Broken pages are not rendered

Decided by the user (2026-11-15). Rules: `spec/loading.md` "Errors after the frame". This replaces the rule of 2026-11-14 that rendered the received part of an error-status body.

- A partial page is misleading. The user may read it as the whole page and miss the text that did not arrive. So a page that breaks off (read error, timeout in the body, memory stop) shows an empty page and a popup with the error and `Reload to try again.`. The user reloads instead of reading a part.
- The same holds for a local file read error and for print mode: no partial text prints, only the error line on stderr, and the exit code is 1 because the output is incomplete.

## Remote fetching: measurements (netprobe v1)

One run in game (GT:NH server, user agent `opencomputers/1.12.68-GTNH`, a permissive address config). Raw data: `datacollection/netprobe.txt` (not tracked). The facts with their source keys: `docs/probe/FACTS.md` "Internet card (netprobe v1)".

- The card and the handle give their methods as callable tables. The probe tested `type == "function"` and reported `isHttpEnabled` as missing (a probe bug, now fixed). The fetch code only calls the methods, so it was not affected.
- A 4xx or 5xx status fails in `finishConnect()`. The 404 reason is the URL, and the others are the Java message `Server returned HTTP response code: <N> for URL: <url>`. This broke the assumption behind decision D2 (a readable error body). The program now maps the reason back to a status (`spec/fetch.md` "HTTP error statuses").
- `response()` is nil while the request is pending and gives a value at once after `finishConnect()` returned true, with no read. The wait order in `fetch.open` (connect, then response) was right. The fake card now copies this.
- The card follows same-scheme redirects by itself and gives no final URL. A scheme change comes back as a 302 with an absolute `Location`. So the final URL of a page can be unknown, which matters for relative links (`tasks/todo.md` item 2).
- The limit is 4 connections. Tabs must keep at most 4 handles open, or close a handle before they open another.
- `finishConnect()` stays false until the response headers arrive. The card has no connect timeout of its own (a silent host was pending after 20 s). `CONNECT_TIMEOUT` therefore bounds the time to the first header.
- Each `request()` and `read()` costs one tick (50 ms). The first reads gave 2048 bytes on two hosts. Large reads, memory and a 1 MB page are not measured yet.

## Remote fetching: Internet card API

Reasons for decision D1 (use the card component, not the OpenOS `internet` library):
- The `internet.request` iterator reads with no size limit, so the chunk size is not under program control.
- The iterator raises errors with `error(reason, 2)` and hides `response()` behind its metatable. Every failure would need a `pcall` and string matching.
- The iterator waits with `os.sleep(0)` and has no timeout and no interrupt check.

## Decisions of 2026-11-14 (spec rules)

Decided by the user (2026-11-14). The rules are in the named spec files.

- Misnested inline tags (`spec/layout.md` "The open-element stack"). In `<i><b>a</i>b</b>`, the second "b" stays bold, as in browsers. Pages written for browsers expect this result.
- Broken quoted attribute (`spec/tokenizer.md` "Broken quoted value"). The tag ends at the first `>`, and the text after it is page text. A missing quote then hides only the rest of one tag, not the page that follows.
- A `<` with no `>` (`spec/tokenizer.md` "Broken markup"). The same rule applies at the end of input and at the `MAX_TAG` limit. One rule is simpler, and the user sees all the text of the page, also a cut tag at the end.
- `pre` drops one newline after the start tag (`spec/layout.md` "Preformatted text"). This matches the HTML standard, so a page shows no extra blank line at the top of a `pre` block.
- `--width` maximum (`spec/cli.md` "Output width"). A width larger than the screen cannot be shown. 160 is the tier 3 maximum, the largest screen in the game.
- Installer suffix (`spec/installer.md`). `; old files kept` is true only when the install started to change files. A failed check before the first write changed nothing.

## Startup and loading screen

Explains `spec/loading.md`. Decided by the user (2026-11-14).

- The TUI opens before the heavy modules load and before any network request. The user sees at once that the program runs, also on a slow server or a large page.
- An event pull costs about 15 ms in game. A pull per token would make the render many times slower. A pull about every 0.25 s costs about 6% of the time and keeps `q` responsive.
- The guard yield interval is 0.25 s of CPU time, not 1 s. Ctrl+C arrives as an event during a yield, so a shorter interval gives a faster reaction.
- Status updates are rate-limited to one each 0.25 s, because each update draws on the GPU.
- Unclosed comment, bogus comment, CDATA, `script` or `style` at the end of input gives no text (`spec/tokenizer.md` "Skipped markup"). It is an exception to the rule that a `<` with no `>` becomes text. Browsers hide this content too, so `a<!--` shows "a".
- Inline styles after a misnested end tag, and inline close at block close (`spec/layout.md` "The open-element stack"). A stray `<b>` must not make the rest of the page bold.
- Error popup keys (`spec/viewer.md` "Error popup"). Enter or Esc closes the popup, and other keys are ignored. A key press meant for scrolling then cannot close the popup by accident.
- Exact list of start tags that close `p` (`spec/layout.md` "The open-element stack"). The list follows the HTML standard, so pages written for browsers keep their structure. `dt` and `dd` close `p`. Table cells and form elements do not.
- Stats move out of `html` (`spec/probe.md`, `spec/cli.md`). The user approved the move: `--stats` and `--stats-out` are measurement tools, not user features, and `tools/probe2.lua` can collect the same keys through the seams without code in the release. The work is low priority.
- Corrected defect: `lowest_free` and the trace cover only the render and the settle after it, not the output.
- Print output loop has no memory check (`spec/cli.md` "Print output loop"). It keeps no new data, so it cannot run out of memory. It yields and checks Ctrl+C. This replaces the old "print-mode memory limit" section.

## Navigation

Explains `spec/navigation.md`, `spec/layout.md` "Links and anchors", `spec/url.md` "Link resolution" and `spec/viewer.md`. Decided by the user (2026-11-15).

- Packed integers and hashed ids. A table per link (`{line, col, href}`) costs much more memory than one integer plus a string. The link counts are measured: `tests/real/wikipedia.html` has 925 links and 3200 ids, and `tests/pages/large.html` has 3160 links. Thousands of tables would not fit. One Lua 5.3 integer holds the whole position of a link. An anchor is a 40-bit hash and a line in one integer, so no id string stays in memory (3200 ids on one real page). The cost is a possible hash collision (a wrong jump), which is accepted, and the limits (line delta 65535, id 256 bytes, href 2048 bytes). The lines keep their format, so the existing memory budget (`docs/rationale.md` "Design: Pipeline") does not change.
- Two phases. A load can fail before it gives any byte (cannot connect, 404, not HTML, a missing file). If the program released the old page first, every such failure would lose the page and the user's place. In phase 1 the old page stays in memory, and a failure shows a popup over it. Only after the source is open does the program commit and release the old page. The memory is too small to hold two pages, so the commit must come before the render, and the size check must come after the release: it must measure the free memory without the old page.
- Back fetches again. A history entry holds only the target, `top` and `sel`. A page in memory costs 66 bytes or more per line (`docs/rationale.md` "Design: Limits and graceful failure"), and the heap holds one page. Keeping pages is not possible. The cost is one more request and a page that can have changed.
- Backspace is Back only outside input fields. Backspace is also the key that deletes a character. When forms get input fields, a focused field must keep Backspace for text, or a typing error would leave the page. The rule is written now, so the form feature can rely on it.
- `z` aborts a load, as in the `links` browser. A load can take up to `CONNECT_TIMEOUT` (15 s) or more, and a slow page should not block the user. `q` asks for a confirmation and ends the program, and Ctrl+C ends the program. `z` is the only key that stops a load and keeps the session. Before the commit the old page is still there. After the commit it is released, so `z` loads the previous history entry.
- Same-document links never fetch. A fetch would cost a request and release the page for a jump inside it.
- Reload keeps `top` and `sel`. The user usually reloads the page to see the change at the same place.
