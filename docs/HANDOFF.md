# Handoff: oc-html

Date: 2026-11-17. Branch: `master` (the only branch). Last release: 0.7.0a. No unreleased changes.

## Status update 2026-11-17 (release 0.7.0a)

Slice S9 is done except the in-game run. `fetch.VERSION` is "0.7.0a", `releases/0.7.0a/` is built (13 files, with `tabs.lua` and `download.lua`), and `releases/latest` points to it. The in-game checklist is `docs/ingame/0.7.0a.md`. Not verified in game.

Next step: Run docs/ingame/0.7.0a.md in game. It also records the open checks: `os.setenv` inheritance, Ctrl+C in the nested shell, Ctrl+S char 19 or code 31, and the `--tabs auto` limit on 1 and 2 sticks.


## Status update 2026-11-17 (0.7.0a spec)

The 0.7.0a spec is written and waits for the user's approval. No code changed. The release stays 0.6.0a.

- New spec files: `spec/tabs.md` (keys, 8-tab limit, status prefix, showing a tab, the `switch` load mode, the tab record, the `pending` rule at a switch), `spec/shell.md` (tab-out sequence, the `HTML_TABOUT` refusal, risks), `spec/download.md` (the Ctrl+S flow, the link to a file, plain-text prompt, working directory, part file, disk space, keys) and `spec/background.md` (planned, 0.7.1a).
- User decisions (2026-11-17): the releases are split; in 0.7.0a a tab switch or `!` stops a load with the `pending` rule; background loads pause during the shell (0.7.1a); a resume without `ETag` or `Last-Modified` restarts from byte 0; the download prompt is plain text; the default download folder is the working directory.
- Revision (user, 2026-11-17): `c` asks ` Close tab? (y/n)` (the rules of the quit prompt); Ctrl+S downloads (char 19, or code 31 with Ctrl down; `d` stays free); a followed link to a file opens the save prompt with the open response and no error popup; the experimental option `--tabs <X|auto>` sets the tab limit. New in-game checks: the Ctrl+S key, the ZIP link, and the `auto` limit on 1 and on 2 sticks.
- Minecraft catches Esc in game. No new feature uses Esc. A blank Enter cancels each prompt.
- Changed specs: `spec/viewer.md`, `spec/navigation.md`, `spec/loading.md`, `spec/fetch.md`, `spec/cache.md`, `spec/errors.md`, `spec/cli.md`, `spec/testing.md`, `SPEC.md`. Reasons: `docs/rationale.md` "Tabs drop the document", "Shell tab-out is a nested shell", "Downloads stream to a part file".
- Open in-game checks: `os.setenv` inheritance in the nested shell, and Ctrl+C in the nested shell.
- Roadmap entries: `tasks/todo.md` "0.7.0a: Utility tabs" (steps S0 to S9) and "0.7.1a: Background loads (planned)" (probes P1 to P6, slices B1 to B8).

## Status update 2026-11-17 (in-game check of 0.6.0a)

The user ran `docs/ingame/0.6.0a.md` in game. All expected results match. Measured: about 9 to 10 KB/s; `wikipedia.com` needs about 90 KB of 120 KB (about 10 s) before the first screen is usable (a large head is a possible cause, not verified); keys react near immediately. See `docs/probe/FACTS.md` "Interactive loading (0.6.0a in game)". A todo item for a faster first screen is in `tasks/todo.md` Future work.

- Esc at the go prompt (closed 2026-11-17): in game, Minecraft catches Esc and removes focus from the OpenComputers screen. This is not a program bug. A blank Enter is the in-game cancel. The Esc code in `go_prompt` stays.
- All in-game checks are done (the user states it, 2026-11-17): the 0.5.0a checks, the 0.4.0a `#fragment` check, the 0.3.0a checklist and the three real pages. The second netprobe run is done (`docs/probe/FACTS.md` "Internet card (netprobe run 2)").

## Status update 2026-11-17 (interactive loading)

Interactive loading (`tasks/todo.md` "Interactive loading", step 6) is built and tested in the container. Not verified in game. Released as 0.6.0a.

