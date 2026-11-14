# Stats output and print-mode memory

Source: `bin/html.lua`, stats getters in `lib/html/guard.lua`. Index: `SPEC.md`.

This file holds the rules for `--stats`, `--stats-out` and the print-mode memory limit. They are kept apart so that they can be replaced as one unit.

## Options

```
html --stats <file>        print the stats lines (below) to stderr
html --stats-out <path> <file>
                           also write the stats lines to <path> (overwrite). Sets --stats
```

## Stats lines

Stats lines, in this order:
```
stats: file=<bytes> bytes
stats: width=<columns>              always a number (80 when the screen width is unknown)
stats: lines=<count>
stats: cpu=<seconds> s              os.clock time of the tokenizer and layout
stats: wall=<seconds> s             computer.uptime time of the same part
stats: free_before=<bytes> bytes    settled free memory before the render
stats: free_after=<bytes> bytes     settled free memory after the render
stats: delta=<bytes> bytes (<x> per line)
stats: lowest_free=<bytes> bytes    lowest freeMemory() reading from the render start to the end of the output
stats: peak_used=<bytes> bytes (<x> per line)
stats: settles=<n> gc_seen=<n> settle_yields=<n>
                                    free_before - lowest_free
stats: trace=<line>:<free><mark>,<line>:<free><mark>,...
                                    freeMemory() readings of the guard (from 0.0.3a)
```

- A missing or invalid value prints as `n/a`, for example `stats: lowest_free=n/a`. The stats report never fails on a missing value. A guard function that is missing (a guard module from an older version) or that fails gives `n/a`. When `lowest_free` is missing, it falls back to `free_after`, then to `free_before`.
- `settles` is the number of settles since `guard.reset()` (see `spec/guard.md`). It includes the settle for `free_after`. `gc_seen` is the number of settles that saw a GC. `settle_yields` is the number of yields of all settles. At about 10 ms per yield, `settle_yields` / 100 is the wall time the settles cost, in seconds.
- `trace` holds at most 60 samples, oldest first. A sample is `<line>:<free><mark>`: the last line count given to `guard.tick()` and a `freeMemory()` reading. The mark is empty for a raw reading of a tick, `s` for a settle result and `S` for a settle result that saw a GC, for example `1803:129682s` or `1803:129682S`. The guard keeps every Nth tick and every settle of `tick()`. When 60 samples are full, it drops every second sample and doubles N, so the samples spread across the whole run. When the guard stops the render, the stopping settle result is the last sample. The line stays under about 1000 characters. With no sample, the line is `stats: trace=n/a`. The trace starts at `guard.reset()`, so it covers the render and the output.
- `delta` (free_before - free_after) is unreliable. Why: `docs/rationale.md` "Commands".
- `peak_used` is an upper bound of the peak memory use. `lowest_free` includes garbage that is not collected yet.
- When the render stops with a controlled error, the stats lines still follow the error line. They hold the values known at that point (file, width, free_before, lowest_free, peak_used without the per-line value) and a last line `stats: stopped=<error message>`. A fetch error does the same.
- The `--stats` lines print after the screen restore, so they stay on the screen.

## Remote pages

- `stats: file=<bytes> bytes` holds the bytes received.
- Two new lines follow it, only for a URL: `stats: url=<final url>` and `stats: http=<code> redirects=<n> fetch=<seconds> s`. `fetch` is the wall time from the request to the end of the body. The order of all other lines does not change.

## --stats-out

- `--stats-out` writes the same lines with LF endings. A write failure prints one line `html: cannot write stats file: <path> (<reason>)` after the stats lines and gives exit code 1. The page output and the stats on stderr are not affected. The write checks the results of `write`, `flush` and `close` (see `spec/errors.md` "File writes").
- A leading `~` in the path expands as in `spec/cli.md` "Home directory".

## Guard functions for stats

- `guard.settles()`, `guard.gc_seen()` and `guard.settle_yields()` return the settle counters. `reset()` clears them.
- `guard.lowest_free()` returns the lowest `freeMemory()` reading that `tick()` and `settled_free()` saw since the last `reset()`, or nil. `reset()` clears it. `--stats` uses it for `lowest_free` and `peak_used`.
- `guard.trace_text()` returns the memory trace (see the `trace` stats line), or "" when it is empty. `reset()` clears it too.

## Print-mode memory limit

- This version has no memory limit of its own for print mode. Print mode renders all lines first and then writes them. The render uses the guard and the size check of `spec/guard.md`, as in the viewer.
