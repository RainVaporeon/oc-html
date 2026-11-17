# Tasks: oc-html after the MVP

Spec: `SPEC.md` (index) and `spec/` (one file per component). Finished MVP plan and tasks: `tasks/archive/mvp-plan.md`, `tasks/archive/mvp-todo.md`.
Test command for every task: `pwsh tests/docker/test.ps1`. Fuzz run: `pwsh tests/docker/test.ps1 fuzz 1000`.

Current release: 0.7.0a (released, in game verified 2026-11-18; open items under "0.7.0a: Utility tabs"). Earlier: 0.6.0a (local and remote pages, loading screen, link following and navigation, interactive loading, disk cache). The features below come from `AGENTS.md`. `SPEC.md` "Scope" lists them as in scope. Each feature needs a short spec section and the user's approval before code starts (`SPEC.md` "Boundaries": the ask-first rule for moving an item into scope covers only CSS and JS, so these features need no ask for scope, but each still needs its spec section and approval).

Sizes: S = one module and its tests, M = two or three modules, L = a new subsystem with in-game measurements.

## Open MVP follow-up

### F1: Real pages print readable text in game

- [x] In game: `html --print` on `tests/real/wiki.html`, `tests/real/wikipedia.html` and `tests/real/manual.html` gives readable text on stdout.

**Result (2026-11-14):** Done. The user ran the check in game and answered "Yes": the text is readable.

**Note:** Checkpoint 3 of the MVP had this item. The container test only checks that these pages render more than zero lines.

**Files likely touched:** none (a manual check). The result is recorded here.

**Size:** S

## Roadmap (dependency order)

### 1. Remote fetching (http and https)

**Goal:** `html http://...` and `html https://...` fetch a page with the Internet Card and show it in the viewer, with the same guards as a local file.

**Spec:** `spec/fetch.md` and `spec/url.md` (roadmap item 1, approved 2026-11-14). Status: approved by the user on 2026-11-14.

**Main files likely touched:** `bin/html.lua` (argument parsing, a chunk reader for a response), a new `lib/html/fetch.lua`, `tests/shim/internet.lua` (a fake internet card), `tests/entry_test.lua`, a new `tests/fetch_test.lua`, `tests/corpus_test.lua`, `tests/fuzz.lua`, `types/openos.lua`. Later: `tools/netprobe.lua` and `tests/netprobe_test.lua`.

**Dependencies:** none. `M.render(read, width)` in `bin/html.lua` already takes a chunk reader, so a response can feed the same pipeline.

**Decided:**
- The response is streamed into the renderer. It is not saved to a cache file first (the user, 2026-11-14).
- The spec section answers the earlier questions: unknown size (the guard alone), redirects, status codes, timeouts, messages, charset and compression.
- D1 (Q1): use the card component directly, not the OpenOS `internet` library (the user, 2026-11-14).
- D2 (Q2): render the body of a 4xx or 5xx response. Show `[HTTP <code>]` in the viewer status line, and a stderr line in `--print` mode. Show a short `HTTP <code> <message>` page when the body is empty or cannot be read. Measurement N10 must confirm that the card gives the error body (the user, 2026-11-14).
- D3 (Q3): convert Latin-1 and Windows-1252 to UTF-8 only (the user, 2026-11-14).
- D4 (Q4): an argument without a scheme opens the local file when it exists. Otherwise, when it looks like a host, it is `http://<arg>`. The spec defines "looks like a host" and lists the edge-case tests (the user, 2026-11-14).

- D5 (Q5): an argument whose last label is `html`, `htm`, `xhtml`, `txt` or `lua` stays a local file. A missing `x.html` gives `html: file not found: x.html` (the user, 2026-11-14).
- D6 (Q6): the exit code is 0 when an error status (4xx, 5xx) renders, in the viewer and in `--print` mode (the user, 2026-11-14).

**Open questions:** none.