- The load is a coroutine. `bin/html.lua` makes it, and the viewer loop (`lib/html/viewer.lua`, `drive`) runs it. The loader yields `wait` (the wait before the next poll), `slice` (the 0.1 s slice of the guard) and `commit` (once, after phase 1). Nothing calls `os.sleep` during a load. The viewer loop is the only reader of events. There is no key listener and no intent queue. The "interrupted" listener (`deps.on_interrupt`) stays and only sets the stop flag.
- Phase 1 (connect) runs in the coroutine, so the old page stays on screen and scrollable while the new page connects. The commit releases the old page and shows the live page.
- The live page: rows draw as lines complete, links join the selection when their start line is complete, End and PgDn stop at the last complete screen, the view never scrolls by itself, and the status line shows `<label> - Loading <n> KB of <m> KB`. Scroll, Tab, Up and Down and Enter on a loaded link work during the load.
- Enter on a link, `g` (after the text is submitted), `r` and Forward (with a later history entry) stop the load, then act. A page left before it finished is not cached. Back, Left, Backspace and `z` keep the abort rules. Forward at the last history entry does nothing and does not stop the load, also on the first load (`spec/navigation.md` "During a load", `bin/html.lua` `stop_load`).
- Tests: `docs/testing.md` "Interactive loading". `tests/run.lua` takes a file filter and a name filter.
- The in-game checklist is `docs/ingame/0.6.0a.md`.
- The roadmap to 1.0.0b is in `tasks/todo.md` and `SPEC.md` "Roadmap": 0.7.0a utility tabs, 0.8.0a session retention, 0.9.0a images, 1.0.0b the beta (`--stats` moves to `tools/probe2.lua`). Future work: more image formats, CSS, Data Card inflate and deflate.

## Status update 2026-11-15 (netprobe v1)

The user ran netprobe v1 in game (`datacollection/netprobe.txt`, ignored by git). The results are in `docs/probe/FACTS.md` "Internet card (netprobe v1)" and `docs/rationale.md` "Remote fetching: measurements (netprobe v1)".

- Code changes (not released): `lib/html/fetch.lua` maps a `finishConnect` failure to an HTTP status (404 by the URL as the reason, other codes by the Java message, `pcall(h.response)` first) and returns a response with the short page, `popup` and `notice`. `bin/html.lua` shows every fetch error after the frame, and a guard memory stop, as a popup in the viewer and keeps the session (exit 0 on quit). Print mode, the no-screen path and errors before the frame are unchanged.
- The fake card (`tests/shim/internet.lua`) copies the measured facts: callable-table methods, a limit of 4, `response()` nil until connect. `tools/netprobe.lua` has three fixes (callable tables, the `n3.before_connect` value, `response()` after a connect error).
- The N1, N3 and N10 risks below are answered. N9 is partly answered (same-scheme redirects are followed by the card, so the final URL is unknown). N4 to N7, N8, N12 (default config), N13 `--leak` and an https to https redirect stay open: the second run (2026-11-17) did not measure them (see `docs/probe/FACTS.md`).
- Unproven: that `response()` gives a status after a failed `finishConnect()`. The text match is the main path.
- Tests: see "Current state" for the commands. The suite and fuzz pass.

## Status update 2026-11-15 (navigation loop)

Roadmap items 2 and 2a are built and tested in the container. Not verified in game.

- `bin/html.lua`: `load_page(target, ctx)` only loads and never shows. It has two phases (phase 1: open the file or `fetch.open`; the commit, where `ctx.on_commit` releases the old page; then the size check and the render). It returns `ok`, `failed` (an error that keeps the session, with `committed`), `aborted`, `error`, `interrupted` or `quit`. `run_session(target, ctx)` is the loop for the viewer path: it holds the page on screen (`held`), the target of that page (`cur`), the history (`lib/html/history.lua`) and the next load request, and it acts on the viewer actions `link`, `back`, `forward`, `reload` and `go`. Print mode and the no-screen path call `load_page` once. `M.render` returns `lines, title, page`.
- The loop rules are in `spec/navigation.md`. Notes where the code settles a detail: a history entry of a link or go load is appended at the commit; a phase 1 failure with no page on screen (the first load) shows the broken page; a link that does not resolve gives a popup on Enter; the anchor lookup decodes `%XX`; `classify` returns the URL fragment (`parse_url` drops it).
- `layout.lua`: the first `<base href>` anywhere counts (`spec/layout.md` "Links and anchors").
- Tests: `tests/entry_test.lua` "Navigation" (the `nav` harness: real viewer, fake gpu, fake card, an event queue for the viewer and one for the key polls of each load). The sandbox has no `collectgarbage`, so no test checks that the old page is freed at the commit. The commit order is by code only.
- Open: the in game check list for item 2 and 2a is `docs/ingame/0.4.0a.md`. `--help` lists the new keys.

