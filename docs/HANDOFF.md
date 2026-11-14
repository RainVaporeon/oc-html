# Handoff: oc-html

Date: 2026-11-14. Branch: `master` (the only branch). Last commit at handoff: `02397e0 Add release 0.1.1a`.

## Purpose

oc-html is an HTML viewer for OpenComputers (Minecraft mod, GT:NH, Lua 5.3, OpenOS). `html <file>` renders a local HTML file as readable text in a full-screen viewer and never crashes on bad input. The long-term goal (`AGENTS.md`) is a small text browser: remote pages, links, tabs, sessions and images.

## Current state

- Release: 0.1.1a (`releases/0.1.1a/`, `releases/latest` points to it). The MVP is finished (decided by the user on 2026-11-14).
- 0.1.0a is frozen and has a broken installer: OpenOS `file:close()` returns no values on success, and 0.1.0a read that as a failure. 0.1.1a fixes this in `tools/installer.lua` and `M.write_text` in `bin/html.lua`. The `lib/` files of 0.1.0a and 0.1.1a are identical.
- Works: forgiving streaming tokenizer, entities and UTF-8 cleaning, layout with styles and word wrap, viewer with scrolling, colors by depth and a quit prompt, `--print`, `--width`, `--stats`, `--stats-out`, `--no-rescale`, memory guard (guard v2), Ctrl+C, error log, one-file installer.
- Verified in the container: `pwsh tests/docker/test.ps1` gives 363 passed, 0 failed, 1 skipped. `fuzz 1000` (seed 1794647241) gives 0 failures.
- Verified in game: the probes (`docs/probe/`), the tracer bullet and memory runs up to 0.0.4a (`docs/ingame/`, `tasks/archive/mvp-plan.md` "Measurements"). The user accepted the 0.1.0a viewer and exit-path checks (`docs/ingame/mvp.md` sections 3, 5, 7 and 8). No measured values are recorded for them.
- Verified in game on 2026-11-14: `html --print` on the three pages in `tests/real/` gives readable text (follow-up F1, done).
- Not verified in game: `docs/ingame/mvp.md` sections 4 and 6, a low-RAM machine, and the 0.1.1a installer itself.

## Repository map

- `AGENTS.md`: project description and feature goals, for any agent.
- `SPEC.md`: the MVP specification (commands, design, limits, tests, releases, boundaries).
- `bin/html.lua`: entry point (arguments, error boundary, stats, screen restore).
- `lib/html/`: `guard.lua` (yields, memory), `tokenizer.lua`, `entities.lua`, `text.lua` (UTF-8 cleaning), `layout.lua` (styled lines), `viewer.lua` (screen, keys).
- `tests/`: `run.lua` (sandboxed runner), `*_test.lua` (unit tests), `shim/` (OpenOS fakes), `cases/` (HTML with expected text), `real/` (saved real pages), `pages/large.html` (about 1 MB, generated), `fuzz.lua` and `fuzz-corpus/`, `docker/` (Dockerfile and `test.ps1`).
- `tools/`: `release.ps1` (makes a release), `mkinstall.lua` and `installer.lua` (one-file installer), `genpage.lua` (makes `tests/pages/large.html`), `probe.lua`, `probe2.lua`, `memprobe.lua` (in-game measurement scripts, not released).
- `releases/`: frozen release folders and the `latest` symlink.
- `docs/intent/mvp.md`: the confirmed MVP intent. `docs/probe/`: probe outputs and `FACTS.md` (measured machine facts). `docs/ingame/`: in-game checklists and results.
- `tasks/todo.md`: roadmap after the MVP. `tasks/archive/`: the finished MVP plan and task list.
- `types/openos.lua` and `.luarc.json`: LuaLS settings and OpenOS type stubs.
- `datacollection/` (ignored): raw files the user copied back from the game.

## How to work

- Build the test image once: `docker build -t oc-html-test tests/docker`.
- All tests: `pwsh tests/docker/test.ps1`. The one skip (`f5_restore_closure_outside_pcall`) is known and expected.
- Fuzz: `pwsh tests/docker/test.ps1 fuzz 1000 [SEED]`. Failures go to `tests/fuzz-failures/` (ignored). Turn each new failure into a unit test.
- Release: commit `bin/`, `lib/` and the installer tools first, then `pwsh tools/release.ps1 <version>` (for example `0.1.2a`). It runs the tests, copies the files, writes `files.txt`, `release.tar.gz` and `html-install.lua`, and updates `releases/latest` in the index. Then commit the new folder and `releases/latest`.
- Test code runs only in the container (sandbox flags in `SPEC.md` "Sandbox"). Do not run it on the host.

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
- Code style in `SPEC.md` "Code Style": two-space indent, only `local`, modules return `M`, controlled errors are strings with the prefix `html: `.
- Tests: one `tests/<module>_test.lua` per module. Corpus cases are `tests/cases/<name>.html` with `<name>.txt`. When a bug is found, add the failing input to the tests (`SPEC.md` "Boundaries").
- Docs use short sentences in active voice.
- New instruction files are named `AGENTS.md`, not `CLAUDE.md`.

## Next step

Start roadmap item 1, remote fetching (`tasks/todo.md`). First write its spec section in `SPEC.md` and list the in-game measurements it needs. Get the user's approval before code starts.

## Open questions for the user

1. F1: can you run `html --print` on the three pages in `tests/real/` in game and report whether the text is readable?
User response: Yes.
2. Remote fetching: stream a response into the renderer, or save it to a cache file first?
User response: Streamed.