**Steps:**
- [x] The user answers Q1 to Q4 (2026-11-14).
- [x] The user approves the spec section and answers Q5 and Q6 (2026-11-14).
- [x] Write `tools/netprobe.lua` (`docs/netprobe-plan.md` "Probe script plan"; tests in `tests/netprobe_test.lua`, in-game steps in `docs/ingame/netprobe.md`) (2026-11-15, done).
- [x] The loading screen: the TUI opens at once, with phases and a byte count, and an invalid URL fails before it (`spec/loading.md`, 2026-11-15, released in 0.3.0a).
- [x] Run the in-game checklist `docs/ingame/0.3.0a.md` (the 0.4.0a checklist covers the same paths) (2026-11-17, the user states it is done).
- [x] Run `tools/netprobe.lua` in game and copy the report to `datacollection/netprobe.txt`. Record N1 to N15 in `docs/probe/FACTS.md` (2026-11-15, netprobe v1: the measured values are in `docs/probe/FACTS.md` "Internet card (netprobe v1)").
- [x] Update the spec with the measured values (redirects, error statuses, limit, API shape). The error status is mapped from the connect failure, and errors after the frame keep the session (`spec/fetch.md`, `spec/loading.md`).
- [x] A second netprobe run after the push (2026-11-17, `datacollection/netprobe-2.txt`; it confirms the first run and N4 to N7, N13 and the https to https redirect are still not measured, see `docs/probe/FACTS.md` "Internet card (netprobe run 2)"): N4 to N7 (large reads, memory, 1 MB page), N8, N12 under the default address config, N13 with `--leak`, and an https to https redirect. The probe now records `response()` after a connect error and the value of `n3.before_connect`.
- [x] Implement `fetch.lua`, the fake card and the tests (2026-11-14, committed in 010a24e, released in 0.2.0a). `spec/fetch.md` "Implementation notes" lists the choices. The measured values can still change the timeouts, the chunk size and the wait order.
- [x] In game: fetch the three real pages (`tests/real/`) (2026-11-17, the user states it is done).
- [x] In game: the 1 MB page while you scroll it (2026-11-17, `docs/ingame/0.6.0a.md` check 5.1).

**Size:** L

### 2. Link following and navigation

**Goal:** Select a link in the viewer and open its target. Go back to the previous page.

**Spec:** `spec/navigation.md` and the link sections of `spec/layout.md`, `spec/url.md`, `spec/viewer.md` (items 2 and 2a, approved by the user on 2026-11-15).

**Build steps:**
- [x] S1: `url.resolve` and `text/*` acceptance (`spec/url.md`, `spec/fetch.md`).
- [x] S2: link and anchor recording in layout.
- [x] S3: the history module.
- [x] S4: viewer keys, cursor, reload, go prompt and the `?` popup.
- [x] S5: refactor `bin/html.lua`.
- [x] S6: the navigation loop with reload, back, forward, abort and anchors.
- [x] In game: follow links, back, forward, reload, `g`, `z` and anchors on real pages (`docs/ingame/0.4.0a.md`) (2026-11-17, the user states it is done).
- [x] Released in 0.4.0a (2026-11-15). Next: the in-game checklist, then 0.7.0a (utility tabs).

**Result (2026-11-15):** Released in 0.4.0a. Built and tested in the container (the suite and fuzz pass). The in-game check is open. The open design questions below are answered by `spec/navigation.md`, `spec/url.md` and `spec/viewer.md`.

**Main files likely touched:** `lib/html/layout.lua` (keep the `href` of each link; today it only sets the link style), `lib/html/viewer.lua` (link selection keys, a back key), `bin/html.lua` (a page-load loop), a new URL resolver module and its tests.

**Dependencies:** 1 (remote fetching). Local relative links can work without it.

**Open design questions:**
- How to store link targets without breaking the one-string-per-line format and its memory budget.
- Keys for link selection, and how the selected link shows on depth 1.
- Relative URL resolution, fragments (`#id`) and links to non-HTML files.
- History size and what one history entry holds.
- After a redirect that the card follows, the final URL is unknown (the card gives none). Relative links may then resolve against the requested URL, which is wrong when the redirect changed the directory. Consider `<base href>`.

**Size:** L

### 2a. Visible cursor

**Goal:** Show a visible cursor, so the user sees what is selected (a link) or where input goes (a form field).

**Spec:** `spec/navigation.md` and `spec/viewer.md` (approved by the user on 2026-11-15, built with item 2, step S4).

