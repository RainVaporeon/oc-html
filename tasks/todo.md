# Tasks: oc-html after the MVP

Spec: `SPEC.md` (index) and `spec/` (one file per component). Finished MVP plan and tasks: `tasks/archive/mvp-plan.md`, `tasks/archive/mvp-todo.md`.
Test command for every task: `pwsh tests/docker/test.ps1`. Fuzz run: `pwsh tests/docker/test.ps1 fuzz 1000`.

Current release: 0.2.0a (local files and remote fetching). The features below come from `AGENTS.md`. `SPEC.md` "Scope" lists them as in scope. Each feature needs a short spec section and the user's approval before code starts (`SPEC.md` "Boundaries": the ask-first rule for moving an item into scope covers only CSS and JS, so these features need no ask for scope, but each still needs its spec section and approval).

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
- [x] Write `tools/netprobe.lua` (`docs/netprobe-plan.md` "Probe script plan"; tests in `tests/netprobe_test.lua`, in-game steps in `docs/ingame/netprobe.md`) (2026-11-15).
- [ ] Run `tools/netprobe.lua` in game and copy the report to `datacollection/netprobe.txt`. Record N1 to N15 in `docs/probe/FACTS.md`.
- [ ] Update the spec with the measured values (timeouts, chunk size, redirect and error behavior).
- [x] Implement `fetch.lua`, the fake card and the tests (2026-11-14, committed in 010a24e, released in 0.2.0a). `spec/fetch.md` "Implementation notes" lists the choices. The measured values can still change the timeouts, the chunk size and the wait order.
- [ ] In game: fetch the three real pages and a 1 MB page.

**Size:** L

### 2. Link following and navigation

**Goal:** Select a link in the viewer and open its target. Go back to the previous page.

**Main files likely touched:** `lib/html/layout.lua` (keep the `href` of each link; today it only sets the link style), `lib/html/viewer.lua` (link selection keys, a back key), `bin/html.lua` (a page-load loop), a new URL resolver module and its tests.

**Dependencies:** 1 (remote fetching). Local relative links can work without it.

**Open design questions:**
- How to store link targets without breaking the one-string-per-line format and its memory budget.
- Keys for link selection, and how the selected link shows on depth 1.
- Relative URL resolution, fragments (`#id`) and links to non-HTML files.
- History size and what one history entry holds.

**Size:** L

### 2a. Visible cursor

**Goal:** Show a visible cursor, so the user sees what is selected (a link) or where input goes (a form field).

**Spec:** `SPEC.md` "Scope" (in-scope item "Visible cursor"). A short spec section is still needed.

**Main files likely touched:** `lib/html/viewer.lua` (draw the cursor, move it with the selection keys), `lib/html/layout.lua` (positions of selectable items).

**Dependencies:** 2 (link selection). Form input needs form support, which is not on the roadmap yet.

**Open design questions:**
- How the cursor shows on depth 1, where there are no colors.
- Whether the cursor is a highlight of the item or the GPU or `term` cursor.

**Size:** S

### 3. Tabs

**Goal:** Keep several open pages with their state (URL, scroll position) and switch between them.

**Main files likely touched:** `lib/html/viewer.lua`, `bin/html.lua`, a new tab state module.

**Dependencies:** 2 (navigation).

**Open design questions:**
- Memory: does each tab keep its lines, or only its URL and position, and render again on switch?
- Keys and the status line for tabs.

**Size:** M

### 4. Shell tab-out and download

**Goal:** Leave the viewer for the shell and come back to the same state. Save a page or a linked file to disk.

**Main files likely touched:** `lib/html/viewer.lua` (screen save and restore), `bin/html.lua`, a new download module that uses the write checks of `M.write_text` (`close` with no return values is a success).

**Dependencies:** 3 (tabs).

**Open design questions:**
- How to keep the state while the shell runs: a background process, or save and resume through sessions (5)?
- Download target path, overwrite rule and free-space check (the installer has a free-space check to reuse).

**Size:** M

### 5. Session retention

**Goal:** Save the browsing state and resume it after a restart.

**Main files likely touched:** `bin/html.lua` (`html` with no arguments, `-r`), a new session module, `tests/entry_test.lua`.

**Dependencies:** 4 (shell tab-out and download), 3 (tabs).

**Agreed design (`SPEC.md` "Later: sessions"):** an 8-digit lowercase hex ID, `html` with no arguments starts a new session, `html -r <id>` resumes that session, `html -r` resumes the last session.

**Open design questions:**
- The stored content and the storage location (not decided).
- The file format (for example `serialization`) and what happens with a damaged session file.
- Cleanup of old sessions on a small disk.

**Size:** M

### 6. Images (PNG first)

**Goal:** Show images on a Tier 2 or Tier 3 GPU, as close to the source as possible. PNG comes first.

**Main files likely touched:** new modules for PNG decode and drawing, `lib/html/layout.lua` (an image placeholder with a size), `lib/html/viewer.lua`.

**Dependencies:** 1 (remote fetching). A PNG decoder needs inflate: in Lua, or with the Data Card (see the side item below).

**Open design questions:**
- Memory and time budget for the decode in game.
- Pixel mapping (for example two pixels per cell with half-block characters) and the color limits of depth 4 and depth 8.
- Fallback when the GPU or the memory is too small: keep `[img: <alt>]`.

**Size:** L

### Side item: Data Card inflate and deflate

**Goal:** Use the Data Card, when present, to inflate compressed responses and to save traffic.

**Main files likely touched:** `lib/html/fetch.lua` (from 1), a shim for the data component.

**Dependencies:** 1 (remote fetching). Optional hardware: the program must work without a Data Card.

**Open design questions:** which `Content-Encoding` values the Data Card can inflate, and the limits on input size.

**Size:** S

## Low priority

- [ ] Move stats collection from html into tools/probe2.lua (spec/probe.md). Low priority.

## Next recommended step

Run `tools/netprobe.lua` in game (`docs/ingame/netprobe.md`) to measure N1 to N15.
