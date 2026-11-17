# Errors, error log and file writes

Source: `bin/html.lua`. Index: `SPEC.md`. Exit codes: `SPEC.md` "Global rules".

## Controlled and unexpected errors

- Controlled errors are strings with the prefix `html: `, raised with `error("html: <reason>", 0)`. `bin/html.lua` prints such a message as it is. Why strings and not error tables: `docs/rationale.md`.
- Any other error value is unexpected: `bin/html.lua` prints one line and writes the full traceback to `/tmp/html-error.log`. A raw traceback never shows on the screen.
- `bin/html.lua` takes the traceback function as a parameter, because the test sandbox removes `debug`. In game it gets `debug.traceback`.

## Errors that keep the session

In the viewer, a fetch error after the frame opened and a guard memory stop do not end the program. `bin/html.lua` shows the message in a popup over the page, and the exit code is 0 when the user quits. Ctrl+C still gives 130. Print mode, the no-screen path, and every error before the frame print the line and keep the exit code 1 (`spec/loading.md` "Errors after the frame"). A page that broke off (a read error of a body or of a local file, a timeout in the body, a memory stop during the render) is not rendered: the popup has two lines, the error and `Reload to try again.`, over an empty page. The same reload line shows for the errors that `fetch.open` marks with `retry` (`spec/fetch.md` "Errors"). It does not show for: not an HTML page, compressed response, no internet card, HTTP disabled, too large by the size check before reading (known `Content-Length` or file size), unsupported scheme, and redirect errors. In print mode and with no screen, only the error line prints on stderr and the exit code is 1. An unexpected error and a module load error still end the program with code 1.

## Navigation messages

Messages of link following (`spec/navigation.md`). In the viewer they show as a popup, and the session stays. They are not for print mode.

- `html: file not found: <path>`: a local target that does not exist.
- `html: not a file: <path>`: a local target that is a directory.
- `html: unsupported URL scheme: file`: a remote page links to `file:`.
- `<scheme>: links are not supported`: a link with an unsupported scheme. This is a status-line text, not a popup, until the next key.
- `[aborted] <target>`: the status line after an abort with no page to go back to (`spec/navigation.md` "Abort").
- A retry error carries the second popup line `Reload to try again.` (`spec/navigation.md` "Retry line").
- `link too long`: the status-line text for Enter on a link whose href was over 2048 bytes.

## Tab, shell and download messages

Messages of 0.7.0a (`spec/tabs.md`, `spec/shell.md`, `spec/download.md`).

| Text | Kind |
|---|---|
| `tab limit: <n> tabs` | notice |
| `not enough memory for a new tab` | notice (only with `--tabs`) |
| `last tab: q quits` | notice |
| ` Close tab? (y/n)` | prompt |
| ` New tab: ` | prompt |
| ` Quit and close <n> tabs? (y/n)` | prompt |
| `html: shell started. Type exit to return to the browser.` | stdout line |
| `html: already open; type exit to return to it` | stderr, exit code 1 |
| `html: shell error: <reason>` | popup |
| `html: cannot reopen the screen: <reason>` | stderr, exit code 1 |
| ` Save to: ` | prompt |
| ` Overwrite <name>? (y/n)` | prompt |
| `Ctrl+S: only web files can be downloaded` | notice |
| `wait for the load, or press z` | notice |
| `download running: z stops it` | notice |
| `Downloading <name> - <n> KB of <m> KB` / `Downloading <name> - <n> KB` | status |
| `Saved <path> (<n> KB)` | notice |
| `download stopped` | notice |
| `html: no such directory: <dir>` | popup |
| `html: not enough disk space: <n> KB needed, <m> KB free` | popup |
| `html: cannot write <path>: <reason>` | popup |
| `html: --tabs needs a number from 1 to 32, or auto` | usage error (stderr, exit code 2) |

- Notices show in the status line until the next key. A popup has an `[OK]` button. A download error popup has no reload line (`spec/download.md` "Progress, keys and end").
- The shell and the download write with the checks of "File writes".

## Error log

- `/tmp` is only 64 KB. `/tmp/html-error.log` is capped at 8 KB. When the log would grow past the cap, the oldest content is dropped and the newest is kept.
- When the error log cannot be written, the unexpected error line ends with `(cannot write /tmp/html-error.log: <reason>)` in place of `(details in /tmp/html-error.log)`.

## File writes

- On a full `/tmp`, `write` returns success because it is buffered. The error "not enough space" shows at `flush` or `close` (measured). So every file write (the error log, the installer) checks the results of `write`, `flush` and `close`.
- OpenOS `close` returns no values on success (measured, the cause of the 0.1.0a installer failure). So `close` fails only when it returns a reason.
- A failure gives one `html: ` line.

## Ctrl+C

- Ctrl+C (`key_down` char 3, or the "interrupted" event) exits cleanly and restores the screen. The message is `html: interrupted`, exit code 130.
- Ctrl+C during the render: see `spec/guard.md` "Interrupt". During load: see `spec/loading.md`. In the viewer: see `spec/viewer.md` "Quit".