## Purpose

oc-html is an HTML viewer for OpenComputers (Minecraft mod, GT:NH, Lua 5.3, OpenOS). `html <file>` renders a local HTML file as readable text in a full-screen viewer and never crashes on bad input. The long-term goal (`AGENTS.md`) is a small text browser: remote pages, links, tabs, sessions and images.

## Current state

- Release: 0.6.0a (`releases/0.6.0a/`, `releases/latest` points to it, built from commit ab39880). 0.6.0a adds interactive loading ("Status update 2026-11-17"). 0.5.0a is the release before it. 0.3.0a (commit 8e15ec6) added the loading screen (the TUI opens at once and shows the phases and a byte count), the error popup, the rendering rules of 2026-11-14, the URL check before the TUI (`lib/html/url.lua`) and `tools/netprobe.lua`. 0.2.0a added remote fetching: `html http(s)://...` streams the response into the renderer. Remote fetching and the loading screen are implemented and not yet verified in game.
- Changes since 0.4.0a (release 0.5.0a): Tab and Shift+Tab wrap around; Up and Down move between links in document order (also left and right on one line) and scroll one page when no link is on screen. Keys during a load are no longer lost: z, Backspace and Left abort and go back at once, Right does nothing during a load. (In 0.5.0a a key listener caught these keys. The next release has no listener: the viewer loop reads the events, see "Status update 2026-11-17".) The abort race is fixed, and the page area clears when rendering starts. A disk cache in `/home/.cache/html` serves Back, Forward and abort recovery (limits: min(25% of free disk, 2 MiB), 16 pages, 64 KB disk reserve; emptied on exit; reload always fetches). The status hint shows `?:keys` on 80-column screens. The coroutine probe (`tools/coprobe.lua`) is not part of the release.
- Changes since 0.3.0a (release 0.4.0a): link following (Tab and Shift+Tab select links, the selected link shows in reverse video and its URL on the status line, Enter follows); Back (Left, Backspace), Forward (Right), reload (r), go-to prompt (g, spaces allowed), key list (?), abort a load (z); an #anchor link jumps without a refetch, the CLI URL fragment jumps too, and `<base href>` counts; links between local files, any local file opens as text when it is not HTML, remote `text/*` pages open; an error after the screen opens shows a popup and keeps the session, HTTP status popups show `[HTTP 404] Not Found` with the URL, a broken page is not rendered and offers a reload, a retryable error offers a reload; the measured internet card facts (netprobe v1) are in the code and the spec. An abort after the commit of a reload, back or forward keeps its history entry and shows the `[aborted]` page. The full status hint lists `?:keys`.
- Changes since 0.2.0a: the TUI opens at once with the loading status and a byte count (Ctrl+C exits, `q` asks while loading goes on); an error popup with `[OK]` for an error page whose body breaks off; misnested inline tags keep their styles, the exact list of tags that close `p`, `option` is a block break, a `<` with no `>` shows as text, `pre` drops its first newline, a leading `br` gives no blank line, the widest line is width minus 1; `--width` is limited to 2 up to the GPU maximum (160 with no screen); `--stats` and `--stats-out` are removed; `html: file not found` for a missing file; the installer prints `; old files kept` only after writing starts; an invalid URL is a usage error before the TUI opens; new tool `tools/netprobe.lua`.
- Older releases are frozen. 0.1.0a has a broken installer (OpenOS `file:close()` returns no values on success). 0.1.1a fixes it. 0.1.1a is the last local-only release.
- Works: everything in 0.1.1a (tokenizer, entities, UTF-8 cleaning, layout, viewer, `--print`, `--width`, `--no-rescale`, guard v2, Ctrl+C, error log, one-file installer), plus `lib/html/fetch.lua` (internet card client, HTTP status handling, redirects, limits).
- Verified in the container: `pwsh tests/docker/test.ps1` gives 300 passed, 0 failed, 0 skipped. `fuzz 1000` gives 0 failures. (1000 documents) A static check with `luac5.3 -p` and `luac5.3 -l` on `bin/`, `lib/` and `tools/` found no syntax error and no global outside the standard Lua names. The tests use a fake internet card in `tests/shim/internet.lua`.
- Verified in game: netprobe v1 (the card facts), the probes (`docs/probe/`), the tracer bullet and memory runs up to 0.0.4a, the 0.1.0a viewer and exit paths, and `html --print` on the pages in `tests/real/` (2026-11-14).
- Verified in game on 2026-11-17 (0.6.0a checklist): interactive loading, keys during a load, Enter on a loaded link, Back, reload, `g`, Forward, `z`, `q` during a load, the disk cache (Back serves the cache, the cache folder is empty after quit), the 1 MB page popup, Ctrl+C.
- Not verified in game (older text; the user states on 2026-11-17 that all these checks are done): the Esc key at the go prompt, the 0.5.0a checks listed in `tasks/todo.md` "Next recommended step" (Tab wrap, Up and Down on `c.html`, `z` and Left timing, no history entry after an abort, `r` and Forward on a finished page, cache limits, the `?:keys` hint), anchors, the key codes (Shift+Tab, NumPad 4 and 6), memory over many navigations, the 0.4.0a installer and upgrade, the loading screen, `docs/ingame/mvp.md` sections 4 and 6, and a low-RAM machine. The checklists are `docs/ingame/0.4.0a.md` and `docs/ingame/0.5.0a.md`.
- Risks in the fetch code (written before netprobe v1; the three marked N1, N3 and N10 are now measured, see "Status update 2026-11-15"). The fake card follows assumptions that no in-game measurement has confirmed yet.
  - N1: the exact methods of the internet component, the request handle and the `headers` type are unknown.
  - N3: it is unknown whether `response()` gives a value before the first `read`. The wait order in `fetch.open` depends on it.
  - N10: it is unknown whether the card gives the body of a 404 or 500 response. Java raises on these statuses. The code covers both cases, but decision D2 needs the real answer.
  - Full list: `docs/netprobe-plan.md` (N1 to N15).
