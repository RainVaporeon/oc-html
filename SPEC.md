# Spec: oc-html (HTML viewer for OpenComputers)

Source of intent: `docs/intent/mvp.md`.

Status: release 0.4.0a renders local files, fetches remote pages and follows links. The MVP is finished (release 0.1.0a, fixed in 0.1.1a); its plan is in `tasks/archive/`. The roadmap is in `tasks/todo.md`.

This file is the index. The rules of each component are in `spec/` (table below). Rationale, measurements, test coverage, the network probe plan, the project tree and examples are in `docs/` (list in `docs/HANDOFF.md` "Moved spec content").

## Objective

Build `html <file or URL>`, a command that renders an HTML page as readable text on an OpenComputers screen.

- User: GT:NH (Minecraft 1.7.10) players on OpenComputers with Lua 5.3.
- Why: no public script does this. The MVP proved the idea and is the base for remote browsing.
- Principle: simple but robust. Any input is allowed. When the input breaks a limit, the program detects it early and stops with a clear message. It never crashes with a traceback and never leaves the screen in a bad state.

## Scope

In scope:
- Forgiving parsing of any HTML, including broken markup.
- Text rendering with block structure, emphasis and visible links.
- Scrolling viewer with a status line, a loading screen and a quit confirmation.
- Remote fetching (`spec/fetch.md`, roadmap item 1, approved 2026-11-14).
- Following links and navigation (link selection, back and forward, go to, reload, abort): specified in `spec/navigation.md`, awaiting approval (roadmap items 2 and 2a).
- Tabs, shell tab-out, downloads, sessions (save and resume). Planned, see `tasks/todo.md`.
- Images. Planned, see `tasks/todo.md`.
- Data Card inflate and deflate. Planned, see `tasks/todo.md`.
- Correct layout of tables, lists, forms, `<input>` and `<button>`. These render as plain text and must not break anything.
- Visible cursor to let the user see what is being selected or being input into.

Out of scope:
- CSS, JS.

## Tech stack

- Lua 5.3 on OpenComputers, OpenOS.
- OpenOS libraries only: `component`, `computer`, `term`, `event`, `keyboard`, `unicode`, `filesystem`, `serialization`, `shell`.
- No other dependencies. The Internet Card is needed only for remote pages. The Data Card is optional.
- Lua 5.3 in a Docker container for the automated tests (`spec/testing.md`).

## Components

| Component | Spec file | Source files |
|---|---|---|
| Command line, output width, local file messages | `spec/cli.md` | `bin/html.lua` |
| Pipeline, module loading, line format | `spec/pipeline.md` | `bin/html.lua` |
| Startup and loading screen | `spec/loading.md` | `bin/html.lua`, `lib/html/viewer.lua`, `lib/html/guard.lua` |
| Tokenizer | `spec/tokenizer.md` | `lib/html/tokenizer.lua` |
| Text cleaning and entities | `spec/text.md` | `lib/html/text.lua`, `lib/html/entities.lua` |
| Layout | `spec/layout.md` | `lib/html/layout.lua` |
| Navigation and history | `spec/navigation.md` | `bin/html.lua`, `lib/html/history.lua`, `lib/html/viewer.lua` |
| Viewer | `spec/viewer.md` | `lib/html/viewer.lua` |
| Guard: yields and memory limits | `spec/guard.md` | `lib/html/guard.lua`, `bin/html.lua` (size check) |
| Errors, error log, file writes | `spec/errors.md` | `bin/html.lua` |
| URL arguments, link resolution | `spec/url.md` | `lib/html/url.lua`, `bin/html.lua` |
| Remote fetching | `spec/fetch.md` | `lib/html/fetch.lua`, `bin/html.lua` |
| Disk page cache | `spec/cache.md` | `lib/html/cache.lua` |
| Probe render stats | `spec/probe.md` | `tools/probe2.lua`, `lib/html/guard.lua` |
| Installer | `spec/installer.md` | `tools/installer.lua`, `tools/mkinstall.lua` |
| Releases | `spec/release.md` | `tools/release.ps1` |
| Testing and success criteria | `spec/testing.md` | `tests/`, `tests/docker/` |

Code modules:
```
bin/html.lua            entry point: argument parsing, error boundary, screen restore
lib/html/guard.lua      yield timing and memory checks, shared by all stages
lib/html/entities.lua   named and numeric entity decoding
lib/html/text.lua       UTF-8 cleaning and the chunk split helper
lib/html/tokenizer.lua  streaming, forgiving tokenizer (reads the input in chunks)
lib/html/layout.lua     turns tokens into wrapped, styled lines (no DOM tree)
lib/html/viewer.lua     screen drawing, scrolling, keys, quit prompt
lib/html/url.lua        URL parsing, the host rule and link resolution (loads during the argument checks)
lib/html/history.lua    navigation history (pure, no page content)
lib/html/fetch.lua      redirects, the internet card request and the body stream
```

Tests, tools, docs, tasks and releases: `docs/structure.md`.

## Global rules

- Controlled errors are one line with the prefix `html: ` (`spec/errors.md`).
- Exit codes: 0 quit, 1 error, 2 bad arguments, 130 Ctrl+C (also from the viewer). In the viewer, a fetch error after the frame opened shows a popup and gives 0 on quit (`spec/loading.md` "Errors after the frame").
- The screen is restored on every exit path. Error lines print after the restore.
- Errors and notices go to stderr.

### Code style

- Two-space indent. All variables are `local`. No globals.
- Each module returns a table `M`.
- Library functions return values. Only `guard` raises controlled errors. Only `bin/html.lua` prints errors.
- Names: `snake_case` for functions and variables, `UPPER_CASE` for constants.
- Comments explain only related information, such as why a limit exists.
- Example module: `docs/code-style.md`.

## Boundaries

- Always:
  - Keep `tokenizer` and `layout` free of `component` calls.
  - Run `pwsh tests/docker/test.ps1` and a fuzz run before calling a task done.
  - Restore the screen on every exit path.
  - Add a failing input to the tests when a bug is found.
- Ask first:
  - Add any library outside OpenOS.
  - Move an item from "Out of scope" (CSS, JS) into scope.
- Never:
  - Assume input is valid HTML or valid UTF-8.
  - Read the whole file into memory before checking its size.
  - Require an Internet Card or a Data Card to view local files.
  - Show a raw traceback on the screen.
  - Run test code on the host outside the container.
  - Remove a sandbox flag or widen the Lua environment without asking.
  - Change or delete a published release folder. (One exception: release.tar.gz was added to 0.0.1a after publishing, at the user's request.)

## Later: sessions

Planned, see `tasks/todo.md`. Agreed design, to be specified later:
- Each session has an 8-digit lowercase hex ID, for example `4cb2faad`.
- `html` with no arguments starts a new session.
- `html -r <id>` resumes that session. `html -r` resumes the last session.
- The stored content and the storage location are decided when this feature is specified.

## Decisions

- Saved state is not in the MVP.
- The project uses git.
- OCEmu is deprecated. Do not use it.
- Automated tests run in Docker with the sandbox in `spec/testing.md` "Sandbox".
- The default branch is `master`.
- Ground-truth machine facts are in `docs/probe/FACTS.md`.

## Open questions

- None.
