# Tasks: oc-html MVP

Spec: `SPEC.md`. Plan: `tasks/plan.md`.
Test command for every task: `pwsh tests/docker/test.ps1`.

## Phase 1: Foundation

### Task 0: In-game data collector (probe)

**Description:** Build a collector that measures the real machine. Its results replace assumptions in Tasks 2, 3, 8 and 10 and define the shim behavior.

**Acceptance criteria:**
- [x] The probe runs to the end on the default machine with a printed error count.
- [x] The output file has every section.
- [x] The user returned the outputs, and they are saved in `docs/probe/`.

**Verification:**
- [x] Syntax check: `docker run --rm -v "C:/Users/Rain/claude/oc-html/tools:/src:ro" alpine:3.20 sh -c "apk add --no-cache lua5.3 >/dev/null && luac5.3 -p /src/probe.lua && echo OK"`
- [x] Manual check (user, in game): run `probe` and return the output file.

**Note:** The two probe errors are known probe bugs (see `docs/probe/FACTS.md`). The probe stays as it is.

**Dependencies:** None

**Files likely touched:** `tools/probe.lua`, `docs/probe/*.txt`

**Estimated scope:** Medium

### Task 1: Docker test sandbox and runner

**Description:** Build the test image and a sandboxed Lua test runner with OpenOS shims. Every later task uses it.

**Acceptance criteria:**
- [x] `docker build -t oc-html-test tests/docker` succeeds. `pwsh tests/docker/test.ps1` runs and reports "0 failed".
- [x] The container uses every flag in SPEC.md "Sandbox". The repo is read-only. Only `tests/fuzz-failures/` is writable.
- [x] Sandbox self-tests pass: `os.execute`, `io.popen`, `debug` are nil. `io.open` for writing fails. `io.open` outside `tests/` fails. Binary chunks are refused.
- [x] `.gitattributes` contains `* text=auto eol=lf`.
- [x] The shims copy `docs/probe/FACTS.md`: the `unicode.*` results for every probe test string, no `collectgarbage` in the env, and an option for `freeMemory()` jitter.

**Verification:**
- [x] Tests pass: `pwsh tests/docker/test.ps1`
- [x] Manual check: a test that tries to write `/src/x` fails.

**Dependencies:** None (can run in parallel with Task 0)

**Files likely touched:** `tests/docker/Dockerfile`, `tests/docker/test.ps1`, `tests/run.lua`, `tests/shim/computer.lua`, `tests/shim/unicode.lua`, `.gitattributes`

**Estimated scope:** Medium

### Task 2: Guard module (yield and memory)

**Description:** Implement `lib/html/guard.lua` as in SPEC.md: timed yields with `os.clock()` and a memory reserve check that raises a controlled error.

**Acceptance criteria:**
- [x] `tick()` yields when `YIELD_INTERVAL` (1 s of `os.clock()`) has passed, and not before (tested with a fake clock).
- [x] `MEMORY_RESERVE` is 128 KB.
- [x] Below the reserve, `tick()` yields a few times, reads `freeMemory()` again and uses the highest reading. A jitter-only drop does not raise an error (tested with the jitter shim).
- [x] When the settled reading is still below the reserve, `tick()` raises the string error `html: page too large for available memory (rendered N lines before stopping)` with `error(msg, 0)`.
- [x] The module never calls `collectgarbage` and has no other side effects.

**Verification:**
- [x] Tests pass: `pwsh tests/docker/test.ps1`

**Dependencies:** Task 1

**Files likely touched:** `lib/html/guard.lua`, `tests/guard_test.lua`, `tests/shim/computer.lua`

**Estimated scope:** Small

### Task 3: Tracer bullet: file to plain text on stdout

**Description:** Make the thinnest end-to-end path. A minimal tokenizer (tags and text only), a minimal layout (paragraph breaks and wrapping), and `bin/html.lua` that prints lines to stdout inside `xpcall`. Use it in game to confirm the numbers in `docs/probe/FACTS.md` on the real pipeline.