- The spec rules decided on 2026-11-14 are in the code, except the move of the stats to probe2 (`spec/probe.md`, low priority). `--stats` and `--stats-out` are removed from `html`.
- `VERSION` in `lib/html/fetch.lua` is a constant. Update it by hand before each release. A release script run does not change it.

## Repository map

- `AGENTS.md`: project description and feature goals, for any agent.
- `SPEC.md`: the spec index (objective, scope, tech stack, component table, global rules, code style, boundaries).
- `spec/`: the normative rules, one file per component (`cli`, `pipeline`, `loading`, `tokenizer`, `text`, `layout`, `viewer`, `guard`, `errors`, `url`, `fetch`, `probe`, `installer`, `release`, `testing`, and the new `tabs`, `shell`, `download` and `background` (planned)). Informative content is in `docs/` (see "Moved spec content").
- `bin/html.lua`: entry point (arguments, error boundary, screen restore).
- `lib/html/`: `url.lua` (URL parsing, loads during the argument checks), `fetch.lua` (internet card client), `guard.lua` (yields, memory), `tokenizer.lua`, `entities.lua`, `text.lua` (UTF-8 cleaning), `layout.lua` (styled lines), `viewer.lua` (screen, keys).
- `tests/`: `run.lua` (sandboxed runner), `*_test.lua` (unit tests), `shim/` (OpenOS fakes, including a fake internet card), `cases/` (HTML with expected text), `real/` (saved real pages), `pages/large.html` (about 1 MB, generated), `fuzz.lua` and `fuzz-corpus/`, `docker/` (Dockerfile and `test.ps1`).
- `tools/`: `release.ps1` (makes a release), `mkinstall.lua` and `installer.lua` (one-file installer), `genpage.lua` (makes `tests/pages/large.html`), `probe.lua`, `probe2.lua`, `memprobe.lua`, `netprobe.lua` (in-game measurement scripts, not released).
- `releases/`: frozen release folders and the `latest` symlink.
- `docs/intent/mvp.md`: the confirmed MVP intent. `docs/probe/`: probe outputs and `FACTS.md` (measured machine facts). `docs/ingame/`: in-game checklists and results.
- `tasks/todo.md`: roadmap after the MVP. `tasks/archive/`: the finished MVP plan and task list.
- `types/openos.lua` and `.luarc.json`: LuaLS settings and OpenOS type stubs.
- `datacollection/` (ignored): raw files the user copied back from the game.

