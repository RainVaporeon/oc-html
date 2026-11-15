# Startup and loading screen

Source: `bin/html.lua`, `lib/html/viewer.lua`, `lib/html/guard.lua`. Index: `SPEC.md`. Reasons: `docs/rationale.md` "Startup and loading screen".

## Startup

1. `bin/html.lua` checks the arguments (see `spec/cli.md`). A usage error stops here.
2. For a local file, it checks that the file exists and is a file. For a URL, it checks that the URL is valid (`html.url`). A failed check stops here, before the TUI opens.
3. It opens the TUI at once. It sets the resolution (see `spec/viewer.md` "Resolution"), draws the frame and a status line. This happens before it loads the heavy modules (`tokenizer`, `layout`, `fetch` and their dependencies) and before any network request.
4. It loads the modules, opens the source and renders. The status line shows the phase.

- This section describes the first load of a session. A later load (a link, Back, Forward, go, reload) reuses the same phases and status texts, with two phases and the commit (`spec/navigation.md` "Two phases of a load"). For a later load, the size check comes after the commit, because the old page must be released before the free memory is measured. On the first load there is no old page. At the commit of a later load, after a last stop check (`z` still aborts in phase 1), the line rows go blank and the status line keeps the loading text.
- Print mode and the no-screen path do not open the TUI. They keep the order of `spec/cli.md`.
- `html.url` (small, no dependencies) loads during the argument checks for a URL or a missing local path. It parses the URL and decides the host rule. An invalid URL (exit code 2) stops here, before the TUI opens, with no draw call. `html.fetch` loads after the TUI opens, only for a URL.

## Status line during load

- The status line shows the current phase. The text is exact:
  - `Loading <name>...` (the file argument or the URL argument, at once)
  - `Loading modules...`
  - `Connecting to <host>...`
  - `Waiting for response...`
  - `Redirect to <url>...`
  - `Loading <name>... 12 KB` once bytes arrive, or `Loading <name>... 12 KB of 98 KB` when the size is known (from the file size or `Content-Length`). The count rounds up to whole KB. `<name>` is the final URL after a redirect.
- Byte count updates are rate-limited to one each 0.25 s. A phase text shows at once. The last update at the end of the input shows the total and is not rate-limited.

## Content during load

- The first screen of content draws as soon as enough lines exist to fill it. It does not wait for the end of input.
- Scrolling during load is not supported in this version. It is planned later.
- When the load ends, the viewer works as in `spec/viewer.md`.

## Keys during load

- The program checks for key events during load. The check is cheap: an event pull costs about 15 ms in game. It does not pull per token. It pulls about every 0.25 s.
- A key poll with no time gate runs once before the commit of a later load. A `z` that it finds is a phase 1 abort.
- `z` during load aborts the load (`spec/navigation.md` "Abort"). On the first load, with no page to go back to, it shows an empty page with the status `[aborted] <target>`.
- Ctrl+C during load exits at once: `html: interrupted`, exit code 130.
- `q` during load shows the quit confirmation (`spec/viewer.md` "Quit"). Loading continues while the prompt shows.
  - When the user confirms, loading stops and the program exits with code 0.
  - When the user cancels, loading continues as before.
- The guard yield interval is 0.25 s of CPU time (see `spec/guard.md` "Yields"), so Ctrl+C and `q` respond fast.

## Errors after the frame

Decision (user, 2026-11-15): the program will get tabs, so an error after the frame opened must not end the session. Reason: `docs/rationale.md` "Errors keep the session".

- Every fetch error after the frame opened shows as a popup with the error text and an `[OK]` button, over an empty page. This covers: cannot connect, timeout, read error, too many open connections, not an HTML page, too large, no card, HTTP disabled, and a failed redirect. The status line shows the URL and `[error]`.
- A page that broke off is a broken page, and no part of it renders (`docs/rationale.md` "Broken pages are not rendered"). This covers every incomplete load after the frame: a read error in the body, a timeout in the body, and a memory stop by the guard. It holds for a local file too, and for the body of an error status. The popup shows over an empty page. The program drops the lines received so far before it shows the popup.
- The popup text of a broken page has two lines: the error line, then `Reload to try again.` `r` reloads the page (`spec/navigation.md` "Reload").
- The reload line shows for broken pages (body read error, body timeout, memory stop during the render, local read error) and for the retry errors of `fetch.open` (`spec/fetch.md` "Errors"). It does not show for: not an HTML page, compressed response, no internet card, HTTP disabled, too large by the size check before reading (known `Content-Length` or file size), unsupported scheme, redirect errors.
- Two different stops. The size check before reading is a plain error line with no reload line: the same page would fail again. The memory stop during the render is a broken page with the reload line (`spec/guard.md` "Size check before reading").
- After OK, the user can scroll and quit with `q` as usual. The exit code is 0 on a normal quit, and nothing prints on stderr.
- Ctrl+C still exits at once with code 130, also while the popup shows.
- An HTTP error status (404, 500, ...) is not an error here: the short page shows with a popup of two lines, `[HTTP <code>] <phrase>` and the URL (`spec/fetch.md` "HTTP error statuses").
- Not covered: the errors before the frame (argument checks, a missing file, a module that cannot load), an unexpected error, and print mode and the no-screen path. They keep the stderr line, the screen restore and the exit codes of `spec/errors.md`. In print mode and with no screen, a broken page prints no text: only the error line goes to stderr, and the exit code is 1.

## Exit

- The screen is restored on every exit path: normal end, quit during load, controlled error, unexpected error and Ctrl+C.
- Error lines print to stderr after the restore, except the errors that show a popup (see "Errors after the frame").
