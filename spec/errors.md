# Errors, error log and file writes

Source: `bin/html.lua`. Index: `SPEC.md`. Exit codes: `SPEC.md` "Global rules".

## Controlled and unexpected errors

- Controlled errors are strings with the prefix `html: `, raised with `error("html: <reason>", 0)`. `bin/html.lua` prints such a message as it is. Why strings and not error tables: `docs/rationale.md`.
- Any other error value is unexpected: `bin/html.lua` prints one line and writes the full traceback to `/tmp/html-error.log`. A raw traceback never shows on the screen.
- `bin/html.lua` takes the traceback function as a parameter, because the test sandbox removes `debug`. In game it gets `debug.traceback`.

## Error log

- `/tmp` is only 64 KB. `/tmp/html-error.log` is capped at 8 KB. When the log would grow past the cap, the oldest content is dropped and the newest is kept.
- When the error log cannot be written, the unexpected error line ends with `(cannot write /tmp/html-error.log: <reason>)` in place of `(details in /tmp/html-error.log)`.

## File writes

- On a full `/tmp`, `write` returns success because it is buffered. The error "not enough space" shows at `flush` or `close` (measured). So every file write (the error log, `--stats-out`, the installer) checks the results of `write`, `flush` and `close`.
- OpenOS `close` returns no values on success (measured, the cause of the 0.1.0a installer failure). So `close` fails only when it returns a reason.
- A failure gives one `html: ` line.

## Ctrl+C

- Ctrl+C (`key_down` char 3, or the "interrupted" event) exits cleanly and restores the screen. The message is `html: interrupted`, exit code 130.
- Ctrl+C during the render: see `spec/guard.md` "Interrupt". During load: see `spec/loading.md`. In the viewer: see `spec/viewer.md` "Quit".
