# Implementation Plan: oc-html MVP (archived)

Status: closed. The MVP shipped as 0.1.0a, then 0.1.1a. This file was `tasks/plan.md`. New work is in `tasks/todo.md`.

## Overview

Build the MVP in `SPEC.md`: `html <file>` renders a local HTML file as text on an OpenComputers screen and never crashes on bad input. The plan builds the test sandbox first, then a thin end-to-end path to test in game early, then hardens the parser, then the layout, then the viewer.

Tasks with acceptance criteria are in `tasks/archive/mvp-todo.md` (was `tasks/todo.md`).

## Architecture Decisions

- Test sandbox first. Every later task depends on `pwsh tests/docker/test.ps1`.
- Machine facts come from the in-game probe (Task 0). They are in `docs/probe/FACTS.md`. The line format and the guard values are decided from this data, not at Checkpoint 1.
- Tracer bullet early (Task 3). A minimal file-to-text path runs in game before the parser is complete. It confirms the numbers in `docs/probe/FACTS.md` on the real pipeline.
- The guard uses `os.clock()` for the yield timer, `YIELD_INTERVAL` = 1 s and `MEMORY_RESERVE` = 192 KB (guard v2, from 0.0.4a). The effective reserve also covers the next lines-table doubling (see Decisions). Below the reserve it settles on the kernel GC, with a rate limit (see Decisions). It never calls `collectgarbage`.
- Controlled errors are strings with the prefix `html: `. They do not depend on how error tables pass through `pcall` (see run t3 in `FACTS.md`).
- A line is one string with inline style control bytes, not a DOM tree and not a table of styled pieces. Measured: 80 bytes per line.
- The tokenizer uses plain `string.find` and `string.byte` over 4096-byte `io` chunks. No `gsub` or `gmatch` over large strings.
- Text is cleaned before any `unicode.*` call, because `unicode.*` accepts bad bytes silently.
- The fuzz generator comes right after the tokenizer rules. It hardens the parser before layout depends on it.
- Fuzz runs also use very small read chunks (1 to 16 bytes). This catches tokens split across chunk edges.

## Task List

### Phase 1: Foundation
- [x] Task 0: In-game data collector (probe) — done
- [x] Task 1: Docker test sandbox and runner
- [x] Task 2: Guard module (yield and memory)
- [x] Task 3: Tracer bullet: file to plain text on stdout

### Checkpoint 1: Foundation and in-game confirmation of FACTS.md — done

### Phase 2: Parser robustness
- [x] Task 4: Complete tokenizer rules and chunk streaming
- [x] Task 5: Entities and UTF-8 validation
- [x] Task 6: Fuzz generator

### Checkpoint 2: Parser survives fuzzing — done

### Phase 3: Layout
- [x] Task 7: Element handling table
- [x] Task 8: Whitespace, pre and word wrap
- [x] Task 9: Test corpus with expected output and real pages

### Checkpoint 3: Correct text output — done (the in-game real-page check is open, see `tasks/todo.md`)

### Phase 4: Viewer and entry point
- [x] Task 10: Viewer: drawing, status line, scrolling, colors by depth
- [x] Task 11: Entry point: quit prompt, error boundary, screen restore, usage

### Checkpoint 4: MVP complete (all SPEC.md success criteria) — closed by the user on 2026-11-14

## Parallel Work

- Task 2 and Task 5 can run in parallel after Task 1.
- Task 6 needs Task 4. Task 8 needs Task 7.
- Task 10 can start after Checkpoint 2, in parallel with Phase 3, by using fixed test lines.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Stored lines use too much memory on large pages | High | Lines are strings with inline style bytes (80 bytes per line, measured). The guard stops early with a clear message. Measured in 0.0.4a: `lowest_free` hit 0 on large.html at the lines-table doubling from 8192 to 16384 slots (an emergency GC saved it). Fixed: the effective reserve includes the next doubling term 32 * c / 1.8. |
| `os.sleep(0)` slows rendering too much | Low | Measured: 10 ms wall per yield. With one yield per second of CPU, the cost is about 1%. |
| Raw `freeMemory()` readings are up to about 1.3 MB too low (garbage, saw-tooth, measured) and cause a false memory error, as in 0.0.3a on large.html | High | Guard v2 settles: it yields up to 11 times and stops at the first kernel GC (every 10th yield, measured). A rate limit keeps settles few. Only a settle result under the reserve stops the render. If the kernel GC ever stops, the guard stops early with the controlled message. The shim models the saw-tooth and the 10th-yield GC. |
| A long `gsub` or `gmatch` blocks without a yield (679 ms for 64 KB) | High | The tokenizer uses only plain `find` and `byte`, on 4096-byte chunks. |
| Tokens split across chunk edges | High | Unit tests at every edge. Fuzz with 1 to 16 byte chunks. |
| Bad UTF-8 gives wrong widths (`unicode.*` never throws, `utf8.len` accepts surrogates) | Medium | Clean the text before any `unicode.*` call. Test every probe string. |
| Error values are changed in a bad session (run t3) | Low | Controlled errors are strings with the `html: ` prefix. Anything else is handled as unexpected. |
| Shims behave differently from OpenComputers (`unicode.wlen`, `computer.freeMemory`, `utf8`) | Medium | Shims copy `docs/probe/FACTS.md`. In-game checks at every checkpoint. Fix the shim and `FACTS.md` when a difference shows. |
| Only the user can run in-game checks | Medium | Group in-game checks at checkpoints. Write exact steps for each check. |