**Main files likely touched:** `lib/html/viewer.lua` (draw the cursor, move it with the selection keys), `lib/html/layout.lua` (positions of selectable items).

**Status (2026-11-15):** Done, built with item 2, step S4 (reverse-video highlight of the selected link, `-> <target>` in the status line). Open: the in game check (`docs/ingame/0.4.0a.md`; depth 1, depth 4 and depth 8).

**Dependencies:** 2 (link selection). Form input needs form support, which is not on the roadmap yet.

**Open design questions:**
- How the cursor shows on depth 1, where there are no colors.
- Whether the cursor is a highlight of the item or the GPU or `term` cursor.

**Size:** S

### 3. Roadmap to 1.0.0b

Each version below needs its own short spec section and the user's approval before code starts. Sizes: S, M, L as above.

#### 0.6.0a: Loading while you browse (current release, built 2026-11-17)

**Goal:** Scroll, select and follow links in the part of a page that is already laid out, while the rest loads. See "Interactive loading" below. Built and tested in the container. The in-game check ran on 2026-11-17: all expected results match (`docs/ingame/0.6.0a.md`; the measured values are in `docs/probe/FACTS.md` "Interactive loading (0.6.0a in game)"). Esc at the go prompt: Minecraft catches Esc in game and removes focus from the screen, so a blank Enter is the in-game cancel (decided 2026-11-17; the Esc code stays).

**Size:** L

#### 0.7.0a: Utility tabs (done: released, in game verified 2026-11-18)

**Goal:** Three features that let the user work beside one page.
- Browser tabs: keep several open pages with their state (URL, scroll position, history) and switch between them.
- Shell tab-out: leave the browser to use the shell, then return to the same state.
- Download: save a page or a linked file to disk.

**Main files likely touched:** `lib/html/viewer.lua`, `bin/html.lua`, a new tab state module, a new download module that uses the write checks of `M.write_text` (`close` with no return values is a success).

**Dependencies:** navigation (item 2).

**Open design questions:**
- Memory: does each tab keep its lines, or only its URL and position, and render again on switch?
- Keys and the status line for tabs.
- The internet card allows 4 open connections (measured, netprobe v1). Tabs must not hold a handle open while they are idle. Close a handle before the next request, or the 5th request fails with `too many open connections`.
- A tab that fails to load keeps the session: errors after the frame show a popup and do not end the program (`spec/loading.md` "Errors after the frame").
- How to keep the state while the shell runs: a background process, or save and resume (0.8.0a)?
- Download target path, overwrite rule and free-space check (the installer has a free-space check to reuse).

**Size:** L

**Spec (2026-11-17):** `spec/tabs.md`, `spec/shell.md`, `spec/download.md`. The design questions above are answered there. The user decided on 2026-11-17: the releases are split (background loads are 0.7.1a), a tab switch or `!` during a load stops the load with the `pending` rule, the download prompt is plain text, the default download folder is the working directory. No feature uses Esc (Minecraft catches it in game), and a blank Enter cancels each prompt.

