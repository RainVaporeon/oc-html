# Handoff: oc-html

Date: 2026-11-14. Branch: `master` (the only branch). Last release: 0.2.0a.

## Purpose

oc-html is an HTML viewer for OpenComputers (Minecraft mod, GT:NH, Lua 5.3, OpenOS). `html <file>` renders a local HTML file as readable text in a full-screen viewer and never crashes on bad input. The long-term goal (`AGENTS.md`) is a small text browser: remote pages, links, tabs, sessions and images.

## Current state

- Release: 0.2.0a (`releases/0.2.0a/`, `releases/latest` points to it). It adds remote fetching: `html http(s)://...` streams the response into the renderer. Remote fetching is implemented and not yet verified in game.
- Older releases are frozen. 0.1.0a has a broken installer (OpenOS `file:close()` returns no values on success). 0.1.1a fixes it. 0.1.1a is the last local-only release.
- Works: everything in 0.1.1a (tokenizer, entities, UTF-8 cleaning, layout, viewer, `--print`, `--width`, `--no-rescale`, guard v2, Ctrl+C, error log, one-file installer), plus `lib/html/fetch.lua` (internet card client, HTTP status handling, redirects, limits).
- Verified in the container: `pwsh tests/docker/test.ps1` gives 140 passed, 0 failed, 0 skipped. `fuzz 1000` with seed 1794677367 gives 0 failures. The tests use a fake internet card in `tests/shim/internet.lua`.
- Verified in game: the probes (`docs/probe/`), the tracer bullet and memory runs up to 0.0.4a, the 0.1.0a viewer and exit paths, and `html --print` on the pages in `tests/real/` (2026-11-14).
- Not verified in game: all remote fetching, `docs/ingame/mvp.md` sections 4 and 6, a low-RAM machine, and the 0.1.1a installer.
- Risks in the fetch code. The fake card follows assumptions that no in-game measurement has confirmed yet.
  - N1: the exact methods of the internet component, the request handle and the `headers` type are unknown.
  - N3: it is unknown whether `response()` gives a value before the first `read`. The wait order in `fetch.open` depends on it.
  - N10: it is unknown whether the card gives the body of a 404 or 500 response. Java raises on these statuses. The code covers both cases, but decision D2 needs the real answer.
  - Full list: `docs/netprobe-plan.md` (N1 to N15).
- The spec rules decided on 2026-11-14 are in the code, except two: the loading screen (`spec/loading.md`) and the move of the stats to probe2 (`spec/probe.md`). `--stats` and `--stats-out` are removed from `html`.
- `VERSION` in `lib/html/fetch.lua` is a constant. Update it by hand before each release. A release script run does not change it.

## Repository map

- `AGENTS.md`: project description and feature goals, for any agent.
- `SPEC.md`: the spec index (objective, scope, tech stack, component table, global rules, code style, boundaries).
- `spec/`: the normative rules, one file per component (`cli`, `pipeline`, `loading`, `tokenizer`, `text`, `layout`, `viewer`, `guard`, `errors`, `url`, `fetch`, `probe`, `installer`, `release`, `testing`). Informative content is in `docs/` (see "Moved spec content").
- `bin/html.lua`: entry point (arguments, error boundary, screen restore).
- `lib/html/`: `fetch.lua` (internet card client), `guard.lua` (yields, memory), `tokenizer.lua`, `entities.lua`, `text.lua` (UTF-8 cleaning), `layout.lua` (styled lines), `viewer.lua` (screen, keys).
- `tests/`: `run.lua` (sandboxed runner), `*_test.lua` (unit tests), `shim/` (OpenOS fakes, including a fake internet card), `cases/` (HTML with expected text), `real/` (saved real pages), `pages/large.html` (about 1 MB, generated), `fuzz.lua` and `fuzz-corpus/`, `docker/` (Dockerfile and `test.ps1`).
- `tools/`: `release.ps1` (makes a release), `mkinstall.lua` and `installer.lua` (one-file installer), `genpage.lua` (makes `tests/pages/large.html`), `probe.lua`, `probe2.lua`, `memprobe.lua` (in-game measurement scripts, not released).
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
- Release: commit `bin/`, `lib/` and the installer tools first, then `pwsh tools/release.ps1 <version>` (for example `0.2.1a`). It runs the tests, copies the files, writes `files.txt`, `release.tar.gz` and `html-install.lua`, and updates `releases/latest` in the index. Then commit the new folder and `releases/latest`.
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

Write `tools/netprobe.lua` (`docs/netprobe-plan.md` "Probe script plan") and collect N1 to N15 in game. Record the results in `docs/probe/FACTS.md`. Then fix the fetch code where the measurements differ from the assumptions, and run the in-game checks for remote pages.

## Open questions for the user

None. The earlier questions are answered: F1 is done, and remote responses are streamed.