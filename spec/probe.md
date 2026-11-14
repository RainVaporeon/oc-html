# Probe: render stats

Source: `tools/probe2.lua`, `lib/html/guard.lua` (getters). Index: `SPEC.md`.

`html` has no stats option. The render stats come from the render section of `tools/probe2.lua`. The tool is not part of a release. It is planned work (`tasks/todo.md`, low priority).

## How the probe hooks in

- `tools/probe2.lua` loads `bin/html.lua` as a module. A table argument makes the chunk return `M` and not run (see `spec/pipeline.md`).
- It wraps `M.render`, `guard.settled_free`, `fetch.open`, `deps.view` and the gpu. It does not change the render result.
- It collects the keys of "Keys" and the two times of "Time keys".
- The probe never fails on a missing value. A missing or invalid value is `n/a`. When `lowest_free` is missing, it falls back to `free_after`, then to `free_before`.

## Seams (contract)

The probe depends on these seams. They are a contract of `bin/html.lua` and `lib/html/`:
- `M` is reachable through a table argument.
- `M.render` is called through `M`, not through a local alias.
- The public functions `guard.settled_free` and `fetch.open`, and the guard getters of "Guard functions for the probe".
- Injectable `deps` (including `deps.view`).

One test pins these seams (see `spec/testing.md`).

## Keys

The probe reports each key as `render.<page>.<key>`.

- `file`: bytes of the input. For a remote page, the bytes received.
- `width`: columns. A number (80 when the screen width is unknown).
- `lines`: line count.
- `cpu`: `os.clock` seconds of the tokenizer and layout.
- `wall`: `computer.uptime` seconds of the same part.
- `free_before`, `free_after`: settled free memory (bytes) before and after the render.
- `delta`: free_before - free_after, and per line. It is unreliable. Why: `docs/rationale.md` "Commands".
- `lowest_free`: the lowest `freeMemory()` reading from the render start to the end of the settle after the render. It does not cover the output. It includes garbage that is not collected yet.
- `peak_used`: free_before - lowest_free, and per line. It is an upper bound of the peak memory use.
- `settles`, `gc_seen`, `settle_yields`: `settles` is the number of settles since `guard.reset()` (see `spec/guard.md`), including the settle for `free_after`. `gc_seen` is the number of settles that saw a GC. `settle_yields` is the number of yields of all settles. At about 10 ms per yield, `settle_yields` / 100 is the wall time of the settles, in seconds.
- `trace`: at most 60 samples, oldest first. A sample is `<line>:<free><mark>`: the last line count given to `guard.tick()` and a `freeMemory()` reading. The mark is empty for a raw reading of a tick, `s` for a settle result and `S` for a settle result that saw a GC, for example `1803:129682s` or `1803:129682S`. The guard keeps every Nth tick and every settle of `tick()`. When 60 samples are full, it drops every second sample and doubles N, so the samples spread across the whole run. When the guard stops the render, the stopping settle result is the last sample. The text stays under about 1000 characters. With no sample, the value is `n/a`. The trace starts at `guard.reset()`. It covers the render and the settle after it, not the output.
- When the render stops with a controlled error, the probe still reports the values known at that point (file, width, free_before, lowest_free, peak_used without the per-line value) and `stopped=<error message>`. A fetch error does the same.
- A remote page also gives `url` (the final URL), `http` (the status code), `redirects` and `fetch` (seconds from the request to the end of the body).

## Time keys

- `first_frame`: time from the start of the html run (before the probe calls the `bin/html.lua` chunk) to the first gpu draw call of the loading frame.
- `first_screen`: time from the same start to the first draw of a full screen of content lines.

Both are `computer.uptime` seconds. The probe takes both from its gpu wrapper and its clock.

## Guard functions for the probe

- `guard.settles()`, `guard.gc_seen()` and `guard.settle_yields()` return the settle counters. `reset()` clears them.
- `guard.lowest_free()` returns the lowest `freeMemory()` reading that `tick()` and `settled_free()` saw since the last `reset()`, or nil. `reset()` clears it.
- `guard.trace_text()` returns the memory trace, or "" when it is empty. `reset()` clears it too.