## Measurements

Release 0.0.4a, measured in game by probe v2 (tier 3 APU, 2 MiB, width 160). Details: `docs/probe/FACTS.md` "Release 0.0.4a stats".

| Value | Wiki page | large.html |
|---|---|---|
| File | 98891 bytes | 1000193 bytes |
| Lines | 182 | 11302 (all) |
| `cpu` | 0.129 s | 3.998 s |
| `wall` | 0.25 s | 4.75 s |
| `free_before` | 1810593 | 1808728 |
| `free_after` | 1802707 | 1056814 |
| `lowest_free` | 701592 | 0 (at the 8192 to 16384 table doubling) |
| `settles` / `gc_seen` / `settle_yields` | 1 / 1 / 6 | 12 / 12 / 118 |

Compared with `FACTS.md`:
- Speed: about 250 KB/s CPU on large.html, 770 KB/s on the wiki page. A 1 MB page renders in about 5 s wall, well under the 10 to 25 s in the success criteria.
- Live cost: about 66.5 scaled units per line, not 160 to 410 as estimated from 0.0.3a. `FACTS.md` is updated.
- ramScale: 1.800 exactly (a table doubling of 131072 real bytes cost 72818 units). `FACTS.md` is updated.

## Decisions

- Builds reach the in-game computer by a fetch from a remote source, in game.
- `tests/real/` holds one GT:NH wiki page, one Wikipedia article and one plain documentation page.
- Expected-output tests compare normalized text. The runner removes `\r`, removes trailing spaces and tabs on each line, and removes blank lines at the end of the output. Every other difference fails, including wrap points, leading spaces and blank lines between blocks.
- The repository stores text files with LF line endings (`.gitattributes`: `* text=auto eol=lf`).
- The one-file installer (`tools/installer.lua`, `tools/mkinstall.lua`, `releases/<version>/html-install.lua`) is release tooling, not part of Task 11 (entry point). It is built by `tools/release.ps1` for every release from 0.0.2a. See SPEC.md "Installer".

- Guard v2 (0.0.4a). The guard settles on the kernel GC: up to 11 yields, stop at the first GC, use the highest reading. A rate limit spaces the settles by the measured live cost per line. Only a settle result under the reserve (192 KB) stops the render. Reason: raw readings are up to about 1.3 MB too low, and the kernel runs a full GC on every 10th yield (measured). Rules: `SPEC.md` "Limits and graceful failure".
- Reserve rule (from probe v2). The effective reserve is max(`MEMORY_RESERVE`, 32 * c / 1.8), where c is the smallest power of two >= the line count (at least 1024). Reason: a lines-table doubling from c to 2c needs about 32 * c / 1.8 units at once, and on large.html free memory hit 0 at the 8192 to 16384 doubling.
- Cost constants (from probe v2). The live cost per line starts at 100 and is never under 80. Measured: about 66.5 per line, 46 to 76 between settles that saw a GC. The old values 410 and 160 came from a wrong 0.0.3a estimate.
- Keys (from probe v2). The standard codes 199, 200, 201, 207, 208 and 209 are always accepted. The NumPad codes 71, 72, 73, 79, 80 and 81 are navigation keys only when char is 0, so a NumPad digit never navigates (user rule). The user's keyboard sends PgUp, PgDn, Home and End as NumPad codes with char 0.
- No forced GC. The guard does not force a GC with an oversized allocation. Reason: the measured kernel GC on every 10th yield is enough, and the trick depends on failed-allocation behavior that is not measured in game. If OpenOS ever stops the 10th-yield GC, the guard fails safe: it stops early with the controlled message.

## Open Questions

None.
