# Tasks: oc-html after the MVP

Spec: `SPEC.md` (index) and `spec/` (one file per component). Finished MVP plan and tasks: `tasks/archive/mvp-plan.md`, `tasks/archive/mvp-todo.md`.
Test command for every task: `pwsh tests/docker/test.ps1`. Fuzz run: `pwsh tests/docker/test.ps1 fuzz 1000`.

Current release: 0.6.0a (local and remote pages, loading screen, link following and navigation, interactive loading, disk cache). The features below come from `AGENTS.md`. `SPEC.md` "Scope" lists them as in scope. Each feature needs a short spec section and the user's approval before code starts (`SPEC.md` "Boundaries": the ask-first rule for moving an item into scope covers only CSS and JS, so these features need no ask for scope, but each still needs its spec section and approval).

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
- [ ] Run the in-game checklist `docs/ingame/0.3.0a.md` (the 0.4.0a checklist covers the same paths).
- [x] Run `tools/netprobe.lua` in game and copy the report to `datacollection/netprobe.txt`. Record N1 to N15 in `docs/probe/FACTS.md` (2026-11-15, netprobe v1: the measured values are in `docs/probe/FACTS.md` "Internet card (netprobe v1)").
- [x] Update the spec with the measured values (redirects, error statuses, limit, API shape). The error status is mapped from the connect failure, and errors after the frame keep the session (`spec/fetch.md`, `spec/loading.md`).
- [ ] A second netprobe run after the push: N4 to N7 (large reads, memory, 1 MB page), N8, N12 under the default address config, N13 with `--leak`, and an https to https redirect. The probe now records `response()` after a connect error and the value of `n3.before_connect`.
- [x] Implement `fetch.lua`, the fake card and the tests (2026-11-14, committed in 010a24e, released in 0.2.0a). `spec/fetch.md` "Implementation notes" lists the choices. The measured values can still change the timeouts, the chunk size and the wait order.
- [ ] In game: fetch the three real pages (`tests/real/`). Open.
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
- [ ] In game: follow links, back, forward, reload, `g`, `z` and anchors on real pages (`docs/ingame/0.4.0a.md`).
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

**Goal:** Scroll, select and follow links in the part of a page that is already laid out, while the rest loads. See "Interactive loading" below. Built and tested in the container. The in-game check ran on 2026-11-17: all expected results match (`docs/ingame/0.6.0a.md`; the measured values are in `docs/probe/FACTS.md` "Interactive loading (0.6.0a in game)"). One note is open: Esc at the go prompt (see "Next recommended step").

**Size:** L

#### 0.7.0a: Utility tabs

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

#### 0.8.0a: Session retention

**Goal:** Save the browsing state and resume it after a restart.

**Main files likely touched:** `bin/html.lua` (`html` with no arguments, `-r`), a new session module, `tests/entry_test.lua`.

**Dependencies:** 0.7.0a (tabs).

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

The in-game check of 0.6.0a is done (2026-11-17). Its checks cover part of the older checklists. Remaining in-game checks, first:

1. Esc at the go prompt (`docs/ingame/0.6.0a.md` check 3.4). The user wrote: "`Esc` exits the screen, instead a blank input is used to substitute exit, which works." The code and `spec/navigation.md` say Esc cancels the prompt (`lib/html/viewer.lua` `go_prompt`, tested). It is not clear what "exits the screen" means. Ask the user: did the whole program quit, or only the prompt close? Run it again and write down what the screen shows after Esc.
2. 0.5.0a checks that 0.6.0a does not cover: 1.2 (upgrade over 0.4.0a), 2.1 to 2.3 and 2.5 (Tab wrap and Up and Down on `c.html`, a page with no link), 3.1 and 3.3 (`z` and Left during a load, with reaction times), 4.3 (no history entry after an abort), 5.4 (`r` on a finished page fetches again), 5.5 (Forward after Back shows without a download), 5.6 (cache limits), 6.1 (the `?:keys` hint on 80 columns).
3. 0.4.0a: anchors (`#fragment` links). The other 0.4.0a paths are covered (see below). The 0.3.0a checklist is not covered: its loading screen and error popup steps are not compared yet.
4. The three real pages fetched over the network (`tests/real/`).
5. The second netprobe run (N4 to N7, N8, N12, N13 with `--leak`, https to https redirect).

Covered by 0.6.0a (2026-11-17), 0.5.0a check -> 0.6.0a check: 1.1 -> 1.1; 2.4 -> 2.6; 3.2 -> 3.2; 3.4 -> 3.5; 3.5 -> 3.7; 3.6 -> 2.8 and 3.2; 4.1 -> 5.3 and 2.9; 4.2 -> 5.3; 5.1 -> 4.2; 5.2 and 5.3 -> 4.3; 7 (coroutine probe) ran on 2026-11-15 (`docs/probe/FACTS.md`). 0.4.0a: Enter on a link -> 3.1; Back -> 3.2; reload -> 3.3; `g` -> 3.4; Forward -> 3.6; `z` -> 5.3.

After these, start 0.7.0a (utility tabs: browser tabs, shell tab-out, download). It needs its spec section and the user's approval first. The 0.7.0a spec does not need the remaining checks, so it can start in parallel.

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