**Steps:**
- [x] Write the 0.7.0a spec (2026-11-17, waiting for approval).
- [ ] S0: the user approves the 0.7.0a spec. No code before the approval.
- [ ] S1: `history` export and import. New pure `lib/html/tabs.lua`: `new(cap)`, `add_after`, `close`, `next` and `prev` with wrap, `active`, `count`, `snapshot`, `restore`. Files: `lib/html/history.lua`, `lib/html/tabs.lua`, `tests/history_test.lua`, `tests/tabs_test.lua`. Tests: export and import round trip, wrap, close order, limit.
- [ ] S2: refactor `run_session`: `hist`, `guesses`, `held`, `cur`, `top`, `sel`, `popup` and the broken state go into one active-tab record. No behavior change. File: `bin/html.lua`. Tests: the existing suite stays green.
- [ ] S3: viewer. `classify` gets `t`, `c`, `<`, `>`, `!` and Ctrl+S (char 19, or code 31 with `isControlDown`; `d` stays free). New options `opts.tab_label`, `opts.notice`, `opts.quit_text`, `enter_held` at open, and the job kind. The generic prompt (plain initial text, cursor at the end). The y-only confirm. The ` Close tab? (y/n)` prompt (the rules of the quit prompt). The key list text (`Ctrl+S: download, !: shell`). Files: `lib/html/viewer.lua`, `tests/viewer_test.lua`. Tests: each new key returns its action, Ctrl+S works with char 19 and with code 31 plus a fake `isControlDown`, `d` returns nothing, `c` shows the close prompt (`y` returns `tab_close`, another key does not), the save prompt shows the default path, Backspace deletes one character, a blank Enter cancels, the prefix shows, the key list fits 16 rows.
- [x] S4: tabs in the session loop: `t` (link and prompt), `<`, `>`, `c`, the `switch` mode, the stop at a switch with `pending`, the broken and aborted tab state, the limit notice `tab limit: <n> tabs`, the quit text, `M.USAGE`, and the experimental option `--tabs <X|auto>` (the parse and the usage error, the `auto` formula, the memory check of `t` with the notice `not enough memory for a new tab`, `guard.MEMORY_RESERVE` exported). Files: `bin/html.lua`, `lib/html/guard.lua`, `tests/entry_test.lua`. Tests: `--tabs 33` and `--tabs x` give the usage error with exit code 2, `--tabs 2` limits to 2 tabs, `--tabs auto` with a fake `settled_free` gives the formula result; `c` with `n` keeps the tab and its load; open a tab, switch, and return at the saved `top` with no request; a switch in phase 1, then a return, loads the pending link; a switch after the commit, then a return, fetches.
- [x] S5: shell tab-out: `deps.shell`, the `HTML_TABOUT` guard in `main`, the screen reopen, the event drain, `enter_held`. Files: `bin/html.lua`, `lib/html/viewer.lua`, `types/openos.lua`, `tests/entry_test.lua`. Tests: `!` closes the screen, calls the fake shell and reopens; the same tab and `top` come back; a shell error shows a popup; a nested start refuses.
- [ ] S6: fetch `raw` and `file_ok` options (`is_file`, `filename`, the read timeout that starts at the first read of a kept response). Files: `lib/html/fetch.lua`, `tests/fetch_test.lua`. Tests: `image/png` is accepted with `raw`, no Latin-1 step; with `file_ok`, `application/zip` and `text/html` with `Content-Disposition: attachment` give an open response with `is_file` and `filename`, and no body is read.
- [ ] S7: download module: default name, path resolve, part file, streaming, the space checks, stop, and the `write`, `flush` and `close` checks. It makes no `component` calls. `game_deps` gets `space`, `remove`, `rename` and `cwd`. Files: `lib/html/download.lua`, `tests/download_test.lua`, `bin/html.lua`. Tests: default names, no part file after a stop or an error, an existing file stays after a failure, a full-disk flush error.
- [x] S8: download wiring: the Ctrl+S flow, the link to a file (Enter, `t`, the `g` text: the save prompt with the open response, no history change, a blank Enter closes the handle), the save prompt, the overwrite prompt, the job in the `bg` slot, the progress status, the end notices, the refused keys. Files: `bin/html.lua`, `lib/html/viewer.lua`, `tests/entry_test.lua`. Tests: Ctrl+S on a link saves the bytes, Ctrl+S during a load is refused, a followed link to a ZIP file opens the prompt and keeps the history and the page, `z` stops, the overwrite prompt shows.
- [x] S9 (done except the in-game run): release: `fetch.VERSION = "0.7.0a"`, `docs/ingame/0.7.0a.md`, `pwsh tools/release.ps1 0.7.0a`. The release has 13 files.
- Each slice ends with `pwsh tests/docker/test.ps1` and `pwsh tests/docker/test.ps1 fuzz 1000`.
- The in-game checklist outline for `docs/ingame/0.7.0a.md` has these parts: install and upgrade; tabs (open, switch, limit, close with the ` Close tab? (y/n)` prompt (`y`, Enter, `n`, another key, a load that goes on behind it), switch during a load, memory over many switches, quit text, the key list on 50x16; the experimental `--tabs`: `--tabs 0`, `--tabs 33` and `--tabs x` give the usage error, `--tabs 3` stops at 3 tabs with `tab limit: 3 tabs`, record the `auto` limit on 1 and on 2 sticks of tier 3 memory, then open tabs up to the limit with Wikipedia pages and record the free memory, and check the notice `not enough memory for a new tab`); shell tab-out (restore, `exit`, the held Enter, a changed resolution, the nested refusal, Ctrl+C, memory); download (Ctrl+S: record which one the game sends, char 19 or code 31 with Ctrl, and that `d` does nothing; text, raw HTML, binary, 1 MB, `z`, overwrite, directory, disk space, 404, local link, refused keys, `q`; a link to a ZIP file opens the ` Save to: ` prompt with no popup, a blank Enter cancels with the page and the history as before, and an accepted path downloads the file; a link with `Content-Disposition: attachment`); regression.
- In-game checks of the open risks: `os.setenv` inheritance in the nested shell, and Ctrl+C in the nested shell (`spec/shell.md` "Risks").