## Moved spec content

On 2026-11-14, `SPEC.md` was cut down to its normative rules. The informative parts moved to these files. Then the rules were split by component into `spec/`, and `SPEC.md` became the index. The user's decisions of 2026-11-14 (misnested tags, broken markup, `pre`, `--width` maximum, output width, error popup, installer suffix, loading screen) are now rules in `spec/`; their reasons are in `docs/rationale.md`.
- `docs/rationale.md`: reasons and measurements behind the rules (render stats, pipeline, viewer, memory guard), and the remote fetching decision log D1 to D6.
- `docs/testing.md`: test coverage, including the fetch tests and the table of arguments without a scheme.
- `docs/netprobe-plan.md`: measurements N1 to N15 and the `tools/netprobe.lua` plan.
- `docs/structure.md`: the repository tree outside `bin/` and `lib/`.
- `docs/code-style.md`: the code style example module.

## How to work

- Build the test image once: `docker build -t oc-html-test tests/docker`.
- All tests: `pwsh tests/docker/test.ps1`. There is no skipped test.
- Fuzz: `pwsh tests/docker/test.ps1 fuzz 1000 [SEED]`. Failures go to `tests/fuzz-failures/` (ignored). Turn each new failure into a unit test.
- Release: commit `bin/`, `lib/` and the installer tools first, then `pwsh tools/release.ps1 <version>` (for example `0.3.1a`). It runs the tests, copies the files, writes `files.txt`, `release.tar.gz` and `html-install.lua`, and updates `releases/latest` in the index. Then commit the new folder and `releases/latest`.
- Test code runs only in the container (sandbox flags in `spec/testing.md` "Sandbox"). Do not run it on the host.

## Pitfalls

- OpenOS `file:close()` returns no values on success. Treat `close` as failed only when it returns a reason. A full disk shows the error at `flush`, not at `write`.
- Release folders are frozen. Never change or delete one. Fix a bad release with a new version.
- Run docker commands from PowerShell (`pwsh`). Git Bash converts `/src`-style paths and breaks the docker mounts.
- `releases/latest` is a git symlink. On a host without symlink support it shows as a plain file with the version text.
- The game has no `collectgarbage`. Raw `freeMemory()` readings include garbage. See `docs/probe/FACTS.md` before you change the guard.
- Use plain `string.find` and `string.byte` on large text. `gsub` and `gmatch` over big strings can trip the "too long without yielding" limit.

## Conventions

- Commit subject: imperative, capitalized, no final period, for example "Add release 0.1.1a" or "Treat a silent close as success in file writes". The body says why. Each commit ends with a `Co-Authored-By` line.
- History is linear. No merge commits. Use rebase or cherry-pick.
- One release per commit ("Add release <version>"), separate from the code commit it is built from.
- Code style in `SPEC.md` "Code style": two-space indent, only `local`, modules return `M`, controlled errors are strings with the prefix `html: `.
- Tests: one `tests/<module>_test.lua` per module. Corpus cases are `tests/cases/<name>.html` with `<name>.txt`. When a bug is found, add the failing input to the tests (`SPEC.md` "Boundaries").
- Docs use short sentences in active voice.
- New instruction files are named `AGENTS.md`, not `CLAUDE.md`.

## Next step

User approval of the 0.7.0a spec, then slice S1. The 0.7.0a spec is written (2026-11-17): `spec/tabs.md`, `spec/shell.md`, `spec/download.md`; the planned 0.7.1a spec is `spec/background.md`. No code before the approval. The slices S1 to S9 (0.7.0a) and the probes P1 to P6 with the slices B1 to B8 (0.7.1a) are in `tasks/todo.md`.

## Open questions for the user

None. The earlier questions are answered: F1 is done, and remote responses are streamed.