**Acceptance criteria:**
- [x] `tests/cases/basic.html` prints the expected text in the container.
- [x] In game on tier 3: `html basic.html` prints the text. A test page of about 100 KB finishes without a yield error.
- [x] The free memory before and after, and the render time, are recorded in `tasks/plan.md` under a new "Measurements" section and compared with `docs/probe/FACTS.md`.

**Verification:**
- [x] Tests pass: `pwsh tests/docker/test.ps1`
- [x] Manual check (user, in game): run the two pages and report the numbers.

**Dependencies:** Task 2

**Files likely touched:** `bin/html.lua`, `lib/html/tokenizer.lua`, `lib/html/layout.lua`, `tests/cases/basic.html`, `tests/cases/basic.txt`

**Estimated scope:** Medium

### Checkpoint 1: Foundation and in-game confirmation of FACTS.md
- [x] All tests pass.
- [x] The tracer bullet works in game.
- [x] Measurements confirm `docs/probe/FACTS.md`, or `FACTS.md` is updated.
- [x] In game with 0.0.2a: `tests/pages/large.html` (about 1 MB) renders or stops with the controlled memory message, and the stats files of it and of the Wikipedia page are returned (`docs/ingame/task3b.md`). Note: the 0.0.4a run (probe v2) replaces this item. It rendered all 11302 lines of large.html and the whole Wikipedia page.
- [x] Review with the user before Phase 2. The user approved the revisions from the probe v2 results.

## Phase 2: Parser robustness

### Task 4: Complete tokenizer rules and chunk streaming

**Description:** Implement all SPEC.md parsing rules in the tokenizer: comments, doctype, CDATA, processing instructions, quoted, unquoted and broken attributes, raw text for `script` and `style`, and tokens split across chunk edges. Build the tokenizer on plain `string.find` and `string.byte`. Do not run `gsub` or `gmatch` over large strings. Read the file with `io` in 4096-byte chunks.

**Acceptance criteria:**
- [x] Each parsing rule has a unit test.
- [x] The tokenizer uses only plain `string.find` and `string.byte` to scan. No `gsub` or `gmatch` runs over a chunk.
- [x] Every test passes with chunk sizes 1, 2, 7 and 4096.
- [x] No input raises an uncontrolled error.
- [x] Scan choice follows the measured costs (probe v2): plain `find` (about 3.2 us per call) for long jumps (text runs, `-->`, `</script`), `byte` (about 61 ns) inside tags, `sub` (about 260 ns for 80 bytes) to cut the text, and `t[#t+1] = v` for appends (twice as fast as `table.insert`).

**Verification:**
- [x] Tests pass: `pwsh tests/docker/test.ps1`

**Dependencies:** Checkpoint 1

**Files likely touched:** `lib/html/tokenizer.lua`, `tests/tokenizer_test.lua`

**Estimated scope:** Medium

### Task 5: Entities and UTF-8 validation

**Description:** Implement `lib/html/entities.lua` (named and numeric entities) and the text cleaning in SPEC.md "Text cleaning". Cleaning runs before any `unicode.*` call.

**Acceptance criteria:**
- [x] The named entities in SPEC.md, `&#N;` and `&#xN;` decode correctly. Unknown entities stay as written.
- [x] Out-of-range and surrogate code points become `?`.
- [x] Invalid sequences, truncated sequences, overlong forms and encoded surrogates become `?`. Valid multibyte text is unchanged.
- [x] U+00AD, U+200B, U+200C, U+200D, U+200E, U+200F and U+FEFF are removed.
- [x] Control bytes below 0x20 are removed, except tab and newline. `\r` is removed.
- [x] Every probe test string in `docs/probe/FACTS.md` (ascii, é, box, CJK, Japanese, emoji, combining, lone 0x80, truncated, overlong, surrogate, U+200B) has a test.

**Verification:**
- [x] Tests pass: `pwsh tests/docker/test.ps1`

**Dependencies:** Task 1

**Files likely touched:** `lib/html/entities.lua`, `tests/entities_test.lua`, `lib/html/text.lua`, `tests/text_test.lua`

**Estimated scope:** Small