**Open questions:** none.

Open items of 0.7.0a (2026-11-18): 4.7 (memory during a 1 MB download) is not measurable, because `!` is blocked during a download. 4.21 (read-only filesystem wording) is not checked: no read-only disk. 4.1, 4.6 and 4.12 have no recorded values. Retune of the `--tabs auto` formula (possible later work: 8 tabs on 1 stick still left about 400K free; `docs/probe/FACTS.md` "0.7.0a in game"). Recheck 3.1 in game (the fix sets the cursor to (1, 1) and flushes stdout before the shell line).

#### 0.7.1a: Background loads (planned, deferred; not before 0.8.0a unless the user asks)

**Goal:** A tab keeps loading to disk when the user leaves it, when resources allow. **Spec:** `spec/background.md` (planned, not approved). It needs the probes P1 to P6 and the user's approval before code starts. User decisions (2026-11-17): background loads pause during the shell, and a resume without `ETag` or `Last-Modified` restarts from byte 0.

**Steps:**
- [ ] Probes P1 to P6 in game (`tools/netprobe.lua`, a new `tools/fileprobe.lua`, `docs/ingame/fileprobe.md`, `docs/netprobe-plan.md`, `tests/netprobe_test.lua` for the new groups). P1 to P4: the `Range` and `If-Range` headers, a redirect that keeps `Range`, `ETag` and `Last-Modified`, and an idle handle. P5: a second handle reads a file that another handle writes, and `"ab"` appends. P6: the memory of one background job. They gate B5 and B6. Results go into `datacollection/` and `docs/probe/FACTS.md`.
- [ ] B1: cache: in-flight bytes, `suspend` and `resume`, `in_use`, suspended parts as entries. Files: `lib/html/cache.lua`, `tests/cache_test.lua`.
- [ ] B2: loader detach exit. `lib/html/jobs.lua` (limit 2, round robin, oldest-first suspension). The detach checks. The `opts.background` hook in the viewer loop, prompts and popups. The prefix markers. Files: `bin/html.lua`, `lib/html/jobs.lua`, `lib/html/viewer.lua`, `tests/jobs_test.lua`, `tests/entry_test.lua`, `tests/viewer_test.lua`.
- [ ] B3: the fallbacks: `guard.on_low`, the retry after `too many open connections`, writer false. Files: `lib/html/guard.lua`, `bin/html.lua`, `tests/guard_test.lua`, `tests/entry_test.lua`.
- [ ] B4: the job state in the tab record; showing a tab with a job. Files: `lib/html/tabs.lua`, `bin/html.lua`, `tests/tabs_test.lua`.
- [ ] B5: resume: the fetch option `range = { offset, validator }`, the 206 and 200 handling, a restart when there is no validator. Files: `lib/html/fetch.lua`, `tests/fetch_test.lua`, `tests/shim/internet.lua`.
- [ ] B6: promote on return (only if P5 passes), else wait and then render. File: `bin/html.lua`.
- [ ] B7: shell pause: jobs pause during the shell, and the timers reset at the return. Files: `bin/html.lua`, `tests/entry_test.lua`.
- [ ] B8: release 0.7.1a: `fetch.VERSION`, `docs/ingame/0.7.1a.md`, `pwsh tools/release.ps1 0.7.1a`.

**Size:** L

#### 0.8.0a: Session retention

**Goal:** Save the browsing state and resume it after a restart.

**Main files likely touched:** `bin/html.lua` (`html` with no arguments, `-r`), a new session module, `tests/entry_test.lua`.

