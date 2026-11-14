# Startup and loading screen

Source: `bin/html.lua`, `lib/html/viewer.lua`, `lib/html/guard.lua`. Index: `SPEC.md`. Reasons: `docs/rationale.md` "Startup and loading screen".

## Startup

1. `bin/html.lua` checks the arguments (see `spec/cli.md`). A usage error stops here.
2. For a local file, it checks that the file exists and is a file. A failed check stops here, before the TUI opens.
3. It opens the TUI at once. It sets the resolution (see `spec/viewer.md` "Resolution"), draws the frame and a status line. This happens before it loads the heavy modules (`tokenizer`, `layout`, `fetch` and their dependencies) and before any network request.
4. It loads the modules, opens the source and renders. The status line shows the phase.

- Print mode and the no-screen path do not open the TUI. They keep the order of `spec/cli.md`.

## Status line during load

- The status line shows the current phase:
  - `loading modules`
  - `connecting to <host>`
  - `waiting for response`
  - `redirect to <url>`
  - `loading <name>` with a byte count: `12 KB`, or `12 KB of 98 KB` when the size is known (from the file size or `Content-Length`).
- Status updates are rate-limited to one each 0.25 s.

## Content during load

- The first screen of content draws as soon as enough lines exist to fill it. It does not wait for the end of input.
- Scrolling during load is not supported in this version. It is planned later.
- When the load ends, the viewer works as in `spec/viewer.md`.

## Keys during load

- The program checks for key events during load. The check is cheap: an event pull costs about 15 ms in game. It does not pull per token. It pulls about every 0.25 s.
- Ctrl+C during load exits at once: `html: interrupted`, exit code 130.
- `q` during load shows the quit confirmation (`spec/viewer.md` "Quit"). Loading continues while the prompt shows.
  - When the user confirms, loading stops and the program exits with code 0.
  - When the user cancels, loading continues as before.
- The guard yield interval is 0.25 s of CPU time (see `spec/guard.md` "Yields"), so Ctrl+C and `q` respond fast.

## Exit

- The screen is restored on every exit path: normal end, quit during load, controlled error, unexpected error and Ctrl+C.
- Error lines print to stderr after the restore.
