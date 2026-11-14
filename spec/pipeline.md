# Pipeline

Source: `bin/html.lua` (`M.render`, `M.run_program`, `M.clear_modules`). Index: `SPEC.md`.

## Steps

1. `bin/html.lua` checks the arguments and the file (see `spec/cli.md`). It then opens the TUI (see `spec/loading.md`). It runs the rest inside `xpcall`.
2. `tokenizer` reads the input in 4096-byte chunks and produces tokens one at a time (see `spec/tokenizer.md`).
3. `layout` consumes tokens and appends finished lines (see `spec/layout.md`).
4. `viewer` draws the lines and handles keys (see `spec/viewer.md`).

- A remote page uses the same steps. `response.read` takes the place of the file reader (see `spec/fetch.md` "Stream into the pipeline").
- The tokenizer and layout never call `component`. They take `guard` as their only link to the machine.

## Module loading

- Modules load only when needed. A stage releases its data when the next stage no longer needs it.
- OpenOS keeps every required module in `package.loaded` until a reboot, so after an update `require` can return an older module. Details: `docs/rationale.md` "Design: Pipeline".
- `bin/html.lua` removes every `package.loaded` key that starts with `html.` when the chunk loads, before its first `require`. `M.run_program` runs `main` in `pcall` and removes the keys again on every exit path (normal, error, Ctrl+C), then raises the error again. This loads the current code after an update and frees the module memory after a run.
- `M.clear_modules(loaded)` does the removal and returns the count. Other keys stay.

## Line format

A line is one string with inline style control bytes (memory reason: `docs/rationale.md` "Design: Pipeline").

- Bytes 0x01 to 0x05 select a style: normal, heading, emphasis, link, preformatted. A style lasts until the next style byte.
- Text never contains these bytes, because cleaning removes control bytes first (see `spec/text.md`).
- Style bytes never count toward the line width.
- Every non-empty line starts with its style byte. An empty line is "".
- A style byte is never followed by another style byte or by the line end.