**Dependencies:** 0.7.0a (tabs, done).

**Inputs from 0.7.0a:** the tab snapshot in `spec/tabs.md` (`{ v = 1, active, list }`; a loading job is saved as stopped). The cache `clear()` on exit (a resumed session must not rely on cache files). Open question: where the session file lives.

**Agreed design (`SPEC.md` "Later: sessions"):** an 8-digit lowercase hex ID, `html` with no arguments starts a new session, `html -r <id>` resumes that session, `html -r` resumes the last session.

**Open design questions:** the stored content and the storage location, the file format (for example `serialization`), what happens with a damaged session file, and cleanup of old sessions on a small disk.

**Size:** M

#### 0.9.0a: Images

**Goal:** Show images on a Tier 2 or Tier 3 GPU, as close to the source as possible. PNG comes first. If other image formats have a similar structure, this version can include more media types.

**Main files likely touched:** new modules for PNG decode and drawing, `lib/html/layout.lua` (an image placeholder with a size), `lib/html/viewer.lua`.

**Dependencies:** remote fetching (item 1). A PNG decoder needs inflate: in Lua, or with the Data Card (future work below).

**Open design questions:**
- Memory and time budget for the decode in game.
- Pixel mapping (for example two pixels per cell with half-block characters) and the color limits of depth 4 and depth 8.
- Fallback when the GPU or the memory is too small: keep `[img: <alt>]`.

**Size:** L

#### 1.0.0b: Official beta release

**Goal:** The first beta. Move `--stats` away from `html` to `tools/probe2.lua` (`spec/probe.md`).

**Size:** S

#### Future work

- More image formats.
- CSS support (planned, `AGENTS.md` "future goals").
- Investigate a faster first screen for pages with a large head (wikipedia: about 90 KB before the first screen). Measured 2026-11-17: `docs/probe/FACTS.md` "Interactive loading (0.6.0a in game)". The cause is not verified.
- Inflate and deflate with the Data Card (optional hardware: the program must work without it). Open: which `Content-Encoding` values the card can inflate, and the limits on input size.

## Next recommended step

Write the 0.8.0a spec: session retention (`SPEC.md` "Later: sessions", "0.8.0a: Session retention" in this file). The 0.7.1a background loads are planned and deferred; they do not start before 0.8.0a unless the user asks.

All in-game checks are done (2026-11-17; the user states that the 13 open 0.5.0a checks, the 0.4.0a `#fragment` check, the 0.3.0a checklist and the three real pages are done). The second netprobe run is done. Esc at the go prompt is closed: in game Minecraft catches Esc and removes focus from the screen, and a blank Enter cancels the prompt.

### Interactive loading (user request, 2026-11-15, design C1)

**Goal:** While a page loads, the user can scroll, select and follow links in the part that is already laid out.

- [x] The coroutine probe ran in game (`docs/probe/FACTS.md` "Coroutines (coprobe v1)").
- [x] Spec: `spec/loading.md` "Content during load" and "Keys during load", `spec/navigation.md` "During a load", `spec/viewer.md` "Live source", `spec/guard.md` "Yield hook", `spec/fetch.md`; reasons in `docs/rationale.md` "Interactive loading".
- [x] The loader is a coroutine that the viewer loop drives. Nothing calls `os.sleep` during a load. The viewer loop is the only reader of events (no key listener).
- [x] The live page: rows draw as lines complete, the selection list grows, the view never scrolls by itself, the status line shows `<label> - Loading <n> KB of <m> KB`.
- [x] Phase 1 runs in the coroutine: the old page stays usable while the program connects. The commit shows the new empty live page at once.
- [x] Enter on a link, `g`, `r` and Forward stop the load and act. Back, Left, Backspace and `z` keep the abort rules.
- [x] Tests in the container (`docs/testing.md` "Interactive loading").
- [x] In-game check, done 2026-11-17 (`docs/ingame/0.6.0a.md`; all expected results match): the first screen is usable at a realistic 3 KB/s; keys respond during a render (the 0.1 s slice); no key is lost; the memory guard still works with the slices (GC from the 11 slice yields of a settle); Ctrl+C, `q` and `z` during phase 1 and during the body.