### Task 6: Fuzz generator

**Description:** Implement `tests/fuzz.lua`. It generates random tag soup and mutates corpus files, then runs the pipeline with random chunk sizes from 1 to 16 bytes.

**Acceptance criteria:**
- [x] `pwsh tests/docker/test.ps1 fuzz 1000` runs 1000 documents with a printed seed.
- [x] Any uncontrolled error saves the input and seed to `tests/fuzz-failures/` and fails the run.
- [x] The same seed gives the same documents.

**Verification:**
- [x] Fuzz run: `pwsh tests/docker/test.ps1 fuzz 1000`

**Dependencies:** Task 4, Task 5

**Files likely touched:** `tests/fuzz.lua`

**Estimated scope:** Small

### Checkpoint 2: Parser survives fuzzing
- [x] All tests pass.
- [x] `fuzz 1000` gives zero uncontrolled errors, with three different seeds.
- [x] Every fuzz failure found has become a unit test.
- [x] Review items done: fresh-context review and fixes in 0ae63c5 and in the "Fix minor review leftovers before the MVP release" commit.

## Phase 3: Layout

### Task 7: Element handling table

**Description:** Implement the SPEC.md element table in `layout.lua`: dropped elements, `title` to status, headings, block breaks, `br`, `hr`, emphasis, links, `img` alt text, `li` prefix, and the open-element stack for unclosed and stray tags.

**Acceptance criteria:**
- [x] Each row of the element table has a test.
- [x] Unclosed tags close at the parent end or document end. Stray end tags are ignored.
- [x] Unknown tags are inline and keep their content.

**Verification:**
- [x] Tests pass: `pwsh tests/docker/test.ps1`

**Dependencies:** Checkpoint 2

**Files likely touched:** `lib/html/layout.lua`, `tests/layout_test.lua`

**Estimated scope:** Medium

### Task 8: Whitespace, pre and word wrap

**Description:** Collapse whitespace outside `pre`. Keep it inside `pre`. Wrap the cleaned text at word boundaries to a given width with `unicode.wlen`. Split words longer than the width. The inline style bytes never count toward the width.

**Acceptance criteria:**
- [x] Whitespace tests pass for normal text and `pre`.
- [x] Wrapped lines never exceed the width, including with wide characters.
- [x] Style bytes do not count toward the width.
- [x] Styles stay correct across a wrap.
- [x] Inside `pre`, each tab expands to spaces up to the next 8-column stop before the width is measured (the game draws a tab as a 2-cell glyph). Outside `pre`, the whitespace collapse removes tabs.

**Verification:**
- [x] Tests pass: `pwsh tests/docker/test.ps1`

**Dependencies:** Task 7

**Files likely touched:** `lib/html/layout.lua`, `tests/layout_test.lua`, `tests/shim/unicode.lua`

**Estimated scope:** Small

### Task 9: Test corpus with expected output and real pages

**Description:** Add hand-written cases with expected text in `tests/cases/` and saved real pages in `tests/real/`. The runner compares cases with expected text and checks that real pages render.

**Acceptance criteria:**
- [x] At least 10 hand-written cases cover the element table, broken markup and entities.
- [x] One GT:NH wiki page, one Wikipedia article and one plain documentation page are in `tests/real/` and render more than zero lines without error.
- [x] The comparison removes `\r`, trailing spaces and tabs on each line, and blank lines at the end. Every other difference fails.
- [x] The runner shows a readable diff when a case fails.

**Verification:**
- [x] Tests pass: `pwsh tests/docker/test.ps1`
- [x] Fuzz run: `pwsh tests/docker/test.ps1 fuzz 1000`

**Dependencies:** Task 8

**Files likely touched:** `tests/run.lua`, `tests/cases/*`, `tests/real/*`

**Estimated scope:** Medium

### Checkpoint 3: Correct text output
- [ ] All tests and a fuzz run pass.
- [ ] In game: the real pages print readable text to stdout.
- [ ] Review with the user before Phase 4.

## Phase 4: Viewer and entry point

### Task 10: Viewer: drawing, status line, scrolling, colors by depth

