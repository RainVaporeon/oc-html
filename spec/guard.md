# Guard: yields and memory limits

Source: `lib/html/guard.lua`, size check in `bin/html.lua`. Index: `SPEC.md`. Reasons and measurements: `docs/rationale.md` "Design: Limits and graceful failure".

There are no fixed size caps. The program measures and stops before damage happens.

## Yields

- `guard.tick()` runs once per token, once per text token in layout and once per emitted line (not per byte).
- It measures time with `os.clock()`, which has sub-millisecond steps (`computer.uptime()` moves in 50 ms steps).
- It yields with `os.sleep(0)` when more than `YIELD_INTERVAL` (0.25 s of CPU time) has passed since the last yield. This is well below the 5 second OpenOS timeout, and it lets Ctrl+C and `q` respond fast during load (see `spec/loading.md`).
- `guard.reset()` restarts the yield timer, and the tests use it.

## Memory reserve

- `guard.tick()` also checks `computer.freeMemory()` against the effective reserve, in `freeMemory()` units (real bytes / ramScale, measured ramScale 1.800).
- The effective reserve is max(`MEMORY_RESERVE`, next_doubling). `MEMORY_RESERVE` is 192 KB. next_doubling = 32 * c / 1.8, where c is the smallest power of two >= the current line count (at least 1024). `guard.reserve()` returns the effective reserve.
- The link and anchor arrays also double. The layout tells the guard when 2 * link_count or anchor_count crosses a power of two. The doubling term uses c = max(c_lines, c_tables), where c_tables is the smallest power of two >= max(2 * link_count, anchor_count), also at least 1024.

## Settle

- `guard.settled_free()` is public. It runs one settle (up to 11 yields, see below) and returns the highest `freeMemory()` reading.
- Settle (guard v2). The OpenOS kernel runs a full GC on every 10th resume of the main coroutine (measured). A settle yields with `os.sleep(0)` up to 11 times and reads `freeMemory()` after each yield. A rise above the previous reading by more than max(16384, 5% of the previous reading) is a GC. The settle stops at the first GC and returns the highest reading. When it sees no GC in 11 yields, it returns the highest reading and records that it saw no GC. A settle costs up to about 110 ms wall time (10 ms per yield).
- Settle rule in `tick()`. A raw reading under the reserve settles only when the rate limit allows it. After a settle at line L with result F, the wait is gap = max(25, (F - reserve) / (2 * B)). B is the live cost per line in `freeMemory()` units: 100 at the start, then the highest cost measured between two settles that saw a GC, but at least 80 (measured values: `docs/rationale.md`). At B per line, one gap uses at most half of the headroom F - reserve. The next settle comes when the line count grew by gap, or when it grew by gap / 2 and a raw reading is under reserve / 2. The second case covers lines that cost up to 2 * B. A `tick()` without a line count uses the tick count in place of the line count.

## Stop rules

- Between settles, a raw reading under the reserve does not stop the render.
- A raw reading under reserve / 2 after a settle that saw no GC stops the render at once: without a GC, no settle lifts it over the reserve.
- Otherwise only a settle result under the reserve raises the controlled error "html: page too large for available memory (rendered N lines before stopping)".
- Rule change from the first draft: `docs/rationale.md` "Design: Limits and graceful failure".
- Fail-safe. Every settle saw a GC or used all 11 yields. If OpenOS ever stops the 10th-yield GC, a settle cannot lift a low reading, so the guard stops early with the controlled message. It never crashes and never loops. The tests check this with the GC turned off in the shim.
- Decision against a forced GC: the guard does not force a GC with an oversized allocation. Reason: `docs/rationale.md`.
- The program never calls `collectgarbage`. OpenComputers removes it on purpose.

## Size check before reading

- Before parsing, `bin/html.lua` compares the input size with free memory. If the input clearly cannot fit, it stops before reading.
- The check stops when size x 0.5 (`SIZE_COST_MIN`) is more than the settled free memory.
- A stop by this check shows no reload line, because a retry gives the same result. A memory stop by `guard.tick()` during the render is a different stop: it makes a broken page with the reload line (`spec/loading.md` "Errors after the frame").
- The message for a local file is `html: file too large for available memory (<size> bytes, <free> free)`. For a remote page, see `spec/fetch.md` "Memory".

## Interrupt

- Ctrl+C during the render works through an "interrupted" listener and `guard.set_interrupt_check`. The next `guard.tick()` raises `html: interrupted`.
- Only `guard` raises controlled errors (see `SPEC.md` "Code style").
