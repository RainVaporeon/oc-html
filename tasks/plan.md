# Implementation Plan: oc-html MVP

## Overview

Build the MVP in `SPEC.md`: `html <file>` renders a local HTML file as text on an OpenComputers screen and never crashes on bad input. The plan builds the test sandbox first, then a thin end-to-end path to test in game early, then hardens the parser, then the layout, then the viewer.

Tasks with acceptance criteria are in `tasks/todo.md`.

## Architecture Decisions

- Test sandbox first. Every later task depends on `pwsh tests/docker/test.ps1`.
- Machine facts come from the in-game probe (Task 0). They are in `docs/probe/FACTS.md`. The line format and the guard values are decided from this data, not at Checkpoint 1.
- Tracer bullet early (Task 3). A minimal file-to-text path runs in game before the parser is complete. It confirms the numbers in `docs/probe/FACTS.md` on the real pipeline.
- The guard uses `os.clock()` for the yield timer, `YIELD_INTERVAL` = 1 s and `MEMORY_RESERVE` = 128 KB. Below the reserve it yields, reads `freeMemory()` again and uses the highest reading. It never calls `collectgarbage`.
- Controlled errors are strings with the prefix `html: `. They do not depend on how error tables pass through `pcall` (see run t3 in `FACTS.md`).
- A line is one string with inline style control bytes, not a DOM tree and not a table of styled pieces. Measured: 80 bytes per line.
- The tokenizer uses plain `string.find` and `string.byte` over 4096-byte `io` chunks. No `gsub` or `gmatch` over large strings.
- Text is cleaned before any `unicode.*` call, because `unicode.*` accepts bad bytes silently.
- The fuzz generator comes right after the tokenizer rules. It hardens the parser before layout depends on it.
- Fuzz runs also use very small read chunks (1 to 16 bytes). This catches tokens split across chunk edges.

## Task List

### Phase 1: Foundation
- [x] Task 0: In-game data collector (probe) — done
- [ ] Task 1: Docker test sandbox and runner
- [ ] Task 2: Guard module (yield and memory)
- [ ] Task 3: Tracer bullet: file to plain text on stdout

### Checkpoint 1: Foundation and in-game confirmation of FACTS.md

### Phase 2: Parser robustness
- [ ] Task 4: Complete tokenizer rules and chunk streaming
- [ ] Task 5: Entities and UTF-8 validation
- [ ] Task 6: Fuzz generator

### Checkpoint 2: Parser survives fuzzing

### Phase 3: Layout
- [ ] Task 7: Element handling table
- [ ] Task 8: Whitespace, pre and word wrap
- [ ] Task 9: Test corpus with expected output and real pages

### Checkpoint 3: Correct text output

### Phase 4: Viewer and entry point
- [ ] Task 10: Viewer: drawing, status line, scrolling, colors by depth
- [ ] Task 11: Entry point: quit prompt, error boundary, screen restore, usage

### Checkpoint 4: MVP complete (all SPEC.md success criteria)

## Parallel Work

- Task 2 and Task 5 can run in parallel after Task 1.
- Task 6 needs Task 4. Task 8 needs Task 7.
- Task 10 can start after Checkpoint 2, in parallel with Phase 3, by using fixed test lines.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Stored lines use too much memory on large pages | High | Lines are strings with inline style bytes (80 bytes per line, measured). The guard stops early with a clear message. Checkpoint 1 confirms the numbers. |
| `os.sleep(0)` slows rendering too much | Low | Measured: 10 ms wall per yield. With one yield per second of CPU, the cost is about 1%. |
| `freeMemory()` jitter (up to about 200 KB) causes a false memory error | Medium | The guard yields, reads again and uses the highest reading before it raises the error. The shim simulates the jitter. |
| A long `gsub` or `gmatch` blocks without a yield (679 ms for 64 KB) | High | The tokenizer uses only plain `find` and `byte`, on 4096-byte chunks. |
| Tokens split across chunk edges | High | Unit tests at every edge. Fuzz with 1 to 16 byte chunks. |
| Bad UTF-8 gives wrong widths (`unicode.*` never throws, `utf8.len` accepts surrogates) | Medium | Clean the text before any `unicode.*` call. Test every probe string. |
| Error values are changed in a bad session (run t3) | Low | Controlled errors are strings with the `html: ` prefix. Anything else is handled as unexpected. |
| Shims behave differently from OpenComputers (`unicode.wlen`, `computer.freeMemory`, `utf8`) | Medium | Shims copy `docs/probe/FACTS.md`. In-game checks at every checkpoint. Fix the shim and `FACTS.md` when a difference shows. |
| Only the user can run in-game checks | Medium | Group in-game checks at checkpoints. Write exact steps for each check. |

## Decisions

- Builds reach the in-game computer by a fetch from a remote source, in game.
- `tests/real/` holds one GT:NH wiki page, one Wikipedia article and one plain documentation page.
- Expected-output tests compare normalized text. The runner removes `\r`, removes trailing spaces and tabs on each line, and removes blank lines at the end of the output. Every other difference fails, including wrap points, leading spaces and blank lines between blocks.
- The repository stores text files with LF line endings (`.gitattributes`: `* text=auto eol=lf`).

## Open Questions

None.