**Description:** Implement `lib/html/viewer.lua` as in SPEC.md "Viewer". Draw the styled lines and a status line. Scroll with Up, Down, PgUp, PgDn, Home and End.

**Acceptance criteria:**
- [x] All scroll keys work and stop at the start and the end.
- [x] The status line shows the title (or file name), the position in percent and the key hint.
- [x] The screen size comes from `gpu.getResolution()`.
- [x] On start, the resolution is set to maxResolution unless `--no-rescale` is given. Tested with a fake GPU that starts at 120x60.
- [x] Depth 8 and 4 show colors as RGB values. Depth 1 shows plain text. No palette indices are used.
- [x] `setForeground` and `setBackground` are called only when the color changes.
- [x] A one-line scroll uses `gpu.copy` and draws only the new row. `copy` leaves the source row, so the new row is always drawn.
- [x] Keys: the standard codes 199, 200, 201, 207, 208 and 209 are always accepted. The NumPad codes 71, 72, 73, 79, 80 and 81 are Home, Up, PgUp, End, Down and PgDn only when char is 0. Tests: NumPad codes with char 0 navigate. NumPad codes with a digit char (for example code 73 with char 57) do not.
- [x] Queued scroll events are added up before a redraw (key repeat: about 28 events per second).
- [x] The color cache keeps the current foreground and background. Same-color calls are skipped.
- [x] On exit, the viewer restores the screen, calls `term.clear()` and sets the cursor.

**Verification:**
- [x] Tests pass: `pwsh tests/docker/test.ps1` (tested with a fake GPU at depth 8, 4 and 1, and at 120x60, 80x25 and 50x16)
- [ ] Manual check (user, in game): scroll a real page on a depth 8, 4 and 1 screen.

**Dependencies:** Checkpoint 2

**Files likely touched:** `lib/html/viewer.lua`, `tests/viewer_test.lua`, `tests/shim/gpu.lua`

**Estimated scope:** Medium

### Task 11: Entry point: quit prompt, error boundary, screen restore, usage

**Description:** Finish `bin/html.lua` and connect the viewer. Add the `q` quit-or-cancel prompt, the file-size check before reading, controlled and uncontrolled error output, `/tmp/html-error.log`, Ctrl+C handling, screen restore on every exit, and usage for `html` and `html --help`.

**Acceptance criteria:**
- [x] `q` shows the prompt. Cancel returns to the page. Quit exits.
- [x] Every exit path (quit, controlled error, uncontrolled error, Ctrl+C) restores the screen, restores the original resolution and leaves a usable shell prompt.
- [x] Argument parsing accepts `--no-rescale`.
- [x] A missing file, a directory or a file too large for free memory gives a one-line message.
- [x] A string error with the prefix `html: ` prints as it is. Any other error prints one line and writes the traceback to `/tmp/html-error.log`.
- [x] `bin/html.lua` takes the traceback function as a parameter. The tests pass a fake one, because the sandbox has no `debug`.
- [x] `/tmp/html-error.log` never exceeds 8 KB. The newest content is kept.
- [x] Ctrl+C: the viewer quits on `key_down` char 3 and on the "interrupted" event from `event.pull` (measured: both arrive, and neither is an error).
- [x] The error log and `--stats-out` writes check `write`, `flush` and `close` (a full `/tmp` fails only at flush or close). Done in bin/html.lua for the stdout mode. Keep it when the viewer is connected.
- [x] The `--stats` lines print after the screen restore.

**Verification:**
- [x] Tests pass: `pwsh tests/docker/test.ps1`
- [ ] Manual check (user, in game): each exit path, and a page of about 1 MB.

**Dependencies:** Task 9, Task 10

**Files likely touched:** `bin/html.lua`, `lib/html/viewer.lua`, `tests/entry_test.lua`

**Estimated scope:** Medium

### Checkpoint 4: MVP complete
- [ ] All 8 success criteria in SPEC.md are met.
- [ ] Optional: memory check on a real low-RAM machine (tier 1 or tier 2 memory).
- [ ] Review with the user.
